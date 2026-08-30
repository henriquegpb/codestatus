'use strict';

// Port of HookInstaller + ClaudeHookInstaller.
//
// Three guarantees shape everything here:
//
//  1. We never block the agent. Every entry is written with async: true, which
//     Claude Code honours, so our hook never sits on its critical path even if
//     the daemon is wedged.
//  2. We only ever touch our own entries. Ownership is decided by resolving the
//     entry's script path to a real path and comparing it to the file we
//     control — never by substring, which would let us delete a user's own hook
//     whose command merely mentions our name.
//  3. We never lose the user's file. Backup, atomic write, revalidate.
//
// Difference from macOS: there the `command` points at a compiled Swift binary.
// Here it points at node.exe with the script in `args`, so ownership detection
// has to look at the script path inside the invocation rather than at `command`.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const { paths } = require('../platform/paths');

// Every lifecycle hook Claude Code emits that changes what we can say about a
// session's state. Kept in step with ClaudeHookInstaller.events on macOS.
//
// `Notification` is included because its permission_prompt and idle_prompt
// subtypes are the only signal for "the agent is waiting on you" that arrives
// without a matching tool event. `StopFailure` is included because a turn that
// ends in error must not be shown as free.
//
// 2.1.247 offers 31 events. The ones here earn their place by changing what we
// can say about a session; the rest are deliberately left out, because every
// registered event is a process spawned on the user's machine — and on Windows
// that process is a Node cold start, so the list is even less free than it is
// on macOS.
const CLAUDE_EVENTS = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  // A failing tool emits this *instead of* PostToolUse.
  'PostToolUseFailure',
  // Closes a parallel batch even if one result went missing.
  'PostToolBatch',
  'PermissionRequest',
  'PermissionDenied',
  'Notification',
  // An MCP server asking the user something — the other way a session blocks on
  // a human without the turn ending.
  'Elicitation',
  'ElicitationResult',
  'Stop',
  'StopFailure',
  'SessionEnd',
];

// Seconds we give ourselves before the agent gives up on us. The hook is async,
// so this is a backstop against a wedged process, not a latency budget.
const TIMEOUT_SECONDS = 5;

const HOOK_SCRIPT = path.join(__dirname, '..', '..', 'hook', 'hook.js');

// The node on PATH, resolved at install time. Storing the absolute path keeps
// the agent's config from depending on how PATH is set up in its terminal — and
// under Electron process.execPath is electron.exe, not node.
//
// The environment override is a test seam: `where` only exists on Windows, and
// the installer's behaviour is worth testing on any machine.
function resolveNodePath() {
  if (process.env.CODESTATUS_NODE_PATH) return process.env.CODESTATUS_NODE_PATH;
  try {
    const out = execFileSync('where', ['node'], { encoding: 'utf8' });
    const first = out.split(/\r?\n/).find((l) => l.trim().toLowerCase().endsWith('node.exe'));
    if (first) return first.trim();
  } catch { /* fall through */ }
  return 'node';
}

// The command and its arguments, kept separate — never one command line.
//
// This is not style: it is the difference between working and not working on
// Windows. When `args` is present, Claude Code uses the exec form and spawns
// the binary directly. When `args` is omitted it uses the shell form — and on
// Windows that shell can be PowerShell, where a line beginning with a quoted
// path ("C:\...\node.exe" script.js) is merely a *string literal* that
// PowerShell echoes. Without the `&` operator nothing executes, and the hook
// never runs: no error, no log, just silence.
//
// The exec form removes the shell from the equation and, with it, the whole
// question of quoting paths that contain spaces (C:\Program Files\...).
function hookInvocation() {
  return {
    command: resolveNodePath(),
    args: [HOOK_SCRIPT, '--provider', 'claude-code'],
  };
}

// An entry is ours if it references exactly our script — whether the path is in
// `command` (the old single-line format) or in `args` (the current one).
// Compare resolved paths, never substrings: a user's own hook whose line merely
// mentions "codestatus" is not ours and has to survive.
function isOurEntry(entry) {
  if (!entry || typeof entry !== 'object') return false;
  const hooks = Array.isArray(entry.hooks) ? entry.hooks : [];
  const target = path.resolve(HOOK_SCRIPT).toLowerCase();

  return hooks.some((h) => {
    if (!h || typeof h !== 'object') return false;
    const candidates = [];
    if (typeof h.command === 'string') candidates.push(h.command);
    if (Array.isArray(h.args)) {
      for (const a of h.args) if (typeof a === 'string') candidates.push(a);
    }
    return candidates.some((raw) => {
      const match = raw.match(/"([^"]+\.js)"|(\S+\.js)/);
      if (!match) return false;
      try {
        return path.resolve((match[1] || match[2]).trim()).toLowerCase() === target;
      } catch {
        return false;
      }
    });
  });
}

function newEntry() {
  const { command, args } = hookInvocation();
  return {
    hooks: [{
      type: 'command',
      command,
      args,
      timeout: TIMEOUT_SECONDS,
      // Without `async`, the hook runs on the agent's critical path.
      async: true,
    }],
  };
}

function readSettings() {
  try {
    const text = fs.readFileSync(paths.claudeSettings, 'utf8');
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      // Something is at the target path but is not a settings object — we
      // cannot know what replacing it would destroy.
      throw new Error('settings.json does not contain a JSON object');
    }
    return { settings: parsed, existed: true };
  } catch (err) {
    if (err && err.code === 'ENOENT') return { settings: {}, existed: false };
    throw err;
  }
}

