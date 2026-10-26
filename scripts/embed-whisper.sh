#!/usr/bin/env bash
# Puts whisper.cpp's framework beside a binary that links it, and points the binary's
# rpath at it rather than at the copy SwiftPM unpacked under .build. Sourced by the
# build scripts; both the app bundle and the CLI tarball carry the framework.
#
#   embed_whisper <binary> <frameworks directory>

embed_whisper() {
	local binary="$1" frameworks="$2" root
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	local source
	source="$(find "$root/.build/artifacts" -maxdepth 6 -path '*macos-arm64_x86_64/whisper.framework' | head -1)"
	if [[ -z "$source" ]]; then
		echo "whisper.framework not found under .build/artifacts — run swift build first" >&2
		return 1
	fi
	mkdir -p "$frameworks"
	rm -rf "$frameworks/whisper.framework"
	ditto "$source" "$frameworks/whisper.framework"
	# Any rpath into the build directory is one nobody else has. There may be none —
	# grep's exit status then must not end a caller running under pipefail.
	local stale
	for stale in $(otool -l "$binary" | awk '/LC_RPATH/{getline; getline; print $2}' | grep '/.build/' || true); do
		install_name_tool -delete_rpath "$stale" "$binary"
	done
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
}
