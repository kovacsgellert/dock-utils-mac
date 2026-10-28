#!/bin/bash
# Assemble DockUtils.app from SwiftPM release builds: a universal binary
# (Apple Silicon + Intel).
# Usage: VERSION=0.1.0 OUT=dist ./scripts/package-app.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0-dev)}"
OUT="${OUT:-$ROOT/dist}"
APP="$OUT/DockUtils.app"
# CFBundleVersion must be numbers and dots: 2.1.0 for 2.1.0-beta1 too.
BUILD="${VERSION%%-*}"
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || BUILD=0

# One build per architecture (works with just the Command Line Tools,
# unlike --arch), joined with lipo.
BINS=()
for TRIPLE in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
  swift build -c release --product dock-utils --triple "$TRIPLE" --package-path "$ROOT"
  BINS+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path --package-path "$ROOT")/dock-utils")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/dock-utils" "${BINS[@]}"
cp "$ROOT/assets/dock-utils.icns" "$ROOT/assets/menubar.png" "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
if [ -n "${SIGNING_P12:-}" ]; then
  # Self-signed certificate (scripts/make-signing-cert.sh): a stable identity,
  # so the Accessibility grant survives updates. Imported into a throwaway
  # keychain, deleted (and the keychain search list restored) on exit.
  KC_DIR="$(mktemp -d)"
  KC="$KC_DIR/signing.keychain-db"
  KC_PASS="$(uuidgen)"
  ORIG_KEYCHAINS=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [ -n "$line" ] && ORIG_KEYCHAINS+=("$line")
  done < <(security list-keychains -d user)
  cleanup() {
    security list-keychains -d user -s ${ORIG_KEYCHAINS[@]+"${ORIG_KEYCHAINS[@]}"}
    security delete-keychain "$KC" 2>/dev/null || true
    rm -rf "$KC_DIR"
  }
  trap cleanup EXIT
  echo "Signing: creating temporary keychain"
  security create-keychain -p "$KC_PASS" "$KC"
  security set-keychain-settings "$KC" # no auto-lock mid-build
  security unlock-keychain -p "$KC_PASS" "$KC"
  echo "Signing: importing certificate"
  security import "$SIGNING_P12" -k "$KC" -P "${SIGNING_P12_PASSWORD:?SIGNING_P12_PASSWORD not set}" \
    -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
  # codesign finds the private key only via the search list on some macOS
  # versions (--keychain alone fails there: "item could not be found").
  security list-keychains -d user -s "$KC" ${ORIG_KEYCHAINS[@]+"${ORIG_KEYCHAINS[@]}"}
  # Sign by certificate hash: self-signed identities aren't "valid" for lookup by name.
  CERT_SHA1="$(security find-certificate -a -Z "$KC" | awk '/SHA-1 hash:/ { print $3; exit }')"
  test -n "$CERT_SHA1" || { echo "ERROR: no certificate found in $SIGNING_P12" >&2; exit 1; }
  echo "Signing: identities in temporary keychain:"
  security find-identity -p codesigning "$KC"
  codesign --force --deep --keychain "$KC" --sign "$CERT_SHA1" "$APP"
  echo "Signed with self-signed certificate $CERT_SHA1"
else
  # Ad-hoc seal so the bundle is self-consistent. The identity changes every
  # build, so macOS drops the Accessibility grant on update.
  codesign --force --deep --sign - "$APP"
  echo "Signed ad-hoc (set SIGNING_P12 for a stable signature)"
fi
echo "Built $APP ($VERSION)"
