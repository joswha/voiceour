#!/usr/bin/env bash
set -euo pipefail

PIN=592feef04a1802b18cbeffd0fd0eb5d02570c2ec
# Local-only: LICENSE, NOTICE.md, patches/, ggml/embed/, and ggml/include/module.modulemap.
MANIFEST=(
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
readonly PIN MANIFEST
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VENDOR_ROOT="$REPO_ROOT/Vendor/parakeet"

usage() {
    echo "usage: $0 <upstream-checkout> [--check]" >&2
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

[[ $# -ge 1 && $# -le 2 ]] || usage
UPSTREAM=$1
MODE=${2:-}
[[ -z "$MODE" || "$MODE" == '--check' ]] || usage
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

if [[ "$MODE" == '--check' ]]; then
    TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/voiceour-vendor-check.XXXXXX")
    trap 'rm -rf "$TEMP_ROOT"' EXIT

    copy_manifest "$UPSTREAM" "$TEMP_ROOT"
    apply_patches "$TEMP_ROOT"

    drift=0
    for relative in "${MANIFEST[@]}"; do
        if ! cmp -s "$TEMP_ROOT/$relative" "$VENDOR_ROOT/$relative"; then
            echo "[vendor] drift: $relative" >&2
            diff -u "$TEMP_ROOT/$relative" "$VENDOR_ROOT/$relative" || true
            drift=1
        fi
    done

    if ((drift != 0)); then
        echo "error: vendored upstream files contain unexplained drift" >&2
        exit 1
    fi

    echo "[vendor] check passed: ${#MANIFEST[@]} manifest files match $PIN"
    exit 0
fi

copy_manifest "$UPSTREAM" "$VENDOR_ROOT"
apply_patches "$VENDOR_ROOT"
"$VENDOR_ROOT/ggml/embed/regenerate.sh"
echo "[vendor] refreshed ${#MANIFEST[@]} manifest files from $PIN"
