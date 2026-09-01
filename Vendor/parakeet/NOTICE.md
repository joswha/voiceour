# Vendored parakeet.cpp + ggml

## Upstream

| | |
|---|---|
| Repository | https://github.com/ggml-org/whisper.cpp |
| Commit | `592feef04a1802b18cbeffd0fd0eb5d02570c2ec` (v1.9.2 lineage) |
| License | MIT — verbatim copy in `LICENSE` |
| Vendored | 2026-08-14 |

Upstream-relative paths are preserved, so a re-vendor is a file-for-file copy from the same
paths in a fresh checkout at the pinned commit. `PARAKEET_VERSION` is pinned to `"1.9.2"` and
`GGML_VERSION`/`GGML_COMMIT` to `"0.19.0"`/the commit above in `Package.swift`; upstream
generates all three from CMake, which this package does not run.

## File list

Copied verbatim from upstream unless the patch ledger below says otherwise.

- `LICENSE`
- `include/parakeet.h`, `src/parakeet.cpp`, `src/parakeet-arch.h`
- `ggml/include/`: `ggml.h ggml-alloc.h ggml-backend.h ggml-cpp.h ggml-opt.h gguf.h ggml-cpu.h
  ggml-metal.h ggml-blas.h`
- `ggml/src/`: `ggml.c ggml.cpp ggml-alloc.c ggml-backend.cpp ggml-backend-meta.cpp ggml-opt.cpp
  ggml-threading.cpp ggml-threading.h ggml-quants.c ggml-quants.h gguf.cpp ggml-backend-dl.cpp
  ggml-backend-dl.h ggml-backend-reg.cpp ggml-impl.h ggml-backend-impl.h ggml-common.h`
- `ggml/src/ggml-cpu/`: `ggml-cpu.c ggml-cpu.cpp repack.cpp repack.h hbm.cpp hbm.h quants.c
  quants.h traits.cpp traits.h amx/amx.cpp amx/amx.h amx/mmq.cpp amx/mmq.h ggml-cpu-impl.h
  common.h binary-ops.h binary-ops.cpp unary-ops.h unary-ops.cpp simd-mappings.h simd-gemm.h
  arch-fallback.h vec.h vec.cpp ops.h ops.cpp arch/arm/quants.c arch/arm/repack.cpp`
- `ggml/src/ggml-metal/`: `ggml-metal.cpp ggml-metal-device.m ggml-metal-device.cpp
  ggml-metal-common.cpp ggml-metal-context.m ggml-metal-ops.cpp ggml-metal-common.h
  ggml-metal-context.h ggml-metal-device.h ggml-metal-impl.h ggml-metal-ops.h ggml-metal.metal`
- `ggml/src/ggml-blas/ggml-blas.cpp`

`ggml/src/ggml-metal/ggml-metal.metal` is excluded from the SwiftPM source list — SwiftPM would
try to compile it — and is present only as the input to `ggml/embed/regenerate.sh`.

## Local files (not upstream)

- `ggml/include/module.modulemap` — explicit Clang module map. SwiftPM's default umbrella-directory
  map imports every header in `include/`, and `ggml-cpp.h` is guarded with
  `#error "This header is for C++ only"`, which breaks Swift importers. The map lists the
  C-safe headers only; `ggml-cpp.h` stays in place for the vendored `.cpp` sources.
- `ggml/embed/ggml-metal-embed.metal` — generated, committed. Upstream produces the equivalent
  file inside the CMake build directory (`ggml/src/ggml-metal/CMakeLists.txt:37-56`); SwiftPM has
  no code-generation step, so it is generated ahead of time and committed.
- `ggml/embed/regenerate.sh` — reproduces that file with upstream's exact two `sed` invocations.
  Run after every re-vendor of `ggml-metal.metal`, `ggml-metal-impl.h` or `ggml-common.h`.
- `ggml/embed/ggml-metal-embed.c` — the `.incbin` translation unit. Upstream emits a `.s` file
  from CMake with the same directives; the symbols `_ggml_metallib_start`/`_ggml_metallib_end` and
  the `__DATA,__ggml_metallib` section are what `ggml-metal-device.m:125-131` reads. The `.incbin`
  path resolves through the `embed` header search path on the CGgml target.
- `NOTICE.md` — this file.
- `patches/*.patch` — ordered `git apply` patches for every explained drift in an upstream file.

## Patch ledger

Every local change to an upstream file is marked in source with a `VOICEOUR PATCH` comment and
captured under `patches/`.

