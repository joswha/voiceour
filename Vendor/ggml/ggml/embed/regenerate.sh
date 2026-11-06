#!/usr/bin/env bash
# Regenerate the embedded Metal library source for the SwiftPM CGgml target.
#
# Upstream builds this file inside CMake (ggml/src/ggml-metal/CMakeLists.txt:37-56).
# SwiftPM has no code-generation step, so the merged shader source is committed and
# this script reproduces it byte for byte with the same two sed invocations.
#
# Run it after every re-vendor of ggml-metal.metal, ggml-metal-impl.h or ggml-common.h.
set -euo pipefail

EMBED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METAL_DIR="$EMBED_DIR/../src/ggml-metal"
COMMON_H="$EMBED_DIR/../src/ggml-common.h"

TMP="$EMBED_DIR/ggml-metal-embed.metal.tmp"
OUT="$EMBED_DIR/ggml-metal-embed.metal"

sed -e "/__embed_ggml-common.h__/r $COMMON_H" \
    -e "/__embed_ggml-common.h__/d" \
    < "$METAL_DIR/ggml-metal.metal" > "$TMP"

sed -e "/#include \"ggml-metal-impl.h\"/r $METAL_DIR/ggml-metal-impl.h" \
    -e "/#include \"ggml-metal-impl.h\"/d" \
    < "$TMP" > "$OUT"

rm -f "$TMP"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
