#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.website-demo.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/AnyRec Website Demo.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
scratch="$PWD/.build/website-demo"
build() { swift build --scratch-path "$scratch" -Xswiftc -DANYREC_WEBSITE_DEMO "$@"; }
build --product AnyRecBar
cp "$(build --show-bin-path)/AnyRecBar" "$contents/MacOS/AnyRecWebsiteDemo"
cp Resources/AppIcon.icns "$contents/Resources/"
say -o "$contents/Resources/Sketches.m4a" --data-format=aac 'I will send the updated sketches after lunch.'
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.doruchiulan.anyrec.website-demo</string>
<key>CFBundleName</key><string>AnyRec Website Demo</string>
<key>CFBundleExecutable</key><string>AnyRecWebsiteDemo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.2</string>
</dict></plist>
PLIST
source scripts/embed-whisper.sh
source scripts/embed-sparkle.sh
embed_whisper "$contents/MacOS/AnyRecWebsiteDemo" "$contents/Frameworks" "$scratch/artifacts"
embed_sparkle "$contents/Frameworks" "$scratch/artifacts"
codesign --force --sign - "$contents/Frameworks/whisper.framework"
sign_sparkle "$contents/Frameworks" -
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
destination="$PWD/dist/AnyRec Website Demo.app"
if [[ -e "$destination" ]]; then mv "$destination" "$stage/previous.app"; fi
mv "$app" "$destination"
echo "$destination"
