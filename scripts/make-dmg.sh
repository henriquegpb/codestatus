#!/bin/bash
#
# Packages dist/CodeStatus.app into a distributable .dmg.
#
# Usage: scripts/make-dmg.sh [version]
#        SIGNING_IDENTITY="Developer ID Application: …" scripts/make-dmg.sh 1.2.3
#
# Uses only hdiutil, so there is no dependency on create-dmg or any other
# third-party tool. Run scripts/build-app.sh first.
#
# Signing the image matters as much as signing the app inside it: a ticket can
# only be stapled to a signed artifact, so an unsigned .dmg fails `stapler
# staple` with error 65 and reaches users as "no usable signature" no matter
# how well signed the app within it is.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-0.1.0}}"
APP="dist/CodeStatus.app"
DMG="dist/CodeStatus-$VERSION.dmg"
STAGING="dist/dmg-staging"

[[ -d "$APP" ]] || { echo "error: $APP not found; run scripts/build-app.sh first" >&2; exit 1; }

echo "==> Staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
# The drag-to-install convention users expect.
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
hdiutil create \
    -volname "CodeStatus" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG"

rm -rf "$STAGING"

# `--timestamp` is not optional here. Notarisation rejects a signature without
# a secure timestamp, and the local failure it produces is opaque.
# Trimmed for the same reason build-app.sh trims it: a secret pasted into a web
# form carries a trailing newline, and codesign takes the name literally —
# reporting `<name>: no identity found` for a certificate that is right there.
IDENTITY="$(printf '%s' "${SIGNING_IDENTITY:-}" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [[ -n "$IDENTITY" ]]; then
    security find-identity -v -p codesigning | grep -qF "$IDENTITY" || {
        echo "error: no codesigning identity matching:" >&2
        echo "       [$IDENTITY]" >&2
        echo "       The keychain holds:" >&2
        security find-identity -v -p codesigning >&2
        exit 1
    }
    echo "==> Signing $DMG"
    codesign --sign "$IDENTITY" --timestamp "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
else
    echo "==> Not signing: SIGNING_IDENTITY is unset"
    echo "    The image cannot be notarised or stapled until it is signed."
fi

DESCRIPTION="$(codesign -dv "$DMG" 2>&1 || true)"
SIGNATURE="$(awk '/Signature/ { print; exit }' <<<"$DESCRIPTION")"
echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
echo "    signature:     ${SIGNATURE:-unsigned}"
