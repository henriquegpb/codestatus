'use strict';

// The platform seams: why a session is silent, which terminal it is in, how the
// agent is told to invoke the hook, and what the tray says. None of this exists
// on macOS — the platform hands the mac app a start time, a TERM_PROGRAM, and a
// menu bar that takes text — so none of it is covered by the Swift suite either.
//
// Both seams are exercised here, from whichever machine happens to be running
// the suite, by requiring them directly rather than through the dispatcher.
// That is the whole reason src/platform/ is split the way it is: the Windows
// port learned once, expensively, that code which only ever runs on its own
// operating system gets its first execution from a user. Everything below is a
// pure function or a filesystem call against a temporary directory, so none of
// it needs the kernel it describes.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, run } = require('./harness');

const { diagnose, notConnectedTotal } = require('../src/core/diagnosis');
const { chooseDisplay, glyphKeyFor, buildTooltip } = require('../src/ui/tray-content');
const { HostApplication, AgentProvider } = require('../src/core/events');

const win32Host = require('../src/platform/win32/host');
const win32Scan = require('../src/platform/win32/process-scan');
const win32Transport = require('../src/platform/win32/transport');
const linuxHost = require('../src/platform/linux/host');
const linuxScan = require('../src/platform/linux/process-scan');
const linuxRuntime = require('../src/platform/linux/runtime');
const linuxTransport = require('../src/platform/linux/transport');
const linuxFocus = require('../src/platform/linux/focus');

const HOUR = 3600 * 1000;
const NOW = 1_700_000_000_000;

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'codestatus-platform-'));

function silentSession(overrides = {}) {
  return {
    provider: AgentProvider.claudeCode,
    processStartTime: NOW - HOUR,
    hasHookEvidence: false,
    ...overrides,
  };
}

// --- why a session is silent ------------------------------------------------

test('An agent we were never connected to is reported as not connected', () => {
  // The only cause that never resolves on its own: with no hooks in the file,
  // no session of this agent will ever report, however long anyone waits.
  const d = diagnose({
    sessions: [silentSession()],
    hooksInstalledAt: {},
    connectedProviders: new Set(),
    now: NOW,
  });
  assert.strictEqual(notConnectedTotal(d), 1);
  assert.strictEqual(d.predatesHooks, 0);
  assert.strictEqual(d.unexplained, 0);
});

test('A session older than the install predates the hooks', () => {
  const d = diagnose({
    sessions: [silentSession({ processStartTime: NOW - 2 * HOUR })],
    hooksInstalledAt: { claudeCode: NOW - HOUR },
    connectedProviders: new Set([AgentProvider.claudeCode]),
    now: NOW,
  });
  assert.strictEqual(d.predatesHooks, 1, 'a new session fixes this on its own');
  assert.strictEqual(notConnectedTotal(d), 0);
});

test('A session with no start time is unexplained, never guessed at', () => {
  // Reachable on Linux whenever /proc/stat's btime could not be read: the scan
  // reports a null rather than putting a made-up moment on the same axis as the
  // install time it would be compared against.
  const d = diagnose({
    sessions: [silentSession({ processStartTime: null })],
    hooksInstalledAt: { claudeCode: NOW - HOUR },
    connectedProviders: new Set([AgentProvider.claudeCode]),
    now: NOW,
  });
  assert.strictEqual(d.unexplained, 1);
  assert.strictEqual(d.predatesHooks, 0);
});

// --- which terminal, on Windows ---------------------------------------------

test('win32: VS Code is proven from the environment', () => {
  assert.strictEqual(
    win32Host.hostFromEnvironment({ TERM_PROGRAM: 'vscode' }),
    HostApplication.vsCode,
  );
  assert.strictEqual(
    win32Host.hostFromEnvironment({ VSCODE_INJECTION: '1' }),
    HostApplication.vsCode,
  );
});

