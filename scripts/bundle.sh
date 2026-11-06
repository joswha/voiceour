#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/Voiceour.app"
BIN="$ROOT/.build/release/Voiceour"
SIGN_IDENTITY=${VOICEOUR_CODESIGN_IDENTITY:-}
SIGN_KEYCHAIN=${VOICEOUR_CODESIGN_KEYCHAIN:-}
# An explicit identity bypasses local development pins, including during notarization.
if [ -z "$SIGN_IDENTITY" ] && [ -f "$ROOT/.env" ]; then
  . "$ROOT/.env"
  SIGN_IDENTITY=${VOICEOUR_CODESIGN_IDENTITY:-}
  SIGN_KEYCHAIN=${SIGN_KEYCHAIN:-${VOICEOUR_CODESIGN_KEYCHAIN:-}}
fi
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
  printf '%s\n' "warning: ad-hoc signing; run make signing once to preserve Accessibility permission across rebuilds" >&2
fi
swift build -c release --package-path "$ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Voiceour"
# The ASR sidecar ships inside the bundle, beside the app binary: the app resolves it as a
# sibling of its own executable, which is what makes a copied .app able to transcribe.
cp "$ROOT/.build/release/voiceour-asr" "$APP/Contents/MacOS/voiceour-asr"
# VoiceCore checks the standard macOS Resources directory before Bundle.module's
# command-line fallback. Copy the complete SwiftPM bundle so the packaged app is
# independent of this checkout's absolute .build path.
VOICECORE_RESOURCES="$ROOT/.build/release/voiceour_VoiceCore.bundle"
[ -d "$VOICECORE_RESOURCES" ] || {
  printf '%s\n' "bundle.sh: missing $VOICECORE_RESOURCES" >&2
  exit 1
}
cp -R "$VOICECORE_RESOURCES" "$APP/Contents/Resources/voiceour_VoiceCore.bundle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# MIT requires the ggml copyright and permission notice to accompany every copy of the
# software, and a user who is handed only a zipped .app receives no file from the source
# tree. So the notice is assembled into the bundle itself. The licence bodies are read out of
# Vendor/ggml/LICENSE and Vendor/granite/LICENSE rather than inlined here: a second copy
# of a licence text is a copy that silently goes stale the next time a vendor pin moves. The
# pins are extracted from Package.swift, Vendor/granite/include/granite.h and
# Sources/VoiceCore/ASRProtocol.swift for the same reason, the same discipline
# scripts/check_docs.sh applies to the model pins. Nothing here varies between runs, so
# repeated builds produce byte-identical output.
LICENSES="$APP/Contents/Resources/THIRD-PARTY-LICENSES.txt"
VENDOR="$ROOT/Vendor/ggml"
GRANITE_VENDOR="$ROOT/Vendor/granite"
CONTRACT="$ROOT/Sources/VoiceCore/ASRProtocol.swift"
ggml_commit=$(sed -n 's/^ *("GGML_COMMIT", "\\"\([0-9a-f]*\)\\"").*/\1/p' "$ROOT/Package.swift")
transcribe_cpp_commit=$(sed -n 's|^// Adapted from transcribe.cpp (MIT) src/arch/granite5_ctc at \([0-9a-f]\{40\}\),.*|\1|p' "$GRANITE_VENDOR/include/granite.h")
granite_field() {
  sed -n "/^public enum GraniteModelContract/,/^}/s/^ *public static let $1 = \"\([^\"]*\)\".*/\1/p" "$CONTRACT"
}
granite_model_id=$(granite_field modelId)
granite_revision=$(granite_field revision)
granite_file=$(granite_field fileName)
granite_source=$(granite_field sourceCheckpoint)
granite_source_revision=$(granite_field sourceRevision)
for pin in "$ggml_commit" "$transcribe_cpp_commit" \
  "$granite_model_id" "$granite_revision" "$granite_file" "$granite_source" "$granite_source_revision"; do
  case "$pin" in
    '' | *'
'*)
      printf '%s\n' "bundle.sh: could not extract a single pin for $LICENSES" >&2
      exit 1
      ;;
  esac
