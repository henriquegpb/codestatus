'use strict';

// How the hook gets a JavaScript runtime to run in, on Linux.
//
// The Windows seam is a long file because Claude Code's hook schema has no
// field that sets an environment variable, and the app needs ELECTRON_RUN_AS_NODE
// set to use its own Electron as a Node. There it costs a generated .cmd shim
// and a paragraph about how `cmd /c` handles quotes.
//
// Here it costs nothing, because that is exactly what `env(1)` is:
//
//   /usr/bin/env ELECTRON_RUN_AS_NODE=1 <electron> <hook.js> --provider claude-code
//
// Still the exec form — Claude Code spawns `command` directly with the argument
// vector we supply, no shell is involved, and nothing has to be quoted by
// string concatenation. There is no shim file, no cold start of a shell, and no
// quoting rule to get wrong. `/usr/bin/env` is one of the two absolute paths
// that is present on essentially every Linux, NixOS included.
//
// What Linux has instead is a packaging problem the other platforms do not.

const fs = require('fs');

const { isPackaged, resolveHookScript, bundledElectron } = require('../app-layout');

const ENV_BINARY = process.env.CODESTATUS_ENV_BINARY || '/usr/bin/env';

// A path that only exists while the app is running.
//
// An AppImage is a squashfs image mounted on demand: it appears under a
// /tmp/.mount_XXXXXX directory when the app starts and the mount goes away when
// it exits. Both halves of the invocation live in there — the Electron binary
// and hook.js — so a hook entry written from an AppImage names two files that
// are gone the moment the user quits CodeStatus.
//
// That matters more than it first looks. The spool exists precisely so events
// survive the app being closed: the hook writes them to disk and the daemon
// replays them on the next launch. A hook that cannot run while the app is down
// does not degrade, it deletes exactly the events the spool was built for.
//
// So the installer refuses rather than writing a configuration that works in
// testing and fails in the one case it exists for. This is the same rule the
// macOS updater applies to itself when it is running from a disk image or a
// translocated path: a component that cannot do its job safely disables itself
// visibly instead of half-working.
const EPHEMERAL_MOUNT = /^\/tmp\/\.mount_|^\/run\/user\/\d+\/\.mount_/;

function isEphemeral(target) {
  return typeof target === 'string' && EPHEMERAL_MOUNT.test(target);
}

// The binary that will run hook.js, as a Node interpreter.
//
// Packaged, that is the app's own executable — /opt/CodeStatus/codestatus from
// a .deb or .rpm, which is a stable path that survives the app not running.
// From a source checkout it is the Electron that npm installed, not the `node`
// on PATH, because the point is to stop depending on one being there.
function resolveRuntime() {
  if (process.env.CODESTATUS_HOOK_RUNTIME) return process.env.CODESTATUS_HOOK_RUNTIME;
  if (isPackaged()) return process.execPath;

  const local = bundledElectron('electron');
  if (fs.existsSync(local)) return local;

  // Last resort, and the only path that still depends on a Node being
  // installed. Reached from a source checkout whose dependencies were never
  // fetched, which is a state the installer refuses to leave anyone in.
  return process.execPath;
}

// No shim on this platform, and the installer's status screen says so rather
// than showing a path to a file that does not exist.
function launcherPath() {
  return null;
}

// The command and its arguments, kept separate — never one command line.
//
// `env` reads leading NAME=VALUE arguments, applies them, and execs the rest.
// The provider therefore rides in the argument vector like everything else,
// with none of the Windows caveat about what may follow a quoted path.
function hookInvocation(provider = 'claude-code') {
  return {
    command: ENV_BINARY,
    args: [
      'ELECTRON_RUN_AS_NODE=1',
      resolveRuntime(),
      resolveHookScript(),
      '--provider',
      provider,
    ],
  };
}

// Everything an entry of ours may point at.
//
// Only the hook script. `/usr/bin/env` is a system binary anybody's hook may
// use, and the runtime is a path that changes with every update — matching on
// either would make us delete other people's entries or fail to recognise our
// own. The script path is the one stable thing that is unambiguously ours.
function ownedPaths() {
  return [resolveHookScript()];
}

// File extensions a path inside an entry may have. Linux executables have none,
// so this is the script and nothing else.
const SCRIPT_EXTENSIONS = ['js'];

// Why this machine cannot be connected at all, or null when it can.
//
// Pure, and asked by both the settings screen and the installer, so the button
// and the explanation next to it can never disagree.
function blockingProblem({
  runtime = resolveRuntime(),
  script = resolveHookScript(),
} = {}) {
  if (!isEphemeral(runtime) && !isEphemeral(script)) return null;
  return 'CodeStatus is running from an AppImage, whose files exist only while the '
    + 'app is open. Hook entries written now would name paths that disappear when '
    + 'you quit, and the events the spool exists to preserve would be the ones '
    + 'lost. Install the .deb or .rpm instead, or extract the AppImage '
    + '(--appimage-extract) and run AppRun from where you put it.';
}

// Nothing to write. Kept so both seams answer the same call, and so the one
// thing this platform does have to check happens on the same step the Windows
// seam writes its shim on.
function writeLauncher({
  provider = 'claude-code',
  runtime = resolveRuntime(),
  script = resolveHookScript(),
} = {}) {
  const problem = blockingProblem({ runtime, script });
  if (problem) throw new Error(problem);
  return { launcherPath: null, ...hookInvocation(provider) };
}

module.exports = {
  resolveRuntime,
  resolveHookScript,
  launcherPath,
  hookInvocation,
  ownedPaths,
  blockingProblem,
  writeLauncher,
  isEphemeral,
  SCRIPT_EXTENSIONS,
};