test('win32: Windows Terminal is proven from the environment', () => {
  assert.strictEqual(
    win32Host.hostFromEnvironment({ WT_SESSION: 'abc' }),
    HostApplication.windowsTerminal,
  );
});

test('win32: PSModulePath alone is not evidence of PowerShell', () => {
  // It is a machine-wide variable on Windows 10 and later, so it is set in cmd,
  // in VS Code, and in services. Treating it as evidence labelled essentially
  // every session PowerShell.
  const env = { PSModulePath: 'C:\\Program Files\\WindowsPowerShell\\Modules' };
  assert.strictEqual(win32Host.hostFromEnvironment(env), HostApplication.unknown);
});

test('win32: the process tree finds the terminal the environment could not prove', () => {
  const tree = new Map([
    [100, { parentPID: 200, name: 'node.exe' }],
    [200, { parentPID: 300, name: 'pwsh.exe' }],
    [300, { parentPID: 400, name: 'WindowsTerminal.exe' }],
    [400, { parentPID: null, name: 'explorer.exe' }],
  ]);
  // The nearest host wins: the shell the agent actually runs in.
  assert.strictEqual(win32Host.hostFromProcessTree(100, tree), HostApplication.powershell);
});

test('win32: the walk stops at the shell rather than climbing to the session manager', () => {
  const tree = new Map([
    [100, { parentPID: 400, name: 'node.exe' }],
    [400, { parentPID: 500, name: 'explorer.exe' }],
    [500, { parentPID: null, name: 'cmd.exe' }],
  ]);
  assert.strictEqual(win32Host.hostFromProcessTree(100, tree), HostApplication.unknown);
});

test('win32: a process is never its own host', () => {
  // Claude Code launched from VS Code's integrated terminal is a node under
  // Code.exe; a bare `node.exe` with no known ancestor has no host to report.
  const tree = new Map([[100, { parentPID: null, name: 'pwsh.exe' }]]);
  assert.strictEqual(win32Host.hostFromProcessTree(100, tree), HostApplication.unknown);
});

// --- which terminal, on Linux -----------------------------------------------

test('linux: each terminal is proven by the variable it exports', () => {
  const cases = [
    [{ KITTY_WINDOW_ID: '1' }, HostApplication.kitty],
    [{ ALACRITTY_SOCKET: '/run/user/1000/a.sock' }, HostApplication.alacritty],
    [{ WEZTERM_PANE: '0' }, HostApplication.wezterm],
    [{ KONSOLE_VERSION: '230800' }, HostApplication.konsole],
    [{ GNOME_TERMINAL_SCREEN: '/org/gnome/Terminal/screen/x' }, HostApplication.gnomeTerminal],
  ];
  for (const [env, expected] of cases) {
    assert.strictEqual(linuxHost.hostFromEnvironment(env), expected, JSON.stringify(env));
  }
});

test('linux: VS Code wins over the terminal that launched the editor', () => {
  // The integrated terminal inherits the whole environment of whatever started
  // VS Code, so a Konsole-launched editor has KONSOLE_VERSION set in every one
  // of its terminals. Answering "Konsole" there is wrong about the thing the
  // user is actually looking at, which is the row's entire job.
  const env = { KONSOLE_VERSION: '230800', VSCODE_INJECTION: '1' };
  assert.strictEqual(linuxHost.hostFromEnvironment(env), HostApplication.vsCode);
});

test('linux: an unrecognised TERM_PROGRAM proves a terminal but not which one', () => {
  // More honest than unknown, and the daemon's tree walk may still improve on
  // it — but it must never be promoted into a name we did not read.
  assert.strictEqual(
    linuxHost.hostFromEnvironment({ TERM_PROGRAM: 'something-new' }),
    HostApplication.terminal,
  );
  assert.strictEqual(linuxHost.hostFromEnvironment({}), HostApplication.unknown);
});

