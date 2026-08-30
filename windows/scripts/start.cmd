@echo off
REM Starts CodeStatus with the console visible. Use this when you want to see
REM errors; for normal use, launch it from the Start Menu shortcut, which points
REM straight at electron.exe and opens no window at all.

cd /d "%~dp0.."

REM Claude Code is itself an Electron app and exports this variable to the
REM processes it creates. If it leaks in here, electron.exe runs as plain Node
REM and the app dies before it draws anything. main.js detects the state and
REM says so, but clearing it is the actual fix.
set ELECTRON_RUN_AS_NODE=

"%CD%\node_modules\electron\dist\electron.exe" "%CD%"
