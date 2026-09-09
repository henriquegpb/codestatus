'use strict';

// Port of Sources/CodeStatusCore/Runtime/RuntimePaths.swift, for Linux.
//
// Centralised because two independent programs — the app and the hook — have to
// agree exactly on these paths, and here they have to agree without talking:
// Claude Code spawns the hook with whatever environment the terminal had, which
// is not necessarily the one the app was launched with.
//
// That constraint is the whole reason the layout below is split in two.
//
// The XDG basedir spec puts durable data in $XDG_DATA_HOME and sockets in
// $XDG_RUNTIME_DIR, and the tempting reading is to move everything we write at
// runtime into the latter. We do not, and the reason is the hook. It finds the
// daemon by reading a pointer file, and it can only do that if it computes the
// same directory the daemon wrote it to. $XDG_RUNTIME_DIR is set by pam_systemd
// for a login session and inherited by everything in it — but an agent started
// from a systemd unit, a cron job, a container, or an ssh session without
// lingering enabled may not have it. If the pointer lived there, the hook in
// those sessions would compute a different directory, find nothing, and spool
// to a place the daemon never reads: events lost, silently, which is the exact
// failure this app exists to not have.
//
// So the pointer, the heartbeat and the spool live under $XDG_DATA_HOME, which
// falls back to a path derived from $HOME and is therefore always the same for
// both programs. Only the socket itself goes in $XDG_RUNTIME_DIR, because the
// hook never has to guess where it is — it reads the pointer, which holds the
// absolute path. Which is what the pointer was always for.

const os = require('os');
const path = require('path');
const fs = require('fs');

const home = os.homedir();

function xdg(variable, fallback) {
  const value = process.env[variable];
  // The spec says a relative value must be ignored, not resolved.
  return value && path.isAbsolute(value) ? value : fallback;
}

// ~/.local/share/CodeStatus is the Linux equivalent of
// ~/Library/Application Support/CodeStatus.
//
// The override is a test seam, and the same one the Windows file carries: a
// suite that exercises a real install should not leave backups in the data
// directory of whoever ran it.
const base = path.join(
  process.env.CODESTATUS_DATA_HOME
    || xdg('XDG_DATA_HOME', path.join(home, '.local', 'share')),
  'CodeStatus',
);

const run = path.join(base, 'run');
// Small files we generate; nothing is executed from here on Linux, but the
// directory is kept so both seams have the same shape and a future launcher has
// somewhere writable to live.
const bin = path.join(base, 'bin');
const backups = path.join(base, 'backups');
const state = path.join(base, 'state');
const spool = path.join(run, 'spool');

// Where the socket goes.
//
// AF_UNIX addresses are capped at 108 bytes on Linux, including the terminator,
// and the whole path counts. $XDG_RUNTIME_DIR is /run/user/<uid>, which leaves
// plenty; the $HOME fallback usually does too. `/tmp` is the last resort for the
// case neither does — an unusually deep home directory — because a truncated
// address does not fail loudly, it binds to a shorter path than the one we
// asked for and the hook then connects to nothing.
const SUN_PATH_MAX = 108;

function socketDirectory() {
  const runtimeDir = xdg('XDG_RUNTIME_DIR', null);
  const candidates = [
    runtimeDir ? path.join(runtimeDir, 'CodeStatus') : null,
    run,
    // uid rather than username: it cannot contain a separator or a space, and
    // two users must not collide in a shared directory.
    path.join(os.tmpdir(), `codestatus-${typeof os.userInfo === 'function' ? os.userInfo().uid : 0}`),
  ].filter(Boolean);

  for (const dir of candidates) {
    if (Buffer.byteLength(path.join(dir, 'daemon.sock')) < SUN_PATH_MAX) return dir;
  }
  return candidates[candidates.length - 1];
}

const socketDir = socketDirectory();

const paths = {
  home,
  base,
  // ext4, btrfs, xfs and every other filesystem in ordinary use here compare
  // case-sensitively, so two spellings of a path are two different files. The
  // installer needs to know: folding case would let us claim — and then delete
  // — somebody else's hook entry that differs from ours only in case.
  caseInsensitive: false,
  run,
  bin,
  backups,
  state,
  spool,
  socketDir,
  socket: path.join(socketDir, 'daemon.sock'),
  heartbeat: path.join(run, 'heartbeat'),
  // Points at the live socket, so the hook never needs its location compiled
  // in — and, per the header, never has to reconstruct $XDG_RUNTIME_DIR.
  pipePointer: path.join(run, 'pipe-name'),
  sessionsSnapshot: path.join(state, 'sessions.json'),
  prefs: path.join(state, 'prefs.json'),
  installReceipts: path.join(state, 'installation.json'),

  // Where a .desktop file goes to make the app start with the session. Linux
  // has no equivalent of the login-item API the other two platforms expose;
  // see linux/autostart.js.
  autostart: path.join(xdg('XDG_CONFIG_HOME', path.join(home, '.config')), 'autostart'),

  // Claude Code's configuration. One file serves both the CLI and the VS Code
  // extension — the extension bundles its own CLI but reads the same user
  // config — so installing here covers both surfaces with a single edit.
  //
  // Claude Code does not follow XDG for this: it is ~/.claude on every
  // platform, so this line is identical to the Windows one.
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

  // The Claude Code desktop app's own session list, which is where a rename
  // typed in that list is stored — the transcript keeps whatever title was
  // appended to it earlier. Electron's userData on Linux is $XDG_CONFIG_HOME,
  // the equivalent of ~/Library/Application Support on macOS.
  claudeDesktopSessions: process.env.CODESTATUS_CLAUDE_DESKTOP_SESSIONS
    || path.join(
      xdg('XDG_CONFIG_HOME', path.join(home, '.config')),
      'Claude',
      'claude-code-sessions',
    ),
};

// 0700 throughout, matching what the macOS app creates. On a single-user
// Windows profile the default ACL already amounts to this; on Linux a shared
// machine is ordinary, and the spool holds session metadata.
function createDirectories() {
  for (const dir of [base, run, bin, backups, state, spool, socketDir]) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    // mkdir applies the mode only to directories it creates, so a directory
    // that already existed with looser permissions is tightened here.
    try {
      fs.chmodSync(dir, 0o700);
    } catch { /* not ours to tighten; the socket mode still bounds access */ }
  }
}

module.exports = { paths, createDirectories, SUN_PATH_MAX };
