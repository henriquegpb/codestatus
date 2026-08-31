'use strict';

// How the hook gets a JavaScript runtime to run in.
//
// This exists because of one gap in Claude Code's hook schema: a command hook
// takes `command`, `args`, `timeout`, `async` and `shell`, and nothing that
// sets an environment variable. That single missing field decides the shape of
// this whole file.
//
// The app ships an Electron binary, and an Electron binary *is* Node when
// ELECTRON_RUN_AS_NODE is set in its environment. Without a way to set that in
// the hook entry, the packaged app would have to carry a second runtime just to
// run 250 lines of JavaScript — `node.exe` alone is 78 MB, which is most of an
// installer, for a job the binary already sitting next to it can do.
//
// So the installer writes a four-line .cmd that sets the variable and hands
// over, and registers `cmd.exe /c <shim>`. That still uses the exec form: the
// executable Claude Code spawns is cmd.exe itself, with an argument vector we
// control completely. The cost is one cmd.exe per event, around ten
// milliseconds, against 78 MB and a second copy of Node.
//
// The shim takes no arguments, and that is load-bearing rather than tidy. The
// path it lives at contains the user's profile name, which is allowed to have a
// space in it, so Windows quotes it — and `cmd /c` has a documented rule for
// what it does with quotes. With exactly two of them, around the name of an
// executable and nothing after the closing quote, they are preserved. Add
// `--provider claude-code` on the end and that rule stops applying: cmd strips
// the outer pair instead, and then tries to run `C:\Users\John`. So the
// provider is baked into the shim, and a second agent would get a second shim.
//
// The right long-term answer is a compiled hook, the way macOS has one — that
// removes the runtime question and the cold start together. This is what makes
// the app installable before that exists.

const fs = require('fs');
const path = require('path');

const { paths } = require('./paths');

// Whether we are running from an installed bundle or from a source checkout.
//
// Read lazily and defensively: this module is loaded by the installer tests,
// which run under plain Node with no Electron at all.
function electronApp() {
  try {
    // eslint-disable-next-line global-require
    return require('electron').app || null;
  } catch {
    return null;
  }
}

// The binary that will run hook.js, as a Node interpreter.
//
// Packaged, that is the app's own executable. From a source checkout it is the
// Electron that npm installed — not the `node` on PATH, because the point is to
// stop depending on one being there. Both are overridable for tests.
function resolveRuntime() {
  if (process.env.CODESTATUS_HOOK_RUNTIME) return process.env.CODESTATUS_HOOK_RUNTIME;

  const app = electronApp();
  if (app && app.isPackaged) return process.execPath;

  const local = path.join(__dirname, '..', '..', 'node_modules', 'electron', 'dist', 'electron.exe');
  if (fs.existsSync(local)) return local;

  // Last resort, and the only path that still depends on a Node being
  // installed. Reached from a source checkout whose dependencies were never
  // fetched, which is a state the installer refuses to leave anyone in.
  return process.execPath;
}

// Where hook.js lives.
//
// Kept out of the asar archive by `extraResources`, so it is a plain readable
// file on disk. An asar is an Electron construct, and the hook has to be
// runnable by something that is only pretending to be Electron.
function resolveHookScript() {
  if (process.env.CODESTATUS_HOOK_SCRIPT) return process.env.CODESTATUS_HOOK_SCRIPT;

  const app = electronApp();
  if (app && app.isPackaged) return path.join(process.resourcesPath, 'hook', 'hook.js');

  return path.join(__dirname, '..', '..', 'hook', 'hook.js');
}

// The shim lives in app data rather than beside the app.
//
// Two reasons. It is always writable, which the installation directory is not
// once an app is installed for all users. And its path does not move when the
// app updates, so an agent that read the hook configuration before an update
// still finds something valid afterwards.
function shimPath(provider = 'claude-code') {
  return path.join(paths.bin, `hook-${provider}.cmd`);
}

// Writes the shim, and returns where it went.
//
// Rewritten on every install, because both the runtime and the script path move
// when the app is updated or reinstalled somewhere else.
// `target` exists for the test that runs the generated file from a path with a
// space in it. The quoting rule that decides this design is only worth
// believing if something exercises it.
function writeShim({
  provider = 'claude-code',
  runtime = resolveRuntime(),
  script = resolveHookScript(),
  target = shimPath(provider),
} = {}) {
  fs.mkdirSync(path.dirname(target), { recursive: true });

  // `setlocal` keeps the variable from leaking into anything cmd.exe runs
  // afterwards. Everything else is quoted here, where we control the quoting,
  // rather than at the call site where cmd.exe controls it.
  const contents = [
    '@echo off',
    'setlocal',
    'set ELECTRON_RUN_AS_NODE=1',
    `"${runtime}" "${script}" --provider ${provider}`,
    '',
  ].join('\r\n');

  fs.writeFileSync(target, contents, 'utf8');
  return target;
}

module.exports = {
  resolveRuntime, resolveHookScript, shimPath, writeShim,
};
