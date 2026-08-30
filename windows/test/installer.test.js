'use strict';

// Ported from the InstallerTests.swift cases that still hold on Windows.
//
// The central property is the original's: settings.json belongs to the user,
// and an install or an uninstall must never destroy what was already there.
//
// Runs against a temporary file, never the real configuration — see
// CODESTATUS_CLAUDE_SETTINGS in src/platform/paths.js.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'codestatus-test-'));
const SETTINGS = path.join(TMP, 'settings.json');
process.env.CODESTATUS_CLAUDE_SETTINGS = SETTINGS;
// The other test seam: `where node` only exists on Windows, and the installer's
// behaviour is worth checking on whatever machine the developer is sitting at.
process.env.CODESTATUS_NODE_PATH = process.env.CODESTATUS_NODE_PATH || process.execPath;

const installer = require('../src/install/claude');

const { CLAUDE_EVENTS } = installer;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

const read = () => JSON.parse(fs.readFileSync(SETTINGS, 'utf8'));
const write = (obj) => fs.writeFileSync(SETTINGS, JSON.stringify(obj, null, 2), 'utf8');

// --- install ----------------------------------------------------------------

test('Installing registers every lifecycle event', () => {
  write({});
  installer.install();
  const s = read();
  for (const event of CLAUDE_EVENTS) {
    assert.ok(Array.isArray(s.hooks[event]), `missing event ${event}`);
    assert.strictEqual(s.hooks[event].length, 1, `${event} should have one entry`);
  }
  assert.strictEqual(installer.isInstalled(), true);
});

test('The registered set matches the macOS installer', () => {
  // The two lists are maintained by hand in two languages, so the count is
  // asserted rather than assumed: a new event added on one side and forgotten
  // on the other is exactly how the state machines drift apart.
  assert.strictEqual(CLAUDE_EVENTS.length, 14);
  for (const required of ['PostToolUseFailure', 'PostToolBatch', 'Elicitation', 'ElicitationResult']) {
    assert.ok(CLAUDE_EVENTS.includes(required), `${required} is not registered`);
  }
});

test('Every entry is async, so it never sits on the agent’s critical path', () => {
  write({});
  installer.install();
  const s = read();
  for (const event of CLAUDE_EVENTS) {
    const hook = s.hooks[event][0].hooks[0];
    assert.strictEqual(hook.async, true, `${event} is not async`);
    assert.strictEqual(hook.type, 'command');
    assert.ok(hook.timeout > 0);
  }
});

test('Installing preserves the settings the user already had', () => {
  write({
    model: 'opus',
    theme: 'dark',
    permissions: { allow: ['Bash(git status)'] },
    statusLine: { type: 'command', command: 'my-script' },
  });
  installer.install();
  const s = read();
  assert.strictEqual(s.model, 'opus');
  assert.strictEqual(s.theme, 'dark');
  assert.deepStrictEqual(s.permissions, { allow: ['Bash(git status)'] });
  assert.deepStrictEqual(s.statusLine, { type: 'command', command: 'my-script' });
});

test('Installing preserves third-party hooks on the same event', () => {
  write({
    hooks: {
      PreToolUse: [{ hooks: [{ type: 'command', command: 'somebody-elses-tool.exe' }] }],
    },
  });
  installer.install();
  const entries = read().hooks.PreToolUse;
  assert.strictEqual(entries.length, 2, 'the third-party hook should still be there');
  assert.ok(entries.some((e) => !installer.isOurEntry(e)));
  assert.ok(entries.some((e) => installer.isOurEntry(e)));
});

test('Reinstalling does not duplicate entries', () => {
  write({});
  installer.install();
  installer.install();
  installer.install();
  const s = read();
  for (const event of CLAUDE_EVENTS) {
    assert.strictEqual(s.hooks[event].length, 1, `${event} was duplicated`);
  }
});

test('Installing creates the file when it does not exist', () => {
  assert.ok(!fs.existsSync(SETTINGS));
  installer.install();
  assert.ok(fs.existsSync(SETTINGS));
  assert.strictEqual(installer.isInstalled(), true);
});

// --- uninstall --------------------------------------------------------------

test('Uninstalling removes only our entries and restores the file', () => {
  write({
    model: 'opus',
    hooks: {
      PreToolUse: [{ hooks: [{ type: 'command', command: 'somebody-elses-tool.exe' }] }],
    },
  });
  installer.install();
  installer.uninstall();
  const s = read();
  assert.strictEqual(s.model, 'opus');
  assert.strictEqual(s.hooks.PreToolUse.length, 1);
  assert.ok(!installer.isOurEntry(s.hooks.PreToolUse[0]));
  assert.strictEqual(installer.isInstalled(), false);
});

