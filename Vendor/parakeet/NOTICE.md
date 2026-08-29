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

Upstream already defaults both loggers to stderr (`src/parakeet.cpp:3893-3906` routes through
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
