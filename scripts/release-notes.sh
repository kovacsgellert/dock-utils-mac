#!/bin/bash
# Compose GH release notes from CHANGELOG.md.
# Usage: scripts/release-notes.sh <tag>
#   prerelease tag (contains "-"): that version's section only
#   final tag: that section plus all prerelease sections of the same
#   version (everything since the previous non-prerelease).
# Prints Markdown with a "# <tag>" title to stdout.
# CHANGELOG=<path> reads another file (for tests).
set -euo pipefail
TAG="${1:?usage: release-notes.sh <tag>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${TAG%%-*}" # 0.2.0 for both 0.2.0 and 0.2.0-beta1
echo "# $TAG"
echo
awk -v tag="$TAG" -v base="$BASE" '
  /^## / {
    if (collect) {
      # Keep collecting prereleases of the same version; stop at anything else.
      if ($2 ~ ("^" base "-")) { next }
      exit
    }
    if ($2 == tag) { collect = 1 }
    next
  }
  collect && !started && NF == 0 { next }
  collect { started = 1; print }
' "${CHANGELOG:-$ROOT/CHANGELOG.md}"