- `patches/0001-tdt-duration-argmax-raw-logits.patch` changes `src/parakeet.cpp` so the TDT
  decoder chooses duration slots from raw, pre-log-softmax logits instead of values that can
  numerically underflow to `-inf`.
  - Upstream status: ggml-org/whisper.cpp#3932 open as of 2026-08-15; re-check on every re-vendor.
  - Test status: untested-by-construction. No committed input reaches the numeric underflow it
    fixes, and the benchmark corpus decoded identically with and without it.
- `patches/0002-encoder-sched-reservation-high-water-mark.patch` changes `src/parakeet.cpp` so
  `parakeet_ensure_encode_sched` treats its reserved encoder context as a high-water mark
  instead of requiring an exact match. Upstream's equality test frees the encoder scheduler,
  reallocates its metadata, rebuilds a ~1300-node measurement graph and allocates fresh Metal
  compute buffers whenever the mel length differs from the previous call — which, for a
  dictation app, is every decode. `parakeet_init_state` already reserves at the full
  `hparams.n_audio_ctx`, so the reservation now happens once per process.
  - Upstream status: not reported upstream; local behaviour fix, re-check on every re-vendor.
  - Test status: measured. On the frozen latency corpus (Apple M4 Pro, f16), a five-pair
    interleaved A/B of summed warm inference is -2.11%, with all five paired differences in the
    same direction, and peak sidecar RSS falls 15-19 MB. Raw transcripts are byte-identical on
    all 96 corpus rows and on both frozen promotion corpora (400 LibriSpeech + 100 FLEURS).
    The graph that runs is still built from the exact `pstate.n_audio_ctx`, so only the
    reservation changed.
- `patches/0003-skip-graph-reorder-for-single-command-buffer-graphs.patch` changes
  `ggml/src/ggml-metal/ggml-metal-context.m` so `ggml_metal_graph_optimize` skips the reordering
  pass on graphs of 64 nodes or fewer. Upstream runs a pack/reorder/unfuse pass over every graph;
  Parakeet's TDT decode submits an 8-node prediction graph and a 30-node joint graph per emitted
  token, thousands of times per utterance, and the pass costs more there than the concurrency it
  can find. 64 mirrors `n_main` in `ggml_metal_graph_compute`, so the threshold is exactly the
  set of graphs the calling thread encodes into one command buffer.
  - Upstream status: not reported upstream; local tuning, re-check on every re-vendor.
  - Test status: measured. Five-pair interleaved A/B of summed warm inference is -1.67%, four of
    five paired differences in the same direction. Raw transcripts are byte-identical on all 96
    corpus rows and on both frozen promotion corpora, with U-WER and CER deltas of exactly zero.
    Disabling the pass outright is **not** equivalent and must not be done: it also skips the
    encoder's ~1300-node graph, which straddles the `n_nodes_0` command-buffer split, and
    ggml-metal cannot fuse a run across two encoders — that measured -2.39% but flipped
    `the Count's` to `the count's` on `librispeech-test.other-000140`.
- `patches/0004-consume-rel-position-shift-as-strided-view.patch` changes `src/parakeet.cpp` so
  the dense attention path consumes the relative-position shift as the strided view it already
  is, instead of copying it into a fresh contiguous tensor first. The two `ggml_view_3d` calls
  above the copy implement the shift by reading the `[2T-1, T]` score block with a row stride of
  `pos_window` while using only the leading `T` values of each row; ggml-metal's binary ops
  require only `ggml_is_contiguous_rows`, which that view satisfies, so the copy fed the
  following `ggml_add` an operand it never needed. At 24 layers by `[n_time, n_time, n_head]`
  f32 the copy wrote and re-read roughly 290 MB per utterance.
  - Upstream status: not reported upstream; local optimisation, re-check on every re-vendor. If a
    re-vendor tightens ggml-metal's binary-op support to full contiguity, restore the copy.
  - Test status: measured. Five-pair interleaved A/B of summed warm inference is -1.98%, all five
    paired differences in the same direction. Raw transcripts are byte-identical on all 96 corpus
    rows and on both frozen promotion corpora, with U-WER and CER deltas of exactly zero —
    expected, since removing a copy cannot change a value. `CONT` was the most expensive op class
    in the encoder, 27.8 ms of 171.9 ms by per-op-class skipping, and this was its largest single
    contributor.
