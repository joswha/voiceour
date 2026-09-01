#!/usr/bin/env bash
set -euo pipefail

PIN=592feef04a1802b18cbeffd0fd0eb5d02570c2ec
# Every upstream-derived file shipped under Vendor/parakeet.
MANIFEST=(
    'LICENSE'
    'ggml/include/ggml-alloc.h'
    'ggml/include/ggml-backend.h'
    'ggml/include/ggml-blas.h'
    'ggml/include/ggml-cpp.h'
    'ggml/include/ggml-cpu.h'
    'ggml/include/ggml-metal.h'
    'ggml/include/ggml-opt.h'
    'ggml/include/ggml.h'
    'ggml/include/gguf.h'
    'ggml/src/ggml-alloc.c'
    'ggml/src/ggml-backend-dl.cpp'
    'ggml/src/ggml-backend-dl.h'
    'ggml/src/ggml-backend-impl.h'
    'ggml/src/ggml-backend-meta.cpp'
    'ggml/src/ggml-backend-reg.cpp'
    'ggml/src/ggml-backend.cpp'
    'ggml/src/ggml-blas/ggml-blas.cpp'
    'ggml/src/ggml-common.h'
    'ggml/src/ggml-cpu/amx/amx.cpp'
    'ggml/src/ggml-cpu/amx/amx.h'
    'ggml/src/ggml-cpu/amx/mmq.cpp'
    'ggml/src/ggml-cpu/amx/mmq.h'
    'ggml/src/ggml-cpu/arch-fallback.h'
    'ggml/src/ggml-cpu/arch/arm/quants.c'
    'ggml/src/ggml-cpu/arch/arm/repack.cpp'
    'ggml/src/ggml-cpu/binary-ops.cpp'
    'ggml/src/ggml-cpu/binary-ops.h'
    'ggml/src/ggml-cpu/common.h'
    'ggml/src/ggml-cpu/ggml-cpu-impl.h'
    'ggml/src/ggml-cpu/ggml-cpu.c'
    'ggml/src/ggml-cpu/ggml-cpu.cpp'
    'ggml/src/ggml-cpu/hbm.cpp'
    'ggml/src/ggml-cpu/hbm.h'
    'ggml/src/ggml-cpu/ops.cpp'
    'ggml/src/ggml-cpu/ops.h'
    'ggml/src/ggml-cpu/quants.c'
    'ggml/src/ggml-cpu/quants.h'
    'ggml/src/ggml-cpu/repack.cpp'
    'ggml/src/ggml-cpu/repack.h'
    'ggml/src/ggml-cpu/simd-gemm.h'
    'ggml/src/ggml-cpu/simd-mappings.h'
    'ggml/src/ggml-cpu/traits.cpp'
    'ggml/src/ggml-cpu/traits.h'
    'ggml/src/ggml-cpu/unary-ops.cpp'
    'ggml/src/ggml-cpu/unary-ops.h'
    'ggml/src/ggml-cpu/vec.cpp'
    'ggml/src/ggml-cpu/vec.h'
    'ggml/src/ggml-impl.h'
    'ggml/src/ggml-metal/ggml-metal-common.cpp'
    'ggml/src/ggml-metal/ggml-metal-common.h'
    'ggml/src/ggml-metal/ggml-metal-context.h'
    'ggml/src/ggml-metal/ggml-metal-context.m'
    'ggml/src/ggml-metal/ggml-metal-device.cpp'
    'ggml/src/ggml-metal/ggml-metal-device.h'
    'ggml/src/ggml-metal/ggml-metal-device.m'
    'ggml/src/ggml-metal/ggml-metal-impl.h'
    'ggml/src/ggml-metal/ggml-metal-ops.cpp'
    'ggml/src/ggml-metal/ggml-metal-ops.h'
    'ggml/src/ggml-metal/ggml-metal.cpp'
    'ggml/src/ggml-metal/ggml-metal.metal'
    'ggml/src/ggml-opt.cpp'
    'ggml/src/ggml-quants.c'
    'ggml/src/ggml-quants.h'
    'ggml/src/ggml-threading.cpp'
    'ggml/src/ggml-threading.h'
    'ggml/src/ggml.c'
    'ggml/src/ggml.cpp'
    'ggml/src/gguf.cpp'
    'include/parakeet.h'
    'src/parakeet-arch.h'
    'src/parakeet.cpp'
)
LOCAL_FILES=(
    'NOTICE.md'
    'patches/0001-tdt-duration-argmax-raw-logits.patch'
    'patches/0002-encoder-sched-reservation-high-water-mark.patch'
    'patches/0003-skip-graph-reorder-for-single-command-buffer-graphs.patch'
    'patches/0004-consume-rel-position-shift-as-strided-view.patch'
    'patches/0005-relative-position-matmul-operands-as-views.patch'
    'patches/0006-fold-rel-position-roll-into-view-offset.patch'
    'patches/0007-one-graph-per-decode-step.patch'
    'patches/0008-conv-subsampling-bias-add-materialises-layout.patch'
    'patches/0009-pointwise-conv-needs-no-im2col.patch'
    'patches/0010-poll-command-buffer-before-blocking.patch'
    'patches/0011-merge-conv-module-right-pads.patch'
    'patches/0012-three-encode-threads.patch'
    'patches/0013-file-backed-weight-arena.patch'
    'patches/0014-greedy-decode-step-callback.patch'
    'patches/0015-record-authoritative-loader.patch'
    'patches/0016-external-encoder-seam.patch'
    'patches/0017-cpu-tail-backend.patch'
    'patches/0018-persistent-cpu-threadpool.patch'
    'patches/0019-tail-q8-load-repack.patch'
    'patches/0020-bias-variant-conformer-support.patch'
    'patches/0021-plain-rnnt-decoder-support.patch'
    'ggml/include/module.modulemap'
    'ggml/embed/ggml-metal-embed.metal'
    'ggml/embed/ggml-metal-embed.c'
    'ggml/embed/regenerate.sh'
)
readonly PIN MANIFEST LOCAL_FILES
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VENDOR_ROOT="$REPO_ROOT/Vendor/parakeet"

