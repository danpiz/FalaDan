#!/usr/bin/env bash
#
# Create a stable local code-signing identity, once, so macOS stops revoking
# FalaDan's Accessibility grant on every rebuild.
#
#   ./Scripts/setup-dev-signing.sh
#
# ## Why this exists
#
# With no signing certificate on the machine, Scripts/sign-dev-app.sh falls back
# to ad-hoc signing ("-"). TCC remembers a permission grant by the app's
# *designated requirement*, and for an ad-hoc signature that requirement can only
# pin the cdhash:
#
#   identifier "com.faladan.dev" and cdhash H"<changes every build>"
#
# So every `just dev` silently voids the Accessibility grant, while System
# Settings goes on showing the app ticked — the row refers to a signature that no
# longer exists. The symptom is the hotkey doing nothing for no visible reason.
#
# With a certificate the requirement pins the certificate instead:
#
#   identifier "com.faladan.dev" and certificate leaf = H"<same every build>"
#
# The binary's cdhash still changes on every build; it just stops mattering.
# Grant Accessibility once and it survives every rebuild.
#
# ## What this creates
#
# A self-signed code-signing certificate in your login keychain, valid 10 years,
# trusted for code signing only. It is local to this Mac: it cannot sign anything
# anyone else would trust, and it is not a Developer ID — release builds still
# need a real Apple certificate. Nothing leaves the machine.
#
# Safe to re-run; it exits early if the identity already exists.

set -euo pipefail

CERT_NAME="${FALADAN_DEV_CERT_NAME:-FalaDan Dev Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "Identity already present: $CERT_NAME"
    echo "Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate: $CERT_NAME"

# codeSigning EKU is what makes `security find-identity -p codesigning` list it.
# Without it the certificate exists but codesign will never select it.
cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = PLACEHOLDER_CN

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF
sed -i '' "s/PLACEHOLDER_CN/$CERT_NAME/" "$WORK/openssl.cnf"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" >/dev/null 2>&1

# The passphrase must be non-empty. `security import` fails MAC verification on
# an empty-passphrase PKCS#12 and reports it as "MAC verification failed during
# PKCS12 import (wrong password?)" — which reads like the password is wrong when
# the real problem is that there isn't one. A throwaway value keeps the import
# non-interactive; the bundle exists only inside a temp dir this script deletes
# on exit, so the passphrase never needs to be remembered or stored.
P12_PASS="tmp-$(uuidgen)"

openssl pkcs12 -export -legacy -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "==> Importing into the login keychain"
# -T /usr/bin/codesign pre-authorises codesign to use the key, so builds do not
# raise a keychain prompt every time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> Trusting it for code signing"
echo "    (macOS will ask for your login password — this is the trust-settings prompt)"
# User-level trust only: -k login keychain, not the System keychain. No sudo, and
# nothing outside this account is affected.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Stops the keychain re-prompting for key access on every single build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "Done. Identity is available:"
    security find-identity -v -p codesigning | grep -F "$CERT_NAME"
    echo
    echo "Next:"
    echo "  1. just reset-tcc   # clears grants tied to the old ad-hoc signatures"
    echo "  2. just dev         # rebuild, now signed with a stable identity"
    echo "  3. Grant Microphone and Accessibility once when prompted."
    echo
    echo "That grant now survives rebuilds. No environment variable is needed —"
    echo "Scripts/sign-dev-app.sh finds this identity by name."
else
    echo "Import finished but the identity is not listed for code signing." >&2
    echo "Check Keychain Access > login > Certificates for '$CERT_NAME' and that" >&2
    echo "its trust for Code Signing is set to 'Always Trust'." >&2
    exit 1
fi