done
for license in "$VENDOR/LICENSE" "$GRANITE_VENDOR/LICENSE"; do
  [ -s "$license" ] || {
    printf '%s\n' "bundle.sh: missing $license" >&2
    exit 1
  }
done

# Every third-party copyright inside a vendored tree that its verbatim LICENSE does not
# itself name. Swept rather than listed, so a re-vendor that pulls in new attributed code
# carries it into the bundle instead of leaving this notice quietly incomplete. LICENSE is
# excluded because it is reproduced in full, and so is any swept line that restates one of
# its copyright lines, such as a port's provenance comment; NOTICE.md and patches/ never
# compile. The sort makes the result independent of xargs batching.
copyright_sweep() {
  licensed=$(LC_ALL=C grep -h -e 'Copyright (c)' -e 'Copyright (C)' "$1/LICENSE" |
    LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  LC_ALL=C find "$1" -type f \
    ! -path "$1/LICENSE" \
    ! -path "$1/NOTICE.md" \
    ! -path "$1/patches/*" \
    -print0 |
    LC_ALL=C xargs -0 grep -I -h -e 'Copyright (c)' -e 'Copyright (C)' |
    LC_ALL=C sed -e 's|^[[:space:]]*//[[:space:]]*||' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    LC_ALL=C sort -u |
    if [ -n "$licensed" ]; then LC_ALL=C grep -v -F -e "$licensed" || true; else cat; fi
}
vendor_attributions=$(copyright_sweep "$VENDOR")
granite_attributions=$(copyright_sweep "$GRANITE_VENDOR")

{
  cat <<EOF
Voiceour third-party licences

Voiceour itself is MIT licensed; its LICENSE accompanies the source repository. This file
carries the notices of the third-party code compiled into this bundle, and of the speech
model the app downloads at runtime.


================================================================================
ggml -- MIT
================================================================================

The voiceour-asr sidecar in Contents/MacOS links ggml, vendored from
https://github.com/ggml-org/whisper.cpp at commit
$ggml_commit. The upstream licence follows verbatim.

EOF
  cat "$VENDOR/LICENSE"
  if [ -n "$vendor_attributions" ]; then
    cat <<'EOF'

Further copyright holders of code included in that vendored tree, covered by the
permission notice above:

EOF
    printf '%s\n' "$vendor_attributions" | sed 's/^/    /'
  fi
  cat <<EOF


================================================================================
transcribe.cpp Granite port -- MIT
================================================================================

The voiceour-asr sidecar also links Voiceour's adaptation of transcribe.cpp's Granite
Speech 5 TurboCTC implementation, ported from
https://github.com/handy-computer/transcribe.cpp at commit
$transcribe_cpp_commit onto the ggml above. The upstream licence follows
verbatim.

EOF
  cat "$GRANITE_VENDOR/LICENSE"
  if [ -n "$granite_attributions" ]; then
    cat <<'EOF'

Further copyright holders of code included in that ported tree, covered by the
permission notice above:

EOF
    printf '%s\n' "$granite_attributions" | sed 's/^/    /'
  fi
  cat <<EOF


================================================================================
Granite speech model weights -- Apache-2.0
================================================================================

No model weights are contained in this bundle or in the Voiceour source repository. On first
use the app downloads one GGUF conversion of IBM's Granite Speech 5.0 470M TurboCTC
checkpoint into a local cache; that download is the only network access the app makes.
Those weights are not Voiceour's work and are not MIT licensed:

    Model:        IBM Granite Speech 5.0 470M TurboCTC
    Creator:      IBM
    Licence:      Apache License, Version 2.0
                  https://www.apache.org/licenses/LICENSE-2.0
    Upstream:     https://huggingface.co/$granite_source
                  revision $granite_source_revision
    Conversion:   https://huggingface.co/$granite_model_id
                  revision $granite_revision
                  file $granite_file

The conversion repository's publisher converted the checkpoint to GGUF with transcribe.cpp
and quantised it to Q8_0, without retraining; it is labelled Apache-2.0, matching the
checkpoint, and is not an official IBM release. The weights are provided on an "AS IS"
basis, without warranties or conditions of any kind; sections 7 and 8 of the licence state
the disclaimer of warranty and limitation of liability. IBM does not endorse, sponsor or
certify Voiceour.
EOF
} > "$LICENSES"
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
