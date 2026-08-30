# Packages CodeStatus for Windows to carry to another computer.
#
# Source only (~200 KB). node_modules is left out deliberately: it is roughly
# 370 MB, and the Electron binary is specific to platform and architecture, so
# copying it saves nothing and can break on the target.
#
# Only needed for a machine without git — otherwise clone the repository and run
# scripts\install.ps1 in the windows folder.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\package.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\package.ps1 -Destination D:\usb

param(
    [string]$Destination = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$zip = Join-Path $Destination 'CodeStatus-windows.zip'

$include = @(
    'src', 'hook', 'test', 'scripts',
    'package.json', 'README.md', '.gitignore', 'CodeStatus.vbs'
)

$temp = Join-Path ([System.IO.Path]::GetTempPath()) "codestatus-pack-$(Get-Random)"
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    foreach ($item in $include) {
        $source = Join-Path $root $item
        if (-not (Test-Path $source)) { continue }
        Copy-Item $source -Destination $temp -Recurse -Force
    }

    # The visual-check images are generated on demand; there is no reason to
    # carry them along.
    $icons = Join-Path $temp 'test\icons'
    if (Test-Path $icons) { Remove-Item $icons -Recurse -Force }

    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zip

    $kb = [math]::Round((Get-Item $zip).Length / 1KB, 1)
    Write-Host "Packaged: $zip ($kb KB)" -ForegroundColor Green
    Write-Host @"

On the other computer:

  1. Unzip it wherever you like (e.g. C:\Users\<you>\CodeStatus)
  2. Open PowerShell in that folder and run:

       powershell -ExecutionPolicy Bypass -File scripts\install.ps1

     Add -StartWithWindows if you want it to come up with Windows.

Prerequisite on the target: Node.js 18+ (https://nodejs.org). The installer
checks and stops with a clear message if it is missing.
"@
} finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
