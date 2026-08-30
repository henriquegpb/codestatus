@echo off
REM Sobe o CodeStatus com o console visivel. Use este quando quiser ver erros;
REM para o uso normal prefira CodeStatus.vbs, que nao abre janela nenhuma.

cd /d "%~dp0"

REM O Claude Code e ele proprio um app Electron e exporta esta variavel para os
REM processos que cria. Se ela vazar para ca, o electron.exe roda como Node puro
REM e o app morre com "Cannot read properties of undefined (reading 'app')".
set ELECTRON_RUN_AS_NODE=

"%~dp0node_modules\electron\dist\electron.exe" "%~dp0."
