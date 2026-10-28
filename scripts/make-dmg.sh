#!/bin/bash
# Build a drag-to-Applications DMG from dist/DockUtils.app.
# Usage: ./scripts/make-dmg.sh   (run package-app.sh first)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0-dev)}"
APP="$OUT/DockUtils.app"
STAGE="$OUT/dmg-stage"
DMG="$OUT/dock-utils-$VERSION-macos-universal.dmg"

test -d "$APP" || { echo "ERROR: $APP not found, run scripts/package-app.sh first" >&2; exit 1; }
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DockUtils" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "Wrote $DMG"
