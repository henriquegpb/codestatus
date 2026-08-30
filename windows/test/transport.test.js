'use strict';

// Integration test for the transport: starts the real daemon, invokes the hook
// the way Claude Code would (payload on stdin), and checks what arrived.
//
// The case that matters most here is privacy. A real Claude Code payload
// carries the prompt, the tool input, and the transcript path, and none of it
// may cross the pipe.
//
// Needs the app closed: only one process can hold the named pipe.

const assert = require('assert');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const { skipUnlessWindows } = require('./harness');

if (skipUnlessWindows('transport')) process.exit(0);

const { Daemon } = require('../src/daemon/daemon');
const { AgentState } = require('../src/core/state');
const { paths } = require('../src/platform/paths');

const HOOK = path.join(__dirname, '..', 'hook', 'hook.js');

// A realistic Claude Code payload, carrying every kind of sensitive content it
// actually holds.
const SECRETS = {
  prompt: 'SECRET-PROMPT-must-not-leak',
  tool_input: { command: 'SECRET-COMMAND', file_path: 'C:\\private\\keys.env' },
  tool_response: 'SECRET-OUTPUT',
  last_assistant_message: 'SECRET-REPLY',
  transcript_path: 'C:\\Users\\someone\\.claude\\transcripts\\SECRET.jsonl',
  message: 'SECRET-MESSAGE',
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
      if (Date.now() - started > timeoutMs) return reject(new Error('timed out waiting'));
      return setTimeout(tick, 50);
    };
    tick();
  });
}

