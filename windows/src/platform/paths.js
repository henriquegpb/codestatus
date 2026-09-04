'use strict';

// Port of Sources/CodeStatusCore/Runtime/RuntimePaths.swift, for Windows.
//
// Centralised because two independent programs — the app and the hook — have to
// agree exactly on these paths.
//
// The main difference from macOS: there the transport is a Unix domain socket
// under ~/Library/Application Support, and all the care about sun_path's
// 104-byte limit exists because of that. Here it is a named pipe, whose name
// lives in the \\.\pipe\ namespace and never touches the filesystem — so there
// is no path limit to work around and the whole socket-path/fallback mechanism
// disappears. The on-disk pointer survives only so the hook can discover the
// pipe name without having it compiled in.

const os = require('os');
const path = require('path');
const fs = require('fs');

const home = os.homedir();

// %LOCALAPPDATA%\CodeStatus is the Windows equivalent of
// ~/Library/Application Support/CodeStatus.
const base = process.env.LOCALAPPDATA
  ? path.join(process.env.LOCALAPPDATA, 'CodeStatus')
  : path.join(home, 'AppData', 'Local', 'CodeStatus');

const run = path.join(base, 'run');
// Small files we generate and the agent then executes — currently the hook
// shim. Kept in app data rather than beside the app: always writable, and its
// path does not move when the app is updated.
const bin = path.join(base, 'bin');
const backups = path.join(base, 'backups');
const state = path.join(base, 'state');
const spool = path.join(run, 'spool');

const paths = {
  home,
  base,
  run,
  bin,
  backups,
  state,
  spool,
  heartbeat: path.join(run, 'heartbeat'),
  // Points at the live pipe, so the hook never needs the name compiled in.
  pipePointer: path.join(run, 'pipe-name'),
  sessionsSnapshot: path.join(state, 'sessions.json'),
  prefs: path.join(state, 'prefs.json'),
  installReceipts: path.join(state, 'installation.json'),

  // Claude Code's configuration. One file serves both the CLI and the VS Code
  // extension — the extension bundles its own CLI but reads the same user
  // config — so installing here covers both surfaces with a single edit.
  //
  // The environment variable is a test seam, equivalent to the `home:`
  // parameter the macOS installer takes: it lets the tests exercise a real
  // install without writing to the user's actual configuration.
  claudeSettings: process.env.CODESTATUS_CLAUDE_SETTINGS
    || path.join(home, '.claude', 'settings.json'),

  // Not ours, and not written by us: the agents' own session stores, read to
  // recover the name a session gave itself. See platform/titles.js for what is
  // taken out of them, which is the title and nothing else.
  //
  // Both are undocumented and unversioned, so every read there is written to
  // fail into a null rather than into an error.
  claudeProjects: process.env.CODESTATUS_CLAUDE_PROJECTS
    || path.join(home, '.claude', 'projects'),
  codexSessionIndex: process.env.CODESTATUS_CODEX_INDEX
    || path.join(home, '.codex', 'session_index.jsonl'),
};

function createDirectories() {
  for (const dir of [base, run, bin, backups, state, spool]) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

module.exports = { paths, createDirectories };