test('linux: $TERM is never evidence', () => {
  // xterm-256color is what Konsole, GNOME Terminal, kitty and tmux all set. It
  // names a terminfo entry, not a program, so it identifies nothing.
  const env = { TERM: 'xterm-256color', COLORTERM: 'truecolor' };
  assert.strictEqual(linuxHost.hostFromEnvironment(env), HostApplication.unknown);
});

test('linux: the process tree finds GNOME Terminal through its server process', () => {
  // gnome-terminal forks a server that owns the window, so the name actually
  // found above a shell is never the one the user typed.
  const tree = new Map([
    [100, { parentPID: 200, name: 'node' }],
    [200, { parentPID: 300, name: 'bash' }],
    [300, { parentPID: 400, name: 'gnome-terminal-server' }],
    [400, { parentPID: null, name: 'systemd' }],
  ]);
  assert.strictEqual(linuxHost.hostFromProcessTree(100, tree), HostApplication.gnomeTerminal);
});

test('linux: the walk stops at the session manager', () => {
  const tree = new Map([
    [100, { parentPID: 200, name: 'node' }],
    [200, { parentPID: 300, name: 'systemd' }],
    [300, { parentPID: null, name: 'konsole' }],
  ]);
  assert.strictEqual(linuxHost.hostFromProcessTree(100, tree), HostApplication.unknown);
});

test('linux: a process name is matched after its path and decorations are stripped', () => {
  assert.strictEqual(linuxHost.normalise('/usr/bin/konsole'), 'konsole');
  assert.strictEqual(linuxHost.normalise('kitty:main'), 'kitty');
  assert.strictEqual(linuxHost.normalise('WezTerm-gui'), 'wezterm-gui');
});

// --- finding agents, on Windows ---------------------------------------------

test('win32: Claude Code is recognised in each shape it ships in', () => {
  const rows = [
    { name: 'claude.exe', cmd: 'claude.exe' },
    { name: 'node.exe', cmd: 'node "C:\\Users\\a\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js"' },
    { name: 'node.exe', cmd: 'node "C:\\Users\\a\\.claude\\local\\node_modules\\x\\cli.js"' },
  ];
  for (const row of rows) {
    assert.strictEqual(win32Scan.providerFor(row), AgentProvider.claudeCode, row.cmd);
  }
});

test('win32: a folder that merely has the word in its path is not an agent', () => {
  // Anchored on installation layout rather than the word anywhere in the line,
  // or every process started from C:\claude-experiments would be a session.
  const row = { name: 'node.exe', cmd: 'node C:\\projects\\claude-notes\\build.js' };
  assert.strictEqual(win32Scan.providerFor(row), null);
});

test('win32: our own hook is never counted as a session', () => {
  // It is a node process spawned by the agent, so without this it would appear
  // as a second silent session on every single tool call.
  const row = { name: 'node.exe', cmd: 'node C:\\CodeStatus\\desktop\\hook\\hook.js --provider claude-code' };
  assert.strictEqual(win32Scan.providerFor(row), null);
});

test('win32: PowerShell’s JSON collapses to an object for one row, and to nothing for none', () => {
  assert.deepStrictEqual(win32Scan.parseRows(''), []);
  assert.deepStrictEqual(win32Scan.parseRows('   '), []);
  assert.deepStrictEqual(win32Scan.parseRows('not json'), []);
  assert.strictEqual(win32Scan.parseRows('{"pid":1}').length, 1);
  assert.strictEqual(win32Scan.parseRows('[{"pid":1},{"pid":2}]').length, 2);
});

// --- finding agents, on Linux -----------------------------------------------

test('linux: Claude Code is recognised in each shape it ships in', () => {
  const rows = [
    { name: 'claude', cmd: '/home/a/.local/bin/claude' },
    { name: 'node', cmd: '/usr/bin/node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js' },
    { name: 'node', cmd: 'node /home/a/.claude/local/node_modules/x/cli.js' },
  ];
  for (const row of rows) {
    assert.strictEqual(linuxScan.providerFor(row), AgentProvider.claudeCode, row.cmd);
  }
});

