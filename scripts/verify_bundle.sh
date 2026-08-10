#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/VoiceOour.app"
BIN="$APP/Contents/MacOS/VoiceOour"

fail() {
  echo "verify_bundle.sh: $*" >&2
  exit 1
}

[ -x "$BIN" ] || fail "missing executable $BIN; run scripts/bundle.sh first"

plutil -lint "$ROOT/Resources/Info.plist" "$ROOT/Resources/VoiceOour.entitlements"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
[ "$bundle_id" = "com.voiceoour.app" ] || fail "unexpected CFBundleIdentifier: $bundle_id"

lsui_element=$(/usr/libexec/PlistBuddy -c 'Print LSUIElement' "$APP/Contents/Info.plist")
[ "$lsui_element" = "true" ] || fail "unexpected LSUIElement: $lsui_element"

microphone_usage=$(/usr/libexec/PlistBuddy -c 'Print NSMicrophoneUsageDescription' "$APP/Contents/Info.plist")
[ -n "$microphone_usage" ] || fail "NSMicrophoneUsageDescription is empty"

codesign --display --verbose=4 "$APP"
entitlements=$(codesign --display --entitlements :- "$APP" 2>&1)
printf '%s\n' "$entitlements"

case "$entitlements" in
  *com.apple.security.device.audio-input*) ;;
  *) fail "missing audio-input entitlement" ;;
esac
case "$entitlements" in
  *com.apple.security.app-sandbox*) fail "unexpected app sandbox entitlement" ;;
esac
case "$entitlements" in
  *com.apple.security.device.input-monitoring*) fail "unexpected input-monitoring entitlement" ;;
esac

codesign --verify --deep --strict --verbose=2 "$APP"

printf '%s\n' "VoiceOour bundle verification passed"
