# encoder-candle

Benchmark-only (bet B4a) rewrite of the FastConformer encoder of the pinned
`ggml-parakeet-tdt-0.6b-v3-f16.bin` on candle 0.11.0 with the Metal backend. It computes what
`parakeet_build_graph_encode` (`Vendor/parakeet/src/parakeet.cpp` L3520–L4116) computes for this
checkpoint. Nothing in the app depends on it.

## Build and run

`vendor/` is untracked and `Cargo.toml` patches `candle-metal-kernels` to `vendor/candle-metal-kernels`,
so on a clean checkout `cargo build` fails until `patches/vendor-candle-metal-kernels.sh` has run once
(see "Metal toolchain"). The script reads the crate from cargo's cache and fails if the cache lacks it,
unless it is called with `--fetch`, which downloads it.

```sh
cd bench/rust/encoder-candle
patches/vendor-candle-metal-kernels.sh   # once per clean checkout; add --fetch if cargo's cache lacks the crate
cargo build --release   # target/release/libencoder_candle.dylib + target/release/encoder-bench
# numerics of every row against the native Metal states (pass 0 only):
./target/release/encoder-bench --dumps ../../../.build/rust-bench/dumps --arms f32,f16w+fused \
  --passes 0 --output ../../../.build/rust-bench/b4a/numerics.jsonl
# timing rows (bet B4, arms candle:<arm>), pass 0 = warmup:
./target/release/encoder-bench --dumps ../../../.build/rust-bench/dumps/general96 --arms f16w,f16w+fused \
  --passes 2 --limit 4 --output ../../../.build/rust-bench/b4a/smoke-timing.jsonl
# states in the dump layout for transcript checks: <dir>/<arm>/<corpus>/<n>.enc.f32 + index.jsonl
./target/release/encoder-bench ... --write-states ../../../.build/rust-bench/b4a/states
# serialized per-stage attribution (syncs after every stage; no timing rows):
./target/release/encoder-bench --dumps ../../../.build/rust-bench/dumps/general96 --arms f16w+fused --profile-ops 1
```

`--dumps` takes a corpus directory or its parent. Within a pass the rows follow a seeded
permutation, and the arms alternate forward and reverse order per row. `elapsed_us` is one
`Encoder::encode` call, which is the body of `ve_encode`: host mel in, host states out, synchronized.
Each row also carries `err {max_abs, rel_l2, min_cos}` against the dump's `<n>.enc.f32`, plus
`output_sha256`. `equal_ref` is null. The run also writes `<output>.summary.json`, with one
aggregate per (arm, corpus).

## C ABI (`ve_`, program contract)

`ve_abi_version()` returns 1. `ve_arms()` returns the list below. `ve_engine_new(model_path, arm,
err, err_len)` creates an engine. `ve_encode(engine, mel, n_mel_frames, n_mels, out, max_enc_frames,
n_state, err, err_len)` returns `ceil(n_mel_frames/8)`, or -1 on error. `ve_engine_free` releases
the engine. No panic crosses the boundary. The engine rejects these inputs instead of computing
them:

- `n_mels != 128` or `n_state != 1024`;
- an output that is too small;
- `T_enc > 8192`, which is native's local-attention branch;
- the bias, speaker-kernel and conv-LayerNorm variants.

## Arms

| arm | activations | matrices | matmul kernel |
|---|---|---|---|
| `f32` | f32 | f16 widened to f32 at load (2.4 GB) | MLX steel gemm f32 |
| `f16` | f16 | f16 | MLX gemm f16 (float accumulation, f16 output) |
| `bf16` | bf16 | f16 rounded to bf16 | MLX gemm bf16 |
| `f16w` | f32 | f16 as stored (1.2 GB), `QTensor` | candle's port of ggml `kernel_mul_mm_f16_f32` (f32 output) |
| `q8_0` | f32 | requantized at load with `parakeet_model::quantize_row_q8_0` | candle `kernel_mul_mm_q8_0_f32` |

The `+fused` suffix selects the op set, not a precision:

- Stock arms use candle's ops, plus the three custom kernels candle lacks: conv.0, the stride-2
  depthwise 3×3 and the k=9 depthwise conv.
- `+fused` arms also run five more custom kernels:
  - residual add + LayerNorm (`add_ln`);
  - the Q/K/V split with `pos_bias_u/v` and the score scale;
  - the relative shift as a gather;
  - GLU + depthwise + BatchNorm + SiLU in one kernel;
  - steel attention writing its output frame-major directly.

Per layer that is about 37 dispatches for stock arms and 23 for `+fused` arms. Weights stay
resident. candle's pool reuses the buffers. Each encode synchronizes once, at readback.

## What it computes

