#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

check_secrets() {
    local name
    for name in ANYREC_CERTIFICATE_BASE64 ANYREC_CERTIFICATE_PASSWORD \
        ANYREC_NOTARY_KEY ANYREC_NOTARY_KEY_ID ANYREC_NOTARY_ISSUER_ID; do
        [[ -n "${!name:-}" ]] || { echo "Missing GitHub secret: $name" >&2; return 1; }
    done
}

prepare() {
    check_secrets
    mkdir -p "$SIGNING_DIR"
    python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP']) / 'anyrec-signing'
try:
    certificate = base64.b64decode(''.join(os.environ['ANYREC_CERTIFICATE_BASE64'].split()), validate=True)
except ValueError:
    raise SystemExit('Signing certificate must be valid base64.') from None
(root / 'certificate.p12').write_bytes(certificate)
(root / 'notary.p8').write_text(os.environ['ANYREC_NOTARY_KEY'])
PY
    local password
    password="$(openssl rand -hex 32)"
    security create-keychain -p "$password" "$KEYCHAIN" >/dev/null 2>&1
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$password" "$KEYCHAIN" >/dev/null 2>&1
    security import "$SIGNING_DIR/certificate.p12" -k "$KEYCHAIN" \
        -P "$ANYREC_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -T /usr/bin/codesign >/dev/null 2>&1
    security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$password" "$KEYCHAIN" >/dev/null 2>&1
    security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
    xcrun notarytool store-credentials anyrec-ci --keychain "$KEYCHAIN" \
        --key "$SIGNING_DIR/notary.p8" --key-id "$ANYREC_NOTARY_KEY_ID" \
        --issuer "$ANYREC_NOTARY_ISSUER_ID" >/dev/null 2>&1
    rm "$SIGNING_DIR/certificate.p12" "$SIGNING_DIR/notary.p8"
    printf 'ANYREC_NOTARY_PROFILE=anyrec-ci\nANYREC_NOTARY_KEYCHAIN=%s\n' "$KEYCHAIN" >>"$GITHUB_ENV"
}

case "${1:-}" in
    check) check_secrets ;;
    prepare|cleanup)
        : "${RUNNER_TEMP:?This command requires a GitHub runner temporary directory}"
        SIGNING_DIR="$RUNNER_TEMP/anyrec-signing"
        KEYCHAIN="$SIGNING_DIR/release.keychain-db"
        if [[ "$1" == prepare ]]; then
            prepare
        else
            security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
            rm -rf "$SIGNING_DIR"
        fi
        ;;
    *) echo 'usage: scripts/ci-signing.sh check|prepare|cleanup' >&2; exit 1 ;;
esac
