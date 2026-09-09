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
// Difference from macOS: there the `command` points at a compiled Swift binary
// and owning an entry is a matter of comparing that one path. Here `command` is
// a system binary — cmd.exe on Windows, /usr/bin/env on Linux — and the real
// work is in `args`, so ownership detection has to look at the paths inside the
// whole invocation rather than at `command`, which anyone's hook may also use.
//
// Everything that differs between the two platforms is behind
// platform/runtime: what the invocation looks like, whether installing writes a
// launcher first, and which paths mark an entry as ours. This file no longer
// knows what a shim is, or that one platform needs one.

const fs = require('fs');
const path = require('path');

const { paths } = require('../platform/paths');
const { AgentProvider } = require('../core/events');
const runtime = require('../platform/runtime');

const { resolveRuntime, resolveHookScript } = runtime;

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

const PROVIDER = 'claude-code';

// Both platforms write the exec form — `command` plus a separate `args` — and
// on Windows that is not style but the difference between working and not
// working. When `args` is present, Claude Code spawns `command` directly with
// no shell involved. When `args` is omitted it passes the line through a shell,
// and the documented default on Windows is PowerShell, where a line beginning
// with a quoted path is merely a *string literal* that PowerShell echoes.
// Without the `&` operator nothing executes, and the hook never runs: no error,
// no log, just silence. The shapes themselves live in platform/runtime.
function hookInvocation() {
  return runtime.hookInvocation(PROVIDER);
}

// Path comparison, folded or not according to the filesystem underneath.
//
// Case matters here in both directions, and which direction is right is a
// property of the platform rather than of this file — so the answer comes from
// the seam. See the note on `caseInsensitive` in each paths.js.
function canonical(p) {
  try {
    const resolved = path.resolve(p);
    return paths.caseInsensitive ? resolved.toLowerCase() : resolved;
  } catch {
    return null;
  }
}

// Everything an entry of ours may point at, canonicalised.
function ownedPaths() {
  return new Set(runtime.ownedPaths(PROVIDER).map(canonical).filter(Boolean));
}

// Matches a path out of the historical single-string command form, by the
// extensions the current platform's launcher and script can have.
const PATH_IN_STRING = new RegExp(
  `"([^"]+\\.(?:${runtime.SCRIPT_EXTENSIONS.join('|')}))"|(\\S+\\.(?:${runtime.SCRIPT_EXTENSIONS.join('|')}))`,
);

