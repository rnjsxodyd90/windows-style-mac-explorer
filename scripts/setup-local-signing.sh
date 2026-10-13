#!/bin/bash
set -euo pipefail

IDENTITY="Windows Style Mac Explorer Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
    echo "Signing identity already installed: $IDENTITY"
    exit 0
fi

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSWORD="$(openssl rand -hex 24)"

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    2>/dev/null

openssl pkcs12 -export -legacy \
    -macalg sha1 \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -name "$IDENTITY" \
    -out "$TMP/identity.p12" \
    -passout "pass:$PASSWORD" \
    2>/dev/null

security import "$TMP/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$PASSWORD" \
    -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY\""
echo "Installed local signing identity: $IDENTITY"
