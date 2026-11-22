#!/usr/bin/env bash
set -euo pipefail
app="${1:?usage: package-app.sh path/to/AnyRec.app output.dmg}"
target="${2:?missing output.dmg}"
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/signing.sh"
[[ "$(basename "$app")" == AnyRec.app && -f "$app/Contents/Info.plist" && "$target" == *.dmg ]]
codesign --verify --strict --deep "$app"
tools="$root/.build/dmg-tools"
if [[ ! -x "$tools/bin/python" ]]; then python3 -m venv "$tools"; fi
"$tools/bin/python" -m pip --disable-pip-version-check install --require-hashes --only-binary=:all: -r "$root/scripts/dmg-requirements.txt"
stage="$(mktemp -d "$(dirname "$target")/.anyrec-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

if [[ "$SIGN_IDENTITY" != "-" ]] && ! xcrun stapler validate "$app" >/dev/null 2>&1; then
    ditto -c -k --keepParent "$app" "$stage/notary.zip"
    if ! notarize "$stage/notary.zip" "$app"; then
        if [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then exit 1; fi
        echo "Building a preview without a stapled app ticket." >&2
    fi
fi
image="$stage/AnyRec.dmg"
artwork="$root/Resources/Installer"
"$tools/bin/dmgbuild" -s "$artwork/layout.py" -D "artwork=$artwork" -D "app=$app" AnyRec "$image"
codesign --force --sign "$SIGN_IDENTITY" --identifier com.doruchiulan.anyrec.dmg "$image"
codesign --verify --strict "$image"
if [[ "$SIGN_IDENTITY" != "-" ]] && ! notarize "$image" "$image"; then
    if [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then exit 1; fi
    echo "Disk image has no stapled ticket." >&2
fi
mv -f "$image" "$target"
echo "$target"
