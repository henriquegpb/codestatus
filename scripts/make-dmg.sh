#!/bin/bash
#
# Packages dist/CodeStatus.app into a distributable .dmg.
#
# Usage: scripts/make-dmg.sh [version]
#
# Uses only hdiutil, so there is no dependency on create-dmg or any other
# third-party tool. Run scripts/build-app.sh first.

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

echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
