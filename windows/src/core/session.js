'use strict';

// Port of AgentSession (Sources/CodeStatusCore/Domain/AgentSession.swift)

const path = require('path');
const { AgentState, StateConfidence } = require('./state');
const { HostApplication, providerDisplayName } = require('./events');
const { LogicalClock } = require('./clock');

// Preferred identity: the agent told us its own session id.
function sessionIDFromProvider(provider, sessionID) {
  return `${provider}:${sessionID}`;
}

// Fallback when there is no provider session id. The start time is part of the
// key because pids are recycled — the pid alone would let a new process inherit
// a dead session's state.
function sessionIDFromProcess(provider, pid, startTime) {
  return `${provider}:pid-${pid}-${startTime || 0}`;
}

function makeSession({
  id, provider, now, sourceAdapter, state = AgentState.discovering,
}) {
  return {
    id,
    provider,
    providerSessionID: null,
    providerTurnID: null,

    state,
    previousState: null,
    stateConfidence: StateConfidence.low,
    stateChangedAt: now,
    startedAt: now,
    lastEventAt: now,

    pid: null,
    // Milliseconds since the epoch, when the OS says the process started.
    // Distinct from startedAt, which is when *we* first saw it — the diagnosis
    // needs the former to date a session against a hook install.
    processStartTime: null,

    cwd: null,
    repositoryName: null,
    workspaceName: null,
    // The name the agent gave this session itself — Claude Code's
    // custom-title, Codex's thread_name. Enrichment, never identity: it
    // arrives a turn or two after the session does, it never arrives at all
    // for `codex exec`, and it is read from the agent's own transcript store
    // rather than from a hook. Everything that has to be correct stays on
    // displayName, which does not consult it.
    //
    // Held in memory only. The persisted snapshot leaves it out, exactly as
    // AgentSession's CodingKeys do on macOS, so the one file this app writes
    // stays free of anything the model composed.
    sessionTitle: null,
    model: null,
    permissionMode: null,

    hostApplication: HostApplication.unknown,

    sourceAdapter,
    controlTarget: { hostApplication: HostApplication.unknown, workspacePath: null },
    lastError: null,

    // Whether any official hook has arrived for this session. This is the
    // distinction the HUD is built on: process discovery proves the session
    // *exists*; only a hook says what it is doing.
    hasHookEvidence: false,

    clock: new LogicalClock(),
  };
}

// A drive root (C:\) would become a label that looks like a bug rather than a
// name, so it is rejected in favour of the provider name.
function isDriveRoot(component) {
  return !component || component === path.sep || /^[A-Za-z]:\\?$/.test(component);
}

// Best available human label: repo, then workspace, then the last component of
// the working directory.
function displayName(session) {
  if (session.repositoryName) return session.repositoryName;
  if (session.workspaceName) return session.workspaceName;
  if (session.cwd) {
    const component = path.basename(session.cwd);
    if (!isDriveRoot(component)) return component;
  }
  return providerDisplayName(session.provider);
}

// The agent's own name for this session, normalised so that a title which is
// present but empty reads as absent everywhere it is consulted.
function agentTitle(session) {
  return session.sessionTitle || null;
}

// What the row leads with: the agent's own title when there is one.
//
// Three sessions in the same repository are three rows reading `backend`,
// which is the one case where the location is no help at all — so when the
// agent has named the session, that name goes first and the location moves to
// secondaryLabel rather than being dropped.
function primaryLabel(session) {
  return agentTitle(session) || displayName(session);
}

// The location, but only once the title has taken the line above it. Null
// without a title, so the caller cannot render the same string twice.
function secondaryLabel(session) {
  return agentTitle(session) ? displayName(session) : null;
}

// A toast body, led by the agent's own name for the session.
//
// The toast's first line stays the repository, for two reasons. It is what
// survives when Windows collapses a stack of notifications into the Action
// Center. And it is the wrong place for text the model composed out of a
// conversation, which a toast shows on a lock screen whether or not the room
// is empty.
//
// The body is where the ambiguity actually needed solving: three sessions in
// one repository produce three identical toasts, and a notification is the
// surface that makes you stop what you are doing.
function announcement(session, sentence) {
  const title = agentTitle(session);
  return title ? `${title} — ${sentence}` : sentence;
}

function durationMs(session, now) {
  return now - session.stateChangedAt;
}

module.exports = {
  makeSession,
  sessionIDFromProvider,
  sessionIDFromProcess,
  displayName,
  agentTitle,
  primaryLabel,
  secondaryLabel,
  announcement,
  durationMs,
};
