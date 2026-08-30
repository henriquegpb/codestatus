'use strict';

// Teste de integracao do transporte: sobe o daemon de verdade, invoca o hook
// como o Claude Code invocaria (payload no stdin) e confere o que chegou.
//
// O caso que mais importa aqui e o de privacidade: o payload real do Claude Code
// carrega prompt, tool_input e transcript_path, e nada disso pode cruzar o pipe.

const assert = require('assert');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const { Daemon } = require('../src/daemon/daemon');
const { AgentState } = require('../src/core/state');
const { paths } = require('../src/core/paths');

const HOOK = path.join(__dirname, '..', 'hook', 'hook.js');

// Um payload realista do Claude Code, com todo o conteudo sensivel que ele
// realmente carrega.
const SECRETS = {
  prompt: 'SEGREDO-PROMPT-nao-pode-vazar',
  tool_input: { command: 'SEGREDO-COMANDO', file_path: 'C:\\privado\\chaves.env' },
  tool_response: 'SEGREDO-SAIDA',
  last_assistant_message: 'SEGREDO-RESPOSTA',
  transcript_path: 'C:\\Users\\alguem\\.claude\\transcripts\\SEGREDO.jsonl',
  message: 'SEGREDO-MENSAGEM',
};

function runHook(payload) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [HOOK, '--provider', 'claude-code'], {
      stdio: ['pipe', 'ignore', 'ignore'],
    });
    child.on('exit', (code) => resolve(code));
    child.stdin.write(JSON.stringify(payload));
    child.stdin.end();
  });
}

function waitFor(predicate, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const tick = () => {
      if (predicate()) return resolve();
      if (Date.now() - started > timeoutMs) return reject(new Error('timeout esperando o evento'));
      setTimeout(tick, 50);
    };
    tick();
  });
}

(async () => {
  // Limpa o spool para nao herdar evento de execucao anterior.
  try {
    for (const f of fs.readdirSync(paths.spool)) fs.unlinkSync(path.join(paths.spool, f));
  } catch { /* ainda nao existe */ }

  const daemon = new Daemon();
  const received = [];
  daemon.on('effects', (effects) => received.push(...effects));

  await new Promise((resolve) => {
    daemon.once('listening', resolve);
    daemon.start();
  });
  console.log(`  daemon ouvindo em ${daemon.pipe}`);

  // Captura o que de fato cruza o pipe, para inspecionar byte a byte.
  const seenLines = [];
  const originalIngest = daemon.ingest.bind(daemon);
  daemon.ingest = (line) => { seenLines.push(line); originalIngest(line); };

  let failed = 0;
  const check = (name, fn) => {
    try { fn(); console.log(`  ok   ${name}`); } catch (err) {
      failed += 1;
      console.log(`  FALHOU ${name}\n         ${err.message}`);
    }
  };

  // --- 1. um turno inteiro atravessando o transporte real -------------------

  const sessionId = `it-${Date.now()}`;
  const codigo1 = await runHook({
    hook_event_name: 'SessionStart',
    session_id: sessionId,
    cwd: 'C:\\Users\\ricar\\projeto-teste',
    model: 'opus',
    ...SECRETS,
  });
  check('o hook sai com 0 mesmo carregando payload sujo', () => {
    assert.strictEqual(codigo1, 0);
  });

  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`));
  check('SessionStart cria a sessao como livre', () => {
    assert.strictEqual(daemon.registry.get(`claudeCode:${sessionId}`).state, AgentState.free);
  });

  await runHook({
    hook_event_name: 'UserPromptSubmit',
    session_id: sessionId,
    turn_id: 'turno-1',
    ...SECRETS,
  });
  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`).state === AgentState.busy);
  check('UserPromptSubmit leva a sessao para busy', () => {
    assert.strictEqual(daemon.registry.get(`claudeCode:${sessionId}`).state, AgentState.busy);
  });

  await runHook({
    hook_event_name: 'Notification',
    session_id: sessionId,
    turn_id: 'turno-1',
    notification_type: 'permission_prompt',
    ...SECRETS,
  });
  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`).state === AgentState.waitingForApproval);
  check('Notification(permission_prompt) pede sua atencao', () => {
    const s = daemon.registry.get(`claudeCode:${sessionId}`);
    assert.strictEqual(s.state, AgentState.waitingForApproval);
    assert.strictEqual(daemon.registry.counts().needsYou, 1);
  });

  await runHook({ hook_event_name: 'Stop', session_id: sessionId, turn_id: 'turno-1', ...SECRETS });
  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`).state === AgentState.free);
  check('Stop devolve a sessao para livre', () => {
    assert.strictEqual(daemon.registry.get(`claudeCode:${sessionId}`).state, AgentState.free);
  });

  // --- 2. privacidade -------------------------------------------------------

  check('nenhum conteudo sensivel cruzou o transporte', () => {
    const wire = seenLines.join('\n');
    assert.ok(wire.length > 0, 'nada chegou ao daemon');
    assert.ok(!wire.includes('SEGREDO'), `vazou conteudo na linha: ${wire}`);
    // Procura a chave na forma em que ela apareceria de fato no JSON. Uma busca
    // por substring crua daria falso positivo: notification_type tem o valor
    // legitimo "permission_prompt", que contem "prompt".
    for (const key of Object.keys(SECRETS)) {
      assert.ok(!wire.includes(`"${key}":`), `a chave ${key} apareceu no transporte`);
    }
  });

  check('o metadado esperado chegou intacto', () => {
    const first = JSON.parse(seenLines[0]);
    assert.strictEqual(first.session_id, sessionId);
    assert.strictEqual(first.hook_event_name, 'SessionStart');
    assert.strictEqual(first.cwd, 'C:\\Users\\ricar\\projeto-teste');
    assert.strictEqual(first.provider, 'claudeCode');
    assert.ok(first.ppid > 0, 'o pid do agente deveria ter sido capturado');
  });

  // --- 3. enriquecimento e identidade --------------------------------------

  check('a sessao guardou cwd, modelo e pid vindos do hook', () => {
    const s = daemon.registry.get(`claudeCode:${sessionId}`);
    assert.strictEqual(s.cwd, 'C:\\Users\\ricar\\projeto-teste');
    assert.strictEqual(s.model, 'opus');
    assert.ok(s.pid > 0);
    assert.strictEqual(s.hasHookEvidence, true);
  });

  // --- 4. spool quando o daemon esta fora ----------------------------------

  daemon.stop();
  const offlineSession = `off-${Date.now()}`;
  await runHook({ hook_event_name: 'SessionStart', session_id: offlineSession, ...SECRETS });
  check('com o daemon fora, o evento vai para o spool', () => {
    const spooled = fs.readdirSync(paths.spool).filter((n) => n.endsWith('.ndjson'));
    assert.ok(spooled.length > 0, 'nada foi enfileirado');
  });

  const revived = new Daemon();
  await new Promise((resolve) => { revived.once('listening', resolve); revived.start(); });
  await waitFor(() => revived.registry.get(`claudeCode:${offlineSession}`));
  check('ao voltar, o daemon reproduz o que ficou no spool', () => {
    assert.ok(revived.registry.get(`claudeCode:${offlineSession}`));
    assert.strictEqual(fs.readdirSync(paths.spool).filter((n) => n.endsWith('.ndjson')).length, 0);
  });
  revived.stop();

  console.log(failed === 0 ? '\ntodos os casos de transporte passaram' : `\n${failed} falharam`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('erro fatal no teste:', err);
  process.exit(1);
});