- **Subsampling.**
  - conv.0 (custom kernel) rounds every mel value to half, as `ggml_im2col` does with its f16
    destination. Its weights stay f32 and it accumulates in float, then adds the bias and applies
    ReLU.
  - The depthwise stride-2 convolutions run in f32.
  - The 1×1 convolutions are `W[256][256]·X[256][S]` plus bias and ReLU.
  - The flatten produces `[T][C][F]`, so the input index is `c·16+f`. Then comes `out` plus bias.
- **Positional encoding.** `freq[k]` is computed on the host exactly as at L4224. `θ = freq·(T−1−p)`,
  `sin` and `cos` run on the device and are interleaved as `[2k]=sin`, `[2k+1]=cos`. Every Metal
  library of this engine, candle's and ours, is compiled with fast math (see "Metal toolchain").
- **Self-attention.**
  - Q, K and V are one `[3072,1024]` matmul.
  - Content and position scores come from the MLX steel attention kernel. The additive mask is
    `shift((Q+v)·P)·scale`. The shift replicates the math: `mask[h][q][k] = bd[h][q][T−1+k−q]`,
    which is relative distance `q−k`. It does not replicate the view trick of patches 0004–0006.
  - The attention mask is all zero for `T = n_len`, so it is omitted.
- **Conv module.** BatchNorm is applied at graph time, as in native: `(x−mean)/sqrt(var)·γ+β`, with no
  eps and not folded. `sqrt(var)` is precomputed on the host, where native runs `ggml_sqrt` per call.
- **LayerNorm.** Follows `ggml_norm` semantics: mean, variance of `x−mean`, eps 1e-5.
- **Block order.** `x += ½FFN1`, then `x += MHSA`, then `x += Conv`, then `x += ½FFN2`, then
  `LN_out`.

**Why the result is not bit-identical.** ggml-metal's `mul_mm` stages both operands to half, even
for the f32×f32 attention products. Our f32 arms keep f32 activations. Observed: `f32` and `f16w`
produce identical `output_sha256` on all 680 rows (checked with the stock op set). The same holds
for the `+fused` pair. Both kernels accumulate 8×8 simdgroup tiles in the same K order.

## candle 0.11.0 findings

- `QMetalStorage::fwd` (the mm path) rebuilds the input layout from the shape. It therefore reads a
  view that does not start at offset 0 from offset 0. The bug showed up as rel_l2 ≈ 1.4 on
  `f16w+fused` before the fix. Workaround: `Linear::fwd` forces an offset-0 copy, and `add_ln`
  puts its LayerNorm output first.
- `candle_nn::ops::sdpa` passes the mask buffer without the mask's start offset. Every mask here
  starts at offset 0.
- `candle-metal-kernels` and `objc2-metal` are named directly, at the exact versions candle-core
  0.11.0 already depends on. `Cargo.lock` still has 196 packages. They are needed only to compile
  and dispatch the custom kernels and to call steel attention with explicit strides.
  `candle-metal-kernels` resolves to the patched copy in `vendor/` (next section), so its
  `Cargo.lock` entry has no registry `source` or `checksum`.

## Metal toolchain

**Requirements.** macOS 15 or later (the pinned language version 3.2 and the math-mode API are
macOS 15; the measured host is macOS 27.0.1 / 26A434, Apple M4 Pro), stable Rust 1.97, and the
macOS tools `patch`, `tar` and `shasum` for the bootstrap script. The `metal` command-line compiler
is needed only for check 1 below.

**Observed failure.** In `.build/rust-bench/official/20261016-run2/b4.general96.jsonl`, all 308
`rust:candle:f16w+fused` rows and all 308 `rust:candle:f16+fused` rows, run through the Swift
harness `voiceour-bench`, have `work.error` (`elapsed_us` null). The logged text (truncated to 2047
characters) is a Metal compile error in candle-metal-kernels' `mlx_gemm.metal`, not in
`kernels.metal`: `BlockMMA<float, float, 32, 32, 16, 2, 2, false, false, 20, 36>` "must explicitly
initialize the member 'Asimd'" (also `Bsimd`, `results`), at lines 302–318 and 1180 of that file.
The harness records that text from `ve_encode`'s error buffer (`EncoderBenchCommand.swift`
L264–265), so the engine was created, including the compile of `kernels.metal`, and the failure came
with the encode, where candle first loads its gemm library. The `mlx:*` arms and the native arms of
the same run have no errors.

