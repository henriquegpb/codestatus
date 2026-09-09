'use strict';

// Ported from the InstallerTests.swift cases that still hold here.
//
// The central property is the original's: settings.json belongs to the user,
// and an install or an uninstall must never destroy what was already there.
// That half is the same on both platforms and every case below runs on both.
//
// What differs is the shape of the entry that gets written, and each seam's
// shape is checked in its own section at the end. Which seam runs is chosen by
// CODESTATUS_PLATFORM, and package.json runs this suite twice — so the Windows
// entry format is checked on a Linux runner and the Linux one on a Mac, rather
// than each being exercised for the first time by a user.
//
// Runs against a temporary file, never the real configuration — see
// CODESTATUS_CLAUDE_SETTINGS in src/platform/<os>/paths.js.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

// Set before anything under src/ is required: the seam is resolved at load.
//
// Taken from the argument vector rather than the environment so package.json
// can run this suite twice in one line on either shell, without a helper
// package to set a variable. Nothing third-party gets added to a project whose
// whole claim is that it watches your coding sessions with no dependencies.
function chosenSeam() {
  const flag = process.argv.indexOf('--seam');
  if (flag !== -1 && process.argv[flag + 1]) return process.argv[flag + 1];
  return process.platform === 'win32' ? 'win32' : 'linux';
}

const SEAM = chosenSeam();
if (SEAM !== 'win32' && SEAM !== 'linux') {
  throw new Error(`unknown seam ${SEAM}; expected win32 or linux`);
}
process.env.CODESTATUS_PLATFORM = SEAM;

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'codestatus-test-'));
const SETTINGS = path.join(TMP, 'settings.json');
process.env.CODESTATUS_CLAUDE_SETTINGS = SETTINGS;
// Installing for real writes a launcher, a receipt and a backup of every
// settings.json this suite creates. They belong in the temp directory with
// everything else, not in the data directory of whoever ran the tests — which
// matters now that the Windows seam runs on machines that are not Windows.
process.env.CODESTATUS_DATA_HOME = TMP;
// The other seams. The runtime and the script have to exist on disk for the
// install to proceed, and neither cmd.exe nor a distribution's /usr/bin/env is
// guaranteed to be where the suite happens to be running — so it points them at
// real files it owns and checks the shape of what gets written.
const RUNTIME = process.execPath;
const SCRIPT = path.join(TMP, 'hook.js');
const COMSPEC = path.join(TMP, 'cmd.exe');
const ENV_BINARY = path.join(TMP, 'env');
fs.writeFileSync(SCRIPT, '// stand-in for hook.js\n');
fs.writeFileSync(COMSPEC, '');
fs.writeFileSync(ENV_BINARY, '');
process.env.CODESTATUS_HOOK_RUNTIME = RUNTIME;
process.env.CODESTATUS_HOOK_SCRIPT = SCRIPT;
process.env.CODESTATUS_COMSPEC = COMSPEC;
process.env.CODESTATUS_ENV_BINARY = ENV_BINARY;

const installer = require('../src/install/claude');
const runtime = require('../src/platform/runtime');

const { CLAUDE_EVENTS } = installer;
const onWin32 = SEAM === 'win32';

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

test('A third-party hook that runs through the same system binary is not ours', () => {
  // Our `command` is a binary anybody may use — cmd.exe on one platform,
  // /usr/bin/env on the other. Ownership has to rest on the paths inside the
  // invocation, never on that.
  const theirs = onWin32
    ? { command: COMSPEC, args: ['/d', '/c', 'C:\\tools\\their-hook.cmd'] }
    : { command: ENV_BINARY, args: ['FOO=1', '/usr/bin/node', '/home/a/their-hook.js'] };
  assert.strictEqual(installer.isOurEntry({ hooks: [{ type: 'command', ...theirs }] }), false);
});

// --- the Windows entry shape ------------------------------------------------

