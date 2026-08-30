'use strict';

// Port of Sources/CodeStatusCore/Runtime/EventWireDecoder.swift
//
// Turns one NDJSON line from the hook into a normalised event. Everything here
// is defensive: the line came from another process and may be truncated,
// repeated, or from a newer version of the hook.

const {
  EventSource,
  HookEventKind,
  KNOWN_EVENT_KINDS,
  NotificationType,
  AgentProvider,
  HostApplication,
} = require('../core/events');

const KNOWN_PROVIDERS = new Set(Object.values(AgentProvider));
const KNOWN_HOSTS = new Set(Object.values(HostApplication));
const KNOWN_NOTIFICATION_TYPES = new Set(Object.values(NotificationType));

function asString(value) {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

// Decodes one line. Returns null when the line is unusable — the caller simply
// drops it, because a hook from a future version sending something we do not
// understand must not take the daemon down.
function decodeLine(text) {
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;

  const id = asString(raw.id);
  if (!id) return null;

  const kind = asString(raw.hook_event_name);
  // An event outside the vocabulary is ignored rather than misclassified: this
  // is what keeps us compatible when the agent adds new events.
  if (!kind || !KNOWN_EVENT_KINDS.has(kind)) return null;

  const provider = KNOWN_PROVIDERS.has(raw.provider) ? raw.provider : AgentProvider.generic;
  const host = KNOWN_HOSTS.has(raw.host) ? raw.host : HostApplication.unknown;

  const notificationType = KNOWN_NOTIFICATION_TYPES.has(raw.notification_type)
    ? raw.notification_type
    : null;

  // The hook sends fractional seconds; the rest of the app works in milliseconds.
  const ts = typeof raw.ts === 'number' && Number.isFinite(raw.ts)
    ? Math.round(raw.ts * 1000)
    : Date.now();

  const pid = Number.isInteger(raw.ppid) && raw.ppid > 0 ? raw.ppid : null;

  return {
    id,
    provider,
    kind,
    source: EventSource.hook,
    timestamp: ts,

    providerSessionID: asString(raw.session_id),
    // Claude Code uses turn_id on some events and prompt_id on others; both
    // delimit the same turn for ordering purposes.
    providerTurnID: asString(raw.turn_id) || asString(raw.prompt_id),

    notificationType,
    toolName: asString(raw.tool_name),
    toolUseID: asString(raw.tool_use_id),
    startReason: asString(raw.source) || asString(raw.start_reason),
    endReason: asString(raw.end_reason),
    errorType: asString(raw.error_type),
    permissionMode: asString(raw.permission_mode),
    model: asString(raw.model),

    cwd: asString(raw.cwd),
    pid,
    host,
    processStartTime: null,
  };
}

// Synthetic event used when the agent's process disappears without a SessionEnd.
//
// `targetSessionID` addresses one specific session rather than routing by pid.
// A single pid can carry two sessions — the one the process scan discovered and
// the one its hooks later reported under the agent's own session id — and
// routing by pid would only ever end the second, leaving the first alive in the
// registry for the lifetime of the app.
function processExitedEvent(pid, now = Date.now(), targetSessionID = null) {
  return {
    id: targetSessionID ? `exit-${targetSessionID}-${now}` : `exit-${pid}-${now}`,
    targetSessionID,
    provider: AgentProvider.generic,
    kind: HookEventKind.processExited,
    source: EventSource.process,
    timestamp: now,
    providerSessionID: null,
    providerTurnID: null,
    notificationType: null,
    toolName: null,
    toolUseID: null,
    startReason: null,
    endReason: null,
    errorType: null,
    permissionMode: null,
    model: null,
    cwd: null,
    pid,
    host: HostApplication.unknown,
    processStartTime: null,
  };
}

module.exports = { decodeLine, processExitedEvent };
