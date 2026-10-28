#!/bin/bash
# Run the tests. With only the Command Line Tools installed (no Xcode),
# SwiftPM doesn't find Swift Testing on its own: point it there.
# Usage: ./scripts/test.sh [swift test options]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$(xcode-select -p)"
if [[ "$DEV" == */CommandLineTools ]]; then
  FW="$DEV/Library/Developer/Frameworks"
  LIB="$DEV/Library/Developer/usr/lib"
  exec swift test --package-path "$ROOT" \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
fi
exec swift test --package-path "$ROOT" "$@"
