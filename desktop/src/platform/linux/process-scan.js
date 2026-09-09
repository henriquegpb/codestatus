'use strict';

// The Linux counterpart to macOS's ProcessInspector: which agents are running
// right now, whether or not they have ever said anything.
//
// This is what lets the app distinguish "no agent is running" from "an agent is
// running and reporting nothing". Without it the popover is simply empty when
// hooks were installed mid-session, which is the single most confusing state
// the app can be in — the agent looks fine, CodeStatus looks broken, and
// nothing on screen explains the difference.
//
// The one place Linux is straightforwardly better than the other two platforms.
// Windows shells out to PowerShell and pays a few hundred milliseconds for the
// process table; macOS calls libproc. /proc is already the table, so this is a
// few milliseconds of readdir and readFile, with no subprocess to spawn, no
// shell to quote for, and nothing to parse out of somebody's serialisation
// format. It is still on the slow timer, because there is no reason for it not
// to be — hooks arrive over the socket regardless of when the last scan ran.

const fs = require('fs');
const path = require('path');

const { AgentProvider } = require('../../core/events');

const PROC = process.env.CODESTATUS_PROC || '/proc';

// The kernel reports process start times in clock ticks, and USER_HZ — the
// value it uses for the fields exposed through /proc — is fixed at 100 on
// Linux regardless of how CONFIG_HZ was set when the kernel was built. That is
// an ABI guarantee, which is why it can be a constant here rather than a
// sysconf call we would need a native module to make.
const USER_HZ = 100;

// How we recognise Claude Code.
//
// Deliberately anchored on installation layout rather than the word "claude"
// anywhere in the command line, which would match any process started from a
// folder that happens to be named after it. The three shapes Claude Code ships
// in: the native binary, the npm global install, and the local installer under
// ~/.claude.
const CLAUDE_COMMAND_LINE = /@anthropic-ai\/claude-code|\/\.claude\/local\/|\/claude\/cli\.js/;
const CLAUDE_EXECUTABLES = new Set(['claude']);

// Interpreters Claude Code is plausibly running under. Checked against the
// command line, never on their own.
const INTERPRETERS = new Set(['node', 'bun', 'deno']);

// Our own hook is a Node process too, and it is spawned by the agent, so it
// would otherwise be counted as a second silent session on every tool call.
const OURS = /codestatus/i;

// Reads /proc/<pid>/stat.
//
// The comm field is wrapped in parentheses and may contain both spaces and
// parentheses of its own — `(node (old))` is a legal value — so the only safe
// way to find the fields after it is to cut at the *last* closing parenthesis.
// Splitting on whitespace, which is the obvious reading, silently shifts every
// field for any process whose name has a space in it.
function parseStat(text) {
  const close = text.lastIndexOf(')');
  const open = text.indexOf('(');
  if (close === -1 || open === -1 || close < open) return null;

  const comm = text.slice(open + 1, close);
  // Fields from `state` onwards, which is field 3 in the proc(5) numbering.
  // ppid is field 4 and starttime is field 22, so they sit at 1 and 19 here.
  const rest = text.slice(close + 2).split(' ');
  if (rest.length < 20) return null;

  const ppid = Number(rest[1]);
  const startTicks = Number(rest[19]);
  return {
    comm,
    ppid: Number.isFinite(ppid) ? ppid : null,
    startTicks: Number.isFinite(startTicks) ? startTicks : null,
  };
}

// Epoch milliseconds at which the machine booted, from /proc/stat's btime line.
//
// Needed because a process start time in /proc is measured from boot, and the
// diagnosis compares it against when the hooks were installed — a wall-clock
// moment. Without this the two are not on the same axis.
function bootTimeMillis(procRoot = PROC) {
  try {
    const text = fs.readFileSync(path.join(procRoot, 'stat'), 'utf8');
    const match = text.match(/^btime\s+(\d+)/m);
    if (!match) return null;
    return Number(match[1]) * 1000;
  } catch {
    return null;
  }
}

