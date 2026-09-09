'use strict';

// Ported from Tests/CodeStatusCoreTests/StateReducerTests.swift. These are the
// invariants that keep the app from lying about what a session is doing.
//
// Kept in step with the Swift suite deliberately: the two implementations are
// separate, so these are the only place a divergence between them can be
// caught. When a case is added there, add it here.

const assert = require('assert');
const { test, run } = require('./harness');

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

function apply(session, events) {
  return events.map((e) => reduce(session, e).outcome);
}

// --- the basic cycle --------------------------------------------------------

test('A whole turn walks discovering -> free -> busy -> free', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.sessionStart),
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
  apply(s, [ev(HookEventKind.stop, { turn: 't1' })]);
  assert.strictEqual(s.state, AgentState.free);
});

test('Stop means the turn ended, not the session — it stays countable', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.free);
});

test('A second turn is ordered after the first', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
    ev(HookEventKind.userPromptSubmit, { turn: 't2' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
});

// --- approval ---------------------------------------------------------------

test('PermissionRequest blocks on approval', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForApproval);
});

test('Approving lets the tool run, returning the session to busy', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
});

test('A late PreToolUse does not knock the session out of waitingForApproval', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForApproval);
});

test('A late PostToolUse does not revive busy after Stop', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.free);
});

// --- blocking on a question, not an approval --------------------------------

test('AskUserQuestion blocks on a reply, not on approval', () => {
  // The state is right that the session is blocked; calling it "needs approval"
  // sends the user to review a command that does not exist.
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1', toolName: 'AskUserQuestion' }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForInput);
});

test('ExitPlanMode blocks on a reply through the permission pipeline too', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1', toolName: 'ExitPlanMode' }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForInput);
});

test('An ordinary tool still blocks on approval', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1', toolName: 'Bash' }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForApproval);
});

test('The whole real sequence of a blocked question stays a question', () => {
  // 2.1.247 emits PreToolUse immediately, PermissionRequest about 3ms later,
  // and Notification(permission_prompt) about six seconds after that. The last
  // one carries no tool_name, and must not get to relabel the first two.
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1', toolName: 'AskUserQuestion' }),
    ev(HookEventKind.permissionRequest, { turn: 't1', toolName: 'AskUserQuestion' }),
    ev(HookEventKind.notification, {
      turn: 't1', notificationType: NotificationType.permissionPrompt,
    }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForInput);
});

// --- tool failure and batches ----------------------------------------------

test('A failing tool closes its tool use', () => {
  // PostToolUseFailure arrives *instead of* PostToolUse. Without it the session
  // sits on whatever the permission check last said, for ever.
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.postToolUseFailure, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
});

test('PostToolBatch closes a batch whose individual result went missing', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.postToolBatch, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
});

test('An MCP elicitation blocks the session and its result releases it', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1', toolName: 'mcp__server__thing' }),
    ev(HookEventKind.elicitation, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForInput);
  apply(s, [ev(HookEventKind.elicitationResult, { turn: 't1' })]);
  assert.strictEqual(s.state, AgentState.busy);
});

// --- notifications ----------------------------------------------------------

test('Notification subtypes map to distinct states', () => {
  const cases = [
    [NotificationType.permissionPrompt, AgentState.waitingForApproval],
    [NotificationType.idlePrompt, AgentState.waitingForInput],
  ];
  for (const [type, expected] of cases) {
    const s = newSession();
    apply(s, [ev(HookEventKind.notification, { notificationType: type })]);
    assert.strictEqual(s.state, expected, `${type} should become ${expected}`);
  }
});

test('idle_prompt still lands after the turn has finished', () => {
  // It means the prompt has been sitting untouched, so it has to outrank Stop.
  // Ranked below it, it was rejected by every session that could produce it —
  // which is every session that has finished a turn.
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
    ev(HookEventKind.notification, { turn: 't1', notificationType: NotificationType.idlePrompt }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForInput);
});

test('permission_prompt is still the backstop when PermissionRequest never came', () => {
  // Ranking it low must not disable it: when the hook was never delivered, this
  // notification is the only evidence that the session is blocked at all.
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.notification, {
      turn: 't1', notificationType: NotificationType.permissionPrompt,
    }),
  ]);
  assert.strictEqual(s.state, AgentState.waitingForApproval);
});

test('A late permission_prompt does not override the request it repeats', () => {
  // Six seconds after PermissionRequest, and without the tool_name that came
  // with it. Rejected as the straggler it is.
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1', toolName: 'Bash' }),
  ]);
  const outcomes = apply(s, [ev(HookEventKind.notification, {
    turn: 't1', notificationType: NotificationType.permissionPrompt,
  })]);
  assert.strictEqual(outcomes[0], Outcome.ignoredOutOfOrder);
});