**Same source, same OS, different host binary.** The standalone `encoder-bench` compiled the same
candle source on the same machine and OS: `.build/rust-bench/b4a/numerics-{stock,fused}.jsonl` hold
680 rows for each of `f32`, `f16w`, `f16`, `bf16`, `q8_0`, each with and without `+fused`, started
2026-10-16T21:26Z–21:31Z (OS 27.0.1, 26A434). The host binaries differ in `LC_BUILD_VERSION`
(`otool -l`): `encoder-bench` and `libencoder_candle.dylib` have `minos 11.0 sdk 27.0`;
`.build/release/voiceour-bench` has `minos 27.0 sdk 27.0` (`Package.swift`: `.macOS(.v27)`). candle
0.11.0 (`kernel.rs`, `get_compile_options`) creates its `MTLCompileOptions` without a
`languageVersion`, so the language version of every library it compiles is whatever Metal picks as
the default for the host process. The Metal toolchain header the compiler reports
(`metal_simdgroup_matrix`, GPUCompiler 32023) declares the `thread`-qualified constructors
unconditionally; it does not branch on language version.

**[INFERENCE]** The default language version follows the host binary (its deployment target), and
the macOS 27 host's default rejects `BlockMMA`'s `simdgroup_matrix` members. Not observed: neither
process printed its default `languageVersion`, and Apple's documentation says only "by default,
Metal uses the most recent language version", which alone would not explain the standalone success.
What is observed is that the outcome depends on the host binary.

