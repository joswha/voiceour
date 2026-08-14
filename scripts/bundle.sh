#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/Voiceour.app"
BIN="$ROOT/.build/release/Voiceour"
SIGN_IDENTITY=${VOICEOUR_CODESIGN_IDENTITY:-}
SIGN_KEYCHAIN=${VOICEOUR_CODESIGN_KEYCHAIN:-}
LOCAL_KEYCHAIN="$HOME/Library/Keychains/voiceour-dev.keychain-db"
if [ -z "$SIGN_IDENTITY" ] && [ -f "$LOCAL_KEYCHAIN" ]; then
  security unlock-keychain -p "" "$LOCAL_KEYCHAIN" >/dev/null 2>&1 || true
  LOCAL_IDENTITY=$(security find-identity -v -p codesigning "$LOCAL_KEYCHAIN" 2>/dev/null | awk -F\" '$2 == "voiceour-dev" {print $2; exit}')
  if [ -n "$LOCAL_IDENTITY" ]; then
    SIGN_IDENTITY=$LOCAL_IDENTITY
    SIGN_KEYCHAIN=$LOCAL_KEYCHAIN
  fi
fi
if [ -n "$SIGN_IDENTITY" ]; then
  SIGN_FLAG=$SIGN_IDENTITY
else
  SIGN_FLAG=-
  printf '%s\n' "warning: ad-hoc signing; run scripts/setup_local_signing.sh once to preserve Accessibility permission across rebuilds" >&2
fi
swift build -c release --package-path "$ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Voiceour"
# The ASR sidecar ships inside the bundle, beside the app binary: the app resolves it as a
# sibling of its own executable, which is what makes a copied .app able to transcribe.
cp "$ROOT/.build/release/voiceour-asr" "$APP/Contents/MacOS/voiceour-asr"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/Voiceour" "$APP/Contents/MacOS/voiceour-asr"
# Sign the helper first and explicitly. --deep on the app would sign it too, but with the
# app's entitlements and in an order that depends on codesign's traversal; sealing it here
# makes the nested signature deterministic and independently verifiable.
if [ -n "$SIGN_KEYCHAIN" ]; then
  codesign --force --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_FLAG" "$APP/Contents/MacOS/voiceour-asr"
  codesign --force --deep --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_FLAG" --entitlements "$ROOT/Resources/Voiceour.entitlements" "$APP"
else
  codesign --force --sign "$SIGN_FLAG" "$APP/Contents/MacOS/voiceour-asr"
  codesign --force --deep --sign "$SIGN_FLAG" --entitlements "$ROOT/Resources/Voiceour.entitlements" "$APP"
fi
printf '%s\n' "$APP"
