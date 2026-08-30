'use strict';

// Port of Sources/CodeStatusCore/Domain/StateReducer.swift
//
// The canonical state machine. Pure and total: no IO, no clock reads, no shared
// state. Every transition is a function of the current session and one event,
// which is what makes the duplicate/out-of-order/replay behaviour testable.

const { AgentState, StateConfidence } = require('./state');
const { HookEventKind, NotificationType, EventSource } = require('./events');

const Outcome = Object.freeze({
  // State moved. Notifications and HUD updates key off this.
  stateChanged: 'stateChanged',
  // Event accepted and timestamps refreshed, but the state is the same.
  refreshed: 'refreshed',
  // Arrived after a newer event for the same session; dropped.
  ignoredOutOfOrder: 'ignoredOutOfOrder',
  // An event we have no mapping for. Deliberately a no-op.
  ignoredUnmapped: 'ignoredUnmapped',
  // The session already ended; nothing can revive it.
  ignoredEnded: 'ignoredEnded',
});

// The state an event implies, or null if the event carries no state meaning.
//
// Returning null rather than throwing is what keeps us forward compatible: when
// an agent adds a new event, we ignore it instead of misclassifying it.
function targetState(event) {
  switch (event.kind) {
    case HookEventKind.sessionStart:
      // A fresh or resumed session is open and idle, waiting for a prompt.
      return AgentState.free;

    case HookEventKind.userPromptSubmit:
      return AgentState.busy;

    case HookEventKind.preToolUse:
      return AgentState.busy;

    case HookEventKind.postToolUse:
    case HookEventKind.postToolUseFailure:
      // The answer arrived; whatever it was, the agent is moving again.
      return AgentState.busy;

    case HookEventKind.postToolBatch:
      return AgentState.busy;

    case HookEventKind.elicitation:
      // An MCP server is asking, which blocks its tool call exactly the way a
      // permission prompt blocks the turn.
      return AgentState.waitingForInput;

    case HookEventKind.elicitationResult:
      return AgentState.busy;

    case HookEventKind.permissionRequest:
      return AgentState.waitingForApproval;

    case HookEventKind.permissionDenied:
      // The auto-deny already happened; the agent carries on.
      return AgentState.busy;

    case HookEventKind.notification:
      switch (event.notificationType) {
        case NotificationType.permissionPrompt: return AgentState.waitingForApproval;
        case NotificationType.idlePrompt: return AgentState.waitingForInput;
        default: return null;
      }

    case HookEventKind.stop:
      // The *turn* finished. The session stays open and countable.
      return AgentState.free;

    case HookEventKind.stopFailure:
      return AgentState.failed;

    case HookEventKind.subagentStop:
      // A subagent finished; the main turn is still running.
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
      // Process exit is a fact, not an inference — it is the one thing process
      // observation may assert about state.
      return event.kind === HookEventKind.processExited
        ? StateConfidence.high
        : StateConfidence.low;
    case EventSource.reconciliation:
      return StateConfidence.medium;
    default:
      return StateConfidence.low;
  }
}

// Human-readable cause, for the diagnostics screen. Never contains content.
function reasonFor(event) {
  switch (event.kind) {
    case HookEventKind.notification:
      return `Notification(${event.notificationType || 'unknown'}) via ${event.source}`;
    case HookEventKind.processExited:
      return 'Process exited without SessionEnd';
    case HookEventKind.stopFailure:
      return `Turn failed (${event.errorType || 'unknown'})`;
    default:
      return `${event.kind} via ${event.source}`;
  }
}

// Copies metadata an event carries onto the session, without ever overwriting a
// known value with a missing one.
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

// Apply one event to one session. Mutates `session` (the registry already works
// on its own copy) and returns the outcome.
function reduce(session, event) {
  // Nothing revives an ended session — not a straggler from before it ended,
  // and not a recycled pid landing on the same identity.
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
    // Idempotency key, inherited from the event that caused the change.
    // Notifications key off this so one event can never notify twice.
    eventID: event.id,
    source: event.source,
    confidence: session.stateConfidence,
    occurredAt: event.timestamp,
    reason: reasonFor(event),
  };
  return { session, outcome: Outcome.stateChanged, transition };
}

module.exports = { Outcome, targetState, confidenceFor, reduce };
