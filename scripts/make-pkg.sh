#!/bin/bash
# Build an installer .pkg that puts DockUtils.app into /Applications.
# Installer itself is unsigned (no paid Developer ID); see README for first launch.
# Usage: [VERSION=0.1.0] ./scripts/make-pkg.sh   (run package-app.sh first)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0-dev)}"
OUT="${OUT:-$ROOT/dist}"
APP="$OUT/DockUtils.app"
PKG="$OUT/dock-utils-$VERSION-macos-universal.pkg"

test -d "$APP" || { echo "ERROR: $APP not found, run scripts/package-app.sh first" >&2; exit 1; }
rm -f "$PKG"
# Stage as root-relative payload (needs --root for --component-plist).
STAGE="$OUT/pkg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications"
cp -R "$APP" "$STAGE/Applications/"
pkgbuild \
  --identifier com.kovacsgellert.dock-utils \
  --version "$VERSION" \
  --install-location / \
  --component-plist "$ROOT/packaging/component.plist" \
  --root "$STAGE" \
  "$PKG"
rm -rf "$STAGE"
echo "Wrote $PKG"