test('linux: a truncated comm still resolves through argv[0]', () => {
  // The kernel caps comm at fifteen characters, so a binary with a longer name
  // arrives clipped. argv[0]'s basename is checked as well, not instead.
  const row = { name: 'claude-code-wra', cmd: '/opt/claude/bin/claude --resume' };
  assert.strictEqual(linuxScan.providerFor(row), AgentProvider.claudeCode);
});

test('linux: a folder that merely has the word in its path is not an agent', () => {
  const row = { name: 'node', cmd: 'node /home/a/projects/claude-notes/build.js' };
  assert.strictEqual(linuxScan.providerFor(row), null);
});

test('linux: our own hook is never counted as a session', () => {
  const row = {
    name: 'node',
    cmd: '/opt/CodeStatus/codestatus /opt/CodeStatus/resources/hook/hook.js --provider claude-code',
  };
  assert.strictEqual(linuxScan.providerFor(row), null);
});

test('linux: /proc/<pid>/stat is cut at the last parenthesis, not split on spaces', () => {
  // A process may name itself anything, spaces and parentheses included, and
  // the comm field is not escaped. Splitting on whitespace — which is the
  // obvious reading of the file — shifts every field after it, so the parent
  // pid becomes a piece of the name and the start time becomes garbage.
  const fields = ['S', '4242', ...Array(17).fill('0'), '999999'].join(' ');
  const parsed = linuxScan.parseStat(`1234 (node (old) thing) ${fields}`);
  assert.strictEqual(parsed.comm, 'node (old) thing');
  assert.strictEqual(parsed.ppid, 4242);
  assert.strictEqual(parsed.startTicks, 999999);
});

test('linux: an unreadable btime yields no start time rather than a wrong one', () => {
  const empty = fs.mkdtempSync(path.join(TMP, 'proc-'));
  assert.strictEqual(linuxScan.bootTimeMillis(empty), null);
});

test('linux: boot time is read from /proc/stat and converted to epoch milliseconds', () => {
  const procRoot = fs.mkdtempSync(path.join(TMP, 'proc-'));
  fs.writeFileSync(
    path.join(procRoot, 'stat'),
    'cpu  1 2 3\nbtime 1700000000\nprocesses 42\n',
  );
  assert.strictEqual(linuxScan.bootTimeMillis(procRoot), 1_700_000_000_000);
});

// The only case here that needs the kernel it describes, and it earns the
// exception. Everything else about the scan is checked against fixtures, which
// proves the parser and proves nothing about /proc actually being shaped the
// way the parser expects — the field offsets, the comm truncation, btime being
// present at all. This is the app's answer to "an agent is running and telling
// you nothing", which is the most confusing state it can be in, so the claim
// that it can read the process table should be a fact somewhere.
if (process.platform === 'linux') {
  test('linux: the real /proc yields this process, with a sane start time', () => {
    return linuxScan.scan().then(({ tree, failed }) => {
      assert.strictEqual(failed, false, '/proc could not be read');
      assert.ok(tree.size > 1, 'the process table came back essentially empty');

      const self = tree.get(process.pid);
      assert.ok(self, 'the running process is not in its own scan');
      assert.strictEqual(self.parentPID, process.ppid);
      // comm is the executable name truncated to fifteen characters, so this is
      // the prefix rather than the whole of it.
      assert.ok('node'.startsWith(self.name) || self.name.startsWith('node'), self.name);

      // Start times are what the unreported diagnosis compares against the
      // moment the hooks were installed, so being on the wall clock at all is
      // the property that matters — a value measured from boot and left there
      // would put every session hours in the past and read as "predates the
      // hooks" for ever.
      const boot = linuxScan.bootTimeMillis();
      assert.ok(boot !== null && boot > 0, 'btime was unreadable');
      assert.ok(boot < Date.now(), 'the machine booted in the future');
    });
  });
}

