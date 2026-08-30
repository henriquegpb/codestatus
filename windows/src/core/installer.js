'use strict';

// Porte de HookInstaller + ClaudeHookInstaller.
//
// Tres garantias moldam tudo aqui:
//
//  1. Nunca bloqueamos o agente. Toda entrada e escrita com async:true, que o
//     Claude Code honra, entao nosso hook nunca senta no caminho critico dele
//     mesmo que o daemon esteja travado.
//  2. So tocamos nas nossas proprias entradas. A posse e decidida resolvendo o
//     `command` da entrada para um caminho real e comparando com o script que
//     controlamos - nunca por substring, que deixaria a gente apagar um hook do
//     usuario cujo comando apenas menciona nosso nome.
//  3. Nunca perdemos o arquivo do usuario. Backup, escrita atomica, revalidacao.
//
// Diferenca em relacao ao original: la o `command` aponta para um binario Swift
// compilado. Aqui aponta para `node hook.js`, entao a deteccao de posse precisa
// olhar o caminho do script dentro da linha de comando, nao a linha inteira.

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const { paths } = require('./paths');

// Todo hook de ciclo de vida que o Claude Code emite e que muda o que podemos
// dizer sobre o estado de uma sessao.
//
// `Notification` entra porque seus subtipos permission_prompt e idle_prompt sao
// o unico sinal de "o agente esta esperando voce" que chega sem um evento de
// ferramenta correspondente. `StopFailure` entra porque um turno que termina em
// erro nao pode ser mostrado como livre.
const CLAUDE_EVENTS = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'PermissionRequest',
  'PermissionDenied',
  'Notification',
  'Stop',
  'StopFailure',
  'SessionEnd',
];

// Segundos que nos damos antes do agente desistir de nos. O hook e async, entao
// isso e uma rede contra um processo travado, nao um orcamento de latencia.
const TIMEOUT_SECONDS = 5;

const HOOK_SCRIPT = path.join(__dirname, '..', '..', 'hook', 'hook.js');

// O node do PATH, resolvido na instalacao. Guardar o caminho absoluto evita que
// a config do agente dependa de como o PATH esta montado no terminal dele - e
// em Electron `process.execPath` e o electron.exe, nao o node.
function resolveNodePath() {
  try {
    const out = execFileSync('where', ['node'], { encoding: 'utf8' });
    const first = out.split(/\r?\n/).find((l) => l.trim().toLowerCase().endsWith('node.exe'));
    if (first) return first.trim();
  } catch { /* cai no fallback */ }
  return 'node';
}

// O comando e os argumentos separados, nunca uma linha de comando unica.
//
// Isto nao e estilo: e a diferenca entre funcionar e nao funcionar no Windows.
// Quando `args` esta presente, o Claude Code usa a forma exec e spawna o binario
// direto. Quando `args` e omitido, ele usa a forma shell - e no Windows esse
// shell pode ser o PowerShell, onde uma linha que comeca com um caminho entre
// aspas ("C:\...\node.exe" script.js) e apenas uma *string literal* que o
// PowerShell ecoa. Sem o operador `&` nada executa, e o hook nunca roda: sem
// erro, sem log, so silencio.
//
// A forma exec elimina o shell da equacao e, junto com ele, toda a questao de
// aspas em caminhos com espaco (`C:\Program Files\...`).
function hookInvocation() {
  return {
    command: resolveNodePath(),
    args: [HOOK_SCRIPT, '--provider', 'claude-code'],
  };
}

// Uma entrada e nossa se ela referencia exatamente o nosso script - esteja o
// caminho no `command` (formato antigo, linha unica) ou no `args` (formato
// atual). Comparar caminho resolvido, nunca substring: um hook do usuario cuja
// linha apenas mencione "codestatus" nao e nosso e precisa sobreviver.
function isOurEntry(entry) {
  if (!entry || typeof entry !== 'object') return false;
  const hooks = Array.isArray(entry.hooks) ? entry.hooks : [];
  const target = path.resolve(HOOK_SCRIPT).toLowerCase();

  return hooks.some((h) => {
    if (!h || typeof h !== 'object') return false;
    const candidates = [];
    if (typeof h.command === 'string') candidates.push(h.command);
    if (Array.isArray(h.args)) {
      for (const a of h.args) if (typeof a === 'string') candidates.push(a);
    }
    return candidates.some((raw) => {
      const match = raw.match(/"([^"]+\.js)"|(\S+\.js)/);
      if (!match) return false;
      try {
        return path.resolve((match[1] || match[2]).trim()).toLowerCase() === target;
      } catch {
        return false;
      }
    });
  });
}

function newEntry() {
  const { command, args } = hookInvocation();
  return {
    hooks: [{
      type: 'command',
      command,
      args,
      timeout: TIMEOUT_SECONDS,
      // Sem `async`, o hook roda no caminho critico do agente.
      async: true,
    }],
  };
}

function readSettings() {
  try {
    const text = fs.readFileSync(paths.claudeSettings, 'utf8');
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      // Algo esta no caminho alvo mas nao e um objeto de config - nao podemos
      // saber o que substitui-lo destruiria.
      throw new Error('settings.json nao contem um objeto JSON');
    }
    return { settings: parsed, existed: true };
  } catch (err) {
    if (err && err.code === 'ENOENT') return { settings: {}, existed: false };
    throw err;
  }
}

