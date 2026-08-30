'use strict';

// Porte de Sources/CodeStatusCore/Runtime/SessionRegistry.swift
//
// A unica fonte de verdade sobre quais sessoes existem e o que estao fazendo.
// Bandeja, HUD, notificacoes e diagnostico leem daqui; nenhum deles mantem a
// propria ideia de estado.

const { AgentState, isActive, bucketOf, StateBucket } = require('./state');
const { HookEventKind, EventSource } = require('./events');
const { EventDeduplicator } = require('./dedup');
const { reduce, Outcome } = require('./reducer');
const {
  makeSession,
  sessionIDFromProvider,
  sessionIDFromProcess,
} = require('./session');

const DropReason = Object.freeze({
  duplicate: 'duplicate',
  outOfOrder: 'outOfOrder',
  unmapped: 'unmapped',
  sessionAlreadyEnded: 'sessionAlreadyEnded',
  unroutable: 'unroutable',
});

// Quanto tempo uma sessao encerrada permanece antes de ser removida, para o HUD
// conseguir mostrar a transicao em vez de a linha sumir na hora.
const ENDED_GRACE_MS = 8000;

class SessionRegistry {
  constructor(dedupCapacity = 4096) {
    this.sessions = new Map();
    this.dedup = new EventDeduplicator(dedupCapacity);
    // Roteia eventos que identificam a sessao so por processo, como saidas
    // reportadas pelo observador de processos.
    this.pidIndex = new Map();
  }

  get all() {
    return Array.from(this.sessions.values());
  }

  get(id) {
    return this.sessions.get(id);
  }

  // Sessoes que o HUD lista, ordenadas por quanto querem o usuario: primeiro as
  // que precisam de atencao, depois as ocupadas, depois o resto.
  //
  // Somente sessoes sobre as quais um agente de fato reportou. Uma sessao achada
  // varrendo processos prova que algo esta rodando; nao diz nada sobre o que
  // esse algo esta fazendo, e lista-la como "desconhecido" pra sempre dilui a
  // unica pergunta que o HUD existe pra responder.
  get visible() {
    return this.all
      .filter((s) => isActive(s.state) && s.hasHookEvidence)
      .sort((a, b) => {
        const pa = displayPriority(a.state);
        const pb = displayPriority(b.state);
        if (pa !== pb) return pb - pa;
        return b.stateChangedAt - a.stateChangedAt;
      });
  }

  // Sessoes vivas sobre as quais nenhum agente reportou ainda. Exposto como
  // contagem em vez de escondido: omitir em silencio um agente rodando seria
  // sua propria forma de desonestidade. Normalmente significa que os hooks
  // foram instalados depois da sessao comecar.
  get unreported() {
    const reportingPIDs = new Set(
      this.all.filter((s) => s.hasHookEvidence && s.pid).map((s) => s.pid),
    );
    return this.all.filter((s) => {
      if (!isActive(s.state) || s.hasHookEvidence) return false;
      if (!s.pid) return true;
      return !reportingPIDs.has(s.pid);
    });
  }

  counts() {
    const out = { free: 0, busy: 0, needsYou: 0, indeterminate: 0 };
    for (const s of this.visible) {
      const b = bucketOf(s.state);
      if (b !== StateBucket.gone) out[b] += 1;
    }
    return out;
  }

  // Aplica um evento. Devolve a lista de efeitos para o app reagir.
  apply(event) {
    const effects = [];

    if (!this.dedup.admit(event.id)) {
      effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.duplicate });
      return effects;
    }

    const id = this.routeToSessionID(event);
    if (!id) {
      effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.unroutable });
      return effects;
    }

    let session = this.sessions.get(id);
    let added = false;
    if (!session) {
      // Um evento terminal para uma sessao que nunca vimos nao cria sessao -
      // criar so pra marcar como encerrada faria linhas fantasma piscarem.
      if (event.kind === HookEventKind.sessionEnd || event.kind === HookEventKind.processExited) {
        effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.unroutable });
        return effects;
      }
      session = makeSession({
        id,
        provider: event.provider,
        now: event.timestamp,
        sourceAdapter: event.source,
      });
      this.sessions.set(id, session);
      added = true;
    }

    const result = reduce(session, event);

    if (session.pid) this.pidIndex.set(session.pid, id);

    if (added) effects.push({ type: 'sessionAdded', sessionID: id });

    switch (result.outcome) {
      case Outcome.stateChanged:
        effects.push({ type: 'sessionChanged', transition: result.transition });
        if (result.transition.to === AgentState.ended) {
          session.endedAt = event.timestamp;
        }
        break;
      case Outcome.refreshed:
        effects.push({ type: 'sessionRefreshed', sessionID: id });
        break;
      case Outcome.ignoredOutOfOrder:
        effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.outOfOrder });
        break;
      case Outcome.ignoredUnmapped:
        effects.push({ type: 'eventDropped', eventID: event.id, reason: DropReason.unmapped });
        break;
      case Outcome.ignoredEnded:
        effects.push({
          type: 'eventDropped',
          eventID: event.id,
          reason: DropReason.sessionAlreadyEnded,
        });
        break;
      default:
        break;
    }

    return effects;
  }

  // Identidade preferida e o session id do proprio agente; o pid so entra
  // quando nao ha nenhum, como nas saidas detectadas pelo watcher.
  routeToSessionID(event) {
    if (event.providerSessionID) {
      return sessionIDFromProvider(event.provider, event.providerSessionID);
    }
    if (event.pid) {
      const known = this.pidIndex.get(event.pid);
      if (known) return known;
      if (event.source === EventSource.process) {
        // Uma saida de processo que nao mapeia pra nenhuma sessao conhecida nao
        // tem o que encerrar.
        return null;
      }
      return sessionIDFromProcess(event.provider, event.pid, event.processStartTime || 0);
    }
    return null;
  }

  // Remove sessoes encerradas depois do periodo de gracia.
  sweep(now = Date.now()) {
    const removed = [];
    for (const [id, s] of this.sessions) {
      if (s.state === AgentState.ended && s.endedAt && now - s.endedAt > ENDED_GRACE_MS) {
        this.sessions.delete(id);
        if (s.pid) this.pidIndex.delete(s.pid);
        removed.push(id);
      }
    }
    return removed;
  }

  // Snapshot serializavel para persistir entre reinicios do app.
  toJSON() {
    return {
      version: 1,
      savedAt: Date.now(),
      sessions: this.all.map((s) => ({ ...s, clock: s.clock.toJSON() })),
    };
  }
}

function displayPriority(state) {
  switch (state) {
    case AgentState.waitingForApproval: return 5;
    case AgentState.waitingForInput: return 5;
    case AgentState.failed: return 4;
    case AgentState.busy: return 3;
    case AgentState.free: return 2;
    default: return 1;
  }
}

module.exports = { SessionRegistry, DropReason, ENDED_GRACE_MS };
