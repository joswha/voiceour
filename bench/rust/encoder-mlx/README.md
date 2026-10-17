# encoder-mlx

Benchmark-only Rust port of the FastConformer encoder of the pinned parakeet-tdt-0.6b-v3 model
over MLX's Metal kernels (bet B4b of the Rust proof program). Nothing in the app depends on it.

It computes what `parakeet_build_graph_encode` (`Vendor/parakeet/src/parakeet.cpp` L3520–L4116)
computes for the pinned file. The pieces are the dw_striding subsampling, the in-graph sinusoidal
relative positional encoding, 24 conformer blocks and each block's output LayerNorm. A block is a
macaron FFN ×0.5, rel-pos MHSA with `pos_bias_u`/`pos_bias_v`, and the conv module (GLU,
depthwise k=9, BatchNorm without epsilon, SiLU). Weights come from `bench/rust/parakeet-model`
as `parakeet_model_load` holds them. The whole utterance is one lazy MLX graph with exactly one
`eval`.

## Build, run

```sh
cd bench/rust/encoder-mlx
cargo build --release        # target/release/libencoder_mlx.dylib + target/release/encoder-bench
./target/release/encoder-bench --dumps ../../../.build/rust-bench/dumps/general96 \
    --arms f32,f16,compiled-f16 --passes 3 --output ../../../.build/rust-bench/b4b-mlx/rows.jsonl \
    [--write-states <dir>] [--model <path>] [--limit N] [--seed S]
```

- **Dependencies**: `mlx-rs = "=0.32.0"`, which pulls in `mlx-sys 0.6.0`. Its bundled mlx-c fetches
  and builds MLX **v0.32.2**, commit `1f8e74e3f12f31365464a6867c6579f0e9b29d85`, with CMake. The
  fetch reaches `github.com` and `developer.apple.com` (metal-cpp). The commit was checked with
  `git -C target/release/build/mlx-sys-*/out/build/_deps/mlx-src log -1`.
- **Build time**: a clean build took 170 s on this machine. It needs `/opt/homebrew/bin/cmake`
  and Xcode's Metal toolchain.
- **Kernel library**: mlx-sys writes the compiled kernel library outside the repository, at
  `~/.mlx/lib/<mlx-c key>/mlx.metallib` (183 MB; the key here is `dd231f807774`). That path is
  compiled into the dylib, so set `MLX_RS_METAL_PATH` for the build to put it elsewhere.
- **Licenses**: MLX and mlx-rs are MIT / Apache-2.0.

## Arms (`ve_arms`)

| arm | weights | activations | matmul operands | attention | elementwise |
|---|---|---|---|---|---|
| `f32` | f16 widened exactly to f32 | f32 | f32 | manual | eager |
| `f16` | f16 as stored | f16 | f16 | `fast::scaled_dot_product_attention` | eager |
| `compiled-f32` | as `f32` | | | manual | `compile` (shapeless) |
| `compiled-f16` | as `f16` | | | SDPA | `compile` (shapeless) |
| `f32-mm16` | f32 | f32 | **rounded to f16 where ggml-metal rounds them** | manual | eager |
| `compiled-f32-mm16` | as `f32-mm16` | | | manual | `compile` |
| `f32-sdpa` | f32 | f32 | f32 | SDPA | eager |
| `f16-manual` | f16 | f16 | f16 | manual | eager |

- **`f32-mm16` (ggml-faithful)**: this arm reproduces ggml-metal's precision. The
  `kernel_mul_mm_{f16,f32}_f32` kernels stage both operands as `half` and accumulate in float
  (`ggml-metal.metal` L10760–L10763). ggml-metal-ops.cpp takes that path whenever
  `ne00 >= 64 && ne11 > 8` (L2436–L2440).
  - The arm therefore rounds to f16 the operands of every projection, the content and position
    score operands, `probs` and `V` (only when T ≥ 64; below that ggml uses the f32
    `kernel_mul_mv`) and `pos_emb`.
  - In the subsampling it rounds what ggml rounds: the mel (im2col to f16), the activations and
    the f32 weights of the two 1×1 convs, and the `out` input.
  - Products of two halves are exact in f32, so the arm differs from ggml only in summation order
    and in how exp, sigmoid, sin and cos are implemented.
- **SDPA arms**: the positional term goes in as the additive mask. It is
  `shift(((Q+v)·1/√128)·Pᵀ)`, a strided view that is never materialized. MLX's full-attention
  kernel accepts a mask whose last stride is 1 (`scaled_dot_product_attention.cpp` L801).
- **Compiled arms**: `compile` (shapeless, built once per engine) fuses six elementwise chains:
  SiLU, the ×0.5 residual, `(a+b)·s`, GLU, BatchNorm+SiLU and bias+ReLU. The F32Mm16 arms also
  fuse the f16 rounding into those chains. Matmuls, LayerNorm and softmax are MLX kernels in every
  arm.

## Mapping to the native graph

