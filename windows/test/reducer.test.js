'use strict';

// Porte dos casos de Tests/CodeStatusCoreTests/StateReducerTests.swift.
// Sao os invariantes que impedem o app de mentir sobre o estado de uma sessao.

const assert = require('assert');

const { AgentState, isTurnCompletion } = require('../src/core/state');
const {
  HookEventKind, NotificationType, EventSource, AgentProvider, HostApplication,
} = require('../src/core/events');
const { reduce, Outcome } = require('../src/core/reducer');
const { makeSession } = require('../src/core/session');
const { SessionRegistry } = require('../src/core/registry');

let counter = 0;
let clockMs = 1_700_000_000_000;

function ev(kind, extra = {}) {
  counter += 1;
  clockMs += 1000;
  return {
    id: extra.id || `e${counter}`,
    provider: AgentProvider.claudeCode,
    kind,
    source: extra.source || EventSource.hook,
    timestamp: extra.timestamp || clockMs,
    providerSessionID: 'sess-1',
    providerTurnID: extra.turn === undefined ? null : extra.turn,
    notificationType: extra.notificationType || null,
    toolName: extra.toolName || null,
    toolUseID: null,
    startReason: null,
    endReason: null,
    errorType: extra.errorType || null,
    permissionMode: null,
    model: extra.model || null,
    cwd: extra.cwd === undefined ? null : extra.cwd,
    pid: extra.pid === undefined ? 4242 : extra.pid,
    host: extra.host || HostApplication.unknown,
    processStartTime: null,
  };
}

function newSession(state = AgentState.discovering) {
  return makeSession({
    id: 'claudeCode:sess-1',
    provider: AgentProvider.claudeCode,
    now: clockMs,
    sourceAdapter: 'test',
    state,
  });
}

function run(session, events) {
  const outcomes = [];
  for (const e of events) outcomes.push(reduce(session, e).outcome);
  return outcomes;
}

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// --- ciclo basico ------------------------------------------------------------

test('Um turno completo caminha discovering -> free -> busy -> free', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.sessionStart),
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
  run(s, [ev(HookEventKind.stop, { turn: 't1' })]);
  assert.strictEqual(s.state, AgentState.free);
});

test('Stop significa que o turno acabou, nao a sessao - ela continua contavel', () => {
  const s = newSession();
  run(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' }), ev(HookEventKind.stop, { turn: 't1' })]);
  assert.strictEqual(s.state, AgentState.free);
  assert.notStrictEqual(s.state, AgentState.ended);
});

test('Um segundo turno e ordenado depois do primeiro', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
    ev(HookEventKind.userPromptSubmit, { turn: 't2' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
});

// --- aprovacao ---------------------------------------------------------------

test('PermissionRequest bloqueia aguardando aprovacao', () => {
  const s = newSession();
  run(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' }), ev(HookEventKind.permissionRequest, { turn: 't1' })]);
  assert.strictEqual(s.state, AgentState.waitingForApproval);
});

test('Aprovar deixa a ferramenta rodar, devolvendo a sessao para busy', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
});

test('Um PreToolUse atrasado nao tira a sessao de waitingForApproval', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForApproval);
});

test('Um PostToolUse atrasado nao ressuscita busy depois do Stop', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.free);
});

// --- notificacoes ------------------------------------------------------------

test('Subtipos de Notification mapeiam para estados distintos', () => {
  const cases = [
    [NotificationType.permissionPrompt, AgentState.waitingForApproval],
    [NotificationType.idlePrompt, AgentState.waitingForInput],
    [NotificationType.agentCompleted, AgentState.free],
  ];
  for (const [type, expected] of cases) {
    const s = newSession();
    run(s, [ev(HookEventKind.notification, { notificationType: type })]);
    assert.strictEqual(s.state, expected, `${type} deveria virar ${expected}`);
  }
});

test('Um subtipo de Notification desconhecido e ignorado, nao chutado', () => {
  const s = newSession();
  run(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' })]);
  const outcomes = run(s, [ev(HookEventKind.notification, { notificationType: 'agent_needs_input' })]);
  assert.strictEqual(outcomes[0], Outcome.ignoredUnmapped);
  assert.strictEqual(s.state, AgentState.busy);
});

// --- falha -------------------------------------------------------------------

test('Um turno que falhou nunca e contado como livre', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stopFailure, { turn: 't1', errorType: 'api_error' }),
  ]);
  assert.strictEqual(s.state, AgentState.failed);
  assert.notStrictEqual(s.state, AgentState.free);
  assert.strictEqual(s.lastError, 'api_error');
});

test('Recuperar da falha limpa o erro registrado', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stopFailure, { turn: 't1', errorType: 'api_error' }),
    ev(HookEventKind.userPromptSubmit, { turn: 't2' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
  assert.strictEqual(s.lastError, null);
});

// --- terminalidade -----------------------------------------------------------

test('SessionEnd vence mesmo chegando fora de ordem', () => {
  const s = newSession();
  run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't5' }),
    ev(HookEventKind.sessionEnd, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.ended);
});

