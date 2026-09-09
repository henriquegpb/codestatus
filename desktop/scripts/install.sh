#!/usr/bin/env bash
# CodeStatus for Linux — install from source.
#
# Most people should not need this: the normal way in is the .deb or .rpm
# published with each release, which carries its own runtime and needs nothing
# preinstalled. This script is for running from a checkout — developing on the
# app, or trying a branch.
#
# It checks the prerequisites, fetches the dependencies, runs the tests on the
# target machine, and writes the desktop entry. It does not touch your Claude
# Code settings.json — connecting the hooks stays an explicit action, from the
# app itself.
#
# Usage:
#   bash scripts/install.sh
#   bash scripts/install.sh --start-with-session

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
start_with_session=0
for arg in "$@"; do
  case "$arg" in
    --start-with-session) start_with_session=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  cyan=$'\033[36m'; green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; off=$'\033[0m'
else
  cyan=''; green=''; red=''; yellow=''; off=''
fi
step() { printf '\n%s==> %s%s\n' "$cyan" "$1" "$off"; }
ok()   { printf '    %sOK   %s%s\n' "$green" "$1" "$off"; }
fail() { printf '    %sERR  %s%s\n' "$red" "$1" "$off"; }
warn() { printf '    %sWARN %s%s\n' "$yellow" "$1" "$off"; }

echo "CodeStatus for Linux — install"
echo "folder: $root"

# --- 1. prerequisites --------------------------------------------------------
# Node is needed to fetch dependencies and to run the tests. It is not needed
# for the hook: that runs on the Electron binary npm is about to install, which
# is a Node runtime whenever ELECTRON_RUN_AS_NODE is set. See
# src/platform/linux/runtime.js.

step "Checking Node.js"
if ! command -v node >/dev/null 2>&1; then
  fail "Node.js was not found on PATH."
  echo "    Install it from your distribution's packages, or from nodejs.org."
  exit 1
fi
ok "$(node --version)"

# --- 2. what this desktop can and cannot do ----------------------------------
# Said before anything is installed rather than discovered afterwards. Neither
# of these stops the app working; both change what it can do, and a user who
# finds out from a row that quietly opens a folder concludes the app is broken.

step "Checking the desktop session"

if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  if [ -n "${DISPLAY:-}" ]; then
    warn "Wayland session with XWayland available."
    echo "    Terminals running through XWayland can be raised when you click a"
    echo "    session. Native Wayland windows cannot: Wayland has no protocol for"
    echo "    one application to raise another's window, deliberately. Those rows"
    echo "    open the project folder instead."
  else
    warn "Wayland session with no XWayland display."
    echo "    Clicking a session will open its project folder rather than raising"
    echo "    the terminal. Everything else works."
  fi
else
  ok "X11 session — clicking a session can raise its terminal."
fi

if ! command -v xdotool >/dev/null 2>&1 && ! command -v wmctrl >/dev/null 2>&1; then
  warn "Neither xdotool nor wmctrl is installed."
  echo "    Install either one to have clicking a session raise its terminal."
  echo "    Debian/Ubuntu: sudo apt install xdotool"
  echo "    Fedora:        sudo dnf install xdotool"
  echo "    Arch:          sudo pacman -S xdotool"
fi

# GNOME removed the tray from the shell in 3.26 and never brought it back. What
# replaced it is an extension, which Ubuntu ships enabled and vanilla GNOME and
# Fedora do not — so on those the icon simply does not appear, with no error.
desktop_name="${XDG_CURRENT_DESKTOP:-unknown}"
case "$desktop_name" in
  *GNOME*)
    warn "GNOME detected."
    echo "    GNOME's shell has no system tray of its own. The AppIndicator"
    echo "    extension provides one, and Ubuntu enables it by default; on"
    echo "    Fedora or vanilla GNOME install gnome-shell-extension-appindicator"
    echo "    and enable it, or the icon will not appear at all."
    ;;
  *KDE*|*XFCE*|*Cinnamon*|*MATE*|*Budgie*|*LXQt*)
    ok "$desktop_name has a system tray."
    ;;
  *)
    warn "Unrecognised desktop ($desktop_name). If no icon appears, its panel"
    echo "    probably has no StatusNotifierItem host."
    ;;
esac

# --- 3. dependencies ---------------------------------------------------------

step "Fetching dependencies"
cd "$root"
npm install --no-audit --no-fund
ok "installed"

# --- 4. tests ----------------------------------------------------------------
# Run on the target machine rather than trusted from CI. The whole point of the
# platform seam is that it is checked where it will run.

step "Running the tests"
npm test
ok "all suites passed"

# --- 5. the desktop entry ----------------------------------------------------

electron="$root/node_modules/electron/dist/electron"
if [ ! -x "$electron" ]; then
  fail "the Electron binary is not at $electron"
  exit 1
fi

applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
entry="$applications/codestatus.desktop"

step "Writing the desktop entry"
mkdir -p "$applications"
cat > "$entry" <<ENTRY
[Desktop Entry]
Type=Application
Name=CodeStatus
Comment=Session monitor for Claude Code (from source)
Exec="$electron" "$root"
Icon=$root/build/icons/256x256.png
Terminal=false
Categories=Development;Utility;
StartupWMClass=CodeStatus
ENTRY
ok "$entry"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications" >/dev/null 2>&1 || true
fi

if [ "$start_with_session" = "1" ]; then
  autostart="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
  mkdir -p "$autostart"
  cp "$entry" "$autostart/codestatus.desktop"
  ok "$autostart/codestatus.desktop"
fi

# --- done --------------------------------------------------------------------

step "Done"
echo "    Start it from your application menu, or run:"
echo "      $electron $root"
echo
echo "    Then choose Connect Claude Code from the tray menu, and start a new"
echo "    session. Sessions already open will never appear: Claude Code reads"
echo "    its hook configuration once, at session start."
