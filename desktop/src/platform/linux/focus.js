'use strict';

// Bringing the user back to the session they clicked, on Linux.
//
// This is the one place where the Linux build is genuinely less capable than
// the other two, and the reason is a deliberate design decision in Wayland
// rather than a gap we can engineer around.
//
// On macOS the app runs AppleScript and selects the exact terminal tab. On
// Windows there are no tabs to select, so it raises the window hosting the
// agent's process. Under X11 the same thing is possible here: a window carries
// _NET_WM_PID, so the window belonging to a pid can be found and activated
// through the window manager.
//
// Under Wayland it cannot. There is no protocol by which one client asks the
// compositor to raise another client's window, and that is the point — it is
// how Wayland stops any application from stealing focus. xdg-activation exists
// for the case where an app *hands over* focus it already has, which is not
// this: the agent never asked to be raised, so there is no activation token to
// pass. So on a Wayland session the honest answer is that we cannot, and the
// caller falls back to opening the project folder.
//
// The nuance that makes this worth attempting anyway: most terminals still run
// through XWayland on a Wayland session, and an XWayland window is a real X11
// window with a real _NET_WM_PID. So the X11 path below is tried whenever there
// is a DISPLAY to try it on, and it succeeds more often than the session type
// alone would suggest. What it cannot do is raise a native Wayland window.

const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

const TIMEOUT_MS = 5000;
// The same bound the Windows seam walks: far enough to climb out of a shell and
// a multiplexer into the terminal, short enough that a cycle cannot spin.
const MAX_DEPTH = 12;

const PROC = process.env.CODESTATUS_PROC || '/proc';

function onWayland() {
  return process.env.XDG_SESSION_TYPE === 'wayland' || Boolean(process.env.WAYLAND_DISPLAY);
}

function hasX11() {
  return Boolean(process.env.DISPLAY);
}

// Resolves a bare name against PATH, so a missing tool is a `false` here rather
// than an ENOENT surfacing from a spawn.
function which(binary) {
  const dirs = (process.env.PATH || '').split(':').filter(Boolean);
  for (const dir of dirs) {
    const full = path.join(dir, binary);
    try {
      fs.accessSync(full, fs.constants.X_OK);
      return full;
    } catch { /* next */ }
  }
  return null;
}

// The pids to try, nearest first: the agent, then its ancestors.
//
// The window belongs to the terminal, not to the `node` process running inside
// it, so the agent's own pid almost never has one. Read straight from /proc
// rather than taken from the daemon's scan, because this runs on a click and
// the scan may be twenty seconds stale — and a pid that has since been reused
// would raise a stranger's window.
function ancestry(pid, procRoot = PROC) {
  const chain = [];
  let current = pid;
  for (let depth = 0; depth < MAX_DEPTH && current > 1; depth += 1) {
    chain.push(current);
    let text;
    try {
      text = fs.readFileSync(path.join(procRoot, String(current), 'stat'), 'utf8');
    } catch {
      break;
    }
    const close = text.lastIndexOf(')');
    if (close === -1) break;
    const parent = Number(text.slice(close + 2).split(' ')[1]);
    if (!Number.isInteger(parent) || parent <= 1 || chain.includes(parent)) break;
    current = parent;
  }
  return chain;
}

// Activating a window through xdotool.
//
// `windowactivate` rather than `windowraise`: raising changes the stacking
// order without moving keyboard focus, which puts the terminal on screen and
// leaves the user typing into CodeStatus. It also switches desktop if the
// window is on another one, which is the behaviour someone clicking a row
// wants.
function tryXdotool(tool, pids, callback) {
  const remaining = pids.slice();

  const attempt = () => {
    if (remaining.length === 0) {
      callback(false);
      return;
    }
    const pid = remaining.shift();
    execFile(tool, ['search', '--pid', String(pid)], { timeout: TIMEOUT_MS }, (err, stdout) => {
      const windows = (stdout || '').split('\n').map((s) => s.trim()).filter(Boolean);
      if (err || windows.length === 0) {
        attempt();
        return;
      }
      // A process can own several windows — a terminal with two windows, or the
      // invisible utility windows some toolkits create. The last one xdotool
      // lists is the most recently created, which is the closest thing to "the
      // one the user was last in" that is available without asking the window
      // manager for a stacking order it need not provide.
      const target = windows[windows.length - 1];
      execFile(tool, ['windowactivate', '--sync', target], { timeout: TIMEOUT_MS }, (actErr) => {
        if (actErr) attempt();
        else callback(true);
      });
    });
  };

  attempt();
}

