#!/usr/bin/env bash
# Starts CodeStatus with the console attached. Use this when you want to see
# errors; for normal use, launch it from the application menu.

set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Claude Code is itself an Electron app and exports this variable to the
# processes it creates. If it leaks in here, the Electron binary runs as plain
# Node and the app dies before it draws anything. main.js detects the state and
# says so, but clearing it is the actual fix.
unset ELECTRON_RUN_AS_NODE

exec "$root/node_modules/electron/dist/electron" "$root" "$@"
