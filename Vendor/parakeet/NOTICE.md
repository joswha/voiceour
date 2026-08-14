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

## Patch ledger

Every local change to an upstream file is listed here and marked in the source with a comment
beginning `VOICEOUR PATCH`.

### 1. Duration argmax on raw logits — upstream issue ggml-org/whisper.cpp#3932

`src/parakeet.cpp`. Upstream's TDT decode loop argmaxes the duration slots of `pstate.logits`
against a `-1e10f` sentinel with strict `>`. `pstate.logits` is the graph's last node, which is
`log(softmax(logits))` (`parakeet_build_graph_joint`), so every duration slot reads `-inf` once
the winning vocabulary logit leads the row by more than about 87. `-inf > -1e10f` is false, the
index stays 0, and `tdt_durations[0]` is 0 — which, on a non-blank token, pins the decoder to the
same encoder frame until `n_max_tokens` forces it forward.

The fix is upstream's first suggested one: argmax the duration slots on the raw, pre-log-softmax
values. Three edits:

- `struct parakeet_state` gains `std::vector<float> duration_logits_raw`.
- `parakeet_joint` fetches the already-named, already-`ggml_set_output` raw `logits` node
  (`ggml_graph_get_tensor(gf, "logits")`) and copies its duration slots into that vector.
- The decode loop argmaxes `duration_logits_raw`, seeded from slot 0 rather than a sentinel, and
  falls back to the log-softmax slots if the raw tensor is unavailable.

### 2. Logging — no patch needed

Upstream already defaults both loggers to stderr (`src/parakeet.cpp:3893-3906` routes through
`g_state.log_callback`, and `ggml_log_callback_default` in `ggml/src/ggml.c:313-320` writes to
stderr). The sidecar installs its own `parakeet_log_set` callback at startup anyway, because
stdout carries the NDJSON protocol and must never receive anything else.

## Build notes

- Compiled as two SwiftPM C targets, `CGgml` and `CParakeet`; see `Package.swift`.
- `-fno-objc-arc` is required: `ggml-metal-device.m` and `ggml-metal-context.m` are manual
  retain/release, and SwiftPM compiles `.m` with ARC on by default while upstream CMake does not.
- `-mcpu=native` is deliberately **not** used, unlike the upstream CMake default. Voiceour ships a
  copyable `.app`, and a binary built with the build host's exact CPU can fault on an older Apple
  Silicon machine. The arm64 baseline still resolves NEON, ARM_FMA, FP16_VA, DOTPROD, ACCELERATE
  and REPACK at compile time, verified by `parakeet_print_system_info()`, and the heavy work runs
  on Metal.
- The embedded shader source is compiled by the Metal runtime on first use: 7.5 s the first time a
  given binary runs on a machine, 9 ms afterwards from the OS shader cache. No Metal toolchain is
  needed at build time; this vendor drop was verified on a host where
  `xcrun -sdk macosx metal --version` fails with "missing Metal Toolchain".
