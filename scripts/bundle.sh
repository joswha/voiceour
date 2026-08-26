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

# MIT requires the ggml copyright and permission notice to accompany every copy of the
# software, and a user who is handed only a zipped .app receives no file from the source
# tree. So the notice is assembled into the bundle itself. The licence body is read out of
# Vendor/parakeet/LICENSE rather than inlined here: a second copy of a licence text is a
# copy that silently goes stale the next time the vendor pin moves. The pins are extracted
# from Package.swift and Sources/VoiceCore/ASRProtocol.swift for the same reason, the same
# discipline scripts/check_docs.sh applies to the model pin. Nothing here varies between
# runs, so repeated builds produce byte-identical output.
LICENSES="$APP/Contents/Resources/THIRD-PARTY-LICENSES.txt"
VENDOR="$ROOT/Vendor/parakeet"
ggml_commit=$(sed -n 's/^ *("GGML_COMMIT", "\\"\([0-9a-f]*\)\\"").*/\1/p' "$ROOT/Package.swift")
model_id=$(sed -n '/^public enum ASRModelContract/,/^}/s/.*modelId = "\(.*\)"/\1/p' "$ROOT/Sources/VoiceCore/ASRProtocol.swift")
model_revision=$(sed -n '/^public enum ASRModelContract/,/^}/s/.*revision = "\(.*\)"/\1/p' "$ROOT/Sources/VoiceCore/ASRProtocol.swift")
for pin in "$ggml_commit" "$model_id" "$model_revision"; do
  [ -n "$pin" ] || {
    printf '%s\n' "bundle.sh: could not extract a pin for $LICENSES" >&2
    exit 1
  }
done
[ -s "$VENDOR/LICENSE" ] || {
  printf '%s\n' "bundle.sh: missing $VENDOR/LICENSE" >&2
  exit 1
}

# Every third-party copyright inside the vendored tree that the verbatim LICENSE above does
# not itself name. Swept rather than listed, so a re-vendor that pulls in new attributed
# code carries it into the bundle instead of leaving this notice quietly incomplete. LICENSE
# is excluded because it is reproduced in full; NOTICE.md and patches/ never compile.
# The sort makes the result independent of xargs batching.
vendor_attributions=$(
  LC_ALL=C find "$VENDOR" -type f \
    ! -path "$VENDOR/LICENSE" \
    ! -path "$VENDOR/NOTICE.md" \
    ! -path "$VENDOR/patches/*" \
    -print0 |
    LC_ALL=C xargs -0 grep -I -h -e 'Copyright (c)' -e 'Copyright (C)' |
    LC_ALL=C sed -e 's|^[[:space:]]*//[[:space:]]*||' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    LC_ALL=C sort -u
)

{
  cat <<EOF
Voiceour third-party licences

Voiceour itself is MIT licensed; its LICENSE accompanies the source repository. This file
carries the notices of the third-party code compiled into this bundle, and of the speech
model the app downloads at runtime.


================================================================================
parakeet.cpp and ggml -- MIT
================================================================================

The voiceour-asr sidecar in Contents/MacOS links parakeet.cpp and ggml, vendored from
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
Speech model weights -- CC BY 4.0
================================================================================

No model weights are contained in this bundle or in the Voiceour source repository. On
first use the app downloads one GGUF conversion of NVIDIA's Parakeet TDT 0.6B v3 speech
recognition checkpoint into a local cache, and that download is the only network access
the app makes. The weights are not Voiceour's work and are not MIT licensed:

    Model:        NVIDIA Parakeet TDT 0.6B v3
    Creator:      NVIDIA Corporation
    Licence:      Creative Commons Attribution 4.0 International (CC BY 4.0)
                  https://creativecommons.org/licenses/by/4.0/
    Upstream:     https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
    Conversion:   https://huggingface.co/$model_id
                  revision $model_revision

CC BY 4.0 permits use, redistribution and commercial use with attribution. The conversion
repository above is labelled MIT on Hugging Face; a re-publisher cannot relicense someone
else's weights, so the governing terms remain NVIDIA's CC BY 4.0.
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
