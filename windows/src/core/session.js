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

function durationMs(session, now) {
  return now - session.stateChangedAt;
}

module.exports = {
  makeSession,
  sessionIDFromProvider,
  sessionIDFromProcess,
  displayName,
  durationMs,
};
