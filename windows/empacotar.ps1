# Empacota o CodeStatus para levar a outro computador.
#
# Leva so a fonte (~160 KB). O node_modules fica de fora de proposito: sao
# ~370 MB e o binario do Electron e especifico de plataforma e arquitetura, entao
# copia-lo nao economiza nada e pode quebrar no destino.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File empacotar.ps1
#   powershell -ExecutionPolicy Bypass -File empacotar.ps1 -Destino D:\pendrive

param(
    [string]$Destino = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$zip = Join-Path $Destino 'CodeStatus.zip'

$incluir = @(
    'src', 'hook', 'test',
    'package.json',
    'CodeStatus.vbs', 'iniciar.cmd',
    'instalar.ps1', 'empacotar.ps1',
    'README.md', '.gitignore'
)

$temp = Join-Path ([System.IO.Path]::GetTempPath()) "codestatus-pack-$(Get-Random)"
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    foreach ($item in $incluir) {
        $origem = Join-Path $raiz $item
        if (-not (Test-Path $origem)) { continue }
        Copy-Item $origem -Destination $temp -Recurse -Force
    }

    # As imagens de conferencia visual sao geradas sob demanda; nao ha porque
    # carrega-las junto.
    $icones = Join-Path $temp 'test\icons'
    if (Test-Path $icones) { Remove-Item $icones -Recurse -Force }

    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zip

    $mb = [math]::Round((Get-Item $zip).Length / 1KB, 1)
    Write-Host "Empacotado: $zip ($mb KB)" -ForegroundColor Green
    Write-Host @"

No outro computador:

  1. Descompacte o zip onde quiser (ex.: C:\Users\<voce>\CodeStatus)
  2. Abra o PowerShell nessa pasta e rode:

       powershell -ExecutionPolicy Bypass -File instalar.ps1

     Acrescente -ComIniciarAutomatico se quiser que ele suba com o Windows.

Pre-requisito no destino: Node.js 18+ (https://nodejs.org). O instalador confere
e para com uma mensagem clara se faltar.
"@
} finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
