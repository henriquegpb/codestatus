'use strict';

// Porte de AgentSession (Sources/CodeStatusCore/Domain/AgentSession.swift)

const path = require('path');
const { AgentState, StateConfidence } = require('./state');
const { HostApplication, providerDisplayName } = require('./events');
const { LogicalClock } = require('./clock');

// Identidade preferida: o agente nos disse o proprio session id.
function sessionIDFromProvider(provider, sessionID) {
  return `${provider}:${sessionID}`;
}

// Fallback quando nao ha session id do provider. O tempo de inicio faz parte da
// chave porque pids sao reciclados - so o pid deixaria um processo novo herdar
// o estado de uma sessao morta.
function sessionIDFromProcess(provider, pid, startTime) {
  return `${provider}:pid-${pid}-${startTime}`;
}

function makeSession({ id, provider, now, sourceAdapter, state = AgentState.discovering }) {
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
    parentPID: null,
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

    // Se algum hook oficial ja chegou para esta sessao. E a distincao sobre a
    // qual o HUD e construido: descoberta por processo prova que a sessao
    // *existe*; so um hook diz o que ela esta fazendo.
    hasHookEvidence: false,

    clock: new LogicalClock(),
  };
}

// Melhor rotulo humano disponivel: repo, depois workspace, depois o ultimo
// componente do diretorio de trabalho.
function displayName(session) {
  if (session.repositoryName) return session.repositoryName;
  if (session.workspaceName) return session.workspaceName;
  if (session.cwd) {
    const component = path.basename(session.cwd);
    // Uma raiz de drive (C:\) viraria um rotulo que parece bug em vez de nome.
    if (component && component !== path.sep && !/^[A-Za-z]:\\?$/.test(component)) {
      return component;
    }
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
