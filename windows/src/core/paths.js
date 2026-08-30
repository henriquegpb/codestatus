'use strict';

// Porte de Sources/CodeStatusCore/Runtime/RuntimePaths.swift para Windows.
//
// Centralizado porque dois binarios independentes - o app e o hook - precisam
// concordar exatamente sobre esses caminhos.
//
// Diferenca principal em relacao ao macOS: la o transporte e um socket Unix em
// ~/Library/Application Support, e todo o cuidado com o limite de 104 bytes do
// sun_path existe por causa disso. No Windows usamos um named pipe, cujo nome
// vive no namespace \\.\pipe\ e nao toca no sistema de arquivos - entao nao ha
// limite de caminho a contornar e todo o mecanismo de socket-path/fallback
// desaparece. O ponteiro em disco continua existindo so para o hook descobrir
// o nome do pipe sem te-lo compilado dentro.

const os = require('os');
const path = require('path');
const fs = require('fs');

const home = os.homedir();

// %LOCALAPPDATA%\CodeStatus e o equivalente Windows de
// ~/Library/Application Support/CodeStatus.
const base = process.env.LOCALAPPDATA
  ? path.join(process.env.LOCALAPPDATA, 'CodeStatus')
  : path.join(home, 'AppData', 'Local', 'CodeStatus');

const run = path.join(base, 'run');
const bin = path.join(base, 'bin');
const backups = path.join(base, 'backups');
const state = path.join(base, 'state');
const spool = path.join(run, 'spool');

const paths = {
  home,
  base,
  run,
  bin,
  backups,
  state,
  spool,
  heartbeat: path.join(run, 'heartbeat'),
  // Aponta para o pipe vivo, para o hook nunca precisar do nome compilado.
  pipePointer: path.join(run, 'pipe-name'),
  sessionsSnapshot: path.join(state, 'sessions.json'),
  prefs: path.join(state, 'prefs.json'),
  installReceipts: path.join(state, 'installation.json'),
  logFile: path.join(state, 'codestatus.log'),

  // Config do Claude Code. Um unico arquivo serve a CLI e a extensao do VS Code
  // - a extensao embute a propria CLI mas le a mesma config do usuario - entao
  // instalar aqui cobre as duas superficies com uma edicao so.
  //
  // A variavel de ambiente e um encaixe de teste, equivalente ao parametro
  // `home:` que o original injeta no instalador: deixa o teste exercitar a
  // instalacao de verdade sem escrever na config real de quem usa o app.
  claudeSettings: process.env.CODESTATUS_CLAUDE_SETTINGS
    || path.join(home, '.claude', 'settings.json'),
  codexHooks: path.join(home, '.codex', 'hooks.json'),
};

// O nome do pipe inclui o usuario para duas contas na mesma maquina nao
// colidirem no namespace global de pipes.
function pipeName() {
  const user = (process.env.USERNAME || 'user').replace(/[^A-Za-z0-9_-]/g, '');
  // Escrito por concatenacao explicita: o nome precisa sair como
  // \\.\pipe\codestatus-<usuario>, e cada barra aqui e uma barra de verdade.
  return '\\\\.\\pipe\\codestatus-' + user;
}

function createDirectories() {
  for (const dir of [base, run, bin, backups, state, spool]) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

module.exports = { paths, pipeName, createDirectories };
