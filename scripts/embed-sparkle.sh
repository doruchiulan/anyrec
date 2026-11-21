#!/usr/bin/env bash
# Puts Sparkle's framework in the app bundle and signs what is inside it. Sourced by
# bundle-app.sh, after embed-whisper.sh has added the rpath to Contents/Frameworks.
#
#   embed_sparkle <frameworks directory>
#   sign_sparkle <frameworks directory> <signing identity>

embed_sparkle() {
	local frameworks="$1" root source
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	source="$(find "${2:-$root/.build/artifacts}/sparkle" -maxdepth 4 -path '*macos-arm64_x86_64/Sparkle.framework' | head -1)"
	if [[ -z "$source" ]]; then
		echo "Sparkle.framework not found under .build/artifacts — run swift build first" >&2
		return 1
	fi
	mkdir -p "$frameworks"
	rm -rf "$frameworks/Sparkle.framework"
	ditto "$source" "$frameworks/Sparkle.framework"
	# The XPC services exist for sandboxed apps; AnyRec is not one, and Sparkle installs
	# through Autoupdate without them. Two fewer bundles to sign and notarize.
	rm -rf "$frameworks/Sparkle.framework/Versions/B/XPCServices" "$frameworks/Sparkle.framework/XPCServices"
}

# Inside out, each with the hardened runtime notarization requires: the installer tool,
# the updater app, then the framework around them.
sign_sparkle() {
	local framework="$1/Sparkle.framework" identity="$2"
	codesign --force --sign "$identity" --options runtime "$framework/Versions/B/Autoupdate"
	codesign --force --sign "$identity" --options runtime "$framework/Versions/B/Updater.app"
	codesign --force --sign "$identity" --options runtime "$framework"
}
