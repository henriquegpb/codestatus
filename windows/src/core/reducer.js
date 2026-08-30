'use strict';

// Porte de Sources/CodeStatusCore/Domain/StateReducer.swift
//
// A maquina de estados canonica. Pura e total: sem IO, sem leitura de relogio,
// sem estado compartilhado. Toda transicao e funcao da sessao atual + um evento,
// que e o que torna o comportamento de duplicata/fora-de-ordem/replay testavel.

const { AgentState, StateConfidence } = require('./state');
const { HookEventKind, NotificationType, EventSource } = require('./events');

const Outcome = Object.freeze({
  stateChanged: 'stateChanged',
  refreshed: 'refreshed',
  ignoredOutOfOrder: 'ignoredOutOfOrder',
  ignoredUnmapped: 'ignoredUnmapped',
  ignoredEnded: 'ignoredEnded',
});

// O estado que um evento implica, ou null se o evento nao carrega significado
// de estado. Retornar null em vez de lancar erro e o que mantem a
// compatibilidade pra frente: quando um agente adiciona um evento novo, a gente
// ignora em vez de classificar errado.
function targetState(event) {
  switch (event.kind) {
    case HookEventKind.sessionStart:
      // Sessao nova ou retomada esta aberta e ociosa, esperando um prompt.
      return AgentState.free;

    case HookEventKind.userPromptSubmit:
      return AgentState.busy;

    case HookEventKind.preToolUse:
    case HookEventKind.postToolUse:
      return AgentState.busy;

    case HookEventKind.permissionRequest:
      return AgentState.waitingForApproval;

    case HookEventKind.permissionDenied:
      // O auto-deny ja aconteceu; o agente segue em frente.
      return AgentState.busy;

    case HookEventKind.notification:
      switch (event.notificationType) {
        case NotificationType.permissionPrompt: return AgentState.waitingForApproval;
        case NotificationType.idlePrompt: return AgentState.waitingForInput;
        case NotificationType.agentCompleted: return AgentState.free;
        default: return null;
      }

    case HookEventKind.stop:
      // O *turno* acabou. A sessao continua aberta e contavel.
      return AgentState.free;

    case HookEventKind.stopFailure:
      return AgentState.failed;

    case HookEventKind.subagentStop:
      // Um subagente terminou; o turno principal continua rodando.
      return AgentState.busy;

    case HookEventKind.sessionEnd:
    case HookEventKind.processExited:
      return AgentState.ended;

    default:
      return null;
  }
}

function confidenceFor(event) {
  switch (event.source) {
    case EventSource.hook:
      return StateConfidence.high;
    case EventSource.process:
      // Saida de processo e fato, nao inferencia - a unica coisa que a
      // observacao de processo pode afirmar sobre estado.
      return event.kind === HookEventKind.processExited
        ? StateConfidence.high
        : StateConfidence.low;
    case EventSource.reconciliation:
      return StateConfidence.medium;
    default:
      return StateConfidence.low;
  }
}

function reasonFor(event) {
  switch (event.kind) {
    case HookEventKind.notification:
      return `Notification(${event.notificationType || 'unknown'}) via ${event.source}`;
    case HookEventKind.processExited:
      return 'Processo saiu sem SessionEnd';
    case HookEventKind.stopFailure:
      return `Turno falhou (${event.errorType || 'unknown'})`;
    default:
      return `${event.kind} via ${event.source}`;
  }
}

// Copia metadado que o evento carrega para a sessao, sem nunca sobrescrever um
// valor conhecido com um ausente.
function applyEnrichment(event, session) {
  if (event.providerSessionID) session.providerSessionID = event.providerSessionID;
  if (event.providerTurnID) session.providerTurnID = event.providerTurnID;
  if (event.cwd) session.cwd = event.cwd;
  if (event.pid) session.pid = event.pid;
  if (event.model) session.model = event.model;
  if (event.permissionMode) session.permissionMode = event.permissionMode;

  if (event.host && event.host !== 'unknown') {
    session.hostApplication = event.host;
    session.controlTarget.hostApplication = event.host;
  }
  if (event.cwd && !session.controlTarget.workspacePath) {
    session.controlTarget.workspacePath = event.cwd;
  }
}

// Aplica um evento a uma sessao. Muta `session` (o registry ja trabalha sobre
// a sua propria copia) e devolve o desfecho.
function reduce(session, event) {
  // Nada revive uma sessao encerrada - nem um retardatario de antes do fim, nem
  // um pid reciclado caindo na mesma identidade.
  if (session.state === AgentState.ended) {
    return { session, outcome: Outcome.ignoredEnded };
  }

  const target = targetState(event);
  if (target === null) {
    return { session, outcome: Outcome.ignoredUnmapped };
  }

  if (!session.clock.accepts(event)) {
    return { session, outcome: Outcome.ignoredOutOfOrder };
  }

  session.clock.advance(event);
  session.lastEventAt = event.timestamp;
  session.stateConfidence = confidenceFor(event);
  if (event.source === EventSource.hook) session.hasHookEvidence = true;
  applyEnrichment(event, session);

  if (target === session.state) {
    return { session, outcome: Outcome.refreshed };
  }

  const from = session.state;
  session.previousState = from;
  session.state = target;
  session.stateChangedAt = event.timestamp;
  session.lastError = target === AgentState.failed ? (event.errorType || null) : null;

  const transition = {
    sessionID: session.id,
    from,
    to: target,
    eventID: event.id,
    source: event.source,
    confidence: session.stateConfidence,
    occurredAt: event.timestamp,
    reason: reasonFor(event),
  };
  return { session, outcome: Outcome.stateChanged, transition };
}

module.exports = { Outcome, targetState, confidenceFor, reduce };
