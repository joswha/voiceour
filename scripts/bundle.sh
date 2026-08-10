#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/VoiceOour.app"
BIN="$ROOT/.build/release/VoiceOour"
SIGN_IDENTITY=${VOICEOOUR_CODESIGN_IDENTITY:-}
SIGN_KEYCHAIN=${VOICEOOUR_CODESIGN_KEYCHAIN:-}
LOCAL_KEYCHAIN="$HOME/Library/Keychains/voiceoour-dev.keychain-db"
if [ -z "$SIGN_IDENTITY" ] && [ -f "$LOCAL_KEYCHAIN" ]; then
  security unlock-keychain -p "" "$LOCAL_KEYCHAIN" >/dev/null 2>&1 || true
  LOCAL_IDENTITY=$(security find-identity -v -p codesigning "$LOCAL_KEYCHAIN" 2>/dev/null | awk -F\" '$2 == "voiceoour-dev" {print $2; exit}')
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
cp "$BIN" "$APP/Contents/MacOS/VoiceOour"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/VoiceOour.entitlements" "$APP/Contents/Resources/VoiceOour.entitlements"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/VoiceOour"
if [ -n "$SIGN_KEYCHAIN" ]; then
  codesign --force --deep --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_FLAG" --entitlements "$ROOT/Resources/VoiceOour.entitlements" "$APP"
else
  codesign --force --deep --sign "$SIGN_FLAG" --entitlements "$ROOT/Resources/VoiceOour.entitlements" "$APP"
fi
printf '%s\n' "$APP"