// The wmctrl fallback.
//
// Where xdotool searches by pid, wmctrl lists every window with its pid and we
// match, then activate by window id. Two tools rather than one because neither
// is installed by default on every distribution and between them the coverage
// is most machines: wmctrl is in Debian and Fedora's default repositories and
// is the older, more widely present of the two.
function tryWmctrl(tool, pids, callback) {
  execFile(tool, ['-l', '-p'], { timeout: TIMEOUT_MS }, (err, stdout) => {
    if (err) {
      callback(false);
      return;
    }
    // Columns: window-id, desktop, pid, host, title.
    const byPid = new Map();
    for (const line of (stdout || '').split('\n')) {
      const parts = line.trim().split(/\s+/);
      if (parts.length < 3) continue;
      const pid = Number(parts[2]);
      if (!Number.isInteger(pid) || pid <= 0) continue;
      // Last wins, for the same reason xdotool takes the last match.
      byPid.set(pid, parts[0]);
    }

    // Nearest ancestor first, so a terminal is preferred over the desktop
    // session that also happens to be an ancestor of everything.
    const target = pids.map((pid) => byPid.get(pid)).find(Boolean);
    if (!target) {
      callback(false);
      return;
    }
    execFile(tool, ['-i', '-a', target], { timeout: TIMEOUT_MS }, (actErr) => callback(!actErr));
  });
}

// Why a focus attempt could not even be made. Shown on the settings screen, so
// that "clicking a row opens a folder" reads as a known limitation of the
// session type rather than as the app being broken.
function focusCapability() {
  if (!hasX11()) {
    return {
      available: false,
      reason: onWayland()
        ? 'This is a Wayland session with no XWayland display. Wayland has no protocol '
          + 'for one application to raise another’s window, so clicking a session '
          + 'opens its folder instead.'
        : 'No X display was found, so there is no window manager to ask.',
    };
  }
  if (!which('xdotool') && !which('wmctrl')) {
    return {
      available: false,
      reason: 'Neither xdotool nor wmctrl is installed. Install either one and clicking '
        + 'a session will raise its terminal instead of opening its folder.',
    };
  }
  if (onWayland()) {
    return {
      available: true,
      reason: 'This is a Wayland session. Terminals running through XWayland can be '
        + 'raised; native Wayland windows cannot, and those fall back to opening '
        + 'the folder.',
    };
  }
  return { available: true, reason: null };
}

// Raises the window hosting `pid`. Calls back with true when one was found.
//
// Never throws and never leaves the callback uncalled: the caller uses `false`
// to decide to open the project folder instead, so a silent failure here would
// mean a click that does nothing at all.
function focusProcessWindow(pid, callback = () => {}) {
  if (!pid || !hasX11()) {
    callback(false);
    return;
  }

  const pids = ancestry(pid);
  if (pids.length === 0) {
    callback(false);
    return;
  }

  const xdotool = which('xdotool');
  const wmctrl = which('wmctrl');

  if (xdotool) {
    tryXdotool(xdotool, pids, (ok) => {
      if (ok || !wmctrl) callback(ok);
      else tryWmctrl(wmctrl, pids, callback);
    });
    return;
  }
  if (wmctrl) {
    tryWmctrl(wmctrl, pids, callback);
    return;
  }
  callback(false);
}

module.exports = {
  focusProcessWindow, focusCapability, ancestry, onWayland, which,
};
