#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/lib/env.sh"
IDENTITY_NAME="$VERBATIM_SIGN_IDENTITY"
LOGIN_KEYCHAIN="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')"

if security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "$IDENTITY_NAME"
    exit 0
fi

TEMP_DIR="$(mktemp -d /private/tmp/verbatim-voice-signing.XXXXXX)"
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

openssl req \
    -new \
    -newkey rsa:2048 \
    -x509 \
    -sha256 \
    -nodes \
    -days 3650 \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$TEMP_DIR/signing.key" \
    -out "$TEMP_DIR/signing.crt"

openssl pkcs12 \
    -export \
    -inkey "$TEMP_DIR/signing.key" \
    -in "$TEMP_DIR/signing.crt" \
    -name "$IDENTITY_NAME" \
    -passout pass:verbatim-voice-one-time-import \
    -out "$TEMP_DIR/signing.p12"

security import "$TEMP_DIR/signing.p12" \
    -k "$LOGIN_KEYCHAIN" \
    -P verbatim-voice-one-time-import \
    -T /usr/bin/codesign

security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$LOGIN_KEYCHAIN" \
    "$TEMP_DIR/signing.crt"

security find-identity -v -p codesigning "$LOGIN_KEYCHAIN"
