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
// The other seams. The runtime and the script have to exist on disk for the
// install to proceed, and cmd.exe does not exist off Windows — so the suite
// points all three at real files it owns and checks the shape of what gets
// written, which is the part that is platform-independent.
const RUNTIME = process.execPath;
const SCRIPT = path.join(TMP, 'hook.js');
const COMSPEC = path.join(TMP, 'cmd.exe');
fs.writeFileSync(SCRIPT, '// stand-in for hook.js\n');
fs.writeFileSync(COMSPEC, '');
process.env.CODESTATUS_HOOK_RUNTIME = RUNTIME;
process.env.CODESTATUS_HOOK_SCRIPT = SCRIPT;
process.env.CODESTATUS_COMSPEC = COMSPEC;

const installer = require('../src/install/claude');
const { shimPath } = require('../src/platform/runtime');

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

test('Installing records when it happened, for the unreported diagnosis', () => {
  write({});
  const before = Date.now();
  installer.install();
  const at = installer.hooksInstalledAt().claudeCode;
  assert.ok(at, 'no install time was recorded');
  assert.ok(at >= before - 1000 && at <= Date.now() + 1000);
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

test('The written command runs our shim, and the shim runs our hook', () => {
  write({});
  installer.install();
  const h = read().hooks.SessionStart[0].hooks[0];
  assert.deepStrictEqual(h.command, COMSPEC);
  assert.deepStrictEqual(h.args, ['/d', '/c', shimPath('claude-code')]);

  const shim = fs.readFileSync(shimPath('claude-code'), 'utf8');
  assert.ok(shim.includes('set ELECTRON_RUN_AS_NODE=1'), 'the shim must set the variable');
  assert.ok(shim.includes(RUNTIME), 'the shim must call the resolved runtime');
  assert.ok(shim.includes(SCRIPT), 'the shim must run hook.js');
  assert.ok(shim.includes('--provider claude-code'), 'the provider belongs in the shim');
});

test('Nothing follows the shim path in the argument vector', () => {
  // `cmd /c` preserves the quotes around an executable path only when nothing
  // comes after the closing quote. Add an argument and it strips them instead,
  // and a user whose profile folder contains a space — which Windows allows —
  // gets a hook that tries to run C:\Users\John. The provider flag lives in
  // the shim for exactly this reason, and this is the case that says so.
  write({});
  installer.install();
  const h = read().hooks.SessionStart[0].hooks[0];
  assert.strictEqual(h.args.length, 3, `expected /d /c <shim>, got ${h.args.join(' ')}`);
  assert.strictEqual(h.args[h.args.length - 1], shimPath('claude-code'));
});

test('The shim is rewritten on every install, because the paths move', () => {
  write({});
  installer.install();
  fs.writeFileSync(shimPath('claude-code'), 'stale\r\n');
  installer.install();
  assert.ok(fs.readFileSync(shimPath('claude-code'), 'utf8').includes('ELECTRON_RUN_AS_NODE'));
});

test('Installing refuses when the runtime is missing', () => {
  // Better to stop here than to write an entry whose only symptom is silence.
  write({});
  process.env.CODESTATUS_HOOK_RUNTIME = path.join(TMP, 'does-not-exist.exe');
  try {
    assert.throws(() => installer.install(), /runtime/i);
  } finally {
    process.env.CODESTATUS_HOOK_RUNTIME = RUNTIME;
  }
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

test('Both older entry formats are still recognised as ours', () => {
  // Anyone who installed before a given fix still has that shape in their file.
  // Each has to stay recognisable, or reinstalling would leave it behind and
  // the hook would fire twice per event.
  const singleLine = {
    hooks: [{
      type: 'command',
      command: `"C:\\node.exe" "${SCRIPT}" --provider claude-code`,
      timeout: 5,
      async: true,
    }],
  };
  const nodeExecForm = {
    hooks: [{
      type: 'command',
      command: 'C:\\Program Files\\nodejs\\node.exe',
      args: [SCRIPT, '--provider', 'claude-code'],
      timeout: 5,
      async: true,
    }],
  };
  assert.strictEqual(installer.isOurEntry(singleLine), true, 'single line');
  assert.strictEqual(installer.isOurEntry(nodeExecForm), true, 'node exec form');
});

test('A third-party hook that also runs through cmd.exe is not ours', () => {
  // cmd.exe is now our `command`, and it is a system binary anyone may use.
  // Ownership has to rest on the paths inside the invocation, never on that.
  const theirs = {
    hooks: [{
      type: 'command',
      command: COMSPEC,
      args: ['/d', '/c', 'C:\\tools\\their-hook.cmd'],
    }],
  };
  assert.strictEqual(installer.isOurEntry(theirs), false);
});

// --- run --------------------------------------------------------------------

let failed = 0;
console.log('\ninstaller');
for (const [name, fn] of tests) {
  try {
    // Every case starts from a clean file.
    try { fs.unlinkSync(SETTINGS); } catch { /* did not exist */ }
    try { fs.unlinkSync(require('../src/platform/paths').paths.installReceipts); } catch { /* ditto */ }
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
