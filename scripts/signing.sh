# The identity the build scripts sign with, sourced by both. macOS keys TCC to
# the signature, so a stable one is what lets grants survive a rebuild.
SIGN_IDENTITY="${ANYREC_SIGN_IDENTITY:-Developer ID Application: Doru Chiulan (D33CLM268G)}"

if [[ "$SIGN_IDENTITY" != "-" ]] &&
	! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
	echo "no \"$SIGN_IDENTITY\" in the keychain; signing ad-hoc instead" >&2
	SIGN_IDENTITY="-"
fi
