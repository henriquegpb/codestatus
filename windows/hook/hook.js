'use strict';

// codestatus-hook — the observer the agent invokes on lifecycle events.
//
// Port of Sources/codestatus-hook/. The contract with the agent, in priority
// order:
//
//   1. Never block.  Every wait is bounded; there is no unbounded read,
//      connect, or write anywhere in this file.
//   2. Never fail.   The process always exits 0, on every path, including
//      malformed input, an absent daemon, and a full disk.
//   3. Never leak.   Only allowlisted metadata is read out of the payload.
//
// It is registered with async: true in Claude Code, so even this bounded work
// happens off the agent's critical path.
//
// Deliberately self-contained: no require of anything in ../src. Claude Code
// spawns this file by absolute path from settings.json, and it has to keep
// working even if the rest of the install is half-updated or broken. The two
// small duplications that buys — the app data path and the host detection — are
// each a handful of lines, and both are noted where they are mirrored.
//
// The one thing that is not a port: the macOS hook is a compiled Foundation-free
// binary, because it runs on every tool call. Here it is a Node cold start,
// which is tens of milliseconds of real work per event. `async: true` keeps it
// off the critical path; it does not make it free. See windows/README.md.

const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PIPE_TIMEOUT_MS = 250;
const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;
// Queue to disk only while the daemon has been seen recently; see writeToSpool.
const SPOOL_MAX_HEARTBEAT_AGE_MS = 24 * 60 * 60 * 1000;
const SPOOL_MAX_FILES = 512;
// Hard safety net: whatever happens, the process dies here.
const HARD_EXIT_MS = 1500;

// The only keys allowed to cross the transport.
//
// Note what is absent and must stay absent: prompt, last_assistant_message,
// tool_input, tool_output, tool_response, message, error_message,
// transcript_path.
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

// Exit 0 whatever happens: a monitoring tool has no right to turn its own
// unavailability into the agent's problem.
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

// Mints a unique idempotency key without coordination. Concurrent hook
// processes do not collide: their pids differ. Sequential runs of the same pid
// do not collide: the monotonic clock differs.
function makeEventID() {
  return `${process.pid}-${process.hrtime.bigint().toString()}-0`;
}

// Windows has no TERM_PROGRAM. The host is inferred from the variables the
// terminals here do export.
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

// Reads all of stdin, keeping at most `limit` bytes but always draining the
// rest. Draining matters: if we stopped reading early the agent's write would
// fail with EPIPE, which is exactly the kind of interference forbidden here.
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
    // A stdin that never closes must not hold us.
    const guard = setTimeout(finish, 400);
    guard.unref();

    process.stdin.on('data', (chunk) => {
      if (total < MAX_PAYLOAD_BYTES) {
        const take = Math.min(chunk.length, MAX_PAYLOAD_BYTES - total);
        chunks.push(take === chunk.length ? chunk : chunk.subarray(0, take));
        total += take;
      }
      // Anything past the limit is read and thrown away.
    });
    process.stdin.on('end', () => { clearTimeout(guard); finish(); });
    process.stdin.on('error', () => { clearTimeout(guard); finish(); });
  });
}

// Reduces the payload to allowlisted scalars. Nothing here re-reads the original
// payload, so there is no path by which prompt or tool content reaches the output.
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
    // An allowlisted key should never hold a container; skip it if it does.
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
    // Our parent is the agent. The daemon resolves this to a session.
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
      try { socket.destroy(); } catch { /* ignore */ }
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

// Writes the event to the on-disk spool so a restarting daemon can replay it.
//
// Conditioned on the daemon being alive: if CodeStatus is deleted without
// running the uninstaller, the hook entries survive in the agent's config and
// would queue for ever, filling the disk of someone who no longer has the app.
// A stale heartbeat means drop the event.
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
    // Atomic publication: a half-written file must never become visible to the
    // daemon under the real name.
    fs.writeFileSync(tempPath, line, { mode: 0o600 });
    fs.renameSync(tempPath, finalPath);
  } catch {
    /* full disk or permissions: silence, by contract */
  }
}

(async () => {
  try {
    const raw = await readStdin();
    const fields = scanAllowed(raw);
    // With no event name there is nothing to report.
    if (!fields.hook_event_name) return done();

    const line = buildLine(fields);
    const pipe = readSmallFile(path.join(runDir, 'pipe-name'));

    let delivered = false;
    if (pipe) delivered = await connectAndSend(pipe, line);
    if (!delivered) writeToSpool(line);
  } catch {
    /* by contract: never propagates */
  }
  return done();
})();
