'use strict';

// Porte dos casos de InstallerTests.swift que continuam valendo no Windows.
//
// A propriedade central e a mesma do original: o settings.json e do usuario, e
// uma instalacao ou remocao nunca pode destruir o que ja estava la.
//
// Roda contra um arquivo temporario, nunca contra a config real - ver
// CODESTATUS_CLAUDE_SETTINGS em src/core/paths.js.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'codestatus-test-'));
const SETTINGS = path.join(TMP, 'settings.json');
process.env.CODESTATUS_CLAUDE_SETTINGS = SETTINGS;

const installer = require('../src/core/installer');
const { CLAUDE_EVENTS } = installer;

let failed = 0;
function test(name, fn) {
  try {
    // Cada caso comeca de um arquivo limpo.
    try { fs.unlinkSync(SETTINGS); } catch { /* nao existia */ }
    fn();
    console.log(`  ok   ${name}`);
  } catch (err) {
    failed += 1;
    console.log(`  FALHOU ${name}\n         ${err.message}`);
  }
}

const read = () => JSON.parse(fs.readFileSync(SETTINGS, 'utf8'));
const write = (obj) => fs.writeFileSync(SETTINGS, JSON.stringify(obj, null, 2), 'utf8');

// --- instalacao --------------------------------------------------------------

test('Instalar registra todos os eventos de ciclo de vida', () => {
  write({});
  installer.install();
  const s = read();
  for (const event of CLAUDE_EVENTS) {
    assert.ok(Array.isArray(s.hooks[event]), `faltou o evento ${event}`);
    assert.strictEqual(s.hooks[event].length, 1, `${event} deveria ter uma entrada`);
  }
  assert.strictEqual(installer.isInstalled(), true);
});

test('Toda entrada e async, para nunca sentar no caminho critico do agente', () => {
  write({});
  installer.install();
  const s = read();
  for (const event of CLAUDE_EVENTS) {
    const hook = s.hooks[event][0].hooks[0];
    assert.strictEqual(hook.async, true, `${event} nao e async`);
    assert.strictEqual(hook.type, 'command');
    assert.ok(hook.timeout > 0);
  }
});

test('Instalar preserva as configuracoes que o usuario ja tinha', () => {
  write({
    model: 'opus',
    theme: 'dark',
    permissions: { allow: ['Bash(git status)'] },
    statusLine: { type: 'command', command: 'meu-script' },
  });
  installer.install();
  const s = read();
  assert.strictEqual(s.model, 'opus');
  assert.strictEqual(s.theme, 'dark');
  assert.deepStrictEqual(s.permissions, { allow: ['Bash(git status)'] });
  assert.deepStrictEqual(s.statusLine, { type: 'command', command: 'meu-script' });
});

test('Instalar preserva hooks de terceiros no mesmo evento', () => {
  write({
    hooks: {
      PreToolUse: [{ hooks: [{ type: 'command', command: 'ferramenta-de-outra-pessoa.exe' }] }],
    },
  });
  installer.install();
  const entries = read().hooks.PreToolUse;
  assert.strictEqual(entries.length, 2, 'o hook de terceiro deveria continuar la');
  assert.ok(entries.some((e) => !installer.isOurEntry(e)));
  assert.ok(entries.some((e) => installer.isOurEntry(e)));
});

test('Reinstalar nao duplica entradas', () => {
  write({});
  installer.install();
  installer.install();
  installer.install();
  const s = read();
  for (const event of CLAUDE_EVENTS) {
    assert.strictEqual(s.hooks[event].length, 1, `${event} duplicou`);
  }
});

test('Instalar cria o arquivo quando ele nao existe', () => {
  assert.ok(!fs.existsSync(SETTINGS));
  installer.install();
  assert.ok(fs.existsSync(SETTINGS));
  assert.strictEqual(installer.isInstalled(), true);
});

// --- remocao -----------------------------------------------------------------

test('Remover tira so as nossas entradas e devolve o arquivo ao estado original', () => {
  const original = {
    model: 'opus',
    hooks: {
      PreToolUse: [{ hooks: [{ type: 'command', command: 'ferramenta-de-outra-pessoa.exe' }] }],
    },
  };
  write(original);
  installer.install();
  installer.uninstall();
  const s = read();
  assert.strictEqual(s.model, 'opus');
  assert.strictEqual(s.hooks.PreToolUse.length, 1);
  assert.ok(!installer.isOurEntry(s.hooks.PreToolUse[0]));
  assert.strictEqual(installer.isInstalled(), false);
});

