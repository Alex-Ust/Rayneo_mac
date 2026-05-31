#!/usr/bin/env bash
# Create a stable self-signed code-signing identity in the login keychain.
# Why: ad-hoc signing (codesign -s -) changes the binary's cdhash on every
# rebuild, so macOS TCC treats each build as a new app and re-asks for Screen
# Recording / Accessibility. A stable cert makes the code-signing requirement
# (bundle id + this certificate) constant across rebuilds, so permissions you
# grant once persist.
#
# Run once:  make signing   (or: bash scripts/setup-signing.sh)
# You may get a keychain prompt the first time codesign uses the key — click
# "Always Allow".
set -euo pipefail

CERT_NAME="RayNeoSpatial Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Signing identity '$CERT_NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.conf" >/dev/null 2>&1

# -legacy: produce a PKCS12 MAC that macOS's `security` can import (OpenSSL 3
# defaults to a newer MAC that fails with "MAC verification failed"). Use a
# non-empty password for the same compatibility reason.
P12PASS="rayneo"
if openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
       -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$P12PASS" >/dev/null 2>&1; then
    :
else
    # Fallback for LibreSSL / OpenSSL builds without -legacy.
    openssl pkcs12 -export -out "$TMP/id.p12" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$P12PASS" >/dev/null 2>&1
fi

# Import key+cert; -A lets codesign use the key without per-run prompts.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign -A

echo "Done. Identity '$CERT_NAME' installed."
echo "Now run 'make runapp', grant Screen Recording + Accessibility once,"
echo "and they will survive future rebuilds."
