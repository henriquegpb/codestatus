'use strict';

// codestatus-hook - o observador que o agente invoca nos eventos de ciclo de vida.
//
// Porte de Sources/codestatus-hook/. Contrato com o agente, em ordem de prioridade:
//
//   1. Nunca bloquear.  Toda espera e limitada; nao existe read, connect ou
//      write ilimitado em lugar nenhum deste arquivo.
//   2. Nunca falhar.    O processo sempre sai com 0, em todo caminho, incluindo
//      entrada malformada, daemon ausente e disco cheio.
//   3. Nunca vazar.     So metadado da allowlist e lido do payload.
//
// E registrado com async:true no Claude Code, entao ate esse trabalho limitado
// acontece fora do caminho critico do agente.

const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PIPE_TIMEOUT_MS = 250;
const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;
// Enfileira em disco so enquanto o daemon foi visto recentemente; ver writeToSpool.
const SPOOL_MAX_HEARTBEAT_AGE_MS = 24 * 60 * 60 * 1000;
const SPOOL_MAX_FILES = 512;
// Rede de seguranca dura: aconteca o que acontecer, o processo morre aqui.
const HARD_EXIT_MS = 1500;

// As unicas chaves que podem cruzar o transporte.
//
// Note o que esta ausente e precisa continuar ausente: prompt,
// last_assistant_message, tool_input, tool_output, tool_response, message,
// error_message, transcript_path.
const ALLOWED_KEYS = new Set([
  'session_id',
  'hook_event_name',
  'cwd',
  'turn_id',
  'prompt_id',
  'tool_use_id',
  'tool_name',
  'notification_type',
  'source',
  'start_reason',
  'end_reason',
  'error_type',
  'permission_mode',
  'model',
]);

const base = process.env.LOCALAPPDATA
  ? path.join(process.env.LOCALAPPDATA, 'CodeStatus')
  : path.join(os.homedir(), 'AppData', 'Local', 'CodeStatus');
const runDir = path.join(base, 'run');

// Sai com 0 aconteca o que acontecer: uma ferramenta de monitoramento nao tem o
// direito de transformar a propria indisponibilidade em problema do agente.
function done() {
  process.exit(0);
}
const hardExit = setTimeout(done, HARD_EXIT_MS);
hardExit.unref();
process.on('uncaughtException', done);
process.on('unhandledRejection', done);

function providerArgument() {
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--provider' && i + 1 < argv.length) {
      const v = argv[i + 1];
      if (v === 'claude-code' || v === 'claudeCode') return 'claudeCode';
      if (v === 'codex') return 'codex';
      return 'generic';
    }
  }
  return 'generic';
}

// Cunha uma chave de idempotencia unica sem coordenacao. Processos de hook
// concorrentes nao colidem: os pids diferem. Execucoes sequenciais do mesmo pid
// nao colidem: o relogio monotonico difere.
function makeEventID() {
  return `${process.pid}-${process.hrtime.bigint().toString()}-0`;
}

// No Windows nao existe TERM_PROGRAM. Deduzimos o host das variaveis que os
// terminais daqui realmente exportam.
function detectHost() {
  if (process.env.TERM_PROGRAM === 'vscode' || process.env.VSCODE_INJECTION) return 'vsCode';
  if (process.env.WT_SESSION) return 'windowsTerminal';
  if (process.env.PSModulePath) return 'powershell';
  return 'unknown';
}

function readSmallFile(p) {
  try {
    return fs.readFileSync(p, 'utf8').trim();
  } catch {
    return null;
  }
}

// Le todo o stdin, guardando no maximo `limit` bytes mas sempre drenando o
// resto. Drenar importa: se parassemos de ler cedo, a escrita do agente
// falharia com EPIPE, que e exatamente o tipo de interferencia proibida aqui.
function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    let total = 0;
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    };
    // Um stdin que nunca fecha nao pode nos prender.
    const guard = setTimeout(finish, 400);
    guard.unref();

    process.stdin.on('data', (chunk) => {
      if (total < MAX_PAYLOAD_BYTES) {
        const take = Math.min(chunk.length, MAX_PAYLOAD_BYTES - total);
        chunks.push(take === chunk.length ? chunk : chunk.subarray(0, take));
        total += take;
      }
      // Tudo alem do limite e lido e jogado fora.
    });
    process.stdin.on('end', () => { clearTimeout(guard); finish(); });
    process.stdin.on('error', () => { clearTimeout(guard); finish(); });
  });
}

