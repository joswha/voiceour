# Vendored ggml

## Upstream

| | |
|---|---|
| Repository | https://github.com/ggml-org/whisper.cpp |
| Commit | `592feef04a1802b18cbeffd0fd0eb5d02570c2ec` (v1.9.2 lineage) |
| License | MIT — verbatim copy in `LICENSE` |
| Vendored | 2026-08-14 |

This directory holds whisper.cpp's copy of ggml (0.19.0), the tensor library under the Granite port in
`Vendor/granite` (SwiftPM target `CGranite`). Upstream-relative paths are preserved — `ggml/...` here is
`ggml/...` in whisper.cpp — so a re-vendor is a file-for-file copy from the same paths in a fresh
checkout at the pinned commit: `scripts/vendor_ggml.sh <upstream-checkout>`, then
`scripts/vendor_ggml.sh <upstream-checkout> --check`. `GGML_VERSION`/`GGML_COMMIT` are pinned to
`"0.19.0"`/the commit above in `Package.swift`; upstream generates both from CMake, which this package
does not run.

## File list

Copied verbatim from upstream unless the patch ledger below says otherwise.

- `LICENSE`
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
  path resolves through the `embed` header search path on the CGgml target. Its arm64 `#error`
  text names the directory this drop was first vendored into; the file is kept byte-identical.
- `NOTICE.md` — this file.
- `patches/*.patch` — ordered `git apply` patches for every explained drift in an upstream file.

## Patch ledger

Every local change to an upstream file is marked in source with a `VOICEOUR PATCH` comment and
captured under `patches/`, applied in file-name order. The measurements below are dated records
taken on the transducer recognizer this drop first served (Parakeet TDT, Apple M4 Pro, 2026-08);
none of these patches changes a computed value except where stated.

- `patches/0001-skip-graph-reorder-for-single-command-buffer-graphs.patch` changes
  `ggml/src/ggml-metal/ggml-metal-context.m` so `ggml_metal_graph_optimize` skips the reordering
  pass on graphs of 64 nodes or fewer. Upstream runs a pack/reorder/unfuse pass over every graph;
  on small graphs the pass costs more than the concurrency it can find. 64 mirrors `n_main` in
  `ggml_metal_graph_compute`, so the threshold is exactly the set of graphs the calling thread
  encodes into one command buffer; larger graphs keep upstream's pass.
  - Upstream status: not reported upstream; local tuning, re-check on every re-vendor.
  - Test status: measured on a decode loop submitting thousands of 8- and 30-node graphs per
    utterance. Five-pair interleaved A/B of summed warm inference is -1.67%, four of five paired
    differences in the same direction, with byte-identical raw transcripts on the 96-row latency
    corpus and both frozen promotion corpora. Disabling the pass outright is **not** equivalent and
    must not be done: it also skips graphs that straddle the `n_nodes_0` command-buffer split, and
    ggml-metal cannot fuse a run across two encoders — that measured -2.39% but changed one
    transcript's casing.
- `patches/0002-poll-command-buffer-before-blocking.patch` polls `cmd_buf_last` for a bounded
  number of iterations in `ggml_metal_synchronize` before calling `waitUntilCompleted`.
  `waitUntilCompleted` parks the calling thread, so returning from it costs a scheduler wake-up on
  top of the GPU's own completion. The budget is bounded, so the cost when polling does not pay off
  is capped at roughly 200 us per call instead of scaling with the wait, and `waitUntilCompleted`
  still runs afterwards.
  - Upstream status: not reported upstream. The trade suits small, strictly sequential graphs; a
    batched LLM would not benefit and would pay the poll.
  - Test status: measured on a decode loop of ~4,825 graph submissions (~160 us each, wake-up
    ~2.2 us); a budget sweep put the recoverable share at 0.9% of summed warm inference.
    Value-preserving by construction: only the manner of waiting changes, never a computed value.
- `patches/0003-three-encode-threads.patch` raises `ggml_backend_metal_set_n_cb` from 1 to 3 at
  both backend init sites. `ggml_metal_graph_compute` keeps the first `MAX(64, 0.1*n)` nodes on the
  calling thread and splits the rest across `n_cb` threads, so this affects only large graphs.
  Upstream's comment cites 1 or 2 as optimal for LLaMA on M1 Pro and M2 Ultra, which is a different
  shape of workload from one large fixed encoder graph on an M4 Pro.
  - Upstream status: not reported upstream. The value is host- and graph-dependent, so it is a
    local tuning choice rather than a defect.
  - Test status: measured. Summed warm inference across the sweep: 2368/2365 at `n_cb` 1,
    2355/2353 at 2, 2344/2354 at 3, 2345/2349 at 4, 2346/2346 at 6. It changes encode ranges, and
    ggml-metal cannot fuse a run spanning two command buffers, so its value preservation is tested
    rather than proven — the frozen gate reported 0 raw-transcript drift on all 500 rows with U-WER
    and CER deltas of exactly zero.
- `patches/0004-macos27-warning-clean-build.patch` makes the vendored ggml warning-clean under
  Swift 6.4's default Swift Build engine and the macOS 27 SDK.
  Tensor dimensions, byte strides, block counts and loop indices retain their source widths;
  conversions to existing fixed-width vector, scheduler and Metal kernel interfaces are explicit.
  `GGML_TENSOR_LOCALS` honors its caller-selected type without an implicit narrowing conversion.
  C library assertion and Darwin MIN/MAX macros are imported before local fallback definitions.
  Metal device setup uses unified-memory capability rather than the unsupported Apple Silicon
  eGPU-location query, and logs Apple/Metal GPU families without the deprecated Common family.
  No warning is disabled, no kernel argument layout changes, and no per-element validation is added.
  - Upstream status: not reported upstream; re-check these compiler/SDK compatibility changes
    when updating the vendor pin.
  - Verification: `make build` passes with Swift, C and C++ warnings as errors. A before/after
    production-sidecar comparison of 24 LibriSpeech, FLEURS and TechTerms clips (1.39–34.96 s)
    had zero errors and identical transcripts, cleanup output and confidence values.

Upstream already defaults ggml's logger to stderr (`ggml_log_callback_default` in
`ggml/src/ggml.c:313-320`). stdout carries the sidecar's NDJSON protocol and must never receive
anything else; `voiceour-asr` installs its own `ggml_log_set` callback at startup (honouring
`VOICEOUR_ASR_LOG`) beside the Granite port's `granite_log_set`, so no logging patch is required.

## Build notes

- Compiled as one SwiftPM C target, `CGgml`; see `Package.swift`.
- `-fno-objc-arc` is required: `ggml-metal-device.m` and `ggml-metal-context.m` are manual
  retain/release, and SwiftPM compiles `.m` with ARC on by default while upstream CMake does not.
- `ggml/embed/ggml-metal-embed.c` rejects non-arm64 compilation because this drop intentionally
  omits the x86 architecture sources.
- `-mcpu=native` is deliberately **not** used, unlike the upstream CMake default. Voiceour ships a
  copyable `.app`, and a binary built with the build host's exact CPU can fault on an older Apple
  Silicon machine. The arm64 baseline still resolves NEON, ARM_FMA, FP16_VA, DOTPROD, ACCELERATE
  and REPACK at compile time, and the heavy work runs on Metal.
- The embedded shader source is compiled by the Metal runtime on first use: 7.5 s the first time a
  given binary runs on a machine, 9 ms afterwards from the OS shader cache. No Metal toolchain is
  needed at build time; this vendor drop was verified on a host where
  `xcrun -sdk macosx metal --version` fails with "missing Metal Toolchain".
