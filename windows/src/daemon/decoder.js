'use strict';

// Porte de Sources/CodeStatusCore/Runtime/EventWireDecoder.swift
//
// Converte uma linha NDJSON vinda do hook num AgentEvent normalizado. Tudo aqui
// e defensivo: a linha veio de outro processo e pode estar truncada, repetida ou
// de uma versao mais nova do hook.

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

// Decodifica uma linha. Devolve null quando a linha nao e utilizavel - o
// chamador simplesmente a descarta, porque um hook de uma versao futura mandando
// algo que nao entendemos nao pode derrubar o daemon.
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
  // Um evento que nao esta no vocabulario e ignorado em vez de mal classificado:
  // e o que mantem a compatibilidade quando o agente adiciona eventos novos.
  if (!kind || !KNOWN_EVENT_KINDS.has(kind)) return null;

  const provider = KNOWN_PROVIDERS.has(raw.provider) ? raw.provider : AgentProvider.generic;
  const host = KNOWN_HOSTS.has(raw.host) ? raw.host : HostApplication.unknown;

  const notificationType = KNOWN_NOTIFICATION_TYPES.has(raw.notification_type)
    ? raw.notification_type
    : null;

  // O hook manda segundos com fracao; o resto do app trabalha em milissegundos.
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
    // O Claude Code usa turn_id em alguns eventos e prompt_id em outros; os dois
    // delimitam o mesmo turno para efeito de ordenacao.
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

// Evento sintetico usado quando o processo do agente some sem SessionEnd.
function processExitedEvent(pid, now = Date.now()) {
  return {
    id: `exit-${pid}-${now}`,
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