test('A saida do processo encerra uma sessao que nunca mandou SessionEnd', () => {
  const s = newSession();
  run(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' })]);
  run(s, [ev(HookEventKind.processExited, { source: EventSource.process })]);
  assert.strictEqual(s.state, AgentState.ended);
});

test('Nada revive uma sessao encerrada', () => {
  const s = newSession();
  run(s, [ev(HookEventKind.sessionEnd)]);
  const outcomes = run(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't9' }),
    ev(HookEventKind.sessionStart),
  ]);
  assert.deepStrictEqual(outcomes, [Outcome.ignoredEnded, Outcome.ignoredEnded]);
  assert.strictEqual(s.state, AgentState.ended);
});

// --- silencio e enriquecimento ----------------------------------------------

test('Tempo parado nunca muda o estado sozinho', () => {
  const s = newSession();
  run(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' })]);
  const before = s.state;
  clockMs += 10 * 60 * 1000;
  assert.strictEqual(s.state, before);
  assert.strictEqual(s.state, AgentState.busy);
});

test('Um evento posterior sem metadado nunca apaga o que ja sabiamos', () => {
  const s = newSession();
  run(s, [ev(HookEventKind.sessionStart, { cwd: 'C:\\repo\\alpha', model: 'opus' })]);
  assert.strictEqual(s.cwd, 'C:\\repo\\alpha');
  run(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1', cwd: null, model: null })]);
  assert.strictEqual(s.cwd, 'C:\\repo\\alpha');
  assert.strictEqual(s.model, 'opus');
});

// --- aviso de conclusao ------------------------------------------------------

test('Um turno que termina conta como conclusao', () => {
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.free), true);
});

test('Destravar e terminar tambem conta como conclusao', () => {
  assert.strictEqual(isTurnCompletion(AgentState.waitingForApproval, AgentState.free), true);
  assert.strictEqual(isTurnCompletion(AgentState.waitingForInput, AgentState.free), true);
});

test('Abrir uma sessao NAO conta como conclusao', () => {
  // SessionStart tambem chega em `free`. Avisar aqui diria "terminou" no exato
  // momento em que nada comecou.
  assert.strictEqual(isTurnCompletion(AgentState.discovering, AgentState.free), false);
});

test('Reconectar apos reiniciar o app NAO conta como conclusao', () => {
  assert.strictEqual(isTurnCompletion(AgentState.reconnecting, AgentState.free), false);
});

test('Nada que nao termine em livre conta como conclusao', () => {
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.failed), false);
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.waitingForApproval), false);
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.ended), false);
});

test('O fluxo real de um turno produz exatamente uma conclusao', () => {
  const s = newSession();
  const conclusoes = [];
  const eventos = [
    ev(HookEventKind.sessionStart),
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
  ];
  for (const e of eventos) {
    const r = reduce(s, e);
    if (r.outcome === Outcome.stateChanged
      && isTurnCompletion(r.transition.from, r.transition.to)) {
      conclusoes.push(r.transition);
    }
  }
  assert.strictEqual(conclusoes.length, 1, 'deveria avisar uma vez, no Stop');
  assert.strictEqual(conclusoes[0].from, AgentState.busy);
});

// --- registry ----------------------------------------------------------------

test('Reproduzir um fluxo identico e no-op depois da primeira passada', () => {
  const events = [
    ev(HookEventKind.sessionStart),
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
  ];
  const registry = new SessionRegistry();
  for (const e of events) registry.apply(e);
  const stateAfterFirst = registry.get('claudeCode:sess-1').state;

  // Mesmos ids: o deduplicador precisa descartar tudo.
  const second = events.flatMap((e) => registry.apply(e));
  assert.ok(second.every((eff) => eff.type === 'eventDropped' && eff.reason === 'duplicate'));
  assert.strictEqual(registry.get('claudeCode:sess-1').state, stateAfterFirst);
});

test('So sessoes com evidencia de hook entram nos contadores', () => {
  const registry = new SessionRegistry();
  registry.apply(ev(HookEventKind.userPromptSubmit, { turn: 't1' }));
  assert.strictEqual(registry.counts().busy, 1);
  assert.strictEqual(registry.visible.length, 1);
  assert.strictEqual(registry.unreported.length, 0);
});

test('Uma sessao encerrada sai dos contadores', () => {
  const registry = new SessionRegistry();
  registry.apply(ev(HookEventKind.userPromptSubmit, { turn: 't1' }));
  registry.apply(ev(HookEventKind.sessionEnd));
  assert.strictEqual(registry.counts().busy, 0);
  assert.strictEqual(registry.visible.length, 0);
});

// --- execucao ----------------------------------------------------------------

let failed = 0;
for (const [name, fn] of tests) {
  try {
    fn();
    console.log(`  ok   ${name}`);
  } catch (err) {
    failed += 1;
    console.log(`  FALHOU ${name}`);
    console.log(`         ${err.message}`);
  }
}
console.log(`\n${tests.length - failed}/${tests.length} passaram`);
process.exit(failed === 0 ? 0 : 1);