function backup() {
  try {
    if (!fs.existsSync(paths.claudeSettings)) return null;
    fs.mkdirSync(paths.backups, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const dest = path.join(paths.backups, `settings-${stamp}.json`);
    fs.copyFileSync(paths.claudeSettings, dest);
    return dest;
  } catch {
    return null;
  }
}

function writeSettings(settings) {
  const dir = path.dirname(paths.claudeSettings);
  fs.mkdirSync(dir, { recursive: true });
  const text = `${JSON.stringify(settings, null, 2)}\n`;
  const tmp = `${paths.claudeSettings}.codestatus.tmp`;
  fs.writeFileSync(tmp, text, 'utf8');
  // Revalidate before publishing: we never leave an unreadable file where the
  // user's configuration used to be.
  JSON.parse(fs.readFileSync(tmp, 'utf8'));
  fs.renameSync(tmp, paths.claudeSettings);
}

function loadReceipts() {
  try {
    return JSON.parse(fs.readFileSync(paths.installReceipts, 'utf8'));
  } catch {
    return {};
  }
}

function saveReceipt(receipt) {
  try {
    fs.mkdirSync(paths.state, { recursive: true });
    const all = loadReceipts();
    all[receipt.targetPath] = receipt;
    fs.writeFileSync(paths.installReceipts, JSON.stringify(all, null, 2), 'utf8');
  } catch { /* losing the receipt is not fatal; see uninstall */ }
}

function forgetReceipt(targetPath) {
  try {
    const all = loadReceipts();
    delete all[targetPath];
    fs.writeFileSync(paths.installReceipts, JSON.stringify(all, null, 2), 'utf8');
  } catch { /* ignore */ }
}

function isInstalled() {
  try {
    const { settings } = readSettings();
    const hooks = settings.hooks;
    if (!hooks || typeof hooks !== 'object') return false;
    return CLAUDE_EVENTS.every((event) => {
      const arr = hooks[event];
      return Array.isArray(arr) && arr.some(isOurEntry);
    });
  } catch {
    return false;
  }
}

function install() {
  // Fail loudly and early rather than writing an entry that can never run.
  // Without a node on disk the hook is a command Claude Code tries to execute
  // and cannot find — and the symptom of that is the worst possible one: total
  // silence, no error, nothing in the spool.
  if (!fs.existsSync(HOOK_SCRIPT)) {
    throw new Error(`The hook script does not exist at ${HOOK_SCRIPT}.`);
  }
  if (resolveNodePath() === 'node') {
    throw new Error(
      'node.exe was not found on PATH. The hook needs Node.js to run.\n'
      + 'Install it from https://nodejs.org and try again.',
    );
  }

  const { settings, existed } = readSettings();
  const backupPath = backup();

  // The receipt answers a question the file itself cannot: did the `hooks` key
  // exist before we arrived? A user who wrote "hooks": {} by hand and a file we
  // created are identical once our entries are gone. So we remember instead of
  // guessing.
  const receipt = {
    targetPath: paths.claudeSettings,
    createdFile: !existed,
    createdHooksKey: !settings.hooks,
    createdEventKeys: [],
    hookInvocation: hookInvocation(),
    installedAt: new Date().toISOString(),
    backupPath,
  };

  if (!settings.hooks || typeof settings.hooks !== 'object' || Array.isArray(settings.hooks)) {
    settings.hooks = {};
    receipt.createdHooksKey = true;
  }

  for (const event of CLAUDE_EVENTS) {
    if (!Array.isArray(settings.hooks[event])) {
      settings.hooks[event] = [];
      receipt.createdEventKeys.push(event);
    }
    // Strip any older entry of ours before adding the new one, or reinstalling
    // would fire the hook twice per event.
    settings.hooks[event] = settings.hooks[event].filter((e) => !isOurEntry(e));
    settings.hooks[event].push(newEntry());
  }

  writeSettings(settings);
  saveReceipt(receipt);
  return receipt;
}

function uninstall() {
  const { settings } = readSettings();
  const receipt = loadReceipts()[paths.claudeSettings] || {};
  backup();

  if (!settings.hooks || typeof settings.hooks !== 'object') return { removed: 0 };

  let removed = 0;
  for (const event of CLAUDE_EVENTS) {
    const arr = settings.hooks[event];
    if (!Array.isArray(arr)) continue;
    const before = arr.length;
    settings.hooks[event] = arr.filter((e) => !isOurEntry(e));
    removed += before - settings.hooks[event].length;

    // We only remove structure we can prove we created.
    if (settings.hooks[event].length === 0
      && (receipt.createdEventKeys || []).includes(event)) {
      delete settings.hooks[event];
    }
  }

  if (receipt.createdHooksKey && Object.keys(settings.hooks).length === 0) {
    delete settings.hooks;
  }

  writeSettings(settings);
  forgetReceipt(paths.claudeSettings);
  return { removed };
}

// What the app shows on the diagnostics screen.
function status() {
  const problems = [];
  if (!fs.existsSync(HOOK_SCRIPT)) {
    problems.push('The hook script was not found on disk.');
  }
  const node = resolveNodePath();
  if (node === 'node') {
    problems.push('node.exe was not found on PATH; the hooks depend on it.');
  }
  return {
    installed: isInstalled(),
    settingsPath: paths.claudeSettings,
    hookScript: HOOK_SCRIPT,
    nodePath: node,
    problems,
  };
}

module.exports = {
  CLAUDE_EVENTS,
  HOOK_SCRIPT,
  install,
  uninstall,
  isInstalled,
  status,
  isOurEntry,
  hookInvocation,
  resolveNodePath,
};
