# The identity the build scripts sign with, sourced by both. macOS keys TCC to
# the signature, so a stable one is what lets grants survive a rebuild.
SIGN_IDENTITY="${ANYREC_SIGN_IDENTITY:-Developer ID Application: Doru Chiulan (D33CLM268G)}"

if [[ "$SIGN_IDENTITY" != "-" ]] &&
	! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
	if [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 ]]; then
		echo "required Developer ID signing identity is unavailable" >&2
		return 1
	fi
	echo "no \"$SIGN_IDENTITY\" in the keychain; signing ad-hoc instead" >&2
	SIGN_IDENTITY="-"
fi

# The keychain profile `xcrun notarytool store-credentials` wrote. The credential itself
# never appears here, or anywhere else in this repository.
NOTARY_PROFILE="${ANYREC_NOTARY_PROFILE:-anyrec-notary}"
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${ANYREC_NOTARY_KEYCHAIN:-}" ]]; then
	NOTARY_ARGS+=(--keychain "$ANYREC_NOTARY_KEYCHAIN")
fi

if [[ "${ANYREC_REQUIRE_NOTARIZATION:-0}" == 1 && "$SIGN_IDENTITY" == "-" ]]; then
	echo "release requires Developer ID signing, not ad-hoc signing" >&2
	return 1
fi

notarize_archive() {
	local archive="$1" result

	if [[ "$SIGN_IDENTITY" == "-" ]]; then
		echo "ad-hoc signed, so there is nothing to notarise" >&2
		return 1
	fi
	if ! xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
		echo "no notary credentials in keychain profile \"$NOTARY_PROFILE\"; skipping" >&2
		echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team>" >&2
		return 1
	fi

	result="$(mktemp)"
	if ! xcrun notarytool submit "$archive" "${NOTARY_ARGS[@]}" --wait --output-format json >"$result"; then
		rm -f "$result"
		return 1
	fi
	local accepted=0
	python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])).get("status") != "Accepted")' "$result" || accepted=$?
	rm -f "$result"
	return "$accepted"
}

notarize() {
	notarize_archive "$1" || return 1
	xcrun stapler staple "$2" || return 1
	xcrun stapler validate "$2"
}
