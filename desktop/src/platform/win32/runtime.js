'use strict';

// How the hook gets a JavaScript runtime to run in, on Windows.
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
// Linux needs none of this: `/usr/bin/env` sets the variable in the exec form
// itself, so linux/runtime.js has no shim at all. See the note there.

const fs = require('fs');
const path = require('path');

const { paths } = require('./paths');
const { isPackaged, resolveHookScript, bundledElectron } = require('../app-layout');

// The binary that will run hook.js, as a Node interpreter.
//
// Packaged, that is the app's own executable. From a source checkout it is the
// Electron that npm installed — not the `node` on PATH, because the point is to
// stop depending on one being there. Both are overridable for tests.
function resolveRuntime() {
  if (process.env.CODESTATUS_HOOK_RUNTIME) return process.env.CODESTATUS_HOOK_RUNTIME;
  if (isPackaged()) return process.execPath;

  const local = bundledElectron('electron.exe');
  if (fs.existsSync(local)) return local;

  // Last resort, and the only path that still depends on a Node being
  // installed. Reached from a source checkout whose dependencies were never
  // fetched, which is a state the installer refuses to leave anyone in.
  return process.execPath;
}

// The shim lives in app data rather than beside the app.
//
// Two reasons. It is always writable, which the installation directory is not
// once an app is installed for all users. And its path does not move when the
// app updates, so an agent that read the hook configuration before an update
// still finds something valid afterwards.
function launcherPath(provider = 'claude-code') {
  return path.join(paths.bin, `hook-${provider}.cmd`);
}

// The shell cmd.exe is invoked as, resolved from the environment so a machine
// with Windows installed somewhere unusual still works.
function comSpec() {
  return process.env.CODESTATUS_COMSPEC || process.env.ComSpec || 'C:\\Windows\\System32\\cmd.exe';
}

// The command and its arguments, kept separate — never one command line.
//
// This is not style: it is the difference between working and not working on
// Windows. When `args` is present, Claude Code spawns `command` directly with
// no shell involved. When `args` is omitted it passes the line through a shell
// — and the documented default on Windows is PowerShell, where a line beginning
// with a quoted path is merely a *string literal* that PowerShell echoes.
// Without the `&` operator nothing executes, and the hook never runs: no error,
// no log, just silence.
//
// cmd.exe as the executable is not a return to the shell form. The argument
// vector is ours, quoted by the spawn rather than by string concatenation, and
// the file it runs is one we wrote.
function hookInvocation(provider = 'claude-code') {
  return {
    command: comSpec(),
    args: ['/d', '/c', launcherPath(provider)],
  };
}

// Everything an entry of ours may point at.
//
// Two shapes are current and one is historical: `hook.js` appears in entries
// written before the shim existed, and they have to stay recognisable or
// reinstalling would leave them behind and the hook would fire twice per event.
//
// cmd.exe is deliberately absent. It is our `command`, but it is also a system
// binary anyone's hook may use, so matching on it would make us delete other
// people's entries.
function ownedPaths(provider = 'claude-code') {
  return [launcherPath(provider), resolveHookScript()];
}

// File extensions a path inside an entry may have, for pulling one out of the
// historical single-string command form.
const SCRIPT_EXTENSIONS = ['js', 'cmd'];

// Nothing on Windows stops the app from being connected: the app data directory
// is always writable and the paths it writes are stable across a restart. The
// counterpart on Linux has one case that is not; see the note there.
function blockingProblem() {
  return null;
}

// Writes the shim, and returns the invocation that now points at it.
//
// Rewritten on every install, because both the runtime and the script path move
// when the app is updated or reinstalled somewhere else.
// `target` exists for the test that runs the generated file from a path with a
// space in it. The quoting rule that decides this design is only worth
// believing if something exercises it.
function writeLauncher({
  provider = 'claude-code',
  runtime = resolveRuntime(),
  script = resolveHookScript(),
  target = launcherPath(provider),
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
  return { launcherPath: target, ...hookInvocation(provider) };
}

module.exports = {
  resolveRuntime,
  resolveHookScript,
  launcherPath,
  hookInvocation,
  ownedPaths,
  blockingProblem,
  writeLauncher,
  SCRIPT_EXTENSIONS,
  // Kept under its old name for the suite that exercises the quoting rule.
  writeShim: writeLauncher,
  shimPath: launcherPath,
};