// Reduz o payload a escalares da allowlist. Nada aqui re-le o payload original,
// entao nao ha caminho pelo qual conteudo de prompt ou de ferramenta chegue a
// saida.
function scanAllowed(raw) {
  const out = {};
  let parsed;
  try {
    parsed = JSON.parse(raw.toString('utf8'));
  } catch {
    return out;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return out;
  for (const key of Object.keys(parsed)) {
    if (!ALLOWED_KEYS.has(key)) continue;
    const value = parsed[key];
    const t = typeof value;
    // Uma chave da allowlist nunca deveria conter um container; ignore se contiver.
    if (value === null || t === 'string' || t === 'number' || t === 'boolean') {
      out[key] = value;
    }
  }
  return out;
}

function buildLine(fields) {
  const envelope = {
    v: 1,
    id: makeEventID(),
    provider: providerArgument(),
    ts: Date.now() / 1000,
    // Nosso pai e o agente. O daemon resolve isso para cwd e tempo de inicio.
    ppid: process.ppid,
    host: detectHost(),
  };
  return `${JSON.stringify({ ...envelope, ...fields })}\n`;
}

function connectAndSend(pipe, line) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      try { socket.destroy(); } catch { /* ignora */ }
      resolve(ok);
    };
    const socket = net.connect(pipe);
    socket.setTimeout(PIPE_TIMEOUT_MS, () => finish(false));
    socket.on('error', () => finish(false));
    socket.on('connect', () => {
      socket.write(line, () => finish(true));
    });
    const guard = setTimeout(() => finish(false), PIPE_TIMEOUT_MS);
    guard.unref();
  });
}

// Escreve o evento no spool em disco para um daemon reiniciando conseguir
// reproduzi-lo.
//
// Condicionado a vida do daemon: se o CodeStatus for apagado sem rodar o
// desinstalador, as entradas de hook sobrevivem na config do agente e ficariam
// enfileirando pra sempre, enchendo o disco de alguem que nem tem mais o app.
// Um heartbeat velho significa descartar o evento.
function writeToSpool(line) {
  try {
    const hb = fs.statSync(path.join(runDir, 'heartbeat'));
    if (Date.now() - hb.mtimeMs > SPOOL_MAX_HEARTBEAT_AGE_MS) return;
  } catch {
    return;
  }
  const spoolDir = path.join(runDir, 'spool');
  try {
    fs.mkdirSync(spoolDir, { recursive: true });
    if (fs.readdirSync(spoolDir).length >= SPOOL_MAX_FILES) return;
    const name = `${Date.now()}-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
    const finalPath = path.join(spoolDir, `${name}.ndjson`);
    const tempPath = `${finalPath}.tmp`;
    // Publicacao atomica: um arquivo escrito pela metade nunca pode ficar
    // visivel ao daemon sob o nome real.
    fs.writeFileSync(tempPath, line, { mode: 0o600 });
    fs.renameSync(tempPath, finalPath);
  } catch {
    /* disco cheio ou permissao: silencio, por contrato */
  }
}

(async () => {
  try {
    const raw = await readStdin();
    const fields = scanAllowed(raw);
    // Sem nome de evento nao ha o que reportar.
    if (!fields.hook_event_name) return done();

    const line = buildLine(fields);
    const pipe = readSmallFile(path.join(runDir, 'pipe-name'));

    let delivered = false;
    if (pipe) delivered = await connectAndSend(pipe, line);
    if (!delivered) writeToSpool(line);
  } catch {
    /* por contrato: nunca propaga */
  }
  done();
})();