- **Subsampling**: in NHWC (H = time, W = freq), `conv2d(1→256, 3×3, s2, p1)` → ReLU →
  depthwise `conv2d(groups=256)` + b → 1×1 as `matmul` + b → ReLU → depthwise + b → 1×1 + b → ReLU.
  Then `[t, f, c] → [t, c·16+f]` (L3606–L3615) → `out`.
- **Positional encoding**:
  - The frequencies are `freq[k] = expf(-(float(2k)·logf(10000)/1024))`, built on the host with
    the native expression (L4217–L4228). The positions are `rel[p] = T−1−p`.
  - `theta = rel ⊗ freq` (f32), then sin and cos on the device, interleaved as `[2k] = sin`,
    `[2k+1] = cos`.
  - The 24 `linear_pos` projections run as one matmul against the stacked `[24·1024, 1024]`
    weights. Each output element is the same dot product as in the native per-layer matmuls.
- **rel_shift** (the math of patches 0004–0006): `score[h][q][k]` takes column `T−1+k−q` of the
  `[H, T, 2T−1]` positional scores, which is relative distance `q−k`. It is an `as_strided` view
  of the matmul output with shape `[H, T, T]`, strides `[T(2T−1), 2T−2, 1]` and offset `T−1`.
- **Attention (manual)**: `softmax(((Q+u)·Kᵀ + shifted)·1/√128)·V` → `linear_out`.
- **Conv module**: LN → `pw1` → GLU (first half · σ(second half)) → zero-pad 4 frames on each side →
  `conv1d(groups=1024, k=9, pad 0)`. That is MLX's depthwise fast path, and it computes
  `y[t][c] = Σ_k w[c][k]·x[t+k−4][c]`. Then `((x−mean)/sqrt(var))·γ+β`, where `sqrt(var)` is
  computed once on the host from the as-loaded variance with no epsilon. Then SiLU → `pw2` →
  residual.
- **Order of a block**: `x += 0.5·FFN1`, `x += MHSA`, `x += Conv`, `x += 0.5·FFN2`, then
  `x = LN_out(x)`, using `fast::layer_norm` with eps 1e-5. The last layer's LN output is the
  encoder output.
- **Unsupported inputs**: anything other than the pinned variant is refused at engine creation
  (BN stats only; no biases, speaker kernel or causal subsampling). So is `T_enc > 8192`, where the
  native graph switches to local attention.

## C ABI (`libencoder_mlx.dylib`)

This is the contract's `ve_*` ABI: `ve_abi_version()` = 1, `ve_arms()`, `ve_engine_new`,
`ve_encode` (returns `n_enc_frames` or -1 and fills `err`) and `ve_engine_free`.

- No panic crosses the boundary.
- Handles are single-threaded.
- Engines of one weight dtype created on one thread share one uploaded copy of the weights. The
  f32-family arms share 2.4 GB and the f16 arms share 1.2 GB.
- One `ve_encode` uploads the mel (`Array::from_slice`), builds the graph, runs one `eval` (GPU
  run and synchronization) and copies the f32 states out.
- `Engine::last_profile()` splits that time into build, eval and copy. The bench records the split
  in `work`.

## `encoder-bench` rows

The bench writes contract rows: bet `B4`, arm `mlx:<arm>`, `row_id` = the dump `id`.

- **Order**: pass 0 is warmup and passes 1..N are timed. Rows follow a seeded per-pass
  permutation (the SplitMix64 Fisher–Yates of the other harnesses), and the arm order alternates
  forward/reverse from row to row.
- **`err`**: `{max_abs, rel_l2, min_frame_cos}` against the dumped native Metal states, with f64
  accumulation. `rel_l2 = ‖a−b‖₂/‖b‖₂`.
- **`equal_ref`**: `null`. Bit-identity of the states is `work.bit_equal`. Transcript identity is
  judged by the Swift harness from the same states.
