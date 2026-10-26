#!/usr/bin/env bash
# Builds universal, signed copies of both front ends, and the two archives a Homebrew
# formula and cask point at.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ARCHS=(--arch arm64 --arch x86_64)

# The app bundle takes its version from the source rather than from this argument, so a
# mismatch here would ship an archive whose name disagrees with what is inside it.
SOURCE_VERSION="$(sed -n 's/.*version: "\([^"]*\)".*/\1/p' "$ROOT/Sources/anyrec/AnyRec.swift" | head -1)"
if [[ "$VERSION" != "$SOURCE_VERSION" ]]; then
	echo "asked for $VERSION, but Sources/anyrec/AnyRec.swift says $SOURCE_VERSION" >&2
	exit 1
fi

cd "$ROOT"
source "$ROOT/scripts/signing.sh"
rm -rf "$DIST"
mkdir -p "$DIST"

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/anyrec"

# The CLI ships as bin/anyrec plus Frameworks/whisper.framework, laid out as Homebrew
# installs them: the binary's rpath is @executable_path/../Frameworks, and the prefix
# has both.
CLI="$DIST/cli"
mkdir -p "$CLI/bin"
cp "$BIN" "$CLI/bin/anyrec"
source "$ROOT/scripts/embed-whisper.sh"
embed_whisper "$CLI/bin/anyrec" "$CLI/Frameworks"

codesign --force --sign "$SIGN_IDENTITY" --options runtime \
	--identifier org.ggml.whisper "$CLI/Frameworks/whisper.framework"
codesign --force --sign "$SIGN_IDENTITY" --options runtime \
	--entitlements "$ROOT/Resources/anyrec.entitlements" "$CLI/bin/anyrec"
codesign --verify --strict --deep "$CLI/bin/anyrec"

CLI_ZIP="$DIST/cli-notarization.zip"
ditto -c -k --keepParent "$CLI" "$CLI_ZIP"
if ! notarize_archive "$CLI_ZIP" && [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
	echo "CLI notarization failed; release stopped" >&2
	exit 1
fi
rm "$CLI_ZIP"

TARBALL="$DIST/anyrec-$VERSION-universal.tar.gz"
tar -czf "$TARBALL" -C "$CLI" bin Frameworks

# `ditto` rather than `zip`, which flattens the symlinks and extended attributes a
# signed bundle is checked against — the app arrives with a broken signature otherwise.
"$ROOT/scripts/bundle-app.sh" release >/dev/null
ZIP="$DIST/AnyRec-$VERSION.zip"
ditto -c -k --keepParent "$DIST/AnyRec.app" "$ZIP"

# Zipped twice: the first archive is what goes up to Apple, and the ticket comes back
# stapled to the bundle rather than to it. The second is what people download.
if notarize "$ZIP" "$DIST/AnyRec.app"; then
	rm "$ZIP"
	ditto -c -k --keepParent "$DIST/AnyRec.app" "$ZIP"
	NOTARISED="yes"
else
	if [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
		echo "app notarization failed; release stopped" >&2
		exit 1
	fi
	NOTARISED="no — a cask install of this will be refused by Gatekeeper"
fi

(cd "$DIST" && shasum -a 256 "AnyRec-$VERSION.zip" "anyrec-$VERSION-universal.tar.gz" > SHA256SUMS)

echo
lipo -archs "$CLI/bin/anyrec"
lipo -archs "$DIST/AnyRec.app/Contents/MacOS/AnyRec"
echo
echo "tarball: $TARBALL"
echo "sha256:  $(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo "zip:     $ZIP"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "notarised: $NOTARISED"
echo
echo "Attach both to a GitHub release tagged v$VERSION, then copy each sha256 into"
echo "Formula/anyrec.rb and Casks/anyrec-app.rb in your tap."
