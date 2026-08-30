'use strict';

// Porte de Sources/CodeStatusCore/Domain/AgentEvent.swift

const EventSource = Object.freeze({
  hook: 'hook',
  process: 'process',
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
  // sintetizado localmente quando o processo some sem SessionEnd
  processExited: '__processExited',
});

const KNOWN_EVENT_KINDS = new Set(Object.values(HookEventKind));

// Os valores de notification_type que o Claude Code realmente emite hoje.
// Valores desconhecidos precisam ser no-op em vez de erro - e isso que mantem
// o app compativel quando tipos novos aparecerem.
const NotificationType = Object.freeze({
  permissionPrompt: 'permission_prompt',
  idlePrompt: 'idle_prompt',
  agentCompleted: 'agent_completed',
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

// No Windows nao existe TERM_PROGRAM como no macOS. O host e deduzido de
// variaveis que os terminais do Windows exportam de fato.
const HostApplication = Object.freeze({
  windowsTerminal: 'windowsTerminal',
  vsCode: 'vsCode',
  powershell: 'powershell',
  conhost: 'conhost',
  unknown: 'unknown',
});

function hostDisplayName(host) {
  switch (host) {
    case HostApplication.windowsTerminal: return 'Windows Terminal';
    case HostApplication.vsCode: return 'VS Code';
    case HostApplication.powershell: return 'PowerShell';
    case HostApplication.conhost: return 'Console';
    default: return 'Desconhecido';
  }
}

// Eventos terminais sao aplicados incondicionalmente: uma sessao encerrada nao
// pode ser revivida por um retardatario de antes do encerramento.
function isTerminalEvent(event) {
  return event.kind === HookEventKind.sessionEnd
    || event.kind === HookEventKind.processExited;
}

// Posicao do evento *dentro* de um turno. Os ranks existem para rejeitar
// retardatarios que regrediriam a sessao. As lacunas que importam:
//  - permissionRequest > preToolUse, entao um PreToolUse atrasado nao tira a
//    sessao de waitingForApproval de volta pra busy.
//  - postToolUse > permissionRequest, entao a ferramenta rodando depois da
//    aprovacao devolve a sessao pra busy corretamente.
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
        case NotificationType.agentCompleted: return 8;
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
