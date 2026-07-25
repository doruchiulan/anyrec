#!/usr/bin/env bash
# Builds a universal, signed slack-rec and the tarball a Homebrew formula points at.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ARCHS=(--arch arm64 --arch x86_64)

cd "$ROOT"
rm -rf "$DIST"
mkdir -p "$DIST"

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/slack-rec"

# Ad-hoc signature. Swap `-` for a Developer ID to notarize instead.
codesign --force --sign - --options runtime \
	--entitlements "$ROOT/Resources/slack-rec.entitlements" "$BIN"
codesign --verify --strict "$BIN"

cp "$BIN" "$DIST/slack-rec"
TARBALL="$DIST/slack-rec-$VERSION-universal.tar.gz"
tar -czf "$TARBALL" -C "$DIST" slack-rec

echo
lipo -archs "$DIST/slack-rec"
echo "tarball: $TARBALL"
echo "sha256:  $(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo
echo "Attach the tarball to a GitHub release tagged v$VERSION, then put the"
echo "sha256 above into Formula/slack-rec.rb in your tap."
