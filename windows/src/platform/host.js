'use strict';

// Which terminal an agent session is running in.
//
// macOS gets this for free: TERM_PROGRAM is set by every terminal worth naming,
// and the hook reads one variable. Windows has no such convention, so this is
// answered twice, from strongest evidence to weakest:
//
//  1. The hook reads the few environment variables that Windows terminals do
//     export. Cheap, but only VS Code and Windows Terminal set anything.
//  2. The daemon walks up the process tree from the agent's pid looking for a
//     known host executable. Reliable for everything, and free — the process
//     scan already has the whole tree in hand.
//
// What is deliberately absent: guessing PowerShell from PSModulePath. That
// variable is machine-wide on Windows 10 and later, so it is present in cmd, in
// VS Code, and in services, and treating it as evidence labelled essentially
// every session PowerShell.

const { HostApplication } = require('../core/events');

// Executable names, lower-cased, mapped to what we call them.
const HOST_BY_EXECUTABLE = new Map([
  ['windowsterminal.exe', HostApplication.windowsTerminal],
  ['wt.exe', HostApplication.windowsTerminal],
  ['code.exe', HostApplication.vsCode],
  ['code - insiders.exe', HostApplication.vsCode],
  ['codium.exe', HostApplication.vsCode],
  ['cursor.exe', HostApplication.vsCode],
  ['powershell.exe', HostApplication.powershell],
  ['pwsh.exe', HostApplication.powershell],
  ['cmd.exe', HostApplication.conhost],
  ['conhost.exe', HostApplication.conhost],
]);

// Where the walk gives up: reaching the shell means no terminal was in the
// chain, and continuing would eventually reach the session manager.
const WALK_STOPS_AT = new Set(['explorer.exe', 'services.exe', 'wininit.exe', 'winlogon.exe']);

// From the hook's own environment. Runs inside the hook process, so it must not
// require anything: see hook/hook.js, which carries its own copy.
function hostFromEnvironment(env = process.env) {
  if (env.TERM_PROGRAM === 'vscode' || env.VSCODE_INJECTION || env.VSCODE_GIT_IPC_HANDLE) {
    return HostApplication.vsCode;
  }
  if (env.WT_SESSION) return HostApplication.windowsTerminal;
  return HostApplication.unknown;
}

// From the process tree. `tree` maps pid -> { parentPID, name }.
function hostFromProcessTree(pid, tree, maxDepth = 12) {
  let current = tree.get(pid);
  for (let depth = 0; depth < maxDepth && current; depth += 1) {
    const name = (current.name || '').toLowerCase();
    if (WALK_STOPS_AT.has(name)) return HostApplication.unknown;
    const host = HOST_BY_EXECUTABLE.get(name);
    // The agent's own process is not its host, so only ancestors count — the
    // caller passes the agent pid and the first iteration looks at its parent.
    if (depth > 0 && host) return host;
    current = current.parentPID ? tree.get(current.parentPID) : null;
  }
  return HostApplication.unknown;
}

module.exports = { hostFromEnvironment, hostFromProcessTree, HOST_BY_EXECUTABLE };
