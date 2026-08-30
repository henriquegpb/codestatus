'use strict';

// Bringing the user back to the session they clicked.
//
// On macOS the app runs AppleScript that selects the exact terminal tab. Windows
// exposes no such thing — not even Windows Terminal surfaces individual tabs to
// other processes — so the honest best is to raise the *window* hosting the
// agent's process, walking up the process tree until one has a window.
//
// If nothing has a window, the caller falls back to opening the project folder,
// which at least lands the user in the right place.

const { execFile } = require('child_process');

const SCRIPT = `
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -Namespace CS -Name Win -MemberDefinition '
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
$target = [int]$env:CODESTATUS_TARGET_PID
for ($i = 0; $i -lt 12 -and $target; $i++) {
  $proc = Get-Process -Id $target
  if ($proc -and $proc.MainWindowHandle -ne 0) {
    [CS.Win]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null
    [CS.Win]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    exit 0
  }
  $target = (Get-CimInstance Win32_Process -Filter "ProcessId=$target").ParentProcessId
}
exit 1`;

// Raises the window hosting `pid`. Calls back with true when one was found.
function focusProcessWindow(pid, callback = () => {}) {
  if (!pid) {
    callback(false);
    return;
  }
  execFile(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', SCRIPT],
    // The pid travels in the environment rather than interpolated into the
    // script: nothing the daemon holds should ever be pasted into a shell.
    { env: { ...process.env, CODESTATUS_TARGET_PID: String(pid) }, timeout: 8000 },
    (err) => callback(!err),
  );
}

module.exports = { focusProcessWindow };
