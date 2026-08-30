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
  // A tool that ended in an error. Its *replacement* for PostToolUse, not a
  // companion to it — a failing tool emits this and nothing else, so without it
  // a failed tool use never closes and the session sits on whatever the
  // permission check last said.
  postToolUseFailure: 'PostToolUseFailure',
  // Every tool in a parallel batch has settled. Mostly redundant, and worth
  // having anyway: it still closes a batch when an individual result was lost.
  postToolBatch: 'PostToolBatch',
  permissionRequest: 'PermissionRequest',
  permissionDenied: 'PermissionDenied',
  notification: 'Notification',
  // An MCP server is asking the user something and the tool call is blocked
  // until they answer.
  elicitation: 'Elicitation',
  elicitationResult: 'ElicitationResult',
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

// Tools whose *call* is the question, rather than an action awaiting consent.
//
// Claude Code routes these through the ordinary permission pipeline: they
// declare requiresUserInteraction(), which forces `behavior: "ask"` whatever
// the permission mode says. Without this list they land on waitingForApproval,
// which tells the user to go review a command that does not exist.
//
// Not exhaustive by construction: an MCP server can mark its own tools with
// `anthropic/requiresUserInteraction`, and those names cannot be known here.
// They keep landing on approval, which stays true enough — blocked is blocked.
const TOOLS_THAT_ASK_THE_USER = new Set(['AskUserQuestion', 'ExitPlanMode']);

function asksTheUser(event) {
  return Boolean(event.toolName) && TOOLS_THAT_ASK_THE_USER.has(event.toolName);
}

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
    // An MCP server's question arrives *after* its tool's permission check and
    // carries neither tool_name nor tool_use_id, so it rides in the step that
    // check opened. Equal rank is what lets it in there.
    case HookEventKind.elicitation: return 3;
    case HookEventKind.notification:
      switch (event.notificationType) {
        // permission_prompt is the same fact as PermissionRequest, announced
        // about six seconds later and without the tool_name that tells a
        // question apart from an approval. Ranking it just below
        // permissionRequest keeps it in its proper role — the backstop that
        // fires when that hook was never delivered — instead of arriving late
        // to relabel a question as an approval.
        case NotificationType.permissionPrompt: return 2;
        // idle_prompt means the turn is long over and the prompt has been
        // sitting untouched, so it has to outrank stop. At rank 3 it was
        // rejected by every session that had actually finished a turn, which is
        // every session that can produce it.
        case NotificationType.idlePrompt: return 9;
        default: return 3;
      }
    case HookEventKind.postToolUse:
    case HookEventKind.postToolUseFailure:
    case HookEventKind.elicitationResult: return 4;
    case HookEventKind.subagentStop: return 5;
    // The batch closes after every tool in it has settled, so it outranks the
    // individual results it summarises.
    case HookEventKind.postToolBatch: return 6;
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
  TOOLS_THAT_ASK_THE_USER,
  AgentProvider,
  HostApplication,
  asksTheUser,
  providerDisplayName,
  hostDisplayName,
  isTerminalEvent,
  rankOf,
};
