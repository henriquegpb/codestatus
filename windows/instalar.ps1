# Instalador do CodeStatus para Windows.
#
# Prepara a pasta num computador novo: confere os pre-requisitos, baixa as
# dependencias e cria os atalhos. Nao toca no settings.json do Claude Code -
# conectar os hooks continua sendo uma acao explicita sua, pelo menu da bandeja.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File instalar.ps1
#   powershell -ExecutionPolicy Bypass -File instalar.ps1 -ComIniciarAutomatico

param(
    [switch]$ComIniciarAutomatico
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path

function Passo($texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }
function Ok($texto)    { Write-Host "    OK  $texto" -ForegroundColor Green }
function Erro($texto)  { Write-Host "    ERRO $texto" -ForegroundColor Red }

Write-Host "CodeStatus - instalacao" -ForegroundColor White
Write-Host "pasta: $raiz"

# --- 1. pre-requisitos -------------------------------------------------------
# O Node e exigencia dura, e nao so para instalar: cada disparo de hook e um
# `node hook.js`. Sem ele o app sobe e fica eternamente vazio.

Passo "Conferindo o Node.js"
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Erro "Node.js nao encontrado no PATH."
    Write-Host "    Instale a versao LTS em https://nodejs.org e rode este script de novo."
    Write-Host "    Ele e necessario tanto para montar o app quanto para os hooks funcionarem."
    exit 1
}
$versao = (& node --version).Trim()
Ok "$versao em $($node.Source)"

$maior = [int]($versao -replace '^v(\d+)\..*$', '$1')
if ($maior -lt 18) {
    Erro "Node $versao e antigo demais; o app precisa de 18 ou mais novo."
    exit 1
}

Passo "Conferindo o Claude Code"
$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($claude) {
    Ok "encontrado em $($claude.Source)"
} else {
    Write-Host "    AVISO: o Claude Code nao esta no PATH." -ForegroundColor Yellow
    Write-Host "    A instalacao continua, mas nao havera nada para monitorar ate instala-lo."
}

# --- 2. dependencias ---------------------------------------------------------
# node_modules nao viaja entre maquinas: o binario do Electron e especifico de
# plataforma e arquitetura, e sao ~370 MB. Sempre reinstale no destino.

Passo "Baixando dependencias (Electron, ~370 MB na primeira vez)"
Push-Location $raiz
try {
    # ELECTRON_RUN_AS_NODE vaza para ca quando o script roda de dentro do Claude
    # Code, que e ele proprio um app Electron. Se ficar setada, o electron.exe
    # roda como Node puro e o app morre na inicializacao.
    $env:ELECTRON_RUN_AS_NODE = $null
    & npm install --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm install terminou com codigo $LASTEXITCODE" }
} finally {
    Pop-Location
}

$exe = Join-Path $raiz 'node_modules\electron\dist\electron.exe'

# O `npm install` instala o *pacote* electron, mas quem baixa e extrai o binario
# de verdade e o postinstall dele. Esse passo falha com frequencia - visto aqui
# tanto travando sem mensagem quanto morrendo com 0xC0000409 - e o npm segue
# adiante como se tivesse dado certo. Entao conferimos e, se faltar, disparamos a
# extracao na mao: o zip normalmente ja esta no cache e isso leva segundos.
if (-not (Test-Path $exe)) {
    Write-Host "    o postinstall nao trouxe o binario; extraindo na mao" -ForegroundColor Yellow
    Push-Location $raiz
    try {
        & node 'node_modules\electron\install.js'
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $exe)) {
    Erro "O binario do Electron nao chegou."
    Write-Host "    Tente na mao, nesta pasta, para ver o erro completo:"
    Write-Host "        npm install"
    Write-Host "        node node_modules\electron\install.js"
    exit 1
}
Ok "dependencias prontas"

# --- 3. verificacao ----------------------------------------------------------

Passo "Rodando os testes"
Push-Location $raiz
try {
    & node test\reducer.test.js | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "os testes do reducer falharam" }
    & node test\installer.test.js | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "os testes do instalador falharam" }
} finally {
    Pop-Location
}
Ok "logica verificada nesta maquina"

# --- 4. atalhos --------------------------------------------------------------

Passo "Criando atalhos"
$vbs = Join-Path $raiz 'CodeStatus.vbs'
$shell = New-Object -ComObject WScript.Shell

function CriarAtalho($destino, $nome) {
    $lnk = $shell.CreateShortcut((Join-Path $destino "$nome.lnk"))
    $lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $lnk.Arguments = """$vbs"""
    $lnk.WorkingDirectory = $raiz
    $lnk.Description = 'Monitor de sessoes do Claude Code'
    $lnk.Save()
}

$menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
CriarAtalho $menu 'CodeStatus'
Ok "menu iniciar"

CriarAtalho ([Environment]::GetFolderPath('Desktop')) 'CodeStatus'
Ok "area de trabalho"

if ($ComIniciarAutomatico) {
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    CriarAtalho $startup 'CodeStatus'
    Ok "inicializacao automatica"
}

# --- 5. fim ------------------------------------------------------------------

Write-Host "`nInstalado." -ForegroundColor Green
Write-Host @"

Faltam dois passos, e os dois sao seus de proposito:

  1. Abra o CodeStatus (menu iniciar ou area de trabalho). Ele sobe direto para
     a bandeja - procure o icone cinza perto do relogio. Se nao aparecer, clique
     na setinha ^ : o Windows esconde icones novos por padrao.

  2. Clique com o botao direito no icone e escolha "Conectar Claude Code". Isso
     grava os hooks no seu ~/.claude/settings.json, com backup automatico.

Depois abra uma sessao NOVA do Claude Code: ele le a configuracao de hooks uma
vez so, no inicio da sessao, entao as janelas ja abertas nao serao vistas.
"@
