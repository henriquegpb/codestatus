#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
electron=${CODESTATUS_ELECTRON:-"$root/node_modules/electron/dist/electron"}
app=${CODESTATUS_APP:-"$root"}

if [ "$(uname -s)" != Linux ]; then
  echo "tray protocol: SKIP (needs Linux)"
  exit 0
fi

if [ ! -x "$electron" ]; then
  echo "Electron is not installed at $electron" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CODESTATUS_TRAY_MARKER="$tmp/registration"
export CODESTATUS_TRAY_READY="$tmp/watcher-ready"
export CODESTATUS_TRAY_LOG="$tmp/app.log"
export CODESTATUS_TRAY_USER_DATA="$tmp/user-data"
export CODESTATUS_TRAY_ELECTRON="$electron"
export CODESTATUS_TRAY_APP="$app"
export CODESTATUS_TRAY_HELPERS="$root/test/helpers"

if ! dbus-run-session -- bash -euo pipefail -c '
  python3 "$CODESTATUS_TRAY_HELPERS/status-notifier-watcher.py" &
  watcher=$!
  app=""
  cleanup() {
    if [ -n "$app" ]; then kill "$app" 2>/dev/null || true; fi
    kill "$watcher" 2>/dev/null || true
    wait "$app" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  }
  trap cleanup EXIT

  for _ in $(seq 1 50); do
    [ -f "$CODESTATUS_TRAY_READY" ] && break
    sleep 0.1
  done
  [ -f "$CODESTATUS_TRAY_READY" ] || { echo "watcher did not start" >&2; exit 1; }

  "$CODESTATUS_TRAY_ELECTRON" "$CODESTATUS_TRAY_APP" \
    --no-sandbox --user-data-dir="$CODESTATUS_TRAY_USER_DATA" \
    >"$CODESTATUS_TRAY_LOG" 2>&1 &
  app=$!

  for _ in $(seq 1 100); do
    [ -f "$CODESTATUS_TRAY_MARKER" ] && break
    kill -0 "$app" 2>/dev/null || break
    sleep 0.1
  done
  [ -f "$CODESTATUS_TRAY_MARKER" ] || {
    echo "the app did not register a tray item" >&2
    cat "$CODESTATUS_TRAY_LOG" >&2
    exit 1
  }
' >"$tmp/session.log" 2>&1; then
  cat "$tmp/session.log" >&2
  exit 1
fi

registration=$(cat "$CODESTATUS_TRAY_MARKER")
echo "tray registration: $registration"
if [[ "$registration" == */* ]]; then
  echo "tray registration combined the D-Bus service and object path" >&2
  exit 1
fi
if [[ ! "$registration" =~ ^org\.freedesktop\.StatusNotifierItem-[0-9]+-[0-9]+$ ]]; then
  echo "tray registration is not a StatusNotifierItem service name" >&2
  exit 1
fi

echo "tray protocol: ok"
