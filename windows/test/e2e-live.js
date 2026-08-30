'use strict';

// Alimenta o app que ja esta rodando com uma sessao simulada, do jeito que o
// Claude Code alimentaria: um processo hook por evento, payload no stdin.
//
// Este processo fica vivo ate o fim de proposito. O hook reporta `process.ppid`
// como o pid do agente, e o daemon encerra sessoes cujo processo sumiu - se o
// pai morresse entre os eventos, a sessao seria corretamente marcada como
// encerrada e nao daria pra observar o resto.

const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { paths } = require('../src/core/paths');

const HOOK = path.join(__dirname, '..', 'hook', 'hook.js');
const SID = `demo-${Date.now()}`;

function runHook(payload) {
  return new Promise((resolve) => {
    const c = spawn(process.execPath, [HOOK, '--provider', 'claude-code'], {
      stdio: ['pipe', 'ignore', 'inherit'],
    });
    c.on('exit', (code) => resolve(code));
    c.stdin.end(JSON.stringify(payload));
  });
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function snapshot() {
  try {
    const j = JSON.parse(fs.readFileSync(paths.sessionsSnapshot, 'utf8'));
    return j.sessions.find((s) => s.id === `claudeCode:${SID}`);
  } catch {
    return null;
  }
}

async function step(label, payload, expected) {
  await runHook(payload);
  // O daemon persiste com um pequeno atraso proposital.
  await wait(2500);
  const s = snapshot();
  const got = s ? s.state : '(sem sessao)';
  const ok = got === expected;
  console.log(`  ${ok ? 'ok  ' : 'FALHOU'} ${label}: esperado=${expected} obtido=${got}`);
  return ok;
}

(async () => {
  console.log(`sessao simulada: ${SID}\npid deste processo (visto como o agente): ${process.pid}\n`);
  let allOk = true;

  allOk = await step('SessionStart -> livre', {
    hook_event_name: 'SessionStart',
    session_id: SID,
    cwd: 'C:\\Users\\ricar\\meu-projeto',
    model: 'opus',
    // conteudo sensivel que nao pode atravessar
    prompt: 'SEGREDO',
    transcript_path: 'C:\\x\\SEGREDO.jsonl',
  }, 'free') && allOk;

  allOk = await step('UserPromptSubmit -> trabalhando', {
    hook_event_name: 'UserPromptSubmit', session_id: SID, turn_id: 't1', prompt: 'SEGREDO',
  }, 'busy') && allOk;

  allOk = await step('Notification(permission_prompt) -> aguardando aprovacao', {
    hook_event_name: 'Notification', session_id: SID, turn_id: 't1', notification_type: 'permission_prompt',
  }, 'waitingForApproval') && allOk;

  allOk = await step('PostToolUse -> voltou a trabalhar', {
    hook_event_name: 'PostToolUse', session_id: SID, turn_id: 't1', tool_name: 'Bash',
  }, 'busy') && allOk;

  allOk = await step('Stop -> livre', {
    hook_event_name: 'Stop', session_id: SID, turn_id: 't1',
  }, 'free') && allOk;

  const s = snapshot();
  console.log('\nmetadado que o app guardou desta sessao:');
  console.log(`  cwd:    ${s && s.cwd}`);
  console.log(`  modelo: ${s && s.model}`);
  console.log(`  pid:    ${s && s.pid}`);
  console.log(`  hook:   ${s && s.hasHookEvidence}`);

  const raw = fs.readFileSync(paths.sessionsSnapshot, 'utf8');
  const vazou = raw.includes('SEGREDO');
  console.log(`\n  ${vazou ? 'FALHOU' : 'ok  '} nada de sensivel foi parar no estado persistido`);

  const cwdOk = s && s.cwd === 'C:\\Users\\ricar\\meu-projeto' && s.model === 'opus';
  console.log(`  ${cwdOk ? 'ok  ' : 'FALHOU'} o enriquecimento do SessionStart sobreviveu aos eventos seguintes`);

  allOk = allOk && !vazou && cwdOk;

  await step('SessionEnd -> encerrada', {
    hook_event_name: 'SessionEnd', session_id: SID,
  }, 'ended');

  console.log(allOk ? '\ne2e ao vivo: tudo certo' : '\ne2e ao vivo: houve falhas');
  process.exit(allOk ? 0 : 1);
})();
