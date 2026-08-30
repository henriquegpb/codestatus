'use strict';

// Preferencias do usuario, guardadas ao lado do resto do estado do app.
//
// Deliberadamente minusculo: sao escolhas sobre quando avisar, nao configuracao
// de comportamento do nucleo. O que decide estado continua sendo so o hook.

const fs = require('fs');
const { paths } = require('./paths');

const PADROES = Object.freeze({
  // Avisar quando um turno termina. O app original nao faz isso - ele so
  // interrompe voce quando ha algo a fazer. Fica ligado porque foi pedido
  // explicitamente, mas continua sendo uma escolha, nao uma imposicao.
  avisarAoTerminar: true,
  // Avisar quando uma sessao passa a precisar de voce (aprovacao, resposta,
  // falha). E a razao de existir do app; desligar deixa so o icone.
  avisarQuandoPrecisa: true,
  // Som junto da notificacao.
  som: true,
});

let cache = null;

function load() {
  if (cache) return cache;
  let salvo = {};
  try {
    salvo = JSON.parse(fs.readFileSync(paths.prefs, 'utf8'));
  } catch { /* primeira execucao, ou arquivo corrompido: usa os padroes */ }
  // Chaves desconhecidas sao ignoradas e chaves ausentes caem no padrao, entao
  // um arquivo de uma versao futura ou anterior nunca quebra o app.
  cache = { ...PADROES };
  for (const chave of Object.keys(PADROES)) {
    if (typeof salvo[chave] === typeof PADROES[chave]) cache[chave] = salvo[chave];
  }
  return cache;
}

function get(chave) {
  return load()[chave];
}

function set(chave, valor) {
  if (!(chave in PADROES)) return;
  load()[chave] = valor;
  try {
    fs.mkdirSync(paths.state, { recursive: true });
    fs.writeFileSync(paths.prefs, JSON.stringify(cache, null, 2), 'utf8');
  } catch { /* nao poder salvar nao pode derrubar o app */ }
}

module.exports = { get, set, PADROES };
