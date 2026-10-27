#!/usr/bin/env bash
# Wraps the AnyRecBar binary in AnyRec.app. macOS grants Screen Recording and
# Microphone to a bundle, so the app has to be one to hold its own grants.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AnyRec.app"
VERSION="$(sed -n 's/.*version: "\([^"]*\)".*/\1/p' "$ROOT/Sources/anyrec/AnyRec.swift" | head -1)"
if [[ -z "$VERSION" ]]; then
	echo "could not read the version out of Sources/anyrec/AnyRec.swift" >&2
	exit 1
fi

cd "$ROOT"

# Only a release bundle is universal: anyone who downloads one may be on an Intel Mac.
# Building both slices for a local run would just double the wait.
if [[ "$CONFIG" == release ]]; then
	build() { swift build -c release --arch arm64 --arch x86_64 "$@"; }
else
	build() { swift build -c "$CONFIG" "$@"; }
fi

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

build --product AnyRecBar
BIN="$(build --show-bin-path)/AnyRecBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AnyRec"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM can record the deployment target as the SDK, disabling current macOS styling.
xcrun vtool -set-build-version macos 15.2 "$SDK_VERSION" -replace \
	-output "$APP/Contents/MacOS/AnyRec" "$APP/Contents/MacOS/AnyRec"

# whisper.cpp is linked as a framework, which the binary looks for on its rpath. Into the
# bundle it goes, with an rpath that points there instead of into .build.
source "$ROOT/scripts/embed-whisper.sh"
embed_whisper "$APP/Contents/MacOS/AnyRec" "$APP/Contents/Frameworks"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>AnyRec</string>
	<key>CFBundleDisplayName</key><string>AnyRec</string>
	<key>CFBundleIdentifier</key><string>com.doruchiulan.anyrec</string>
	<key>CFBundleExecutable</key><string>AnyRec</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>15.2</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>AnyRec records your microphone as its own track, so your side of a call is separate from everyone else's.</string>
</dict>
</plist>
PLIST

# The hardened runtime blocks audio input without the entitlement, so both go on
# together or the microphone never opens.
source "$ROOT/scripts/signing.sh"
codesign --force --sign "$SIGN_IDENTITY" --options runtime \
	--identifier org.ggml.whisper "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN_IDENTITY" --options runtime \
	--entitlements "$ROOT/Resources/anyrec.entitlements" "$APP"
codesign --verify --strict "$APP"

echo
echo "built: $APP"
echo
echo "Move it to /Applications and open it, then grant Screen Recording and"
echo "Microphone in Privacy & Security and reopen it — the grant only takes"
echo "effect for newly launched processes."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
	echo
	echo "An ad-hoc signature changes on every rebuild, so macOS treats each build as"
	echo "a new app and asks again. A Developer ID signature would not."
fi
