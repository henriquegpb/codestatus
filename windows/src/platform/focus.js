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

// Windows refuses SetForegroundWindow from a process that does not own the
// foreground, to stop background apps stealing focus. The documented way for an
// app the user just clicked to opt out is to make the input queues agree first;
// a synthetic ALT keypress is the long-standing way to do that, and without it
// the call silently degrades to flashing the taskbar button.
const SCRIPT = `
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -Namespace CS -Name Win -MemberDefinition @'
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
'@
$target = [int]$env:CODESTATUS_TARGET_PID
for ($i = 0; $i -lt 12 -and $target; $i++) {
  $proc = Get-Process -Id $target
  if ($proc -and $proc.MainWindowHandle -ne 0) {
    $h = $proc.MainWindowHandle
    # 0x12 = VK_MENU (ALT), 0x0002 = KEYEVENTF_KEYUP
    [CS.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [CS.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    # 9 = SW_RESTORE, 5 = SW_SHOW. Restoring a window that is not minimised
    # can resize it, so only unminimise what is actually minimised.
    if ([CS.Win]::IsIconic($h)) { [CS.Win]::ShowWindow($h, 9) } else { [CS.Win]::ShowWindow($h, 5) }
    [CS.Win]::SetForegroundWindow($h) | Out-Null
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