- `patches/0005-relative-position-matmul-operands-as-views.patch` changes `src/parakeet.cpp` so
  the dense attention path hands the relative-position matmul its two operands as permuted views
  rather than materialising both. Twelve lines earlier the same builder already feeds the content
  -score matmul the un-materialised `K_prep`/`Q_prep` views of the same shape and permutation, so
  upstream copied these two operands for no reason the graph itself observes. The
  local-attention branch keeps its copy, applied at its own use site, so that branch — which no
  input this app can produce reaches, since it needs more than 8192 encoder frames — is
  unchanged.
  - Upstream status: not reported upstream; local optimisation, re-check on every re-vendor.
  - Test status: measured. Five-pair interleaved A/B of summed warm inference is -2.48%, all five
    paired differences in the same direction. Raw transcripts are byte-identical on all 96 corpus
    rows and on both frozen promotion corpora, with U-WER and CER deltas of exactly zero, so
    ggml-metal did not reselect a matmul kernel with a different accumulation order.
- `patches/0006-fold-rel-position-roll-into-view-offset.patch` changes `src/parakeet.cpp` so the
  relative-position shift drops its `ggml_roll` and starts its view one element earlier instead.
  `ggml_pad` appends one zero per row so the row pitch exceeds the payload by one, and the view
  then walks rows with the shorter stride — that stride mismatch is what produces the shift.
  Upstream additionally rolled dim 0 forward by one and started the view one element later to
  skip the zero that the roll moved to the front; rolling forward and then reading later is the
  identity. For output element (key k, query q) both forms select relative position
  `center + k - q`, and since `k, q` stay inside `[0, n_frame)` with `n_frame - 1 == center`,
  neither form ever reads the appended zero.
  - Upstream status: not reported upstream; local optimisation, re-check on every re-vendor.
  - Test status: measured. Five-pair interleaved A/B of summed warm inference is -0.83%, all five
    paired differences in the same direction. Raw transcripts are byte-identical on all 96 corpus
    rows and on both frozen promotion corpora, with U-WER and CER deltas of exactly zero — a
    mis-derived offset would not drift one row, it would garble every transcript.
- `patches/0007-one-graph-per-decode-step.patch` changes `src/parakeet.cpp` so the TDT decode
  loop computes one graph per step instead of two, holding the joint network and — when the
  previous step emitted a token — the prediction network that feeds it. `parakeet_predict` and
  `parakeet_joint` become `parakeet_step` over a shared `parakeet_expand_prediction`.
  Nothing reads the predictor's output on the host: it lands in `pstate.pred_out` and the LSTM
  state, so the host argmax always sat between a joint network and the *following* prediction,
  never between a prediction and the joint that consumes it. Those two therefore always ran back
  to back with no host work between them, as two separate graph computes. A graph compute costs
  about 170 us end to end on this hardware regardless of size — measured by skipping every
  MUL_MAT in these graphs, after which the 8-node joint still took 167 us per call and the
  30-node prediction 180 us — so at thousands of emitted tokens per utterance that fixed cost,
  not the arithmetic, dominated the decode loop.
  When the merged graph consumes the prediction it reads the `ggml_cpy` node rather than
  `pstate.pred_out`, because only that expresses the dependency to ggml. The loop can exit with
  a prediction still deferred, and it is applied after the loop so a `parakeet_chunk` caller
  carrying state across chunks still sees the LSTM state one token ahead.
  - Upstream status: not reported upstream; local restructuring, re-check on every re-vendor.
  - Test status: measured. Five-pair interleaved A/B of summed warm inference is -6.59%, all five
    paired differences in the same direction and none smaller than -178 ms. Raw transcripts are
    byte-identical on all 96 corpus rows and on both frozen promotion corpora, with U-WER and CER
    deltas of exactly zero, and the per-token confidences are unchanged. The merged graph is 38
    nodes, still inside the 64 the calling thread encodes into one command buffer, so it gains no
    command-buffer boundary either.
- `patches/0008-conv-subsampling-bias-add-materialises-layout.patch` adds
  `parakeet_conv_2d_bias` to `src/parakeet.cpp` and routes the three convolutions of the
  subsampling front-end through it. `ggml_conv_2d` ends with
  `ggml_cont(ggml_permute(result, 0, 1, 3, 2))`; that permutation leaves dim 0 in place, so the
  view is row-contiguous, ggml-metal's binary ops need only row contiguity, and the bias add that
  follows every one of these convolutions writes a dense tensor of the same shape regardless — so
  the copy wrote the whole convolution result an extra time for nothing. The helper composes the
  same public ggml ops in the same order and then adds the bias, leaving `ggml_conv_2d` itself
  and its contiguity contract untouched for any other caller.
  - Upstream status: not reported upstream. The removable copy is inside upstream's
    `ggml_conv_2d`, so this is expressed at the call site rather than by changing that function.
  - Test status: measured. Per-op-class skipping restricted to the subsampling encode context put
    its copies at 8.91 ms of a 155 ms encode. Five-pair interleaved A/B of summed warm inference
    is -3.24%, all five paired differences in the same direction. Raw transcripts are
    byte-identical on all 96 corpus rows and on both frozen promotion corpora, with U-WER and CER
    deltas of exactly zero — expected, since removing a copy cannot change a value.