usage() {
    echo "usage: $0 --check | $0 <upstream-checkout> [--check]" >&2
    exit 64
}

copy_manifest() {
    local source_root=$1
    local destination_root=$2
    local relative

    for relative in "${MANIFEST[@]}"; do
        if [[ ! -f "$source_root/$relative" ]]; then
            echo "error: manifest source is missing: $relative" >&2
            return 1
        fi
        mkdir -p "$destination_root/$(dirname -- "$relative")"
        cp "$source_root/$relative" "$destination_root/$relative"
    done
}

apply_patches() {
    local destination_root=$1
    local patch
    local patches=("$VENDOR_ROOT"/patches/*.patch)

    if [[ ! -e "${patches[0]}" ]]; then
        echo "error: no patch files found under Vendor/parakeet/patches" >&2
        return 1
    fi

    for patch in "${patches[@]}"; do
        echo "[vendor] applying $(basename -- "$patch")"
        if [[ "$destination_root" == "$VENDOR_ROOT" ]]; then
            git -C "$REPO_ROOT" apply --check --directory=Vendor/parakeet "$patch"
            git -C "$REPO_ROOT" apply --directory=Vendor/parakeet "$patch"
        else
            (
                cd -- "$destination_root"
                git apply --check "$patch"
                git apply "$patch"
            )
        fi
    done
}

is_expected_file() {
    local relative=$1
    local expected

    for expected in "${MANIFEST[@]}" "${LOCAL_FILES[@]}"; do
        if [[ "$relative" == "$expected" ]]; then
            return 0
        fi
    done
    return 1
}

check_file_set() {
    local relative
    local expected
    local unexpected=0

    for expected in "${MANIFEST[@]}" "${LOCAL_FILES[@]}"; do
        if [[ ! -f "$VENDOR_ROOT/$expected" ]]; then
            echo "[vendor] missing: $expected" >&2
            unexpected=1
        fi
    done

    while IFS= read -r relative; do
        relative=${relative#"$VENDOR_ROOT/"}
        if ! is_expected_file "$relative"; then
            echo "[vendor] unexpected: $relative" >&2
            unexpected=1
        fi
    done < <(find "$VENDOR_ROOT" \( -type f -o -type l \) -print)

    if ((unexpected != 0)); then
        echo "error: Vendor/parakeet contains files outside the vendor manifest" >&2
        return 1
    fi
}

check_embed_reproducible() {
    local temp_root=$1
    local tool
    local regen_root="$temp_root/embed-check"
    local embed_relative='ggml/embed/ggml-metal-embed.metal'

    for tool in sed wc tr rm cmp cp mkdir; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "[vendor] embed regeneration skipped: required tool '$tool' is unavailable" >&2
            return 0
        fi
    done

    mkdir -p "$regen_root/ggml/embed" "$regen_root/ggml/src/ggml-metal"
    cp "$VENDOR_ROOT/ggml/embed/regenerate.sh" "$regen_root/ggml/embed/regenerate.sh"
    cp "$VENDOR_ROOT/ggml/src/ggml-common.h" "$regen_root/ggml/src/ggml-common.h"
    cp "$VENDOR_ROOT/ggml/src/ggml-metal/ggml-metal.metal" "$regen_root/ggml/src/ggml-metal/ggml-metal.metal"
    cp "$VENDOR_ROOT/ggml/src/ggml-metal/ggml-metal-impl.h" "$regen_root/ggml/src/ggml-metal/ggml-metal-impl.h"

    if ! "$regen_root/ggml/embed/regenerate.sh" >/dev/null; then
        echo "error: embedded Metal regeneration failed" >&2
        return 1
    fi
    if ! cmp -s "$regen_root/$embed_relative" "$VENDOR_ROOT/$embed_relative"; then
        echo "[vendor] drift: $embed_relative" >&2
        diff -u "$regen_root/$embed_relative" "$VENDOR_ROOT/$embed_relative" || true
        echo "error: committed embedded Metal source is not reproducible" >&2
        return 1
    fi
    echo "[vendor] embedded Metal source is byte-reproducible"
}

UPSTREAM=
MODE=
if [[ $# -eq 1 && "$1" == '--check' ]]; then
    MODE=--check
elif [[ $# -ge 1 && $# -le 2 ]]; then
    UPSTREAM=$1
    MODE=${2:-}
    [[ -z "$MODE" || "$MODE" == '--check' ]] || usage
else
    usage
fi

if [[ -n "$UPSTREAM" ]]; then
    [[ -d "$UPSTREAM" ]] || {
        echo "error: upstream checkout is not a directory: $UPSTREAM" >&2
        exit 1
    }
    UPSTREAM="$(cd -- "$UPSTREAM" && pwd)"

    ACTUAL_PIN=$(git -C "$UPSTREAM" rev-parse HEAD 2>/dev/null) || {
        echo "error: cannot read git HEAD from upstream checkout: $UPSTREAM" >&2
        exit 1
    }
    if [[ "$ACTUAL_PIN" != "$PIN" ]]; then
        echo "error: upstream checkout is at $ACTUAL_PIN; expected $PIN" >&2
        exit 1
    fi
    if ! git -C "$UPSTREAM" diff --quiet HEAD -- "${MANIFEST[@]}"; then
        echo "error: upstream checkout has modified manifest files; use a clean checkout at $PIN" >&2
        exit 1
    fi
fi

if [[ "$MODE" == '--check' ]]; then
    TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/voiceour-vendor-check.XXXXXX")
    trap 'rm -rf "$TEMP_ROOT"' EXIT
    drift=0

    if [[ -n "$UPSTREAM" ]]; then
        copy_manifest "$UPSTREAM" "$TEMP_ROOT"
        apply_patches "$TEMP_ROOT"
        for relative in "${MANIFEST[@]}"; do
            if ! cmp -s "$TEMP_ROOT/$relative" "$VENDOR_ROOT/$relative"; then
                echo "[vendor] drift: $relative" >&2
                diff -u "$TEMP_ROOT/$relative" "$VENDOR_ROOT/$relative" || true
                drift=1
            fi
        done
    fi

    check_file_set || drift=1
    check_embed_reproducible "$TEMP_ROOT" || drift=1
    if ((drift != 0)); then
        echo "error: vendored source check failed" >&2
        exit 1
    fi

    if [[ -n "$UPSTREAM" ]]; then
        echo "[vendor] check passed: ${#MANIFEST[@]} manifest files match $PIN; file set is exact"
    else
        echo "[vendor] check passed: file set is exact (upstream drift not checked without a checkout)"
    fi
    exit 0
fi

[[ -n "$UPSTREAM" ]] || usage
copy_manifest "$UPSTREAM" "$VENDOR_ROOT"
apply_patches "$VENDOR_ROOT"
"$VENDOR_ROOT/ggml/embed/regenerate.sh"
echo "[vendor] refreshed ${#MANIFEST[@]} manifest files from $PIN"
