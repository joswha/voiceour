#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# --check-env validates the Apple credentials and exits without building, signing or
# submitting anything. scripts/release.sh calls it so the credential rule below lives in
# exactly one place instead of being restated by the preflight.
CHECK_ENV_ONLY=0
case "${1:-}" in
  '') ;;
  --check-env) CHECK_ENV_ONLY=1 ;;
  *)
    printf '%s\n' "usage: $0 [--check-env]" >&2
    exit 64
    ;;
esac

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
if [ "$CHECK_ENV_ONLY" -eq 1 ]; then
  if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
    printf '%s\n' "sign_notarize.sh: signing environment present: identity \"$IDENTITY\", notarytool keychain profile \"$NOTARY_KEYCHAIN_PROFILE\""
  else
    printf '%s\n' "sign_notarize.sh: signing environment present: identity \"$IDENTITY\", Apple ID $APPLE_ID, team $TEAM_ID"
  fi
  exit 0
fi

APP=$(VOICEOUR_CODESIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/bundle.sh")
codesign --force --options runtime --entitlements "$ROOT/Resources/Voiceour.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements :- "$APP"
"$ROOT/scripts/verify_bundle.sh"

# Resources/Info.plist is the single source of truth for the version, read back off the
# bundle that was actually built rather than restated here.
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
short_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
ARCHIVE_NAME="Voiceour-$short_version.zip"
ARCHIVE="$ROOT/.build/$ARCHIVE_NAME"
SUBMISSION_ZIP="$ROOT/.build/Voiceour-$short_version-notarization-submission.zip"

# The app is archived twice on purpose and the two archives are not interchangeable.
# notarytool cannot take a .app directory, so the app is zipped once purely as a submission
# envelope. Notarization does not alter what was submitted: the ticket comes back
# afterwards and `stapler staple` writes it into the .app on disk. Any archive built
# *before* stapling therefore ships an unstapled app, and every downloader of it needs an
# online Gatekeeper lookup to launch — which fails offline. So the distributable archive is
# created only after the ticket is stapled and validated, and the submission envelope is
# deleted so it can never be mistaken for the release artifact. Do not collapse this into
# one ditto call: the single-archive form is exactly the bug this ordering fixes.
rm -f "$SUBMISSION_ZIP" "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
  xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
else
  echo 'Warning: APPLE_APP_SPECIFIC_PASSWORD is visible in the process table during notarization; run once: xcrun notarytool store-credentials "Voiceour-notary", then set NOTARY_KEYCHAIN_PROFILE=Voiceour-notary.' >&2
  xcrun notarytool submit "$SUBMISSION_ZIP" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD" --wait
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

# Apple's own pre-distribution linter, run here and nowhere else in this script: it is the
# only point at which the app on disk claims to be distributable, because the ticket is
# stapled and the signature is a Developer ID one. It reports a fatal "Notary Ticket
# Missing" finding for anything unstapled and warns on an ad-hoc signature, so a clean
# result is exactly the property a published archive needs and a nonzero exit is a release
# that must not ship. scripts/verify_bundle.sh runs the same tool informationally, before
# signing, where those findings are expected.
if [ -x /usr/bin/syspolicy_check ]; then
  if ! syspolicy_findings=$(/usr/bin/syspolicy_check distribution "$APP" 2>&1); then
    printf '%s\n' "$syspolicy_findings" >&2
    echo "sign_notarize.sh: syspolicy_check rejected the stapled bundle; not releasing $APP" >&2
    exit 1
  fi
  [ -z "$syspolicy_findings" ] || printf '%s\n' "$syspolicy_findings"
  printf '%s\n' "sign_notarize.sh: syspolicy_check distribution passed for $APP"
else
  echo "sign_notarize.sh: /usr/bin/syspolicy_check is unavailable; the distribution check was not run" >&2
fi

ditto -c -k --keepParent "$APP" "$ARCHIVE"
rm -f "$SUBMISSION_ZIP"

# Every checksum below describes the stapled archive a user downloads, never the submission
# envelope. The sidecar names the archive relatively so `shasum -a 256 -c` works from .build.
sha_line=$(cd "$ROOT/.build" && shasum -a 256 "$ARCHIVE_NAME")
printf '%s\n' "$sha_line" > "$ARCHIVE.sha256"
manifest="$ROOT/.build/Voiceour-release-manifest.txt"
cat > "$manifest" <<EOF
app_path=$APP
zip_path=$ARCHIVE
sha256_path=$ARCHIVE.sha256
CFBundleIdentifier=$bundle_id
CFBundleShortVersionString=$short_version
CFBundleVersion=$bundle_version
DEVELOPER_ID_APPLICATION=$IDENTITY
APPLE_TEAM_ID=$TEAM_ID
$sha_line
EOF
printf '%s\n' "$ARCHIVE"
printf '%s\n' "$sha_line"