if (onWin32) {
  test('win32: the written command runs our shim, and the shim runs our hook', () => {
    write({});
    installer.install();
    const h = read().hooks.SessionStart[0].hooks[0];
    assert.deepStrictEqual(h.command, COMSPEC);
    assert.deepStrictEqual(h.args, ['/d', '/c', runtime.launcherPath('claude-code')]);

    const shim = fs.readFileSync(runtime.launcherPath('claude-code'), 'utf8');
    assert.ok(shim.includes('set ELECTRON_RUN_AS_NODE=1'), 'the shim must set the variable');
    assert.ok(shim.includes(RUNTIME), 'the shim must call the resolved runtime');
    assert.ok(shim.includes(SCRIPT), 'the shim must run hook.js');
    assert.ok(shim.includes('--provider claude-code'), 'the provider belongs in the shim');
  });

  test('win32: nothing follows the shim path in the argument vector', () => {
    // `cmd /c` preserves the quotes around an executable path only when nothing
    // comes after the closing quote. Add an argument and it strips them instead,
    // and a user whose profile folder contains a space — which Windows allows —
    // gets a hook that tries to run C:\Users\John. The provider flag lives in
    // the shim for exactly this reason, and this is the case that says so.
    write({});
    installer.install();
    const h = read().hooks.SessionStart[0].hooks[0];
    assert.strictEqual(h.args.length, 3, `expected /d /c <shim>, got ${h.args.join(' ')}`);
    assert.strictEqual(h.args[h.args.length - 1], runtime.launcherPath('claude-code'));
  });

  test('win32: the shim is rewritten on every install, because the paths move', () => {
    write({});
    installer.install();
    fs.writeFileSync(runtime.launcherPath('claude-code'), 'stale\r\n');
    installer.install();
    const shim = fs.readFileSync(runtime.launcherPath('claude-code'), 'utf8');
    assert.ok(shim.includes('ELECTRON_RUN_AS_NODE'));
  });

  test('win32: both older entry formats are still recognised as ours', () => {
    // Anyone who installed before a given fix still has that shape in their
    // file. Each has to stay recognisable, or reinstalling would leave it
    // behind and the hook would fire twice per event.
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
}

// --- the Linux entry shape --------------------------------------------------

if (!onWin32) {
  test('linux: the entry is env, the variable, the runtime, and the script', () => {
    // Everything the Windows shim exists to work around is one argument here.
    write({});
    installer.install();
    const h = read().hooks.SessionStart[0].hooks[0];
    assert.strictEqual(h.command, ENV_BINARY);
    assert.deepStrictEqual(h.args, [
      'ELECTRON_RUN_AS_NODE=1', RUNTIME, SCRIPT, '--provider', 'claude-code',
    ]);
  });

  test('linux: installing writes no launcher file', () => {
    write({});
    const receipt = installer.install();
    assert.strictEqual(installer.status().launcher, null);
    assert.ok(receipt.hookInvocation.args.includes('ELECTRON_RUN_AS_NODE=1'));
  });

  test('linux: ownership is case-sensitive, because the filesystem is', () => {
    // Folding case here would let us claim — and then delete — an entry
    // pointing at somebody else's file that differs only in case, which is a
    // different file on every Linux filesystem in ordinary use.
    const theirs = {
      hooks: [{
        type: 'command',
        command: ENV_BINARY,
        args: ['ELECTRON_RUN_AS_NODE=1', RUNTIME, SCRIPT.toUpperCase(), '--provider', 'claude-code'],
      }],
    };
    assert.strictEqual(installer.isOurEntry(theirs), false);
  });

  test('linux: an entry naming our hook script is ours whatever else it says', () => {
    // The runtime path changes with every update, so recognising our own entry
    // cannot depend on it — otherwise reinstalling after an update leaves the
    // old entry behind and the hook fires twice per event.
    const afterUpdate = {
      hooks: [{
        type: 'command',
        command: ENV_BINARY,
        args: ['ELECTRON_RUN_AS_NODE=1', '/opt/CodeStatus/old-binary', SCRIPT, '--provider', 'claude-code'],
      }],
    };
    assert.strictEqual(installer.isOurEntry(afterUpdate), true);
  });
}

// --- run --------------------------------------------------------------------

let failed = 0;
console.log(`\ninstaller (${SEAM})`);
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
