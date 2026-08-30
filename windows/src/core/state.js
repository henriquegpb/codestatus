'use strict';

// Porte de Sources/CodeStatusCore/Domain/AgentState.swift
//
// O vocabulario canonico do app inteiro. Nao existe isBusy/isDone/needsApproval
// espalhado por ai: toda superficie (bandeja, HUD, notificacao) deriva o que
// mostra daqui. Ausencia de evidencia e representada explicitamente
// (unknown, reconnecting) em vez de chutada.

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

// falha conta aqui - um erro nunca pode ser apresentado como "livre".
function needsAttention(state) {
  return state === AgentState.waitingForApproval
    || state === AgentState.waitingForInput
    || state === AgentState.failed;
}

function isActive(state) {
  return state !== AgentState.ended;
}

// Se uma transicao representa um turno que acabou de terminar.
//
// Chegar em `free` nao basta: um SessionStart tambem chega em `free`, porque uma
// sessao recem-aberta esta ociosa esperando um prompt. Avisar ali diria "terminou"
// no exato momento em que nada comecou ainda.
//
// O que caracteriza a conclusao e a *origem*: so terminou o que estava em
// andamento - trabalhando, ou parado esperando voce destravar.
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

// Confianca decai com o silencio; o estado nao. Uma sessao quieta ha dez
// minutos no meio de uma tool call continua busy - so a confianca cai.
const StateConfidence = Object.freeze({ low: 0, medium: 1, high: 2 });

const LABELS_PT = Object.freeze({
  discovering: 'descobrindo',
  busy: 'trabalhando',
  free: 'livre',
  waitingForApproval: 'aguardando aprovacao',
  waitingForInput: 'aguardando resposta',
  failed: 'falhou',
  reconnecting: 'reconectando',
  unknown: 'desconhecido',
  ended: 'encerrada',
});

module.exports = {
  AgentState,
  StateBucket,
  StateConfidence,
  needsAttention,
  isActive,
  isTurnCompletion,
  bucketOf,
  LABELS_PT,
};