test('linux: a scan with no /proc reports failure rather than an empty machine', () => {
  // "We could not look" and "nothing is there" are different answers, and the
  // popover says which. This is also the path the suite takes on a Mac.
  return linuxScan.scan({ procRoot: path.join(TMP, 'no-such-proc') }).then((result) => {
    assert.strictEqual(result.failed, true);
    assert.deepStrictEqual(result.agents, []);
  });
});

// --- how the agent is told to invoke the hook, on Linux ---------------------

test('linux: the hook entry is the exec form, with env setting the variable', () => {
  // The Windows seam needs a generated .cmd for this, because the hook schema
  // has no field that sets an environment variable and cmd.exe is the only way
  // to get one. env(1) is that field.
  const { command, args } = linuxRuntime.hookInvocation('claude-code');
  assert.strictEqual(command, '/usr/bin/env');
  assert.strictEqual(args[0], 'ELECTRON_RUN_AS_NODE=1');
  assert.deepStrictEqual(args.slice(-2), ['--provider', 'claude-code']);
  assert.ok(args[2].endsWith('hook.js'), args[2]);
});

test('linux: only the hook script marks an entry as ours', () => {
  // /usr/bin/env is a system binary anybody's hook may run through, and the
  // runtime path changes with every update. Claiming either would make us
  // delete other people's entries or fail to recognise our own.
  const owned = linuxRuntime.ownedPaths('claude-code');
  assert.strictEqual(owned.length, 1);
  assert.ok(owned[0].endsWith('hook.js'), owned[0]);
});

test('linux: installing from an AppImage is refused rather than half-working', () => {
  // Both halves of the invocation live inside a mount that disappears when the
  // app quits — and the spool exists precisely for the time the app is not
  // running, so this would delete exactly the events it was built to keep.
  const mount = '/tmp/.mount_CodeSt12345/usr/bin/codestatus';
  assert.ok(linuxRuntime.isEphemeral(mount));
  assert.ok(!linuxRuntime.isEphemeral('/opt/CodeStatus/codestatus'));

  const problem = linuxRuntime.blockingProblem({ runtime: mount, script: '/opt/x/hook.js' });
  assert.ok(problem && problem.includes('AppImage'), problem);
  assert.throws(
    () => linuxRuntime.writeLauncher({ runtime: mount, script: '/opt/x/hook.js' }),
    /AppImage/,
  );
});

test('linux: a normal install writes no launcher and reports none', () => {
  const result = linuxRuntime.writeLauncher({
    runtime: '/opt/CodeStatus/codestatus',
    script: '/opt/CodeStatus/resources/hook/hook.js',
  });
  assert.strictEqual(result.launcherPath, null);
  assert.strictEqual(linuxRuntime.launcherPath('claude-code'), null);
});

// --- the socket ------------------------------------------------------------

test('linux: a stale socket is cleared, and nothing else ever is', () => {
  // A socket outlives the daemon that bound it, so a crash would otherwise stop
  // the app from starting again — with an error that reads as though a second
  // copy were running. What must not happen is this clearing anything that is
  // not a socket, because the path can come from an override.
  const regular = path.join(TMP, 'not-a-socket');
  fs.writeFileSync(regular, 'important');
  assert.strictEqual(linuxTransport.prepare(regular), false);
  assert.ok(fs.existsSync(regular), 'a regular file must survive');

  assert.strictEqual(linuxTransport.prepare(path.join(TMP, 'absent')), false);
});

test('win32: there is no socket file to clear or tighten', () => {
  // A pipe name dies with its last handle, so both calls exist only so the
  // daemon can make them unconditionally.
  assert.strictEqual(win32Transport.prepare(), undefined);
  assert.strictEqual(win32Transport.finalize(), undefined);
  assert.ok(win32Transport.endpoint().startsWith('\\\\.\\pipe\\') || process.env.CODESTATUS_PIPE);
});

// --- returning to a session, on Linux ---------------------------------------