// An entry is ours if it references one of those paths, wherever in the
// invocation it appears. Compare resolved paths, never substrings: a user's own
// hook whose line merely mentions "codestatus" is not ours and has to survive.
//
// `command` is checked too, because the historical Windows format put the path
// there — but neither platform's `command` is a path we own (cmd.exe,
// /usr/bin/env), so an unrelated hook that also runs through one of those is
// safe.
function isOurEntry(entry) {
  if (!entry || typeof entry !== 'object') return false;
  const hooks = Array.isArray(entry.hooks) ? entry.hooks : [];
  const owned = ownedPaths();

  return hooks.some((h) => {
    if (!h || typeof h !== 'object') return false;
    const candidates = [];
    if (typeof h.command === 'string') candidates.push(h.command);
    if (Array.isArray(h.args)) {
      for (const a of h.args) if (typeof a === 'string') candidates.push(a);
    }
    return candidates.some((raw) => {
      // Whole argument first: that is the shape the exec form produces. The
      // extraction is for the historical single-line command, where the path
      // sits inside a longer string.
      const forms = [raw.trim().replace(/^"|"$/g, '')];
      const match = raw.match(PATH_IN_STRING);
      if (match) forms.push((match[1] || match[2]).trim());
      return forms.some((form) => owned.has(canonical(form)));
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

// Answering this means reading and parsing the user's settings.json, and the
// daemon asks on every snapshot — which is every hook event. A short cache
// keeps a busy turn from re-reading the file a dozen times a second, and is
// short enough that editing the file by hand still shows up promptly.
const INSTALLED_CACHE_MS = 5000;
let installedCache = { value: null, at: 0 };

function invalidateInstalledCache() {
  installedCache = { value: null, at: 0 };
}

function isInstalled() {
  const now = Date.now();
  if (installedCache.value !== null && now - installedCache.at < INSTALLED_CACHE_MS) {
    return installedCache.value;
  }

  let value;
  try {
    const { settings } = readSettings();
    const hooks = settings.hooks;
    value = Boolean(hooks) && typeof hooks === 'object' && CLAUDE_EVENTS.every((event) => {
      const arr = hooks[event];
      return Array.isArray(arr) && arr.some(isOurEntry);
    });
  } catch {
    value = false;
  }

  installedCache = { value, at: now };
  return value;
}

// Providers whose hook entries are in their config file right now. What the
// diagnosis uses to tell "never connected" from "started before the install".
function connectedProviders() {
  const connected = new Set();
  if (isInstalled()) connected.add(AgentProvider.claudeCode);
  return connected;
}

// When each provider's hooks were written, as epoch milliseconds.
function hooksInstalledAt() {
  const out = {};
  const receipt = loadReceipts()[paths.claudeSettings];
  if (receipt && receipt.installedAt) {
    const at = Date.parse(receipt.installedAt);
    if (!Number.isNaN(at)) out[AgentProvider.claudeCode] = at;
  }
  return out;
}

function install() {
  // Fail loudly and early rather than writing an entry that can never run. The
  // symptom of a hook entry pointing at something absent is the worst possible
  // one: total silence, no error, nothing in the spool.
  const script = resolveHookScript();
  if (!fs.existsSync(script)) {
    throw new Error(`The hook script does not exist at ${script}.`);
  }
  const interpreter = resolveRuntime();
  if (!fs.existsSync(interpreter)) {
    throw new Error(
      `The JavaScript runtime for the hook was not found at ${interpreter}.\n`
      + 'If you are running from a source checkout, run npm install first.',
    );
  }

  // Whatever this platform needs on disk before an entry can point at it. On
  // Windows that is the shim, rewritten on every install because both paths
  // inside it move when the app is updated or reinstalled somewhere else. On
  // Linux it is nothing — but it is also where the AppImage refusal happens,
  // which is why it runs before the settings file is touched.
  runtime.writeLauncher({ provider: PROVIDER, runtime: interpreter, script });

  const { settings, existed } = readSettings();
  const backupPath = backup();

  // The receipt answers a question the file itself cannot: did the `hooks` key
  // exist before we arrived? A user who wrote "hooks": {} by hand and a file we
  // created are identical once our entries are gone. So we remember instead of
  // guessing.
  const receipt = {
    targetPath: paths.claudeSettings,
    provider: AgentProvider.claudeCode,
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
  invalidateInstalledCache();
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
  invalidateInstalledCache();
  return { removed };
}

// What the app shows on the settings screen.
function status() {
  const problems = [];
  const script = resolveHookScript();
  const interpreter = resolveRuntime();
  if (!fs.existsSync(script)) {
    problems.push('The hook script was not found on disk.');
  }
  if (!fs.existsSync(interpreter)) {
    problems.push('The JavaScript runtime for the hook was not found.');
  }
  // Asked of the same function the installer refuses on, so the settings screen
  // and the Connect button can never disagree about whether this machine can be
  // connected at all. Currently only linux/runtime.js ever declines.
  const blocking = runtime.blockingProblem({ runtime: interpreter, script });
  if (blocking) problems.push(blocking);
  return {
    installed: isInstalled(),
    settingsPath: paths.claudeSettings,
    hookScript: script,
    runtime: interpreter,
    launcher: runtime.launcherPath(PROVIDER),
    events: CLAUDE_EVENTS.length,
    problems,
  };
}

module.exports = {
  CLAUDE_EVENTS,
  install,
  uninstall,
  isInstalled,
  status,
  isOurEntry,
  hookInvocation,
  connectedProviders,
  hooksInstalledAt,
};