function backup() {
  try {
    if (!fs.existsSync(paths.claudeSettings)) return null;
    fs.mkdirSync(paths.backups, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const dest = path.join(paths.backups, `settings-${stamp}.json`);
    fs.copyFileSync(paths.claudeSettings, dest);
    return dest;
  } catch {
    return null;
  }
}

function writeSettings(settings) {
  const dir = path.dirname(paths.claudeSettings);
  fs.mkdirSync(dir, { recursive: true });
  const text = `${JSON.stringify(settings, null, 2)}\n`;
  const tmp = `${paths.claudeSettings}.codestatus.tmp`;
  fs.writeFileSync(tmp, text, 'utf8');
  // Revalida antes de publicar: nunca deixamos um arquivo ilegivel no lugar do
  // que o usuario tinha.
  JSON.parse(fs.readFileSync(tmp, 'utf8'));
  fs.renameSync(tmp, paths.claudeSettings);
}

function loadReceipts() {
  try {
    return JSON.parse(fs.readFileSync(paths.installReceipts, 'utf8'));
  } catch {
    return {};
  }
}

function saveReceipt(receipt) {
  try {
    fs.mkdirSync(paths.state, { recursive: true });
    const all = loadReceipts();
    all[receipt.targetPath] = receipt;
    fs.writeFileSync(paths.installReceipts, JSON.stringify(all, null, 2), 'utf8');
  } catch { /* perder o recibo nao e fatal; ver uninstall */ }
}

function forgetReceipt(targetPath) {
  try {
    const all = loadReceipts();
    delete all[targetPath];
    fs.writeFileSync(paths.installReceipts, JSON.stringify(all, null, 2), 'utf8');
  } catch { /* ignora */ }
}

function isInstalled() {
  try {
    const { settings } = readSettings();
    const hooks = settings.hooks;
    if (!hooks || typeof hooks !== 'object') return false;
    return CLAUDE_EVENTS.every((event) => {
      const arr = hooks[event];
      return Array.isArray(arr) && arr.some(isOurEntry);
    });
  } catch {
    return false;
  }
}

function install() {
  // Falha alto e cedo em vez de gravar uma entrada que nunca vai rodar. Sem um
  // node no disco o hook e um comando que o Claude Code tenta executar e nao
  // acha - e o sintoma disso e o pior possivel: silencio total, sem erro e sem
  // nada no spool.
  if (!fs.existsSync(HOOK_SCRIPT)) {
    throw new Error(`O script do hook nao existe em ${HOOK_SCRIPT}.`);
  }
  if (resolveNodePath() === 'node') {
    throw new Error(
      'node.exe nao foi encontrado no PATH. O hook precisa do Node.js para rodar.\n'
      + 'Instale em https://nodejs.org e tente de novo.',
    );
  }

  const { settings, existed } = readSettings();
  const backupPath = backup();

  // O recibo responde uma pergunta que o arquivo em si nao consegue: a chave
  // `hooks` existia antes de a gente chegar? Um usuario que escreveu "hooks": {}
  // a mao e um arquivo onde nos criamos sao identicos depois que nossas
  // entradas somem. Entao lembramos, em vez de adivinhar.
  const receipt = {
    targetPath: paths.claudeSettings,
    createdFile: !existed,
    createdHooksKey: !settings.hooks,
    createdEventKeys: [],
    hookInvocation: hookInvocation(),
    installedAt: new Date().toISOString(),
    backupPath,
  };

  if (!settings.hooks || typeof settings.hooks !== 'object' || Array.isArray(settings.hooks)) {
    settings.hooks = {};
    receipt.createdHooksKey = true;
  }

  for (const event of CLAUDE_EVENTS) {
    if (!Array.isArray(settings.hooks[event])) {
      settings.hooks[event] = [];
      receipt.createdEventKeys.push(event);
    }
    // Remove qualquer entrada nossa antiga antes de adicionar a nova, senao uma
    // reinstalacao dispararia o hook duas vezes por evento.
    settings.hooks[event] = settings.hooks[event].filter((e) => !isOurEntry(e));
    settings.hooks[event].push(newEntry());
  }

  writeSettings(settings);
  saveReceipt(receipt);
  return receipt;
}

function uninstall() {
  const { settings } = readSettings();
  const receipt = loadReceipts()[paths.claudeSettings] || {};
  backup();

  if (!settings.hooks || typeof settings.hooks !== 'object') return { removed: 0 };

  let removed = 0;
  for (const event of CLAUDE_EVENTS) {
    const arr = settings.hooks[event];
    if (!Array.isArray(arr)) continue;
    const before = arr.length;
    settings.hooks[event] = arr.filter((e) => !isOurEntry(e));
    removed += before - settings.hooks[event].length;

    // So removemos estrutura que provamos ter criado.
    if (settings.hooks[event].length === 0
      && (receipt.createdEventKeys || []).includes(event)) {
      delete settings.hooks[event];
    }
  }

  if (receipt.createdHooksKey && Object.keys(settings.hooks).length === 0) {
    delete settings.hooks;
  }

  writeSettings(settings);
  forgetReceipt(paths.claudeSettings);
  return { removed };
}

// O que o app precisa mostrar no diagnostico.
function status() {
  const problems = [];
  if (!fs.existsSync(HOOK_SCRIPT)) {
    problems.push('O script do hook nao foi encontrado no disco.');
  }
  const node = resolveNodePath();
  if (node === 'node') {
    problems.push('node.exe nao foi encontrado no PATH; os hooks dependem dele.');
  }
  return {
    installed: isInstalled(),
    settingsPath: paths.claudeSettings,
    hookScript: HOOK_SCRIPT,
    nodePath: node,
    problems,
  };
}

module.exports = {
  CLAUDE_EVENTS,
  HOOK_SCRIPT,
  install,
  uninstall,
  isInstalled,
  status,
  isOurEntry,
  hookInvocation,
  resolveNodePath,
};
