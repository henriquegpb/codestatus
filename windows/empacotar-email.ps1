# Empacota o CodeStatus num zip que sobrevive ao filtro de anexos do Gmail.
#
# O Gmail recusa .js, .ps1, .vbs e .cmd - inclusive dentro de arquivos zip - e o
# pacote inteiro e feito desses quatro tipos. Um zip normal simplesmente nao sai.
#
# A saida daqui e o mesmo pacote com um `.txt` acrescentado a cada arquivo
# bloqueado. O destinatario roda uma linha de PowerShell para desfazer, e a
# pasta volta a ser exatamente a original.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File empacotar-email.ps1 -Destino C:\saida

param(
    [string]$Destino = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$zip = Join-Path $Destino 'CodeStatus-para-email.zip'

$incluir = @(
    'src', 'hook', 'test',
    'package.json',
    'CodeStatus.vbs', 'iniciar.cmd',
    'instalar.ps1', 'empacotar.ps1', 'empacotar-email.ps1',
    'README.md', '.gitignore'
)

$bloqueadas = '\.(js|ps1|vbs|cmd)$'

$temp = Join-Path ([System.IO.Path]::GetTempPath()) "codestatus-email-$(Get-Random)"
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    foreach ($item in $incluir) {
        $origem = Join-Path $raiz $item
        if (-not (Test-Path $origem)) { continue }
        Copy-Item $origem -Destination $temp -Recurse -Force
    }

    $icones = Join-Path $temp 'test\icons'
    if (Test-Path $icones) { Remove-Item $icones -Recurse -Force }

    $renomeados = 0
    Get-ChildItem $temp -Recurse -File | Where-Object { $_.Name -match $bloqueadas } | ForEach-Object {
        Rename-Item $_.FullName -NewName ($_.Name + '.txt')
        $renomeados++
    }

    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zip

    $kb = [math]::Round((Get-Item $zip).Length / 1KB, 1)
    Write-Host "Pacote de email: $zip ($kb KB)" -ForegroundColor Green
    Write-Host "$renomeados arquivos receberam .txt para passar pelo filtro do Gmail."
} finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
