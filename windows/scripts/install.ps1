# CodeStatus for Windows — installer.
#
# Prepares the folder on a new machine: checks the prerequisites, fetches the
# dependencies, runs the tests on the target machine, and creates the shortcuts.
# It does not touch your Claude Code settings.json — connecting the hooks stays
# an explicit action, from the app.
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
# Node is a hard requirement, and not only to build: every hook firing is a
# `node hook.js`. Without it the app starts and stays permanently empty.

Step "Checking Node.js"
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Fail "Node.js was not found on PATH."
    Write-Host "    Install the LTS build from https://nodejs.org and run this again."
    Write-Host "    It is needed both to assemble the app and for the hooks to run at all."
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
} finally {
    Pop-Location
}
Ok "logic verified on this machine"

# --- 4. shortcuts ------------------------------------------------------------

Step "Creating shortcuts"

$shell = New-Object -ComObject WScript.Shell
$vbs = Join-Path $root 'CodeStatus.vbs'

function New-CodeStatusShortcut($destination, $name) {
    $link = $shell.CreateShortcut((Join-Path $destination "$name.lnk"))
    $link.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $link.Arguments = """$vbs"""
    $link.WorkingDirectory = $root
    $link.Description = 'Session monitor for Claude Code'
    $link.Save()
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-CodeStatusShortcut $startMenu 'CodeStatus'
Ok "start menu"

New-CodeStatusShortcut ([Environment]::GetFolderPath('Desktop')) 'CodeStatus'
Ok "desktop"

if ($StartWithWindows) {
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    New-CodeStatusShortcut $startup 'CodeStatus'
    Ok "start with Windows"
}

# --- 5. done -----------------------------------------------------------------

Write-Host "`nInstalled." -ForegroundColor Green
Write-Host @"

Two steps left, and both are yours on purpose:

  1. Open CodeStatus (start menu or desktop). It goes straight to the tray —
     look for the grey circle near the clock. If you cannot see it, click the ^
     arrow: Windows hides new tray icons by default.

  2. Open it and choose "Connect Claude Code". That writes the hooks into your
     ~/.claude/settings.json, with an automatic backup.

Then start a NEW Claude Code session: it reads its hook configuration once, at
session start, so windows that are already open will not be seen.
"@