// /proc/<pid>/cmdline is NUL-separated and NUL-terminated. Joined with spaces
// for matching only; nothing here is displayed or persisted.
function readCmdline(procRoot, pid) {
  try {
    const raw = fs.readFileSync(path.join(procRoot, String(pid), 'cmdline'));
    if (raw.length === 0) return '';
    return raw.toString('utf8').replace(/\0+$/, '').split('\0').join(' ');
  } catch {
    // A kernel thread has an empty cmdline, and a process that exited between
    // the readdir and this read has none at all. Both are simply not agents.
    return null;
  }
}

// Which agent a row is, or null.
//
// `name` is the kernel's comm, which is truncated to fifteen characters — long
// enough for every name we look for, and the reason argv[0]'s basename is
// checked as well rather than instead.
function providerFor(row) {
  const cmd = row.cmd || '';
  if (OURS.test(cmd)) return null;

  const names = new Set([
    (row.name || '').toLowerCase(),
    (cmd.split(' ')[0] || '').split('/').pop().toLowerCase(),
  ]);

  for (const name of names) {
    if (CLAUDE_EXECUTABLES.has(name)) return AgentProvider.claudeCode;
    if (INTERPRETERS.has(name) && CLAUDE_COMMAND_LINE.test(cmd)) return AgentProvider.claudeCode;
  }
  return null;
}

// Returns { agents, tree, failed }.
//
//   agents: [{ pid, provider, startTime, parentPID }]
//   tree:   Map pid -> { parentPID, name }, for host detection
//
// Never rejects: a scan that fails is a scan that found nothing, and the app
// carries on with hook evidence alone. `failed` is the difference between the
// two, and the popover says so — "we could not look" is not "nothing is there".
//
// Async in signature only. The reads are small and served from memory by procfs
// with no I/O behind them, and doing them synchronously keeps the whole table
// consistent with itself; the promise is there because the Windows seam needs
// one and the daemon awaits both.
function scan({ procRoot = PROC } = {}) {
  return new Promise((resolve) => {
    let entries;
    try {
      entries = fs.readdirSync(procRoot);
    } catch {
      // No /proc. Not Linux, or a container that did not mount it.
      resolve({ agents: [], tree: new Map(), failed: true });
      return;
    }

    const boot = bootTimeMillis(procRoot);
    const tree = new Map();
    const agents = [];

    for (const entry of entries) {
      // Only the numeric ones are processes; the rest of /proc is the kernel's.
      if (entry.charCodeAt(0) < 0x30 || entry.charCodeAt(0) > 0x39) continue;
      const pid = Number(entry);
      if (!Number.isInteger(pid) || pid <= 0) continue;

      let stat;
      try {
        stat = parseStat(fs.readFileSync(path.join(procRoot, entry, 'stat'), 'utf8'));
      } catch {
        // Exited between the readdir and here, or belongs to another user under
        // hidepid. Either way there is nothing to say about it.
        continue;
      }
      if (!stat) continue;

      tree.set(pid, { parentPID: stat.ppid || null, name: stat.comm });

      const cmd = readCmdline(procRoot, pid);
      if (cmd === null || cmd === '') continue;

      const provider = providerFor({ name: stat.comm, cmd });
      if (!provider) continue;

      agents.push({
        pid,
        parentPID: stat.ppid || null,
        provider,
        // Null rather than a guess when btime was unreadable. The diagnosis
        // already has a branch for a session with no start time, and it says
        // "unexplained" rather than inventing a cause.
        startTime: boot !== null && stat.startTicks !== null
          ? Math.round(boot + (stat.startTicks / USER_HZ) * 1000)
          : null,
      });
    }

    resolve({ agents, tree, failed: false });
  });
}

module.exports = {
  scan, providerFor, parseStat, bootTimeMillis, readCmdline, USER_HZ,
};
