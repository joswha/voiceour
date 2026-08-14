#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IDENTITY=${DEVELOPER_ID_APPLICATION:-}
APPLE_ID=${APPLE_ID:-}
TEAM_ID=${APPLE_TEAM_ID:-}
PASSWORD=${APPLE_APP_SPECIFIC_PASSWORD:-}
NOTARY_KEYCHAIN_PROFILE=${NOTARY_KEYCHAIN_PROFILE:-}
if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
  if [ -z "$IDENTITY" ]; then
    echo "Missing signing environment. Set DEVELOPER_ID_APPLICATION." >&2
    exit 2
  fi
elif [ -z "$IDENTITY" ] || [ -z "$APPLE_ID" ] || [ -z "$TEAM_ID" ] || [ -z "$PASSWORD" ]; then
  echo "Missing signing/notarization environment. Set DEVELOPER_ID_APPLICATION, APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD." >&2
  exit 2
fi
APP=$(VOICEOUR_CODESIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/bundle.sh")
codesign --force --options runtime --entitlements "$ROOT/Resources/Voiceour.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements :- "$APP"
"$ROOT/scripts/verify_bundle.sh"
ZIP="$ROOT/.build/Voiceour.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
else
  echo 'Warning: APPLE_APP_SPECIFIC_PASSWORD is visible in the process table during notarization; run once: xcrun notarytool store-credentials "Voiceour-notary", then set NOTARY_KEYCHAIN_PROFILE=Voiceour-notary.' >&2
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD" --wait
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
sha_line=$(shasum -a 256 "$ZIP")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
short_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
manifest="$ROOT/.build/Voiceour-release-manifest.txt"
cat > "$manifest" <<EOF
app_path=$APP
zip_path=$ZIP
CFBundleIdentifier=$bundle_id
CFBundleShortVersionString=$short_version
CFBundleVersion=$bundle_version
DEVELOPER_ID_APPLICATION=$IDENTITY
APPLE_TEAM_ID=$TEAM_ID
$sha_line
EOF
printf '%s\n' "$sha_line"
