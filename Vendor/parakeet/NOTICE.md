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
  - Test status: measured. On the frozen latency corpus (Apple M4 Pro, f16) warm inference p95
    fell from 282.0 ms to 270.5 ms and peak sidecar RSS fell 19 MB, with byte-identical raw
    transcripts on all 96 corpus rows and on both frozen promotion corpora (400 LibriSpeech +
    100 FLEURS rows). The graph that runs is still built from the exact `pstate.n_audio_ctx`,
    so only the reservation changed.

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