test('Uninstalling deletes the hooks key only when we created it', () => {
  write({ model: 'opus' });
  installer.install();
  installer.uninstall();
  assert.strictEqual(read().hooks, undefined, 'the hooks key should be gone');

  // Now the opposite: the user had the key before we arrived.
  write({ model: 'opus', hooks: {} });
  installer.install();
  installer.uninstall();
  assert.notStrictEqual(read().hooks, undefined, 'the hooks key was the user’s');
});

test('Uninstalling is idempotent', () => {
  write({ model: 'opus' });
  installer.install();
  installer.uninstall();
  installer.uninstall();
  assert.strictEqual(installer.isInstalled(), false);
  assert.strictEqual(read().model, 'opus');
});

// --- ownership --------------------------------------------------------------

test('Someone else’s hook that merely mentions our name is not ours', () => {
  const impostor = {
    hooks: [{ type: 'command', command: 'echo "codestatus is nice" >> C:\\log.txt' }],
  };
  assert.strictEqual(installer.isOurEntry(impostor), false);
});

test('A malformed entry is never claimed as ours', () => {
  assert.strictEqual(installer.isOurEntry(null), false);
  assert.strictEqual(installer.isOurEntry({}), false);
  assert.strictEqual(installer.isOurEntry({ hooks: 'not an array' }), false);
  assert.strictEqual(installer.isOurEntry({ hooks: [{ type: 'command' }] }), false);
});

// --- file safety ------------------------------------------------------------

test('An invalid settings.json stops the install rather than overwriting it', () => {
  fs.writeFileSync(SETTINGS, '{ this is not valid json', 'utf8');
  assert.throws(() => installer.install());
  assert.ok(fs.readFileSync(SETTINGS, 'utf8').includes('this is not valid json'));
});

test('Installing leaves a backup behind', () => {
  write({ model: 'opus' });
  const receipt = installer.install();
  assert.ok(receipt.backupPath, 'no backup was recorded');
  assert.ok(fs.existsSync(receipt.backupPath));
  assert.strictEqual(JSON.parse(fs.readFileSync(receipt.backupPath, 'utf8')).model, 'opus');
});

test('The written command points at a real node and at our hook', () => {
  write({});
  installer.install();
  const h = read().hooks.SessionStart[0].hooks[0];
  assert.strictEqual(h.command, installer.resolveNodePath());
  assert.notStrictEqual(h.command, 'node', 'the absolute path should have been resolved');
  assert.ok(h.args.some((a) => a.endsWith('hook.js')), 'args should point at hook.js');
  assert.deepStrictEqual(h.args.slice(-2), ['--provider', 'claude-code']);
});

// Regression. The first version of this port wrote everything as one command
// line, with no `args`. That puts Claude Code in its shell form, and on Windows
// that shell can be PowerShell — where "C:\...\node.exe" script.js is a string
// literal it echoes rather than executes. The hook never ran, with no error at
// all: no log, nothing in the spool, just silence.
test('The entry uses the exec form (args), never a single command line', () => {
  write({});
  installer.install();
  for (const event of CLAUDE_EVENTS) {
    const h = read().hooks[event][0].hooks[0];
    assert.ok(Array.isArray(h.args), `${event} needs args to use the exec form`);
    assert.ok(!h.command.includes(' --provider'), `${event} folded arguments into command`);
    assert.ok(!h.command.includes('"'), `${event} has quotes in command, a single-line sign`);
  }
});

test('An entry in the old single-line format is still recognised as ours', () => {
  // Anyone who installed before that fix has the single-line entry. It has to
  // stay recognisable, or reinstalling would leave it behind and the hook would
  // fire twice per event.
  const old = {
    hooks: [{
      type: 'command',
      command: `"C:\\node.exe" "${installer.HOOK_SCRIPT}" --provider claude-code`,
      timeout: 5,
      async: true,
    }],
  };
  assert.strictEqual(installer.isOurEntry(old), true);
});

// --- run --------------------------------------------------------------------

let failed = 0;
console.log('\ninstaller');
for (const [name, fn] of tests) {
  try {
    // Every case starts from a clean file.
    try { fs.unlinkSync(SETTINGS); } catch { /* did not exist */ }
    fn();
    console.log(`  ok    ${name}`);
  } catch (err) {
    failed += 1;
    console.log(`  FAIL  ${name}\n        ${err.message}`);
  }
}

try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* ignore */ }
console.log(`\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed === 0 ? 0 : 1);