- `patches/0009-pointwise-conv-needs-no-im2col.patch` gives `parakeet_conv_2d_bias` a branch for
  a 1x1 kernel at unit stride and dilation with no padding, which the subsampling front-end's
  second and third convolutions are. For that case `ggml_im2col` reduces to a transpose and a
  cast: it writes `dst[c, oh*OW + ow] = x[c*IW*IH + oh*IW + ow]`, and with `OW == IW` and
  `OH == IH` that is exactly `transpose` of the `[IW*IH, IC]` view converted to the matmul's
  input type. Both paths round the same f32 elements to f16 with Metal's round-to-nearest-even,
  so the values are identical.
  The reason to care is the dispatch, not the arithmetic. `ggml_metal_op_im2col` sizes its
  threadgroup `(min(max_threads/(KH*KW), N), KH, KW)` and its grid `(IC, OH, OW)`, so it
  parallelises over the batch — and single-utterance inference has `N == 1`. A pointwise kernel
  therefore ran as 7.2 million one-thread threadgroups for the first of these two convolutions,
  around 3% SIMD occupancy.
  - Upstream status: not reported upstream. The batch-only threadgroup sizing is an upstream
    ggml-metal weakness for `N == 1` convolutions and is worth reporting; both
    `kernel_im2col` and `kernel_im2col_ext` share it.
  - Test status: measured. im2col cost 23.66 ms of a 147 ms encode while moving only ~56 MB,
    about 2.4 GB/s. Five-pair interleaved A/B of summed warm inference is -9.23%, all five paired
    differences in the same direction and within 13 ms of each other. Raw transcripts are
    byte-identical on all 96 corpus rows and on both frozen promotion corpora, with U-WER and CER
    deltas of exactly zero.
- `patches/0010-poll-command-buffer-before-blocking.patch` polls `cmd_buf_last` for a bounded
  number of iterations in `ggml_metal_synchronize` before calling `waitUntilCompleted`.
  `waitUntilCompleted` parks the calling thread, so returning from it costs a scheduler wake-up on
  top of the GPU's own completion. That is invisible against a 50 ms encoder graph but not against
  the TDT decode loop, which submits one graph per emitted token and waits on each. The budget is
  bounded, so the cost when polling does not pay off is capped at roughly 200 us per call instead
  of scaling with the wait, and `waitUntilCompleted` still runs afterwards.
  - Upstream status: not reported upstream. The trade is specific to a workload whose graphs are
    small and strictly sequential; a batched LLM would not benefit and would pay the poll.
  - Test status: measured. Decode is 772 ms over ~4,825 steps, about 160 us per step, of which the
    wake-up is ~2.2 us; a budget sweep put the recoverable share at 0.9% of summed warm inference.
    Value-preserving by construction: only the manner of waiting changes, never a computed value.
- `patches/0011-merge-conv-module-right-pads.patch` replaces the convolution module's
  `pad(dw_pad)` / `roll(dw_pad)` / `pad(dw_pad)` with one `pad(2*dw_pad)` followed by the same
  roll. `ggml_pad` right-pads and `ggml_roll(+n)` is a forward circular shift, so upstream builds
  `[0 x dw_pad, values, 0 x dw_pad]` by parking zeros at the end and rotating half of them to the
  front; padding to the final width first and then rotating lands the identical tensor.
  - Upstream status: not reported upstream. Upstream's three-op form is equivalent, just wider.
  - Test status: measured. Saves one node and one `[n_time + dw_pad, n_state]` f32 write-and-reread
    per layer across 24 layers. Value-preserving by construction: the same elements end up in the
    same positions.