test('agent_completed is ignored — it is about a different session', () => {
  // The fleet-view watcher raises it when *some other* agent changes band.
  // Acting on it marks this session free because a different one finished.
  const s = newSession();
  apply(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' })]);
  const outcomes = apply(s, [
    ev(HookEventKind.notification, { notificationType: 'agent_completed' }),
  ]);
  assert.strictEqual(outcomes[0], Outcome.ignoredUnmapped);
  assert.strictEqual(s.state, AgentState.busy);
});

test('An unknown Notification subtype is ignored, not guessed', () => {
  const s = newSession();
  apply(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' })]);
  const outcomes = apply(s, [
    ev(HookEventKind.notification, { notificationType: 'agent_needs_input' }),
  ]);
  assert.strictEqual(outcomes[0], Outcome.ignoredUnmapped);
  assert.strictEqual(s.state, AgentState.busy);
});

// --- failure ----------------------------------------------------------------

test('A failed turn is never counted as free', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stopFailure, { turn: 't1', errorType: 'api_error' }),
  ]);
  assert.strictEqual(s.state, AgentState.failed);
  assert.strictEqual(s.lastError, 'api_error');
});

test('Recovering from a failure clears the recorded error', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stopFailure, { turn: 't1', errorType: 'api_error' }),
    ev(HookEventKind.userPromptSubmit, { turn: 't2' }),
  ]);
  assert.strictEqual(s.state, AgentState.busy);
  assert.strictEqual(s.lastError, null);
});

// --- terminality ------------------------------------------------------------

test('SessionEnd wins even when it arrives out of order', () => {
  const s = newSession();
  apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't5' }),
    ev(HookEventKind.sessionEnd, { turn: 't1' }),
  ]);
  assert.strictEqual(s.state, AgentState.ended);
});

test('Process exit ends a session that never sent SessionEnd', () => {
  const s = newSession();
  apply(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' })]);
  apply(s, [ev(HookEventKind.processExited, { source: EventSource.process })]);
  assert.strictEqual(s.state, AgentState.ended);
});

test('Nothing revives an ended session', () => {
  const s = newSession();
  apply(s, [ev(HookEventKind.sessionEnd)]);
  const outcomes = apply(s, [
    ev(HookEventKind.userPromptSubmit, { turn: 't9' }),
    ev(HookEventKind.sessionStart),
  ]);
  assert.deepStrictEqual(outcomes, [Outcome.ignoredEnded, Outcome.ignoredEnded]);
  assert.strictEqual(s.state, AgentState.ended);
});

// --- silence and enrichment -------------------------------------------------

test('Elapsed time never changes the state on its own', () => {
  const s = newSession();
  apply(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1' })]);
  clockMs += 10 * 60 * 1000;
  assert.strictEqual(s.state, AgentState.busy);
});

test('A later event with no metadata never erases what we knew', () => {
  const s = newSession();
  apply(s, [ev(HookEventKind.sessionStart, { cwd: 'C:\\repo\\alpha', model: 'opus' })]);
  assert.strictEqual(s.cwd, 'C:\\repo\\alpha');
  apply(s, [ev(HookEventKind.userPromptSubmit, { turn: 't1', cwd: null, model: null })]);
  assert.strictEqual(s.cwd, 'C:\\repo\\alpha');
  assert.strictEqual(s.model, 'opus');
});

// --- completion notices -----------------------------------------------------

test('A turn that ends counts as a completion', () => {
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.free), true);
});

test('Unblocking and then finishing counts too', () => {
  assert.strictEqual(isTurnCompletion(AgentState.waitingForApproval, AgentState.free), true);
  assert.strictEqual(isTurnCompletion(AgentState.waitingForInput, AgentState.free), true);
});

test('Opening a session does NOT count as a completion', () => {
  // SessionStart also arrives at `free`. Announcing here would say "finished"
  // at the exact moment nothing has started.
  assert.strictEqual(isTurnCompletion(AgentState.discovering, AgentState.free), false);
});

test('Reconnecting after an app restart does NOT count as a completion', () => {
  assert.strictEqual(isTurnCompletion(AgentState.reconnecting, AgentState.free), false);
});

test('Nothing that does not end at free counts as a completion', () => {
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.failed), false);
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.waitingForApproval), false);
  assert.strictEqual(isTurnCompletion(AgentState.busy, AgentState.ended), false);
});

test('A real turn produces exactly one completion', () => {
  const s = newSession();
  const completions = [];
  const events = [
    ev(HookEventKind.sessionStart),
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.preToolUse, { turn: 't1' }),
    ev(HookEventKind.permissionRequest, { turn: 't1' }),
    ev(HookEventKind.postToolUse, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
  ];
  for (const e of events) {
    const r = reduce(s, e);
    if (r.outcome === Outcome.stateChanged
      && isTurnCompletion(r.transition.from, r.transition.to)) {
      completions.push(r.transition);
    }
  }
  assert.strictEqual(completions.length, 1, 'should announce once, at Stop');
  assert.strictEqual(completions[0].from, AgentState.busy);
});

