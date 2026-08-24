#!/bin/bash
#
# Builds CodeStatus.app as a universal binary, optionally signed.
#
# Usage:
#   scripts/build-app.sh                    # unsigned, for local development
#   scripts/build-app.sh --sign             # ad-hoc signed (enough for notifications)
#   scripts/build-app.sh --sign "Developer ID Application: Name (TEAMID)"
#
# On macOS 26, UNUserNotificationCenter silently refuses to deliver from an
# unsigned bundle. `--sign` with no identity does an ad-hoc signature, which is
# enough to make notifications work locally without a paid account.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
CONFIG="${CONFIG:-release}"
APP="dist/CodeStatus.app"

SIGN=false
IDENTITY="-"
if [[ "${1:-}" == "--sign" ]]; then
    SIGN=true
    [[ -n "${2:-}" ]] && IDENTITY="$2"
fi

TRIPLES=(arm64-apple-macosx14.0 x86_64-apple-macosx14.0)
STAGE="dist/universal"

# Built per-triple and lipo'd together rather than with `swift build --arch`.
#
# `--arch` routes through xcbuild, which links Foundation into every product
# whether or not it imports it -- so the hook shipped in the bundle linked
# Foundation while the arm64-only build did not, quietly costing the startup
# time the whole scanner design exists to protect. `--triple` uses SwiftPM's
# own build system, which links only what is imported.
#
# One invocation per product as well: `swift build` honours only the last
# --product it is given, so passing both silently builds just the second.
echo "==> Building ($CONFIG) for ${TRIPLES[*]}"
rm -rf "$STAGE"; mkdir -p "$STAGE"
for product in CodeStatusApp codestatus-hook; do
    slices=()
    for triple in "${TRIPLES[@]}"; do
        swift build -c "$CONFIG" --triple "$triple" --product "$product"
        slices+=("$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)/$product")
    done
    lipo -create "${slices[@]}" -output "$STAGE/$product"
done

BIN_DIR="$STAGE"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BIN_DIR/CodeStatusApp" "$APP/Contents/MacOS/CodeStatusApp"

# The hook lives inside the bundle as the canonical copy. On launch the app
# copies it to ~/Library/Application Support/CodeStatus/bin/ and refreshes that
# copy when versions differ, so moving or updating the app never requires
# rewriting any agent's configuration.
cp "$BIN_DIR/codestatus-hook" "$APP/Contents/Helpers/codestatus-hook"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    scripts/AppInfo.plist > "$APP/Contents/Info.plist"

# Resources are optional while the UI is still being built.
[[ -d Resources ]] && cp -R Resources/. "$APP/Contents/Resources/"

if $SIGN; then
    if [[ "$IDENTITY" == "-" ]]; then
        echo "==> Signing ad-hoc (local development)"
        # No hardened runtime ad-hoc: it would demand a real identity for the
        # Apple Events entitlement to be honoured anyway.
        codesign --force --sign - "$APP/Contents/Helpers/codestatus-hook"
        codesign --force --sign - --entitlements scripts/CodeStatus.entitlements "$APP"
    else
        echo "==> Signing with: $IDENTITY"
        # Inside-out: nested code must be signed before the bundle that holds it.
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$APP/Contents/Helpers/codestatus-hook"
        codesign --force --options runtime --timestamp \
            --entitlements scripts/CodeStatus.entitlements \
            --sign "$IDENTITY" "$APP"
    fi
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> Built $APP"
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/CodeStatusApp")"
# Read the description once, then match against it in memory. Piping codesign
# into `grep -m1` looks equivalent and is not: grep exits at the first match,
# codesign dies of SIGPIPE, and under `pipefail` the pipeline reports 141 — so
# the `|| echo 'unsigned'` fallback fires *after* the real value was printed
# and every correctly signed build is labelled unsigned in the release log.
DESCRIPTION="$(codesign -dv "$APP" 2>&1 || true)"
SIGNATURE="$(awk '/Signature/ { print; exit }' <<<"$DESCRIPTION")"
echo "    signature:     ${SIGNATURE:-unsigned}"