- **`work`**: `{n_mel_frames, n_enc_frames, bit_equal, build_us, eval_us, copy_us}`.
- **`--write-states <dir>`**: writes `<dir>/<arm>/<n>.enc.f32` (the dump's file names) plus an
  `index.jsonl`, for decoding through the production tail.

## Verified (this worktree, shared machine)

- **Build**: `cargo build --release` builds without warnings.
- **ABI from a foreign process**: an out-of-repo C program dlopened the dylib and drove all five
  symbols. `nm -gU` shows them exported. Results:
  - `ve_abi_version` = 1.
  - An unknown arm returns NULL with a message.
  - `ve_encode` on general96 row 0 returned 133 frames with rel_l2 8.08e-4 (`f32`).
  - `n_mels = 64` and `max_enc_frames` too small both returned -1 with a message.
  - `ve_engine_free(NULL)` is a no-op.
- **Numerics against the dumped native Metal states**: pass 0 on every row (680 rows). Rows are
  in `.build/rust-bench/b4b-mlx/numerics-<corpus>.jsonl`. Each cell is
  `max_abs (max) / rel_l2 median / rel_l2 max / min frame cosine`.
  - Determinism comes from the timing smoke runs (16 rows, 3–4 calls each): every arm gave the
    same output hash on every pass.
  - No output was non-finite.
  - `compiled-f16` matched `f16` to the printed digits on every corpus.
  - `f32-sdpa` and `f16-manual` were run on general96 and jargon456 only.

| arm | general96 (96) | jargon456 (456) | librispeech128 (128) |
|---|---|---|---|
| `f32` | 9.42e-3 / 1.13e-3 / 1.49e-2 / 0.99483 | 1.93e-2 / 7.14e-4 / 4.29e-2 / 0.96936 | 8.23e-3 / 9.84e-4 / 6.01e-3 / 0.99515 |
| `compiled-f32` | 9.43e-3 / 1.13e-3 / 1.49e-2 / 0.99482 | 1.93e-2 / 7.14e-4 / 4.29e-2 / 0.96934 | 8.23e-3 / 9.84e-4 / 6.02e-3 / 0.99515 |
| `f32-mm16` | 6.43e-3 / 5.72e-4 / 5.32e-3 / 0.99702 | 4.06e-3 / 4.37e-4 / 7.13e-3 / 0.99882 | 6.43e-3 / 5.44e-4 / 4.08e-3 / 0.99702 |
| `compiled-f32-mm16` | 4.25e-3 / 5.81e-4 / 4.13e-3 / 0.99942 | 9.04e-3 / 4.41e-4 / 1.89e-2 / 0.99364 | 6.02e-3 / 5.63e-4 / 3.00e-3 / 0.99854 |
| `f16` | 2.91e-2 / 2.34e-3 / 2.03e-2 / 0.94514 | 2.42e-2 / 1.75e-3 / 5.57e-2 / 0.95059 | 3.12e-2 / 2.28e-3 / 2.83e-2 / 0.88563 |
| `compiled-f16` | identical to `f16` | identical to `f16` | identical to `f16` |
| `f32-sdpa` | 9.41e-3 / 1.13e-3 / 1.49e-2 / 0.99483 | 1.93e-2 / 7.14e-4 / 4.30e-2 / 0.96931 | not run |
| `f16-manual` | 3.84e-2 / 2.64e-3 / 2.29e-2 / 0.91149 | 2.79e-2 / 2.04e-3 / 5.50e-2 / 0.95159 | not run |

- **Development timing smoke runs**: these are not official, and the machine was shared. The
  5-minute load average was 29.6 during the last run. Values are per-row medians of `ve_encode`
  (passes ≥ 1).
  - general96, first 12 rows, 3 passes. On the T = 133 (10.56 s) row: `f32` 48.2 ms,
    `compiled-f32` 47.0, `f16` 42.8, `compiled-f16` 41.7, `f32-sdpa` 50.1, `f16-manual` 43.2.
    For comparison, the native Metal encoder measured 48.6 ms on this row in the orchestrator's
    stage profile.
  - A second run on the same 12 rows (2 passes) gave these medians over rows: `f32` 45.0 ms,
    `f16` 39.0, `compiled-f16` 38.6, `f32-mm16` 50.0, `compiled-f32-mm16` 48.8.
  - librispeech128, 4 rows with T = 410–437 (33–35 s), 2 passes. Medians over rows: `f16` 110.7
    ms, `compiled-f16` 106.6, `f32` 130.0, `f32-mm16` 170.8.
  - Graph construction (`work.build_us`) took 0.4–0.9 ms per call, so the time is GPU execution.
  - Correctness runs on general96 and librispeech128 under that load averaged 0.6–0.8 s per call.
    The cause was not investigated. Contention from concurrent agents is likely but unverified.

## Known limits

- **No arm is bit-identical to ggml-metal.**
  - `f32-mm16` reproduces ggml's operand rounding and comes closest: median rel_l2 ≈ 4.4–5.7e-4.
  - What remains comes from accumulation order and from how exp, sigmoid, sin and cos are
    implemented. Those f32-level differences sometimes cross an f16 rounding boundary, and the
    flip then propagates through 24 layers.
  - Plain `f32` is closer to exact math than ggml is, but it is 2× further from ggml in the median
    and up to 6× in the worst row (jargon456: rel_l2 4.3e-2, cosine 0.969).
- **The f16 arms have the largest per-frame deviations** (min frame cosine down to 0.886 on
  librispeech128). Their transcript identity has to be measured through the production tail
  (`--write-states`).
- **SDPA**: in f32 it matches manual attention to the printed digits and was 1–2 ms slower in the
  smoke runs. In f16, row means are better than `f16-manual` but some single rows are worse, and
  the smoke runs showed no speed difference.
- **compile**: shapeless and per engine, so there is no retrace per utterance length. The smoke
  runs showed gains of about 1–3%, which is within noise.
- **f32-family arms read 2.4 GB of weights per utterance**, against 1.2 GB for f16. That
  bandwidth sets a floor of roughly 9 ms (inferred from about 270 GB/s, not measured).
