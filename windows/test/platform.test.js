'use strict';

// The Windows-specific pieces: why a session is silent, which terminal it is
// in, and what the tray says. None of this exists on macOS — the platform hands
// the mac app a start time, a TERM_PROGRAM, and a menu bar that takes text — so
// none of it is covered by the Swift suite either.

const assert = require('assert');
const { test, run } = require('./harness');

const { diagnose, total, notConnectedTotal } = require('../src/core/diagnosis');
const { hostFromEnvironment, hostFromProcessTree } = require('../src/platform/host');
const { providerFor, parseRows } = require('../src/platform/process-scan');
const { chooseDisplay, glyphKeyFor, buildTooltip } = require('../src/ui/tray-content');
const { HostApplication, AgentProvider } = require('../src/core/events');

const HOUR = 3600 * 1000;
const NOW = 1_700_000_000_000;

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
  const d = diagnose({
    sessions: [silentSession({ processStartTime: null })],
    hooksInstalledAt: { claudeCode: NOW - HOUR },
    connectedProviders: new Set([AgentProvider.claudeCode]),
    now: NOW,
  });
  assert.strictEqual(d.unexplained, 1);
  assert.strictEqual(d.predatesHooks, 0);
});

test('A silent session started after the install is counted but not explained', () => {
  const d = diagnose({
    sessions: [silentSession({ processStartTime: NOW - 60 * 1000 })],
    hooksInstalledAt: { claudeCode: NOW - HOUR },
    connectedProviders: new Set([AgentProvider.claudeCode]),
    now: NOW,
  });
  assert.strictEqual(d.unexplained, 1);
  assert.strictEqual(total(d), 1);
});

test('Nothing silent means nothing to explain', () => {
  const d = diagnose({ sessions: [], hooksInstalledAt: {}, now: NOW });
  assert.strictEqual(total(d), 0);
});

// --- which terminal ---------------------------------------------------------

test('VS Code is proven from the environment', () => {
  assert.strictEqual(hostFromEnvironment({ TERM_PROGRAM: 'vscode' }), HostApplication.vsCode);
  assert.strictEqual(hostFromEnvironment({ VSCODE_INJECTION: '1' }), HostApplication.vsCode);
});

test('Windows Terminal is proven from the environment', () => {
  assert.strictEqual(hostFromEnvironment({ WT_SESSION: 'abc' }), HostApplication.windowsTerminal);
});

test('PSModulePath alone is not evidence of PowerShell', () => {
  // It is a machine-wide variable on Windows 10 and later, so it is set in cmd,
  // in VS Code, and in services. Treating it as evidence labelled essentially
  // every session PowerShell.
  const env = { PSModulePath: 'C:\\Program Files\\WindowsPowerShell\\Modules' };
  assert.strictEqual(hostFromEnvironment(env), HostApplication.unknown);
});

test('The process tree finds the terminal the environment could not prove', () => {
  const tree = new Map([
    [100, { parentPID: 200, name: 'node.exe' }],
    [200, { parentPID: 300, name: 'pwsh.exe' }],
    [300, { parentPID: 400, name: 'WindowsTerminal.exe' }],
    [400, { parentPID: null, name: 'explorer.exe' }],
  ]);
  // The nearest host wins: the shell the agent actually runs in.
  assert.strictEqual(hostFromProcessTree(100, tree), HostApplication.powershell);
});

test('The walk stops at the shell rather than climbing to the session manager', () => {
  const tree = new Map([
    [100, { parentPID: 400, name: 'node.exe' }],
    [400, { parentPID: 500, name: 'explorer.exe' }],
    [500, { parentPID: null, name: 'cmd.exe' }],
  ]);
  assert.strictEqual(hostFromProcessTree(100, tree), HostApplication.unknown);
});

test('A process is never its own host', () => {
  // Claude Code launched from VS Code's integrated terminal is a node under
  // Code.exe; a bare `node.exe` with no known ancestor has no host to report.
  const tree = new Map([[100, { parentPID: null, name: 'pwsh.exe' }]]);
  assert.strictEqual(hostFromProcessTree(100, tree), HostApplication.unknown);
});

// --- finding agents ---------------------------------------------------------

test('Claude Code is recognised in each shape it ships in', () => {
  const rows = [
    { name: 'claude.exe', cmd: 'claude.exe' },
    { name: 'node.exe', cmd: 'node "C:\\Users\\a\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js"' },
    { name: 'node.exe', cmd: 'node "C:\\Users\\a\\.claude\\local\\node_modules\\x\\cli.js"' },
  ];
  for (const row of rows) {
    assert.strictEqual(providerFor(row), AgentProvider.claudeCode, row.cmd);
  }
});

test('A folder that merely has the word in its path is not an agent', () => {
  // Anchored on installation layout rather than the word anywhere in the line,
  // or every process started from C:\claude-experiments would be a session.
  const row = { name: 'node.exe', cmd: 'node C:\\projects\\claude-notes\\build.js' };
  assert.strictEqual(providerFor(row), null);
});

test('Our own hook is never counted as a session', () => {
  // It is a node process spawned by the agent, so without this it would appear
  // as a second silent session on every single tool call.
  const row = { name: 'node.exe', cmd: 'node C:\\CodeStatus\\windows\\hook\\hook.js --provider claude-code' };
  assert.strictEqual(providerFor(row), null);
});

test('PowerShell’s JSON collapses to an object for one row, and to nothing for none', () => {
  assert.deepStrictEqual(parseRows(''), []);
  assert.deepStrictEqual(parseRows('   '), []);
  assert.deepStrictEqual(parseRows('not json'), []);
  assert.strictEqual(parseRows('{"pid":1}').length, 1);
  assert.strictEqual(parseRows('[{"pid":1},{"pid":2}]').length, 2);
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

run('platform');
