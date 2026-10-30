#!/bin/bash
# Build and (re)launch "DockUtils Dev.app" for local testing: its own name
# and bundle id, so it sits apart from an installed DockUtils, and signed
# with a local self-signed certificate that stays the same across builds,
# so its Accessibility grant does too (an ad-hoc signature changes with
# every build). Creates that certificate on first run.
# Usage: ./scripts/dev-app.sh   (DEV_CERT_DIR to keep the certificate elsewhere)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${DEV_CERT_DIR:-$HOME/.codesign-dev}"
NAME="DockUtils Dev"
BUNDLE_ID="com.kovacsgellert.dock-utils.dev"

if [ ! -e "$CERT_DIR/signing.p12" ]; then
  # Local only: not the release certificate, never uploaded anywhere.
  CN="DockUtils Dev Code Signing" "$ROOT/scripts/make-signing-cert.sh" "$CERT_DIR" >/dev/null
  echo "Created dev signing certificate in $CERT_DIR"
fi

# Matched by executable path from the start: a looser pattern also
# matches any shell whose command line mentions the app.
# Two copies would both draw badges and clones and both take Option+number.
if pgrep -qf "^/Applications/DockUtils.app/Contents/MacOS/"; then
  echo "Note: the installed DockUtils is running too; quit it while testing." >&2
fi

NAME="$NAME" BUNDLE_ID="$BUNDLE_ID" ARCHS="$(uname -m)" \
  VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)-dev" \
  SIGNING_P12="$CERT_DIR/signing.p12" SIGNING_P12_PASSWORD="$(cat "$CERT_DIR/signing.p12.password")" \
  "$ROOT/scripts/package-app.sh"

RUNNING="^$ROOT/dist/$NAME.app/Contents/MacOS/"
if pgrep -qf "$RUNNING"; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  while pgrep -qf "$RUNNING"; do sleep 0.2; done
fi
open "$ROOT/dist/$NAME.app"
echo "Launched $ROOT/dist/$NAME.app"
