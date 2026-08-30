'use strict';

// Port of Sources/CodeStatusCore/Domain/AgentEvent.swift

const EventSource = Object.freeze({
  // An official lifecycle hook from the agent. The source of truth.
  hook: 'hook',
  // Observed process lifecycle. It may report that a session *stopped
  // existing*, but it never invents what the agent is doing internally.
  process: 'process',
  // Produced by the daemon while reconciling after a restart or wake.
  reconciliation: 'reconciliation',
});

const HookEventKind = Object.freeze({
  sessionStart: 'SessionStart',
  userPromptSubmit: 'UserPromptSubmit',
  preToolUse: 'PreToolUse',
  postToolUse: 'PostToolUse',
  permissionRequest: 'PermissionRequest',
  permissionDenied: 'PermissionDenied',
  notification: 'Notification',
  stop: 'Stop',
  stopFailure: 'StopFailure',
  subagentStop: 'SubagentStop',
  sessionEnd: 'SessionEnd',
  // Synthesised locally when the process disappears without a SessionEnd.
  processExited: '__processExited',
});

const KNOWN_EVENT_KINDS = new Set(Object.values(HookEventKind));

// The `notification_type` values we act on.
//
// Claude Code 2.1.247 emits fourteen. Only the two that describe *this*
// session's state are modelled; everything else is deliberately absent so it
// decodes to null and no-ops.
//
// `agent_needs_input` and `agent_completed` are the trap in that list. Both
// read like the signal we want, and neither is about the session whose hook
// fired: they come from the fleet-view watcher and describe some *other* agent
// changing band. Acting on them would mark this session free, or blocked,
// because a different one did.
const NotificationType = Object.freeze({
  permissionPrompt: 'permission_prompt',
  idlePrompt: 'idle_prompt',
});

const AgentProvider = Object.freeze({
  claudeCode: 'claudeCode',
  codex: 'codex',
  generic: 'generic',
});

function providerDisplayName(provider) {
  switch (provider) {
    case AgentProvider.claudeCode: return 'Claude Code';
    case AgentProvider.codex: return 'Codex';
    default: return 'Agent';
  }
}

// Windows has no TERM_PROGRAM as macOS does. The host is inferred from the
// variables Windows terminals actually export.
const HostApplication = Object.freeze({
  windowsTerminal: 'windowsTerminal',
  vsCode: 'vsCode',
  powershell: 'powershell',
  conhost: 'conhost',
  unknown: 'unknown',
});

function hostDisplayName(host) {
  switch (host) {
    case HostApplication.windowsTerminal: return 'Terminal';
    case HostApplication.vsCode: return 'VS Code';
    case HostApplication.powershell: return 'PowerShell';
    case HostApplication.conhost: return 'Console';
    default: return '';
  }
}

// Terminal events are applied unconditionally: a session that has ended cannot
// be revived by a straggler from before it ended.
function isTerminalEvent(event) {
  return event.kind === HookEventKind.sessionEnd
    || event.kind === HookEventKind.processExited;
}

// The event's position *within* a turn. Ranks exist to reject stragglers that
// would regress a session. The gaps that matter:
//  - permissionRequest > preToolUse, so a late PreToolUse does not knock the
//    session out of waitingForApproval and back into busy.
//  - postToolUse > permissionRequest, so the tool running after approval does
//    correctly return the session to busy.
function rankOf(event) {
  switch (event.kind) {
    case HookEventKind.sessionStart: return 0;
    case HookEventKind.userPromptSubmit: return 1;
    case HookEventKind.preToolUse: return 2;
    case HookEventKind.permissionRequest:
    case HookEventKind.permissionDenied: return 3;
    case HookEventKind.notification:
      switch (event.notificationType) {
        case NotificationType.permissionPrompt:
        case NotificationType.idlePrompt: return 3;
        default: return 3;
      }
    case HookEventKind.postToolUse: return 4;
    case HookEventKind.subagentStop: return 5;
    case HookEventKind.stop:
    case HookEventKind.stopFailure: return 8;
    case HookEventKind.sessionEnd:
    case HookEventKind.processExited: return 9;
    default: return 0;
  }
}

module.exports = {
  EventSource,
  HookEventKind,
  KNOWN_EVENT_KINDS,
  NotificationType,
  AgentProvider,
  HostApplication,
  providerDisplayName,
  hostDisplayName,
  isTerminalEvent,
  rankOf,
};