test('linux: with no X display, focus is unavailable and says why', () => {
  const saved = { DISPLAY: process.env.DISPLAY, XDG_SESSION_TYPE: process.env.XDG_SESSION_TYPE };
  delete process.env.DISPLAY;
  process.env.XDG_SESSION_TYPE = 'wayland';
  try {
    const capability = linuxFocus.focusCapability();
    assert.strictEqual(capability.available, false);
    assert.ok(capability.reason.includes('Wayland'), capability.reason);
  } finally {
    if (saved.DISPLAY === undefined) delete process.env.DISPLAY;
    else process.env.DISPLAY = saved.DISPLAY;
    if (saved.XDG_SESSION_TYPE === undefined) delete process.env.XDG_SESSION_TYPE;
    else process.env.XDG_SESSION_TYPE = saved.XDG_SESSION_TYPE;
  }
});

test('linux: focus never leaves its callback uncalled', () => {
  // The caller uses false to decide to open the project folder instead, so a
  // path that silently returns is a click that does nothing at all.
  let called = 0;
  linuxFocus.focusProcessWindow(0, () => { called += 1; });
  assert.strictEqual(called, 1, 'a missing pid answers immediately');
});

test('linux: the ancestry walk cannot loop', () => {
  // Read from /proc on click rather than from the daemon's scan, which may be
  // twenty seconds stale — a reused pid would raise a stranger's window.
  const chain = linuxFocus.ancestry(process.pid);
  assert.ok(chain.length >= 1);
  assert.strictEqual(chain[0], process.pid);
  assert.strictEqual(new Set(chain).size, chain.length, 'no pid appears twice');
});

// --- what the tray says -----------------------------------------------------

test('What needs you outranks everything else in the icon', () => {
  const counts = {
    free: 3, busy: 2, needsYou: 1, indeterminate: 0,
  };
  assert.deepStrictEqual(chooseDisplay(counts).value, 1);
  assert.strictEqual(chooseDisplay(counts).bucket, 'needsYou');
});

test('With nothing waiting, the icon counts what is working', () => {
  const counts = {
    free: 3, busy: 2, needsYou: 0, indeterminate: 0,
  };
  assert.strictEqual(chooseDisplay(counts).bucket, 'busy');
  assert.strictEqual(chooseDisplay(counts).value, 2);
});

test('An empty machine draws a grey disc with no number', () => {
  const counts = {
    free: 0, busy: 0, needsYou: 0, indeterminate: 0,
  };
  assert.strictEqual(chooseDisplay(counts).value, 0);
  assert.strictEqual(glyphKeyFor(0), null);
});

test('Past nine the icon shows a plus, so the glyph is always one character', () => {
  assert.strictEqual(glyphKeyFor(9), '9');
  assert.strictEqual(glyphKeyFor(10), '+');
  assert.strictEqual(glyphKeyFor(999), '+');
});

test('The tooltip carries the whole breakdown the menu bar would show', () => {
  const tip = buildTooltip({
    free: 1, busy: 2, needsYou: 1, indeterminate: 0,
  }, 0, null);
  assert.strictEqual(tip, 'CodeStatus — 1 needs you, 2 busy, 1 free');
});

test('An unconnected agent takes over the tooltip', () => {
  const tip = buildTooltip(
    {
      free: 0, busy: 0, needsYou: 0, indeterminate: 0,
    },
    2,
    { notConnected: { claudeCode: 2 }, predatesHooks: 0, unexplained: 0 },
  );
  assert.ok(tip.includes('not connected'), tip);
});

test('Silent sessions are admitted rather than shown as an empty machine', () => {
  const tip = buildTooltip({
    free: 0, busy: 0, needsYou: 0, indeterminate: 0,
  }, 3, null);
  assert.ok(tip.includes('3 session(s) found but not reporting'), tip);
});

process.on('exit', () => {
  try {
    fs.rmSync(TMP, { recursive: true, force: true });
  } catch { /* a temp directory that outlives the run is not a failure */ }
});

run('platform');
