'use strict';

// The Windows counterpart to macOS's ProcessInspector: which agents are running
// right now, whether or not they have ever said anything.
//
// This is what lets the app distinguish "no agent is running" from "an agent is
// running and reporting nothing". Without it the popover is simply empty when
// hooks were installed mid-session, which is the single most confusing state
// the app can be in — the agent looks fine, CodeStatus looks broken, and
// nothing on screen explains the difference.
//
// One PowerShell invocation returns the whole process table. That is not cheap
// (a few hundred milliseconds), so it runs on a slow timer and on demand, never
// in the event path. The transport is unaffected: hooks arrive over the pipe
// regardless of when the last scan ran.

const { execFile } = require('child_process');
const { AgentProvider } = require('../core/events');

// Select the four fields we need, and project the start time to epoch
// milliseconds in PowerShell rather than parsing a CIM date in JS — Windows
// PowerShell 5.1 and PowerShell 7 serialise DateTime differently, and a number
// is the same in both.
const SCRIPT = `
$ErrorActionPreference = 'SilentlyContinue'
$epoch = [datetime]'1970-01-01T00:00:00Z'
$rows = Get-CimInstance Win32_Process | ForEach-Object {
  [pscustomobject]@{
    pid     = [int]$_.ProcessId
    ppid    = [int]$_.ParentProcessId
    name    = $_.Name
    cmd     = $_.CommandLine
    started = if ($_.CreationDate) { [int64](($_.CreationDate.ToUniversalTime() - $epoch).TotalMilliseconds) } else { 0 }
  }
}
ConvertTo-Json -Compress -Depth 2 -InputObject @($rows)`;

// How we recognise Claude Code.
//
// Deliberately anchored on installation layout rather than the word "claude"
// anywhere in the command line, which would match any process started from a
// folder that happens to be named after it. The three shapes Claude Code ships
// in on Windows: the native binary, the npm global install, and the local
// installer under ~/.claude.
const CLAUDE_COMMAND_LINE = /@anthropic-ai[\\/]claude-code|[\\/]\.claude[\\/]local[\\/]|[\\/]claude[\\/]cli\.js/i;
const CLAUDE_EXECUTABLES = new Set(['claude.exe']);

// Our own hook is a node process too, and it is spawned by the agent, so it
// would otherwise be counted as a second silent session on every tool call.
const OURS = /codestatus/i;

function providerFor(row) {
  const name = (row.name || '').toLowerCase();
  const cmd = row.cmd || '';
  if (OURS.test(cmd)) return null;
  if (CLAUDE_EXECUTABLES.has(name)) return AgentProvider.claudeCode;
  if (name === 'node.exe' && CLAUDE_COMMAND_LINE.test(cmd)) return AgentProvider.claudeCode;
  return null;
}

// PowerShell's ConvertTo-Json collapses a one-element array to a bare object,
// and @() around an empty result serialises to nothing at all.
function parseRows(text) {
  if (!text || !text.trim()) return [];
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (!parsed) return [];
  return Array.isArray(parsed) ? parsed : [parsed];
}

// Returns { agents, tree }.
//
//   agents: [{ pid, provider, startTime, parentPID }]
//   tree:   Map pid -> { parentPID, name }, for host detection
//
// Never rejects: a scan that fails is a scan that found nothing, and the app
// carries on with hook evidence alone.
function scan({ timeout = 15000 } = {}) {
  return new Promise((resolve) => {
    execFile(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', SCRIPT],
      { timeout, maxBuffer: 16 * 1024 * 1024, windowsHide: true },
      (err, stdout) => {
        if (err && !stdout) {
          resolve({ agents: [], tree: new Map(), failed: true });
          return;
        }
        const rows = parseRows(stdout);
        const tree = new Map();
        const agents = [];
        for (const row of rows) {
          if (!row || !row.pid) continue;
          tree.set(row.pid, { parentPID: row.ppid || null, name: row.name || '' });
          const provider = providerFor(row);
          if (provider) {
            agents.push({
              pid: row.pid,
              parentPID: row.ppid || null,
              provider,
              startTime: row.started || null,
            });
          }
        }
        resolve({ agents, tree, failed: false });
      },
    );
  });
}

module.exports = { scan, providerFor, parseRows };