- `patches/0012-three-encode-threads.patch` raises `ggml_backend_metal_set_n_cb` from 1 to 3 at
  both backend init sites. `ggml_metal_graph_compute` keeps the first `MAX(64, 0.1*n)` nodes on the
  calling thread and splits the rest across `n_cb` threads, so this affects only the encoder's
  ~1300-node graph; the decode loop's per-step graph is under 64 nodes and stays entirely on the
  calling thread. Upstream's comment cites 1 or 2 as optimal for LLaMA on M1 Pro and M2 Ultra,
  which is a different shape of workload from one large fixed graph on an M4 Pro.
  - Upstream status: not reported upstream. The value is host- and graph-dependent, so it is a
    local tuning choice rather than a defect.
  - Test status: measured. Summed warm inference across the sweep: 2368/2365 at `n_cb` 1,
    2355/2353 at 2, 2344/2354 at 3, 2345/2349 at 4, 2346/2346 at 6. This one changes encode
    ranges, and ggml-metal cannot fuse a run spanning two command buffers, so it is the one
    change of the three whose value preservation is tested rather than proven — the frozen gate
    reports 0 raw-transcript drift on all 500 rows with U-WER and CER deltas of exactly zero.
- `patches/0013-file-backed-weight-arena.patch` adds an opt-in C API that receives the model
  and a derived-arena path. It reproduces ggml's tensor offsets with
  `ggml_backend_alloc_ctx_tensors_from_buft_size`, `ggml_backend_dev_buffer_from_host_ptr`, and
  `ggml_tallocr_alloc`, then backs the immutable weights with a page-aligned `MAP_SHARED` file.
  Warm loads still parse and validate every source tensor header but seek over payloads already in
  the arena. Arena reuse requires the exact v1 layout manifest and payload size under a
  cross-process lock; creation physically reserves the data file (`F_PREALLOCATE`) before mapping,
  then uses locked temp data/manifest files, per-tensor `MS_SYNC`, file `fsync`, atomic renames,
  and directory `fsync`. Unsafe, stale, partial, full-volume, or otherwise unusable
  derived state falls back to ordinary ggml buffers. Mapped backend wrappers are freed before
  `munmap` and `close`.
  - Upstream status: not reported upstream. parakeet.cpp's legacy stream format interleaves tensor
    metadata and payload and has no mmap layout; this is a Voiceour cache over the existing
    loader, not a file-format change.
  - Test status: measured before production hardening on Apple M4 Pro. Cold `MAP_SHARED` plus
    per-tensor `MS_SYNC` reached 181.209 MB physical footprint. Deterministic warm offset reuse
    reached 178.537 MB physical footprint / 112.525 MB RSS, with byte-identical transcripts and
    warm p95 at or below 207 ms on the frozen harness.
- `patches/0014-greedy-decode-step-callback.patch` adds an opt-in C callback after each greedy
  TDT token/duration argmax, before blank handling, and passes the frame, selected path, raw
  token logits, and five raw duration logits. Unlike the existing emitted-token callback it
  observes blank steps, so a caller can harvest the complete lattice path without retaining the
  8,193-wide vocabulary tensor. The callback and user data default to null; the extra
  device-to-host token-logit copy is callback-guarded and ordinary state transitions are
  byte-identical.
  - Upstream status: not reported upstream. This is a bounded Voiceour research seam, not a
    shipping decode feature.
  - Test status: the Swift research caller copies only top-8 token logits and all duration slots;
    vendor reproduction and full-corpus harvest are recorded in
    `research/bet1-contextual-decoding.md` and `research/bet3-quantization.md`.
- `patches/0015-record-authoritative-loader.patch` pre-scans the existing custom tensor-record
  stream on seekable loaders and makes each record's storage type authoritative only for the
  explicit 2-D matrix-weight allowlist, choosing that type before any ggml tensor metadata is
  constructed. The scan validates GGML_MAX_NAME-bounded names against the exact expected
  architecture name set before retaining them, dimensions, supported F32/F16/Q8_0/Q4_K/Q6_K
  types, block shapes, checked payload offsets/byte counts under a checked record-count and
  metadata-byte cap, and duplicate names. The payload pass then re-parses every header and
  requires metadata identity with the scanned directory — same name, dimensions, type, offset,
  and byte count — and exact EOF. The pre-scan promises metadata identity only; it never hashes
  payload bytes. Payload authenticity is owned by the product model cache, whose locked
  size/SHA-256 verification gates every artifact before this loader sees it. Fixed/scalar/
  non-matmul tensors retain their architecture type, including the legacy zero-dimension F32
  `num_batches_tracked` record loaded into I32 metadata. Non-seekable custom loaders retain the
  global-`ftype` path.
  - Upstream status: not reported upstream. The custom stream already stores a type per record;
    this makes that existing metadata usable for mixed-precision research without a format or
    graph change.
  - Test status: focused real-artifact probes accept one Q8 matrix in a nominal F16 stream and
    an F16 record under a nominal-Q6 global type with `n_subsampling_channels=255`, and reject a
    duplicate name, an overlong (1 MiB) name length, a truncated final record, Q6_K with inner
    dimension 640, and an architecture-dimension mismatch. Legacy F16/Q8 regular, cold-arena,
    and warm-arena identity is recorded in `.build/asr-research/three-bets/mixed-loader/`, and
    the dual-source provenance summary is tracked at
    `research/bet3-mixed-quantize-provenance.json`.
