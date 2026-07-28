#!/usr/bin/env bash
# Builds a universal, signed anyrec and the tarball a Homebrew formula points at.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ARCHS=(--arch arm64 --arch x86_64)

cd "$ROOT"
rm -rf "$DIST"
mkdir -p "$DIST"

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/anyrec"

# Ad-hoc signature. Swap `-` for a Developer ID to notarize instead.
codesign --force --sign - --options runtime \
	--entitlements "$ROOT/Resources/anyrec.entitlements" "$BIN"
codesign --verify --strict "$BIN"

cp "$BIN" "$DIST/anyrec"
TARBALL="$DIST/anyrec-$VERSION-universal.tar.gz"
tar -czf "$TARBALL" -C "$DIST" anyrec

echo
lipo -archs "$DIST/anyrec"
echo "tarball: $TARBALL"
echo "sha256:  $(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo
echo "Attach the tarball to a GitHub release tagged v$VERSION, then put the"
echo "sha256 above into Formula/anyrec.rb in your tap."