(async () => {
  console.log('\ntransport');

  // Clear the spool so nothing is inherited from a previous run.
  try {
    for (const f of fs.readdirSync(paths.spool)) fs.unlinkSync(path.join(paths.spool, f));
  } catch { /* does not exist yet */ }

  const daemon = new Daemon();

  await new Promise((resolve) => {
    daemon.once('listening', resolve);
    daemon.start();
  });
  console.log(`  ..    daemon listening on ${daemon.pipe}`);

  // Capture what actually crosses the pipe, so it can be inspected byte by byte.
  const seenLines = [];
  const originalIngest = daemon.ingest.bind(daemon);
  daemon.ingest = (line) => { seenLines.push(line); originalIngest(line); };

  let failed = 0;
  const check = (name, fn) => {
    try {
      fn();
      console.log(`  ok    ${name}`);
    } catch (err) {
      failed += 1;
      console.log(`  FAIL  ${name}\n        ${err.message}`);
    }
  };

  // --- 1. a whole turn across the real transport ----------------------------

  const sessionId = `it-${Date.now()}`;
  const exitCode = await runHook({
    hook_event_name: 'SessionStart',
    session_id: sessionId,
    cwd: 'C:\\Users\\test\\project',
    model: 'opus',
    ...SECRETS,
  });
  check('the hook exits 0 even carrying a dirty payload', () => {
    assert.strictEqual(exitCode, 0);
  });

  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`));
  check('SessionStart creates the session as free', () => {
    assert.strictEqual(daemon.registry.get(`claudeCode:${sessionId}`).state, AgentState.free);
  });

  await runHook({
    hook_event_name: 'UserPromptSubmit', session_id: sessionId, turn_id: 'turn-1', ...SECRETS,
  });
  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`).state === AgentState.busy);
  check('UserPromptSubmit takes the session to busy', () => {
    assert.strictEqual(daemon.registry.get(`claudeCode:${sessionId}`).state, AgentState.busy);
  });

  await runHook({
    hook_event_name: 'Notification',
    session_id: sessionId,
    turn_id: 'turn-1',
    notification_type: 'permission_prompt',
    ...SECRETS,
  });
  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`).state
    === AgentState.waitingForApproval);
  check('Notification(permission_prompt) asks for your attention', () => {
    assert.strictEqual(daemon.registry.counts().needsYou, 1);
  });

  await runHook({
    hook_event_name: 'Stop', session_id: sessionId, turn_id: 'turn-1', ...SECRETS,
  });
  await waitFor(() => daemon.registry.get(`claudeCode:${sessionId}`).state === AgentState.free);
  check('Stop returns the session to free', () => {
    assert.strictEqual(daemon.registry.get(`claudeCode:${sessionId}`).state, AgentState.free);
  });

  // --- 2. privacy -----------------------------------------------------------

  check('no sensitive content crossed the transport', () => {
    const wire = seenLines.join('\n');
    assert.ok(wire.length > 0, 'nothing reached the daemon');
    assert.ok(!wire.includes('SECRET'), `content leaked on the wire: ${wire}`);
    // Looks for the key in the form it would actually take in the JSON. A raw
    // substring search would false-positive: notification_type legitimately
    // holds "permission_prompt", which contains "prompt".
    for (const key of Object.keys(SECRETS)) {
      assert.ok(!wire.includes(`"${key}":`), `the key ${key} appeared on the wire`);
    }
  });

  check('the expected metadata arrived intact', () => {
    const first = JSON.parse(seenLines[0]);
    assert.strictEqual(first.session_id, sessionId);
    assert.strictEqual(first.hook_event_name, 'SessionStart');
    assert.strictEqual(first.cwd, 'C:\\Users\\test\\project');
    assert.strictEqual(first.provider, 'claudeCode');
    assert.ok(first.ppid > 0, 'the agent’s pid should have been captured');
  });

  check('the session kept the cwd, model and pid the hook carried', () => {
    const s = daemon.registry.get(`claudeCode:${sessionId}`);
    assert.strictEqual(s.cwd, 'C:\\Users\\test\\project');
    assert.strictEqual(s.model, 'opus');
    assert.ok(s.pid > 0);
    assert.strictEqual(s.hasHookEvidence, true);
  });

  // --- 3. delivery ----------------------------------------------------------

  // Regression. The hook used to resolve on the write callback and then call
  // destroy(), which fires when the data reaches the OS rather than the peer
  // and aborts the pipe rather than closing it. Events went missing now and
  // then, with no error anywhere. Twenty back-to-back deliveries is enough to
  // catch it: it never lost all of them, only some.
  const burstSession = `burst-${Date.now()}`;
  const BURST = 20;
  const before = seenLines.length;
  for (let i = 0; i < BURST; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await runHook({
      hook_event_name: 'PreToolUse',
      session_id: burstSession,
      turn_id: `turn-${i}`,
      tool_name: 'Read',
      ...SECRETS,
    });
  }
  await waitFor(() => seenLines.length - before >= BURST, 8000).catch(() => {});
  check('every event in a burst is delivered, not most of them', () => {
    assert.strictEqual(seenLines.length - before, BURST);
  });

  // --- 4. the spool, when the daemon is away --------------------------------

  daemon.stop();
  const offlineSession = `off-${Date.now()}`;
  await runHook({ hook_event_name: 'SessionStart', session_id: offlineSession, ...SECRETS });
  check('with the daemon away, the event goes to the spool', () => {
    const spooled = fs.readdirSync(paths.spool).filter((n) => n.endsWith('.ndjson'));
    assert.ok(spooled.length > 0, 'nothing was queued');
  });

  const revived = new Daemon();
  await new Promise((resolve) => { revived.once('listening', resolve); revived.start(); });
  await waitFor(() => revived.registry.get(`claudeCode:${offlineSession}`));
  check('on the way back, the daemon replays what the spool held', () => {
    assert.ok(revived.registry.get(`claudeCode:${offlineSession}`));
    assert.strictEqual(
      fs.readdirSync(paths.spool).filter((n) => n.endsWith('.ndjson')).length,
      0,
    );
  });
  revived.stop();

  console.log(failed === 0 ? '\nall transport cases passed' : `\n${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('fatal error in the test:', err);
  process.exit(1);
});
