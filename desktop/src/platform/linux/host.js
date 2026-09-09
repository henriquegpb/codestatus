'use strict';

// Which terminal an agent session is running in, on Linux.
//
// The same two-pass shape as the Windows seam, for a different reason. There,
// almost nothing is exported and the process tree does nearly all the work.
// Here the opposite is true: Linux terminals export plenty, they just do not
// agree on what. Every one of the variables below is that terminal's own idea
// of how to announce itself, and reading them is both cheaper and more precise
// than a tree walk — kitty and Alacritty are recognisable from the environment
// before the daemon has scanned anything.
//
// So:
//
//  1. The hook reads the environment. Covers most terminals, and it is the only
//     pass that runs inside the session, so it sees variables a scan cannot.
//  2. The daemon walks up the process tree from the agent's pid looking for a
//     known executable. Catches what exports nothing, and fixes the case where
//     the agent was started through something that stripped the environment.
//
// What is deliberately absent: guessing from $TERM. It describes the terminfo
// entry, not the program — `xterm-256color` is what Konsole, GNOME Terminal and
// tmux all set, so it identifies nothing. And $COLORTERM is worse: it answers a
// question about colour depth that some terminals answer with their own name
// and most answer with `truecolor`.

const { HostApplication } = require('../../core/events');

// Executable names, lower-cased, mapped to what we call them.
//
// The long tail maps onto `terminal` rather than getting a value of its own:
// see the note on HostApplication. What matters for a row is that we knew it
// was a terminal, and the six that are named are the ones a user reads as a
// name rather than as a category.
const HOST_BY_EXECUTABLE = new Map([
  ['konsole', HostApplication.konsole],
  ['gnome-terminal', HostApplication.gnomeTerminal],
  // GNOME Terminal forks a server and the window belongs to that, so this is
  // the name actually found in the tree above a shell.
  ['gnome-terminal-server', HostApplication.gnomeTerminal],
  ['xfce4-terminal', HostApplication.xfceTerminal],
  ['kitty', HostApplication.kitty],
  ['alacritty', HostApplication.alacritty],
  ['wezterm-gui', HostApplication.wezterm],
  ['wezterm', HostApplication.wezterm],
  ['code', HostApplication.vsCode],
  ['code-insiders', HostApplication.vsCode],
  ['codium', HostApplication.vsCode],
  ['cursor', HostApplication.vsCode],
  ['windsurf', HostApplication.vsCode],
  // Recognised as terminals, shown as such.
  ['xterm', HostApplication.terminal],
  ['urxvt', HostApplication.terminal],
  ['rxvt', HostApplication.terminal],
  ['st', HostApplication.terminal],
  ['foot', HostApplication.terminal],
  ['footclient', HostApplication.terminal],
  ['tilix', HostApplication.terminal],
  ['terminator', HostApplication.terminal],
  ['ptyxis', HostApplication.terminal],
  ['ptyxis-agent', HostApplication.terminal],
  ['deepin-terminal', HostApplication.terminal],
  ['lxterminal', HostApplication.terminal],
  ['mate-terminal', HostApplication.terminal],
  ['qterminal', HostApplication.terminal],
  ['guake', HostApplication.terminal],
  ['contour', HostApplication.terminal],
  ['ghostty', HostApplication.terminal],
  ['konsole-bin', HostApplication.konsole],
]);

// Where the walk gives up. Reaching any of these means no terminal was in the
// chain, and continuing would climb out of the user's session entirely.
//
// systemd appears twice over: as pid 1 on the machine and as the per-user
// manager that owns everything in a graphical session, which is the one this
// walk actually meets.
const WALK_STOPS_AT = new Set([
  'systemd', 'init', 'sshd', 'login', 'dbus-daemon', 'dbus-broker',
  'gnome-session-binary', 'plasmashell', 'xfce4-session', 'lxsession',
  'upstart', 'runit', 'openrc-run', 's6-supervise',
]);

// Terminals that are only identifiable from their own environment variable.
//
// Ordered most specific first. VS Code has to be checked before anything else:
// its integrated terminal inherits the variables of whatever terminal launched
// the editor, so a Konsole-launched VS Code sets KONSOLE_VERSION too, and
// answering "Konsole" there would be wrong about the thing the user is looking
// at.
const HOST_BY_VARIABLE = [
  ['VSCODE_INJECTION', HostApplication.vsCode],
  ['VSCODE_GIT_IPC_HANDLE', HostApplication.vsCode],
  ['KITTY_WINDOW_ID', HostApplication.kitty],
  ['ALACRITTY_SOCKET', HostApplication.alacritty],
  ['ALACRITTY_WINDOW_ID', HostApplication.alacritty],
  ['ALACRITTY_LOG', HostApplication.alacritty],
  ['WEZTERM_PANE', HostApplication.wezterm],
  ['WEZTERM_EXECUTABLE', HostApplication.wezterm],
  ['KONSOLE_VERSION', HostApplication.konsole],
  ['KONSOLE_DBUS_SESSION', HostApplication.konsole],
  ['GNOME_TERMINAL_SCREEN', HostApplication.gnomeTerminal],
  ['GNOME_TERMINAL_SERVICE', HostApplication.gnomeTerminal],
  // Set by foot and by Ghostty respectively; both land on the generic value.
  ['FOOT_PID', HostApplication.terminal],
  ['GHOSTTY_RESOURCES_DIR', HostApplication.terminal],
];

// From the hook's own environment. Runs inside the hook process, so it must not
// require anything: see hook/hook.js, which carries its own copy.
function hostFromEnvironment(env = process.env) {
  // TERM_PROGRAM is not a Linux convention, but the programs that set it on
  // macOS set it here too — VS Code above all, which is the one that matters.
  if (env.TERM_PROGRAM === 'vscode') return HostApplication.vsCode;

  for (const [variable, host] of HOST_BY_VARIABLE) {
    if (env[variable]) return host;
  }

  // Last, and only as a category: TERM_PROGRAM set to anything else means some
  // terminal claimed the variable, so we know it is a terminal without knowing
  // which. Better than unknown, and the tree walk may still improve on it.
  if (env.TERM_PROGRAM) return HostApplication.terminal;
  return HostApplication.unknown;
}

// Strips what Linux process names carry and executable names do not: a path, a
// version suffix on a symlinked binary, and the `:` decorations some programs
// write into their own argv[0].
function normalise(name) {
  if (!name) return '';
  const base = name.split('/').pop().toLowerCase();
  return base.split(':')[0].trim();
}

// From the process tree. `tree` maps pid -> { parentPID, name }.
function hostFromProcessTree(pid, tree, maxDepth = 12) {
  let current = tree.get(pid);
  for (let depth = 0; depth < maxDepth && current; depth += 1) {
    const name = normalise(current.name);
    if (WALK_STOPS_AT.has(name)) return HostApplication.unknown;
    const host = HOST_BY_EXECUTABLE.get(name);
    // The agent's own process is not its host, so only ancestors count — the
    // caller passes the agent pid and the first iteration looks at its parent.
    if (depth > 0 && host) return host;
    current = current.parentPID ? tree.get(current.parentPID) : null;
  }
  return HostApplication.unknown;
}

module.exports = {
  hostFromEnvironment, hostFromProcessTree, HOST_BY_EXECUTABLE, HOST_BY_VARIABLE, normalise,
};