- `patches/0016-external-encoder-seam.patch` adds two opt-in C APIs for heterogeneous
  execution: a read-only view of the default state's native frame-major mel tensor and a full
  path that validates and copies caller-provided frame-major F32 encoder states into `enc_out`
  before running the existing greedy TDT decode and result construction. The injection requires
  the model's 1024-channel width, the exact `(n_mel + 7) / 8` valid-frame count, and a frame count
  no larger than the state's allocated `enc_out` capacity. Ordinary `parakeet_full` never calls
  either API, so an unused seam performs no work and changes no default state transition.
  - Upstream status: not reported upstream. This is the narrow boundary needed to keep the
    native parakeet frontend and TDT tail while executing only the FastConformer encoder in
    CoreML.
  - Test status: the separate CoreML encoder prototype under
    `.build/asr-research/three-bets/coreml-native-mel/` copied native zero-padded mel into the
    fixed `[1,128,1501]` model input, injected only the valid `[frames,1024]` output, and was
    byte-deterministic across the frozen 552-row two-pass gate. Pooled U-WER delta was +0.000717
    and active compute-rail energy fell 47.0%.
- `patches/0017-cpu-tail-backend.patch` adds an opt-in `tail_backend_cpu` context parameter
  (default false). When set, the decode scheduler is built from the CPU/Accelerate backends
  only, the prediction/joint weight records allocate CPU-side (a distinct weight-arena path
  suffix keeps the layouts separate), and `enc_out`, the LSTM state, and `pred_out` are placed
  in CPU buffers so per-step decode runs without Metal dispatches or cross-device copies.
  Default-off behavior is byte-identical: the parameter only selects backends and buffer
  placement, never arithmetic.
  - Upstream status: not reported upstream. It exists for the heterogeneous configuration where
    the encoder runs in CoreML and the GPU otherwise stays idle during decode.
  - Test status: transcripts byte-identical to the Metal tail across all 552 frozen rows and
    3x fresh-process determinism (`.build/asr-research/three-bets/tail-cpu/`); under the
    palettized CoreML encoder ladder the candidate GPU rail drops to 0.4-2.6 J per block with
    energy ratio 0.3371/0.3377 across two ABBA runs and general-corpus inference p95 183-185 ms.



Upstream already defaults both loggers to stderr (`src/parakeet.cpp:4894-4931` routes through
`g_state.log_callback`, and `ggml_log_callback_default` in `ggml/src/ggml.c:313-320` writes to
stderr). The sidecar installs its own `parakeet_log_set` callback at startup because stdout carries
the NDJSON protocol and must never receive anything else; no logging patch is required.

## Build notes

- Compiled as two SwiftPM C targets, `CGgml` and `CParakeet`; see `Package.swift`.
- `-fno-objc-arc` is required: `ggml-metal-device.m` and `ggml-metal-context.m` are manual
  retain/release, and SwiftPM compiles `.m` with ARC on by default while upstream CMake does not.
- `ggml/embed/ggml-metal-embed.c` rejects non-arm64 compilation because this drop intentionally
  omits the x86 architecture sources.
- `-mcpu=native` is deliberately **not** used, unlike the upstream CMake default. Voiceour ships a
  copyable `.app`, and a binary built with the build host's exact CPU can fault on an older Apple
  Silicon machine. The arm64 baseline still resolves NEON, ARM_FMA, FP16_VA, DOTPROD, ACCELERATE
  and REPACK at compile time, verified by `parakeet_print_system_info()`, and the heavy work runs
  on Metal.
- The embedded shader source is compiled by the Metal runtime on first use: 7.5 s the first time a
  given binary runs on a machine, 9 ms afterwards from the OS shader cache. No Metal toolchain is
  needed at build time; this vendor drop was verified on a host where
  `xcrun -sdk macosx metal --version` fails with "missing Metal Toolchain".
