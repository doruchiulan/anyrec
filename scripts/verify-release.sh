#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: scripts/verify-release.sh X.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
SCRATCH="$(mktemp -d)"
mount="$SCRATCH/volume"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then hdiutil detach "$mount" || return 1; fi
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

(cd "$DIST" && shasum -a 256 -c SHA256SUMS)
DMG="$DIST/AnyRec-$VERSION.dmg"
hdiutil verify "$DMG"
codesign --verify --strict "$DMG"
mkdir "$mount"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$DMG"
mounted=1
[[ "$(readlink "$mount/Applications")" == /Applications && -s "$mount/.DS_Store" ]]
cmp "$ROOT/Resources/AppIcon.icns" "$mount/AnyRec.app/Contents/Resources/AppIcon.icns"
mkdir "$SCRATCH/cli"
tar -xzf "$DIST/anyrec-$VERSION-universal.tar.gz" -C "$SCRATCH/cli"
APP="$mount/AnyRec.app"
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
# The updater: present, signed, and pointed at the feed with the key that checks it.
codesign --verify --strict "$APP/Contents/Frameworks/Sparkle.framework"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" ]]
codesign --verify --strict --deep "$APP"
CLI_VERSION="$("$SCRATCH/cli/bin/anyrec" --version)" || {
    echo 'Packaged CLI failed to launch.' >&2
    exit 1
}
[[ "$CLI_VERSION" == "$VERSION" ]]
if [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature "$DMG"
    xcrun stapler validate "$APP"
    spctl --assess --type execute "$APP"
    codesign --verify --strict --check-notarization -R=notarized "$SCRATCH/cli/bin/anyrec"
fi
