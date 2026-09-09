# CodeStatus for Windows — install from source.
#
# Most people should not need this: scripts\package.ps1 aside, the normal way in
# is the installer published with each release, which carries its own runtime
# and needs nothing preinstalled. This script is for running from a checkout —
# developing on the app, or trying a branch.
#
# It checks the prerequisites, fetches the dependencies, runs the tests on the
# target machine, and creates the shortcuts. It does not touch your Claude Code
# settings.json — connecting the hooks stays an explicit action, from the app.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -StartWithWindows

param(
    [switch]$StartWithWindows
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "    OK   $text" -ForegroundColor Green }
function Fail($text) { Write-Host "    ERR  $text" -ForegroundColor Red }
function Warn($text) { Write-Host "    WARN $text" -ForegroundColor Yellow }

Write-Host "CodeStatus for Windows — install" -ForegroundColor White
Write-Host "folder: $root"

# --- 1. prerequisites --------------------------------------------------------
# Node is needed to fetch dependencies and to run the tests. It is no longer
# needed for the hook: that runs on the Electron binary npm is about to install,
# which is a Node runtime whenever ELECTRON_RUN_AS_NODE is set. See
# src/platform/runtime.js.

Step "Checking Node.js"
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Fail "Node.js was not found on PATH."
    Write-Host "    Install the LTS build from https://nodejs.org and run this again."
    Write-Host "    It is needed to fetch dependencies and run the tests."
    Write-Host "    To avoid this entirely, use the installer from the releases page."
    exit 1
}
$version = (& node --version).Trim()
Ok "$version at $($node.Source)"

$major = [int]($version -replace '^v(\d+)\..*$', '$1')
if ($major -lt 18) {
    Fail "Node $version is too old; the app needs 18 or newer."
    exit 1
}

Step "Checking Claude Code"
$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($claude) {
    Ok "found at $($claude.Source)"
} else {
    Warn "Claude Code is not on PATH."
    Write-Host "    The install continues, but there will be nothing to watch until you add it."
}

# --- 2. dependencies ---------------------------------------------------------
# node_modules does not travel between machines: the Electron binary is specific
# to platform and architecture, and it is roughly 370 MB. Always reinstall here.

Step "Fetching dependencies (Electron, ~370 MB the first time)"
Push-Location $root
try {
    # ELECTRON_RUN_AS_NODE leaks in when this script is run from inside Claude
    # Code, which is itself an Electron app. Left set, electron.exe runs as plain
    # Node and the app dies on startup.
    $env:ELECTRON_RUN_AS_NODE = $null
    & npm install --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm install exited with code $LASTEXITCODE" }
} finally {
    Pop-Location
}

$exe = Join-Path $root 'node_modules\electron\dist\electron.exe'

# `npm install` installs the electron *package*, but what downloads and extracts
# the actual binary is its postinstall script. That step fails often — seen both
# hanging with no message and dying with 0xC0000409 — and npm carries on as if
# it had succeeded. So we check, and if the binary is missing we run the
# extraction by hand: the zip is usually already cached and it takes seconds.
if (-not (Test-Path $exe)) {
    Warn "the postinstall did not deliver the binary; extracting by hand"
    Push-Location $root
    try {
        & node 'node_modules\electron\install.js'
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $exe)) {
    Fail "The Electron binary never arrived."
    Write-Host "    Try it by hand in this folder to see the full error:"
    Write-Host "        npm install"
    Write-Host "        node node_modules\electron\install.js"
    exit 1
}
Ok "dependencies ready"

# --- 3. verification ---------------------------------------------------------

Step "Running the tests"
Push-Location $root
try {
    & node test\reducer.test.js | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "the reducer tests failed" }
    & node test\installer.test.js | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "the installer tests failed" }
    & node test\platform.test.js | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "the platform tests failed" }
} finally {
    Pop-Location
}
Ok "logic verified on this machine"

# --- 4. shortcuts ------------------------------------------------------------

Step "Creating shortcuts"

$appUserModelId = 'com.codestatus.windows'

# Windows addresses a toast notification to an *application identity*, not to a
# process, and it learns that identity from a Start Menu shortcut. Without the
# AppUserModelID set on the shortcut, notifications are either attributed to
# "Electron" or silently dropped. Setting it means a short trip through
# IPropertyStore, because WScript.Shell cannot write shell properties.
#
# Wrapped in try/catch on purpose: if the interop fails, the app still works and
# only the notification attribution suffers, which is not worth aborting for.
$propertyStoreType = @'
using System;
using System.Runtime.InteropServices;

public static class ShortcutIdentity {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink { }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [ComImport, Guid("0000010B-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName,
                  [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid f, uint p) { fmtid = f; pid = p; }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant pvar);

    // PKEY_AppUserModel_ID
    private static readonly Guid AppUserModel =
        new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    public static void Apply(string shortcutPath, string appId) {
        var link = (IPersistFile)new ShellLink();
        link.Load(shortcutPath, 2 /* STGM_READWRITE */);

        var store = (IPropertyStore)link;
        var key = new PropertyKey(AppUserModel, 5);
        var value = new PropVariant {
            vt = 31 /* VT_LPWSTR */,
            pointerValue = Marshal.StringToCoTaskMemUni(appId)
        };
        store.SetValue(ref key, ref value);
        store.Commit();
        PropVariantClear(ref value);

        link.Save(shortcutPath, true);
    }
}
'@

$canSetIdentity = $true
try {
    Add-Type -TypeDefinition $propertyStoreType -Language CSharp -ErrorAction Stop
} catch {
    $canSetIdentity = $false
    Warn "could not prepare the shortcut identity helper; notifications may be unattributed"
}

$shell = New-Object -ComObject WScript.Shell

function New-CodeStatusShortcut($destination, $name) {
    $linkPath = Join-Path $destination "$name.lnk"
    $link = $shell.CreateShortcut($linkPath)
    # Pointed straight at electron.exe rather than through a .vbs wrapper.
    # electron.exe is a GUI-subsystem binary, so launching it from a shortcut
    # opens no console window — and Windows can only attach a notification
    # identity to a shortcut whose target is the executable itself.
    $link.TargetPath = $exe
    $link.Arguments = """$root"""
    $link.WorkingDirectory = $root
    $link.Description = 'Session monitor for Claude Code'
    $link.Save()

    if ($canSetIdentity) {
        try {
            [ShortcutIdentity]::Apply($linkPath, $appUserModelId)
        } catch {
            Warn "could not stamp the notification identity onto $name"
        }
    }
    return $linkPath
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-CodeStatusShortcut $startMenu 'CodeStatus' | Out-Null
Ok "start menu"

New-CodeStatusShortcut ([Environment]::GetFolderPath('Desktop')) 'CodeStatus' | Out-Null
Ok "desktop"

if ($StartWithWindows) {
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    New-CodeStatusShortcut $startup 'CodeStatus' | Out-Null
    Ok "start with Windows"
}

# --- 5. done -----------------------------------------------------------------

Write-Host "`nInstalled." -ForegroundColor Green
Write-Host @"

Two steps left, and both are yours on purpose:

  1. Open CodeStatus (start menu or desktop). It goes straight to the tray —
     look for the grey circle near the clock. If you cannot see it, click the ^
     arrow: Windows hides new tray icons by default. Drag it out once and it
     stays visible for good.

  2. Open it and choose "Connect Claude Code". That writes the hooks into your
     ~/.claude/settings.json, with an automatic backup.

Then start a NEW Claude Code session: it reads its hook configuration once, at
session start, so windows that are already open will not be seen.
"@