**Fix (unverified until the parent's smoke).** Every Metal library of this engine is compiled with
an explicit language version, **3.2** (macOS 15, the release candle 0.11.0's sources and its
`available!(macos = 15)` math-mode branch target):

- candle's libraries, through `patches/candle-metal-kernels-0.11.0-msl-language-version.patch`
  (3 hunks in `src/kernel.rs`) applied to the crates.io crate by
  `patches/vendor-candle-metal-kernels.sh`. The script requires the `.crate` sha256
  `242e83c6…213d3e` (the `Cargo.lock` checksum), applies the patch with no fuzz, and requires the
  patched `src/kernel.rs` to hash to `980b76c0…74d70b`. It stops on any mismatch and does not touch
  `~/.cargo`. The network is used only with `--fetch`.
- `kernels.metal`, in `Kernels::new` (`src/kernels.rs`), which also sets fast math explicitly
  (`setFastMathEnabled(true)`: math mode and floating-point functions both fast). It was compiled
  with default options before. Apple documents the default math mode as depending on the language
  version, so this pins what the earlier standalone numerics may have taken from the default.

`CANDLE_METAL_LANGUAGE_VERSION=3.0|3.1|3.2|4.0` overrides the version for both, with no rebuild.
Any other value is an error.

**Checks to run (not run by the author of this change).**

```sh
# 1. Does the source compile, per language version? (needs the Metal toolchain component)
for std in metal3.1 metal3.2 metal4.0; do
  xcrun -sdk macosx metal -std=$std -fsyntax-only vendor/candle-metal-kernels/src/metal_src/mlx_gemm.metal \
    && echo "$std ok"
done
# 2. Standalone, per language version (the arms f16w+fused and f16+fused load the gemm library);
#    which versions fail says whether the language version alone decides the outcome.
for v in 3.2 4.0; do
  CANDLE_METAL_LANGUAGE_VERSION=$v ./target/release/encoder-bench --dumps ../../../.build/rust-bench/dumps/general96 \
    --arms f16w+fused,f16+fused --passes 0 --limit 2 --output ../../../.build/rust-bench/b4a/msl-$v.jsonl
done
# 3. The failing path, from the repository root:
.build/release/voiceour-bench encoder-bench --dumps .build/rust-bench/dumps/jargon456 --output UNIQUE --passes 1 --limit 2 \
  --rust-encoder-lib bench/rust/encoder-candle/target/release/libencoder_candle.dylib,bench/rust/encoder-mlx/target/release/libencoder_mlx.dylib \
  --rust-arms candle:f16w+fused,candle:f16+fused,mlx:f16
```

The numerics and timing results below were produced before the options were pinned. Compare
`output_sha256` of the same rows and arms against `numerics-fused.jsonl`: equal hashes mean the
pinned options did not change the kernels' output; unequal hashes mean the earlier default differed
in language version or math mode, and the numerics tables need re-running.

## Results (observed in this worktree; machine shared, load average ≈ 10–14)

### Numerics vs the native Metal encoder states, all 680 rows (`--passes 0`)

Logs: `.build/rust-bench/b4a/numerics-{stock,fused}.{jsonl,log,summary.json}`.

| arm | corpus | rel_l2 median | p95 | max | max_abs | min per-frame cos | rows > 1e-2 |
|---|---|---|---|---|---|---|---|
| f32 = f16w | general96 | 1.13e-3 | 3.69e-3 | 1.67e-2 | 1.03e-2 | 0.99358 | 1 |
| f32 = f16w | jargon456 | 7.11e-4 | 2.91e-3 | 4.64e-2 | 2.06e-2 | 0.96470 | 4 |
| f32 = f16w | librispeech128 | 9.63e-4 | 3.52e-3 | 6.75e-3 | 9.17e-3 | 0.99390 | 0 |
| f32/f16w +fused | general96 / jargon456 / librispeech128 | 1.13e-3 / 7.11e-4 / 9.63e-4 | 3.70e-3 / 2.92e-3 / 3.52e-3 | 1.67e-2 / 4.64e-2 / 6.75e-3 | 1.03e-2 / 2.06e-2 / 9.17e-3 | 0.99359 / 0.96470 / 0.99390 | 5 (each arm) |
| f16 | general96 / jargon456 / librispeech128 | 2.37e-3 / 1.81e-3 / 2.23e-3 | 1.05e-2 / 8.12e-3 / 5.46e-3 | 2.35e-2 / 5.59e-2 / 1.67e-2 | 3.16e-2 max | 0.9308 min | 25 |
| f16+fused | general96 / jargon456 / librispeech128 | 1.74e-3 / 1.38e-3 / 1.68e-3 | 4.38e-3 / 5.63e-3 / 4.88e-3 | 5.00e-2 / 3.95e-2 / 1.37e-2 | 4.26e-2 max | 0.9494 min | 10 |
| bf16 / bf16+fused | all | 1.2e-2 – 2.2e-2 | ≤ 6.3e-2 | ≤ 2.5e-1 | ≤ 1.5e-1 | 0.25 min | 680 / 668 |
| q8_0 / q8_0+fused | all | 1.24e-2 – 1.77e-2 | ≤ 4.1e-2 | 2.17e-1 | 9.97e-2 | 0.30 min | 680 / 680 |

What the table shows:

- `f32` and `f16w` are faithful: the per-corpus median rel_l2 is 7e-4 to 1.1e-3, and 675 of 680
  rows stay below 1e-2.
- The 5 outliers are scattered and are not short rows. Rows with T_enc < 64 have a median of 7.1e-4,
  against 9.6e-4 for T_enc ≥ 64. The worst is `jg_0433_negative_we_shared_a_bowl_of_soup_beside_`,
  with T_enc 36, rel_l2 4.6e-2 and min cos 0.965. The others are `fleurs-en_us-test-000031`,
  `jg_0344_dataweb_vue`, `jg_0054_cloud_control_plane` and `jg_0069_cloud_nomad`.
- [INFERENCE] The outliers come from native's half staging amplified through 24 layers on those
  inputs. No CPU-encoder oracle was available to confirm this.
- `bf16` and `q8_0` fail the 1e-2 bar on every row. [INFERENCE] The cause is the format: bf16 has an
  8-bit mantissa, and q8_0 quantizes the weights. These failures are not wiring bugs, because the
  same graph code is faithful at f32. The q8_0 kernel was not checked in isolation.

### Development timing smoke (not official)

The smoke covered general96 rows 1–4 with 2 timed passes after the warmup, about 27 s wall.

| arm | median per row | µs per audio second |
|---|---|---|
| `f16w` | 101.8 ms | 10,801 |
| `f16w+fused` | 77.8 ms | 7,919 |

- On `fleurs-en_us-test-000001` (10.56 s audio, 133 frames), `f16w+fused` took 46.3, 48.1 and
  46.9 ms in passes 0, 1 and 2.
- The same row in passes 1 and 2 took 98–134 ms on other rows of this run, so it is very noisy.
- The dispatch's native smoke stage profile for that row was 48.6 ms.
- The first encode after load took 3.89 s, which is pipeline compilation.
- Loading takes 3–22 s, depending on machine load.
- Two earlier smoke attempts that loaded 3 to 5 precisions did not finish within 55–120 s, because
  loading is slow under load. They produced no rows.

### Where candle's time goes

This is the serialized `--profile-ops 1` profile on fleurs 000001. Every stage includes a device
sync of about 0.15–0.3 ms, so small elementwise stages are mostly sync latency.

- **`f16w+fused`** (157.5 ms staged). Matmuls take 93 ms, 59% of the total:
  - FFN up 26.2 ms, FFN down 20.1 ms;
  - `linear_pos` on 2T−1 rows 11.6 ms;
  - QKV 9.1 ms;
  - conv pw1 8.0 ms, pw2 6.5 ms;
  - out 6.0 ms;
  - position scores 5.5 ms.

  The rest:
  - `add_ln` 18.2 ms over 96 calls;
  - SiLU 12.7 ms;
  - steel attention 5.6 ms;
  - rel_shift 4.0 ms;
  - the fused conv chain 5.0 ms;
  - subsampling about 7 ms.
- **`f16w` stock** (308 ms staged). Matmuls take 129 ms, 42%. LayerNorm (34 ms), residual adds
  (25 ms), BatchNorm as 4 broadcast ops (24 ms), SiLU (28 ms), the GLU (11 ms), the bias/split
  ops (14 ms) and the head merge (7 ms) are dispatch-bound.

The fused op set removes about 14 dispatches per layer. That is the measured 24% median gain in
the smoke. Metal System Trace (`xctrace`) was not run.
