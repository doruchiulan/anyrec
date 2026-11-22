#!/usr/bin/env bash
# Writes dist/appcast.xml: the update feed the app checks, one item for this release,
# its download signed with the Sparkle EdDSA key. Uploaded with the release, so
# releases/latest/download/appcast.xml always names the newest version.
#
# The key comes from SPARKLE_PRIVATE_KEY (CI), else from the login keychain (account
# "anyrec", where generate_keys put it).
set -euo pipefail

VERSION="${1:?usage: scripts/appcast.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$ROOT/dist/AnyRec-$VERSION.dmg"
REPO="https://github.com/doruchiulan/anyrec"
[[ -f "$DMG" ]] || { echo "$DMG not found — run scripts/release.sh $VERSION first" >&2; exit 1; }

SIGN="$(find "$ROOT/.build/artifacts/sparkle" -maxdepth 4 -path '*/bin/sign_update' -not -path '*old_dsa*' | head -1)"
[[ -x "$SIGN" ]] || { echo "sign_update not found under .build/artifacts — run swift build first" >&2; exit 1; }

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
	ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$DMG")"
elif [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
	echo "SPARKLE_PRIVATE_KEY is not set; a release without a signed feed cannot update anyone" >&2
	exit 1
else
	ENCLOSURE="$("$SIGN" --account anyrec "$DMG")"
fi
[[ "$ENCLOSURE" == *'sparkle:edSignature="'*'length="'* ]] || { echo "sign_update gave no signature" >&2; exit 1; }

cat >"$ROOT/dist/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AnyRec</title>
    <link>$REPO</link>
    <item>
      <title>AnyRec $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.2</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$REPO/releases/download/v$VERSION/AnyRec-$VERSION.dmg" type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML
echo "wrote $ROOT/dist/appcast.xml"
