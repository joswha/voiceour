#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/Voiceour.app"
BIN="$APP/Contents/MacOS/Voiceour"
SIDECAR="$APP/Contents/MacOS/voiceour-asr"
LICENSES="$APP/Contents/Resources/THIRD-PARTY-LICENSES.txt"

fail() {
  echo "verify_bundle.sh: $*" >&2
  exit 1
}

[ -x "$BIN" ] || fail "missing executable $BIN; run scripts/bundle.sh first"

# The whole point of the bundle: a copied .app must carry its own ASR sidecar.
[ -x "$SIDECAR" ] || fail "missing ASR sidecar $SIDECAR; run scripts/bundle.sh first"
binary_archs=$(lipo -archs "$BIN")
[ "$binary_archs" = "arm64" ] || fail "unexpected architectures for $BIN: $binary_archs"
sidecar_archs=$(lipo -archs "$SIDECAR")
[ "$sidecar_archs" = "arm64" ] || fail "unexpected architectures for $SIDECAR: $sidecar_archs"
codesign --verify --strict --verbose=2 "$SIDECAR"

# MIT obliges the ggml notice to travel with every copy of the binary, and a downloader of
# the .app alone never sees the source tree. The literal string is the assertion that
# matters: existence and size cannot tell a real licence body from a heading whose
# generation silently produced nothing.
[ -f "$LICENSES" ] || fail "missing $LICENSES; run scripts/bundle.sh first"
[ -s "$LICENSES" ] || fail "empty $LICENSES"
grep -Fq 'The ggml authors' "$LICENSES" || fail "$LICENSES does not carry the ggml copyright notice"

plutil -lint "$ROOT/Resources/Info.plist" "$ROOT/Resources/Voiceour.entitlements"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
[ "$bundle_id" = "com.voiceour.app" ] || fail "unexpected CFBundleIdentifier: $bundle_id"

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

# Apple's own pre-distribution linter, reported and never enforced here. An ad-hoc or
# locally signed bundle is the correct artifact for `make bundle`, and it always has a
# fatal "Notary Ticket Missing" finding, so failing on it would break verification for
# every contributor. scripts/sign_notarize.sh runs the same tool as a hard gate after
# stapling, which is the only path that claims to be distributable. Absent before the
# macOS releases that ship it, hence the guard.
if [ -x /usr/bin/syspolicy_check ]; then
  printf '%s\n' "syspolicy_check distribution findings (informational):"
  /usr/bin/syspolicy_check distribution "$APP" 2>&1 | sed 's/^/  /' || true
else
  printf '%s\n' "syspolicy_check is unavailable on this host; skipping distribution findings"
fi

printf '%s\n' "Voiceour bundle verification passed"
