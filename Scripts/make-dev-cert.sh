#!/bin/bash
# Creates the self-signed code-signing certificate "Cyclop Dev" in the login
# keychain, once. bundle.sh then signs local builds with it, so macOS sees the
# same app after every rebuild and keeps the Screen Recording / Accessibility
# permission you granted instead of asking again.
#
# Run it yourself in Terminal: macOS may ask to unlock the keychain and to let
# codesign use the new key (choose "Always Allow"). Nothing here needs an Apple
# account, and the certificate is only trusted by being named on the command
# line; it does not make the Mac trust anything else.
set -euo pipefail

NAME="Cyclop Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already in the keychain."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CFG

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null

# Key and certificate separately: macOS pairs them into one identity, and this
# avoids the PKCS#12 encryption mismatch between newer OpenSSL and `security`.
security import "$TMP/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$KEYCHAIN"

echo
security find-identity -p codesigning | grep "$NAME" || {
    echo "!!! the identity did not appear; see the output above" >&2
    exit 1
}
echo "Done. Run ./Scripts/bundle.sh and the app is signed as \"$NAME\"."
