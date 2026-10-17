#!/bin/sh
# Materialise bench/rust/encoder-candle/vendor/candle-metal-kernels: the crates.io crate
# candle-metal-kernels 0.11.0 plus patches/candle-metal-kernels-0.11.0-msl-language-version.patch.
# Cargo.toml's `[patch.crates-io]` points at that directory, so run this once on a clean checkout
# before `cargo build`. vendor/ is untracked (see ../.gitignore).
#
# It fails closed. The input must be a .crate file whose sha256 is the one pinned below (the
# checksum Cargo.lock recorded for the crate), the patch must apply with no fuzz, and the patched
# src/kernel.rs must hash to the pinned value. It only reads ~/.cargo (the crate cache and the
# registry config) and never writes there. The network is used only with --fetch, which runs
# `cargo fetch` on a throwaway project requiring exactly `candle-metal-kernels = "=0.11.0"` in a
# scratch CARGO_HOME that holds a copy of the registry config; the digest check still applies.
#
#   patches/vendor-candle-metal-kernels.sh            use the .crate already in cargo's cache
#   patches/vendor-candle-metal-kernels.sh --fetch    download it first with `cargo fetch` (network)
#   patches/vendor-candle-metal-kernels.sh --crate P  use the .crate file at P
set -eu

version=0.11.0
crate_sha256=242e83c6acf639bb273c929d73c67a882bb4dd08a140f121096e19ba2f213d3e
patched_kernel_sha256=980b76c0212b16e7724c7dd4f7aeb7598041c166106ccd7c379a277b1374d70b

here=$(cd "$(dirname "$0")/.." && pwd)
patch_file="$here/patches/candle-metal-kernels-$version-msl-language-version.patch"
dest="$here/vendor/candle-metal-kernels"
name="candle-metal-kernels-$version"

die() {
    echo "vendor-candle-metal-kernels: $*" >&2
    exit 1
}

sha256() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

fetch=0
crate_override=
while [ $# -gt 0 ]; do
    case $1 in
        --fetch) fetch=1 ;;
        --crate)
            [ $# -ge 2 ] || die "--crate needs a path"
            crate_override=$2
            shift
            ;;
        *) die "usage: $0 [--fetch] [--crate FILE.crate]" ;;
    esac
    shift
done

[ -f "$patch_file" ] || die "missing $patch_file"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

crate=
mismatched=

# Sets `crate` to the first candidate whose digest matches; records the ones that do not.
pick_crate() {
    for candidate in "$@"; do
        [ -f "$candidate" ] || continue
        if [ "$(sha256 "$candidate")" = "$crate_sha256" ]; then
            crate=$candidate
            return 0
        fi
        mismatched="$mismatched $candidate"
    done
    return 0
}

cargo_home=${CARGO_HOME:-$HOME/.cargo}

# Look for the .crate in the registry cache under the cargo home given as $1.
cache_candidates() {
    pick_crate "$1"/registry/cache/*/"$name.crate"
}

if [ -n "$crate_override" ]; then
    pick_crate "$crate_override"
else
    cache_candidates "$cargo_home"
    if [ -z "$crate" ] && [ "$fetch" = 1 ]; then
        echo "vendor-candle-metal-kernels: --fetch: cargo fetch (network, registry per $cargo_home/config.toml) for $name" >&2
        scratch_home="$stage/cargo-home"
        mkdir -p "$scratch_home" "$stage/probe/src"
        for config in config.toml config; do
            [ ! -f "$cargo_home/$config" ] || cp "$cargo_home/$config" "$scratch_home/$config"
        done
        : > "$stage/probe/src/lib.rs"
        cat > "$stage/probe/Cargo.toml" <<EOF
[package]
name = "probe"
version = "0.0.0"
edition = "2021"

[dependencies]
candle-metal-kernels = "=$version"

[workspace]
EOF
        (cd "$stage/probe" && CARGO_HOME="$scratch_home" cargo fetch)
        cache_candidates "$scratch_home"
    fi
fi

if [ -z "$crate" ]; then
    [ -z "$mismatched" ] || die "digest mismatch (want $crate_sha256) for:$mismatched"
    die "no $name.crate found in $cargo_home/registry/cache; rerun with --fetch, or --crate FILE"
fi

echo "vendor-candle-metal-kernels: using $crate (sha256 $crate_sha256)" >&2

mkdir "$stage/src"
tar -xzf "$crate" -C "$stage/src"
[ -d "$stage/src/$name" ] || die "$crate does not contain $name/"

patch -p1 -F0 -N -s -d "$stage/src/$name" -i "$patch_file" || die "patch did not apply cleanly"
if [ -n "$(find "$stage/src/$name" -name '*.rej' -print)" ]; then
    die "patch left .rej files"
fi
rm -f "$stage/src/$name/src/kernel.rs.orig"
[ "$(sha256 "$stage/src/$name/src/kernel.rs")" = "$patched_kernel_sha256" ] ||
    die "patched src/kernel.rs digest differs from the pinned $patched_kernel_sha256"

mkdir -p "$here/vendor"
rm -rf "$dest"
mv "$stage/src/$name" "$dest"
echo "vendor-candle-metal-kernels: wrote $dest" >&2