test('Remover apaga a chave hooks so quando fomos nos que a criamos', () => {
  write({ model: 'opus' });
  installer.install();
  installer.uninstall();
  assert.strictEqual(read().hooks, undefined, 'a chave hooks deveria ter sumido');

  // Agora o oposto: o usuario tinha a chave antes de nos.
  write({ model: 'opus', hooks: {} });
  installer.install();
  installer.uninstall();
  assert.notStrictEqual(read().hooks, undefined, 'a chave hooks era do usuario');
});

test('Remover e idempotente', () => {
  write({ model: 'opus' });
  installer.install();
  installer.uninstall();
  installer.uninstall();
  assert.strictEqual(installer.isInstalled(), false);
  assert.strictEqual(read().model, 'opus');
});

// --- posse -------------------------------------------------------------------

test('Um hook alheio que apenas menciona nosso nome nao e nosso', () => {
  const impostor = {
    hooks: [{ type: 'command', command: 'echo "codestatus e legal" >> C:\\log.txt' }],
  };
  assert.strictEqual(installer.isOurEntry(impostor), false);
});

test('Uma entrada malformada nunca e reivindicada como nossa', () => {
  assert.strictEqual(installer.isOurEntry(null), false);
  assert.strictEqual(installer.isOurEntry({}), false);
  assert.strictEqual(installer.isOurEntry({ hooks: 'nao e array' }), false);
  assert.strictEqual(installer.isOurEntry({ hooks: [{ type: 'command' }] }), false);
});

// --- seguranca do arquivo ----------------------------------------------------

test('Um settings.json invalido faz a instalacao parar em vez de sobrescrever', () => {
  fs.writeFileSync(SETTINGS, '{ isto nao e json valido', 'utf8');
  assert.throws(() => installer.install());
  // O conteudo original continua intacto no disco.
  assert.ok(fs.readFileSync(SETTINGS, 'utf8').includes('isto nao e json valido'));
});

test('Instalar deixa um backup para tras', () => {
  write({ model: 'opus' });
  const receipt = installer.install();
  assert.ok(receipt.backupPath, 'nenhum backup foi registrado');
  assert.ok(fs.existsSync(receipt.backupPath));
  assert.strictEqual(JSON.parse(fs.readFileSync(receipt.backupPath, 'utf8')).model, 'opus');
});

test('O comando gravado aponta para o nosso hook e para um node real', () => {
  write({});
  installer.install();
  const h = read().hooks.SessionStart[0].hooks[0];
  assert.ok(/node\.exe$/i.test(h.command) || h.command === 'node', `node nao resolvido: ${h.command}`);
  assert.ok(h.args.some((a) => a.endsWith('hook.js')), 'os args deveriam apontar para o hook.js');
  assert.deepStrictEqual(h.args.slice(-2), ['--provider', 'claude-code']);
});

// Regressao: a primeira versao escrevia tudo numa linha de comando so, sem
// `args`. Isso poe o Claude Code na forma shell, e no Windows esse shell pode
// ser o PowerShell - onde "C:\...\node.exe" script.js e uma string literal que
// ele ecoa em vez de executar. O hook nunca rodava, sem erro nenhum.
test('A entrada usa a forma exec (args), nunca uma linha de comando unica', () => {
  write({});
  installer.install();
  for (const event of CLAUDE_EVENTS) {
    const h = read().hooks[event][0].hooks[0];
    assert.ok(Array.isArray(h.args), `${event} precisa de args para usar a forma exec`);
    assert.ok(!h.command.includes(' --provider'), `${event} juntou argumentos no command`);
    assert.ok(!h.command.includes('"'), `${event} tem aspas no command, sinal de linha unica`);
  }
});

test('Uma entrada do formato antigo ainda e reconhecida como nossa', () => {
  // Quem instalou antes desta correcao tem a entrada em linha unica. Ela precisa
  // continuar sendo reconhecida, senao a reinstalacao a deixaria para tras e o
  // hook dispararia duas vezes por evento.
  const antiga = {
    hooks: [{
      type: 'command',
      command: `"C:\\node.exe" "${installer.HOOK_SCRIPT}" --provider claude-code`,
      timeout: 5,
      async: true,
    }],
  };
  assert.strictEqual(installer.isOurEntry(antiga), true);
});

// --- fim ---------------------------------------------------------------------

try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* ignora */ }
console.log(failed === 0 ? '\ntodos os casos do instalador passaram' : `\n${failed} falharam`);
process.exit(failed === 0 ? 0 : 1);
