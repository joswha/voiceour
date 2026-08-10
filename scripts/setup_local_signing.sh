#!/bin/sh
set -eu

IDENTITY=voiceoour-dev
KEYCHAIN="$HOME/Library/Keychains/voiceoour-dev.keychain-db"
TMP_DIR=
CREATED=0
COMPLETE=0

cleanup() {
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ "$CREATED" = "1" ] && [ "$COMPLETE" = "0" ]; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
}
register_keychain() {
  set -- "$KEYCHAIN"
  while IFS= read -r existing; do
    [ -n "$existing" ] || continue
    if [ "$existing" != "$KEYCHAIN" ]; then
      set -- "$@" "$existing"
    fi
  done <<EOF
$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
EOF
  security list-keychains -d user -s "$@"
}

trap cleanup EXIT HUP INT TERM

if [ -f "$KEYCHAIN" ]; then
  if ! security unlock-keychain -p "" "$KEYCHAIN" >/dev/null 2>&1; then
    printf '%s\n' "Refusing to replace existing keychain: $KEYCHAIN" >&2
    exit 1
  fi
  EXISTING=$(security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | awk -F\" -v identity="$IDENTITY" '$2 == identity {print $2; exit}')
  if [ "$EXISTING" = "$IDENTITY" ]; then
    register_keychain
    printf '%s\n' "Local signing identity is ready: $IDENTITY"
    exit 0
  fi
  printf '%s\n' "Existing keychain does not contain a valid $IDENTITY identity: $KEYCHAIN" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/voiceoour-signing.XXXXXX")
KEY_FILE="$TMP_DIR/$IDENTITY.key.pem"
CERT_FILE="$TMP_DIR/$IDENTITY.cert.pem"
P12_FILE="$TMP_DIR/$IDENTITY.p12"

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -subj "/CN=$IDENTITY" \
  -addext basicConstraints=critical,CA:FALSE \
  -addext keyUsage=critical,digitalSignature \
  -addext extendedKeyUsage=critical,codeSigning \
  -keyout "$KEY_FILE" \
  -out "$CERT_FILE" >/dev/null 2>&1
openssl pkcs12 -export -legacy \
  -inkey "$KEY_FILE" \
  -in "$CERT_FILE" \
  -name "$IDENTITY" \
  -passout pass:voiceoour-local-import \
  -out "$P12_FILE"

security create-keychain -p "" "$KEYCHAIN"
CREATED=1
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "" "$KEYCHAIN"
security import "$P12_FILE" \
  -k "$KEYCHAIN" \
  -P voiceoour-local-import \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "" \
  "$KEYCHAIN" >/dev/null
security add-trusted-cert \
  -d \
  -r trustRoot \
  -k "$KEYCHAIN" \
  "$CERT_FILE"

INSTALLED=$(security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | awk -F\" -v identity="$IDENTITY" '$2 == identity {print $2; exit}')
if [ "$INSTALLED" != "$IDENTITY" ]; then
  printf '%s\n' "Failed to install valid local signing identity: $IDENTITY" >&2
  exit 1
fi

register_keychain

COMPLETE=1
printf '%s\n' "Installed password-free local signing identity: $IDENTITY"
printf '%s\n' "VoiceOour rebuilds can now preserve Accessibility permission."
