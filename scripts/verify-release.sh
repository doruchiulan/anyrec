#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: scripts/verify-release.sh X.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

(cd "$DIST" && shasum -a 256 -c SHA256SUMS)
ditto -x -k "$DIST/AnyRec-$VERSION.zip" "$SCRATCH"
mkdir "$SCRATCH/cli"
tar -xzf "$DIST/anyrec-$VERSION-universal.tar.gz" -C "$SCRATCH/cli"
APP="$SCRATCH/AnyRec.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
for binary in "$APP/Contents/MacOS/AnyRec" "$SCRATCH/cli/bin/anyrec"; do
    for architecture in arm64 x86_64; do
        lipo "$binary" -verify_arch "$architecture"
    done
    codesign --verify --strict "$binary"
done
for framework in "$APP/Contents/Frameworks/whisper.framework" "$SCRATCH/cli/Frameworks/whisper.framework"; do
    for architecture in arm64 x86_64; do
        lipo "$framework/Versions/Current/whisper" -verify_arch "$architecture"
    done
    codesign --verify --strict "$framework"
done
codesign --verify --strict --deep "$APP"
CLI_VERSION="$("$SCRATCH/cli/bin/anyrec" --version)" || {
    echo 'Packaged CLI failed to launch.' >&2
    exit 1
}
[[ "$CLI_VERSION" == "$VERSION" ]]
if [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
    xcrun stapler validate "$APP"
    spctl --assess --type execute "$APP"
    codesign --verify --strict --check-notarization -R=notarized "$SCRATCH/cli/bin/anyrec"
fi
