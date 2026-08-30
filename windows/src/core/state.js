'use strict';

// Port of Sources/CodeStatusCore/Domain/AgentState.swift
//
// The canonical vocabulary for the whole app. There is no isBusy/isDone/
// needsApproval scattered around: every surface (tray, HUD, notifications)
// derives what it shows from here. Absence of evidence is represented
// explicitly (unknown, reconnecting) rather than guessed.

const AgentState = Object.freeze({
  discovering: 'discovering',
  busy: 'busy',
  free: 'free',
  waitingForApproval: 'waitingForApproval',
  waitingForInput: 'waitingForInput',
  failed: 'failed',
  reconnecting: 'reconnecting',
  unknown: 'unknown',
  ended: 'ended',
});

const StateBucket = Object.freeze({
  free: 'free',
  busy: 'busy',
  needsYou: 'needsYou',
  indeterminate: 'indeterminate',
  gone: 'gone',
});

// `failed` counts here — an error must never be presented as "free".
function needsAttention(state) {
  return state === AgentState.waitingForApproval
    || state === AgentState.waitingForInput
    || state === AgentState.failed;
}

function isActive(state) {
  return state !== AgentState.ended;
}

// Whether a transition represents a turn that just finished.
//
// Arriving at `free` is not enough: a SessionStart also arrives at `free`,
// because a freshly opened session is idle waiting for a prompt. Announcing
// there would say "finished" at the exact moment nothing has started.
//
// What characterises completion is the *origin*: only something that was in
// progress can finish — working, or stopped waiting for you to unblock it.
function isTurnCompletion(from, to) {
  if (to !== AgentState.free) return false;
  return from === AgentState.busy
    || from === AgentState.waitingForApproval
    || from === AgentState.waitingForInput;
}

function bucketOf(state) {
  switch (state) {
    case AgentState.free:
      return StateBucket.free;
    case AgentState.busy:
      return StateBucket.busy;
    case AgentState.waitingForApproval:
    case AgentState.waitingForInput:
    case AgentState.failed:
      return StateBucket.needsYou;
    case AgentState.discovering:
    case AgentState.reconnecting:
    case AgentState.unknown:
      return StateBucket.indeterminate;
    case AgentState.ended:
    default:
      return StateBucket.gone;
  }
}

// Confidence decays with silence; the state does not. A session quiet for ten
// minutes in the middle of a tool call is still busy — only the confidence drops.
const StateConfidence = Object.freeze({ low: 0, medium: 1, high: 2 });

// The same words the macOS app uses, so a screenshot of either reads the same.
const LABELS = Object.freeze({
  discovering: 'Discovering',
  busy: 'Busy',
  free: 'Free',
  waitingForApproval: 'Needs approval',
  waitingForInput: 'Needs a reply',
  failed: 'Failed',
  reconnecting: 'Reconnecting',
  unknown: 'Unknown',
  ended: 'Ended',
});

// How much a session wants the user, for list ordering. Mirrors the sort the
// macOS popover applies: what needs you first, then work in progress.
function displayPriority(state) {
  switch (state) {
    case AgentState.waitingForApproval:
    case AgentState.waitingForInput:
      return 5;
    case AgentState.failed:
      return 4;
    case AgentState.busy:
      return 3;
    case AgentState.free:
      return 2;
    default:
      return 1;
  }
}

module.exports = {
  AgentState,
  StateBucket,
  StateConfidence,
  needsAttention,
  isActive,
  isTurnCompletion,
  bucketOf,
  displayPriority,
  LABELS,
};