// --- registry ---------------------------------------------------------------

test('Replaying an identical stream is a no-op after the first pass', () => {
  const events = [
    ev(HookEventKind.sessionStart),
    ev(HookEventKind.userPromptSubmit, { turn: 't1' }),
    ev(HookEventKind.stop, { turn: 't1' }),
  ];
  const registry = new SessionRegistry();
  for (const e of events) registry.apply(e);
  const stateAfterFirst = registry.get('claudeCode:sess-1').state;

  const second = events.flatMap((e) => registry.apply(e));
  assert.ok(second.every((eff) => eff.type === 'eventDropped' && eff.reason === 'duplicate'));
  assert.strictEqual(registry.get('claudeCode:sess-1').state, stateAfterFirst);
});

test('Only sessions with hook evidence enter the counts', () => {
  const registry = new SessionRegistry();
  registry.apply(ev(HookEventKind.userPromptSubmit, { turn: 't1' }));
  assert.strictEqual(registry.counts().busy, 1);
  assert.strictEqual(registry.visible.length, 1);
  assert.strictEqual(registry.unreported.length, 0);
});

test('A discovered process counts as unreported, never as a session', () => {
  const registry = new SessionRegistry();
  registry.observeProcess({
    pid: 9001, provider: AgentProvider.claudeCode, startTime: 1, now: clockMs,
  });
  assert.strictEqual(registry.unreported.length, 1);
  assert.strictEqual(registry.visible.length, 0, 'we know it exists, not what it is doing');
});

test('Observing the same process twice adds one session', () => {
  const registry = new SessionRegistry();
  const args = {
    pid: 9002, provider: AgentProvider.claudeCode, startTime: 1, now: clockMs,
  };
  registry.observeProcess(args);
  registry.observeProcess(args);
  assert.strictEqual(registry.unreported.length, 1);
});

test('A hook from a discovered pid stops it being counted as unreported', () => {
  const registry = new SessionRegistry();
  registry.observeProcess({
    pid: 4242, provider: AgentProvider.claudeCode, startTime: 1, now: clockMs,
  });
  assert.strictEqual(registry.unreported.length, 1);
  registry.apply(ev(HookEventKind.userPromptSubmit, { turn: 't1', pid: 4242 }));
  assert.strictEqual(registry.unreported.length, 0, 'same session, seen twice');
  assert.strictEqual(registry.visible.length, 1);
});

test('Both sessions behind one pid can be ended, not just the newer one', () => {
  // A pid carries two identities: the one the scan discovered, and the one its
  // hooks later reported under the agent's own session id. Routing an exit by
  // pid only ever reaches the second, and the first would sit in the registry
  // for the lifetime of the app. So the liveness check addresses each by name.
  const registry = new SessionRegistry();
  registry.observeProcess({
    pid: 4242, provider: AgentProvider.claudeCode, startTime: 7, now: clockMs,
  });
  registry.apply(ev(HookEventKind.userPromptSubmit, { turn: 't1', pid: 4242 }));

  const ids = registry.all.map((s) => s.id);
  assert.strictEqual(ids.length, 2, 'the same pid seen two ways');

  for (const id of ids) {
    registry.apply({
      ...ev(HookEventKind.processExited, { source: EventSource.process, pid: 4242 }),
      targetSessionID: id,
    });
  }
  assert.ok(registry.all.every((s) => s.state === AgentState.ended), 'both should be ended');
});

test('An exit addressed at a session we never had is dropped', () => {
  const registry = new SessionRegistry();
  const effects = registry.apply({
    ...ev(HookEventKind.processExited, { source: EventSource.process, pid: 1 }),
    targetSessionID: 'claudeCode:ghost',
  });
  assert.strictEqual(effects[0].type, 'eventDropped');
  assert.strictEqual(registry.all.length, 0, 'nothing is created just to mark it ended');
});

test('An ended session leaves the counts', () => {
  const registry = new SessionRegistry();
  registry.apply(ev(HookEventKind.userPromptSubmit, { turn: 't1' }));
  registry.apply(ev(HookEventKind.sessionEnd));
  assert.strictEqual(registry.counts().busy, 0);
  assert.strictEqual(registry.visible.length, 0);
});

test('A dismissed session does not come back on the next event', () => {
  const registry = new SessionRegistry();
  registry.apply(ev(HookEventKind.userPromptSubmit, { turn: 't1' }));
  assert.strictEqual(registry.visible.length, 1);
  registry.forget('claudeCode:sess-1');
  assert.strictEqual(registry.visible.length, 0);
  registry.apply(ev(HookEventKind.postToolUse, { turn: 't1' }));
  assert.strictEqual(registry.visible.length, 0, 'dismissing has to stick');
});

run('reducer');
