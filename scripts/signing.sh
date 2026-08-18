# The identity the build scripts sign with, sourced by both. macOS keys TCC to
# the signature, so a stable one is what lets grants survive a rebuild.
SIGN_IDENTITY="${ANYREC_SIGN_IDENTITY:-Developer ID Application: Doru Chiulan (D33CLM268G)}"

if [[ "$SIGN_IDENTITY" != "-" ]] &&
	! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
	echo "no \"$SIGN_IDENTITY\" in the keychain; signing ad-hoc instead" >&2
	SIGN_IDENTITY="-"
fi

# The keychain profile `xcrun notarytool store-credentials` wrote. The credential itself
# never appears here, or anywhere else in this repository.
NOTARY_PROFILE="${ANYREC_NOTARY_PROFILE:-anyrec-notary}"

# Notarising takes an archive, not a bundle, and staples the ticket back onto the bundle
# — so the caller zips, we submit that, and the caller zips again once it is stapled.
# A build that cannot notarise still produces everything else: only a *downloaded* copy
# is checked, and a cask install is a download.
notarize() {
	local archive="$1" bundle="$2"

	if [[ "$SIGN_IDENTITY" == "-" ]]; then
		echo "ad-hoc signed, so there is nothing to notarise" >&2
		return 1
	fi
	if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
		echo "no notary credentials in keychain profile \"$NOTARY_PROFILE\"; skipping" >&2
		echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team>" >&2
		return 1
	fi

	xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$bundle"
}
