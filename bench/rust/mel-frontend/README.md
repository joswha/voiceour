# mel-frontend

Benchmark-only Rust ports of parakeet.cpp's log-mel frontend (bet B2). The crate reproduces
`log_mel_spectrogram` (`Vendor/parakeet/src/parakeet.cpp` L4949–L5221) behind the `vm_` C ABI of
the program contract, plus `mel-bench`, which times every arm against the dumped native mel.
Nothing in the app depends on it.

Line references are to `Vendor/parakeet/src/parakeet.cpp` unless another file is named.

## Build, test, run

```sh
cd bench/rust/mel-frontend
cargo build --release            # target/release/libmel_frontend.dylib, target/release/mel-bench
cargo test --release             # 7 unit + 7 integration tests + 1 doctest
cd ../../..                      # mel-bench resolves index.jsonl audio paths from --repo-root (default .)
bench/rust/mel-frontend/target/release/mel-bench --dumps .build/rust-bench/dumps --passes 0   # verify 680 rows
bench/rust/mel-frontend/target/release/mel-bench --dumps .build/rust-bench/dumps \
  --arms faithful-mt,sparse,best --passes 3 --output .build/rust-bench/b2/rows.jsonl
# Paired against the native frontend, in process (the Swift harness loads the dylib):
.build/release/voiceour-bench mel-bench --dumps .build/rust-bench/dumps/jargon456 --output rows.jsonl \
  --passes 3 --rust-mel-lib bench/rust/mel-frontend/target/release/libmel_frontend.dylib
```

Tests that need the pinned model or the dumps skip themselves, with a note on stderr, when those
files are missing.

`mel-bench --dumps <dir> [--arms a,b] [--passes N] [--output rows.jsonl] [--model <bin>]
[--repo-root <dir>] [--threads N] [--limit N] [--corpus name,...]`:

- `--dumps` is one corpus directory (holding `index.jsonl`) or a parent of several.
- Each row's WAV is checked against `audio_sha256`, decoded by `wav::read_samples`, and the dumped
  mel against `mel_sha256`.
- Passes `0..=N` run, rows in index order, and pass `p` row `r` runs the arms in Williams sequence
  `(p + r) mod k`, the same design as `voiceour-bench`.
- Each output line is one contract timing row (`bet` B2, arm `rust:<name>`): `elapsed_us` is the
  wall time of one `vm_compute` call into a NaN-filled `[n_frames + 16][128]` buffer, `equal_ref`
  is bitwise equality with the dump, and `err` is `{max_abs, rel_l2}` against the dump (null when
  the output is not finite).
- There is one `run_meta` line per corpus; its `arm_details` says which implementation each name
  ran.
- A name with an `@aa` suffix makes an A/A replicate.
- Exit status: 0 when every exact arm matched every row, 1 when one did not, 2 on a usage or I/O
  error.

## The native contract (as compiled)

The ported arithmetic is the one in the release object `.build/release/CParakeet.o`, not the
source alone. SwiftPM builds parakeet.cpp with clang's default `-ffp-contract=on`, so every
`a*b + c` inside one expression becomes a fused `fmadd`/`fmsub`. Rust never contracts on its own,
so each fused operation is written as `mul_add` (or `vfmaq_f32`/`vfmsq_f32`), and every other
operation stays a separate rounding:

| step | source | as compiled (`otool -tV`) |
|---|---|---|
| sin/cos table (`fill_sin_cos_table` L562) | `sinf(theta)`, `cosf(theta)`, `theta = 2πi/n_fft` in double | `fcvt s0, d0` then one `___sincosf_stret` call |
| pre-emphasis (L5128), i from n-1 down to 1 | `x[i] - 0.97f*x[i-1]` | `fmadd s1, x[i-1], -0.97, x[i]` |
| centred padding (L5134) | `n_fft/2 = 256` zeros each side; `n_len = n/160 + 1` | |
| window (L5059) | `window[j] * padded[i*160 + 56 + j]`, 400 taps at offset 56 | `fmul` |
| FFT butterfly (L5012–L5016) | `even ± w·odd`, `w = cos - i·sin` from the table at `k·n_fft/N` | two chained `fmadd`/`fmsub` per output |
| power (L5071) | `re*re + im*im` | `fmul im,im` then `fmadd re,re` |
| mel group (L5080) | `sum += f0*w0 + f1*w1 + f2*w2 + f3*w3` | `fmadd(f3,w3, fmadd(f2,w2, fmadd(f0,w0, f1*w1)))` in float, `fcvt` to double, `fadd` |
| mel remainder (L5088) | `sum += f*w` | float `fmul`, `fcvt`, `fadd` (not fused) |
| log (L5091) | `std::log(sum + 2^-24)` | double `_log`, then `fcvt` to float |
| z-score (L5178–L5205) | double mean and `(n-1)` std over `n/160` frames, `+1e-5`, applied to all frames | variance is `fmadd d, d, sq` |

Facts about the tables and calls:

- **Tables.** The filterbank (`[128][257]`) and the 400-tap window come verbatim from the model
  file, through `parakeet_model::Model::preprocessor()`.
- **Hann window.** `mel_cache.init` (L5626) also builds a periodic Hann window, but that window is
  used only when the file has none (L5120). The engine refuses an empty window instead of
  porting the fallback.
- **Odd-size DFT.** `n_fft` must be a power of two, so the native odd-size `dft` branch (L4984)
  is unreachable and is not ported.
- **Threads.** The production `parakeet_full` passes the sidecar's `threadCount`, which defaults
  to 6 (`ParakeetContext.swift` L268), and the hybrid routes pass 4.
- **Per-call work.** Every call does all of the following:
  - spawns and joins `n_threads - 1` `std::thread`s (L5145–L5170);
  - copies the samples twice, into the pre-emphasised and padded vectors;
  - allocates two FFT buffers per thread;
  - sums all 64 groups plus the remainder, for all 128 filters of every frame;
  - runs the z-score on one thread, iterating bins in the outer loop and frames in the inner one.

## Arms

| arm | bit-identical | what changes vs. the native code | threads/call |
|---|---|---|---|
| `faithful` | yes | nothing: literal port, same recursion and scratch layout, same allocations, same loops | 1 |
| `faithful-spawn` | yes | nothing: literal port with the native threading (spawn + join per call, frame `i ≡ t mod 6`) | 6 |
| `faithful-mt` | yes | the spawns: a persistent pool runs the same six interleaved frame slices | 6 |
| `sparse` | yes | `faithful-mt` + only the 225 non-zero filter groups of 8192, frames in dynamic chunks of 8 | 6 |
| `best` | yes | iterative NEON FFT with the native arithmetic, NEON-batched sparse groups, no per-call allocation or signal copies, z-score in 32-bin column blocks on the pool | 6 |
| `realfft` | no | `best` with the `realfft` 3.5 / `rustfft` 6.4 real FFT | 6 |
| `vdsp` | no | `best` with Accelerate `vDSP_fft_zrip` (64-byte-aligned split buffers) | 6 |
| `best-approx` | yes (alias) | the fastest arm overall, which is `best` (see Timing) | 6 |

`Engine::new(frontend, arm, threads)` takes any thread count, and `mel-bench --threads N` passes
it. `vm_engine_new` always uses 6.

**The pool.** `src/pool.rs` is a persistent fork-join pool:

- The caller publishes a job, unparks the parked workers and starts working itself.
- Jobs claim work through atomic counters, so a worker that wakes late finds less or nothing to do,
  and the caller never waits for a thread that has not started.
- When the caller finishes, it retracts the job and waits only for the workers that entered.
- Workers park as soon as they find no new job, so each call pays the same wake-up a
  once-per-utterance production call would.

### Why `sparse` is exact

The pinned filterbank has 504 non-zero weights. They fall in 225 of the 8192 4-bin groups, and
the remainder bin 256 is zero in every filter. One weight is stored as `-0.0`, and `w != 0.0`
treats it as zero.

1. **A skipped group adds a signed zero.** Every product in a skipped group is a finite,
   non-negative power times `±0`, so the group's float value is `±0`, and so is its double
   widening.
2. **Adding that zero changes nothing.** The double sum starts at `+0`. Under round-to-nearest, a
   sum is `-0` only when both addends are `-0`, so the running sum is never `-0`. And `x + ±0 == x`
   for every other `x`.
3. **Kept groups are unchanged.** Kept groups are computed with the native operations, in the
   native order.

**Non-finite power.** If the power spectrum is not finite (`inf*0` is NaN, which a skipped group
would hide), the frame takes the dense loop instead. A finiteness check runs on every frame.

### Why `best`'s FFT is exact

The native recursive decimation-in-time FFT combines, for each sub-transform of size `N` and each
`k < N/2`, the even half's `E[k]` and the odd half's `O[k]` with the table twiddle at
`k·n_fft/N`. The iterative form over bit-reversed input visits the same `(E[k], O[k], twiddle)`
triples. Each output is computed by the same two fused operations, and NEON `fmla`/`fmls` round
once per lane, exactly like scalar `fmadd`. So every value is identical, and only the schedule
differs:

- stages 1 and 2 run together in registers, with contiguous loads (blocks whose bit-reversed
  sources are adjacent) and transposed stores;
- stages (4, 8), (16, 32) and (64, 128) run as fused pairs in registers;
- the last stage computes only bins `0..=256`.

**Pre-emphasis.** The native backwards loop reads only unmodified `x[t-1]`, so each pre-emphasised
sample is a pure function of two inputs. `best` computes it per frame from the original samples,
so it needs no pre-emphasised copy and no padded copy.

**Exact also means no real-input shortcut.** `cosf((float)(π/2))` is `-4.37e-8`, not 0, so even
the "trivial" twiddles must be applied.

**NaN signs.** Bit-identity covers every finite value, including signed zeros. A NaN stays a NaN,
but its sign is not reproducible. LLVM chooses which multiplicand of `a - b*c` the
`fmsub`/`fmls` instruction negates, because the IR leaves NaN signs unspecified, and a NaN operand
keeps that sign. The only way to get a NaN past the z-score is a non-finite input sample, which
16-bit PCM cannot produce. With one NaN input sample, `best` emits `0xffc00000` where `faithful`
emits `0x7fc00000` in 256 values. The test suite allows exactly this: NaN against NaN of either
sign, and only for non-finite inputs.

### vDSP alignment finding

`vDSP_fft_zrip` takes a different code path, and rounds differently, when its split buffers are
not 64-byte aligned. In a probe on macOS 27, 423 of 512 output floats changed at every byte offset
from 4 to 48. Moving to 64 bytes restored identical output.

With `malloc`'s 16-byte alignment, the arm's output therefore depended on which thread's buffers
a frame landed in. Before the fix, there were 4 distinct outputs per row in 4 passes. The arm now
uses 64-byte-aligned buffers and is deterministic: 1 distinct output per row, also checked by
`approximate_arms_stay_close`.

## Verification (observed in this worktree)

- **Build and tests.** `cargo build --release` gives no warnings. `cargo test --release` passes 7
  unit tests, 7 integration tests and 1 doctest. The integration tests cover:
  - every exact arm at 1, 3 and 6 threads against `faithful` on 25 synthetic signals: lengths
    0–4000, silence, an impulse, a full-scale square wave, int16-quantised noise, 1e-30, 1e30, and
    an inf or NaN sample;
  - the C ABI and its errors;
  - the first 3 dump rows of each corpus against the native mel.
- **Bit-identity on every dumped row.** `mel-bench --dumps .build/rust-bench/dumps --passes 0`
  (final build, file `.build/rust-bench/b2/verify-final.jsonl`) shows **`faithful`,
  `faithful-spawn`, `faithful-mt`, `sparse`, `best` (and `best-approx`) bitwise identical to the
  native mel on 680/680 rows**: general96 96/96, jargon456 456/456, librispeech128 128/128. Every
  WAV matched `audio_sha256`, and every dump matched `mel_sha256`.
- **Through the C ABI from Swift.** The in-process Swift harness loaded the dylib and computed an
  untimed native reference per row (`voiceour-bench mel-bench`, jargon456, 24 rows, 3 passes). All
  exact arms matched it, 72/72 calls each.

### Error of the approximate arms vs. the native mel (all rows, z-scored mel units)

| corpus | rows | `realfft` max_abs | `realfft` max rel_l2 | `vdsp` max_abs | `vdsp` max rel_l2 |
|---|---|---|---|---|---|
| general96 | 96 | 7.242e-4 | 5.713e-6 | 7.134e-4 | 6.394e-6 |
| jargon456 | 456 | 2.835e-4 | 3.155e-6 | 2.844e-4 | 3.854e-6 |
| librispeech128 | 128 | 7.242e-4 | 6.410e-6 | 8.714e-4 | 6.815e-6 |

Neither approximate arm is bit-identical on any row (0/680).

**Downstream effect.** Each arm's mel was decoded with the production encoder and Metal tail
(`voiceour-bench mel-bench --transcripts`, all 680 rows,
`.build/rust-bench/b2/transcripts-<corpus>.jsonl`). Tokens and text were compared with the dump's
`ref`; each cell counts rows with equal tokens / rows with equal text:

| arm | general96 (96 rows) | jargon456 (456 rows) | librispeech128 (128 rows) |
|---|---|---|---|
| `cpp` | 96 / 96 | 456 / 456 | 128 / 128 |
| `best` | 96 / 96 | 456 / 456 | 128 / 128 |
| `realfft` | 91 / 96 | 455 / 455 | 124 / 128 |
| `vdsp` | 89 / 96 | 452 / 456 | 124 / 128 |

`realfft` changed the text of one row, `jg_0094_security_argon2`, with a mel max_abs of 7.0e-5.
Altogether, `realfft` changed the tokens of 10 rows and `vdsp` of 15, but only that one text
changed. So even last-ulp FFT differences reach the decoder; `best` changed nothing.

## Exports

`nm -gU target/release/libmel_frontend.dylib`:

```text
0000000000059d4c T _vm_abi_version
0000000000059d54 T _vm_arms
0000000000059d60 T _vm_compute
000000000005a244 T _vm_engine_free
000000000005a2e8 T _vm_engine_new
```

The functions follow the contract:

- `vm_abi_version()` returns 1.
- `vm_arms()` returns `faithful,faithful-spawn,faithful-mt,sparse,best,realfft,vdsp,best-approx`.
- `vm_engine_new` opens the model (a NULL path means the pinned default), copies the frontend
  tables and drops the mapping.
- `vm_compute` returns `n_samples/160 + 1`, or -1 with `err` filled. It writes nothing on failure
  and never writes past `n_frames * 128`. It fails when:
  - `n_mels` is not 128;
  - `max_frames` is too small;
  - a pointer is NULL with data expected;
  - a negative size is passed.
- No call unwinds; panics become -1/NULL.

## Timing (development smoke only: shared machine, not official)

All runs below were made on an M4 Pro while other agents were running, with the 1-minute load
average between 7 and 25. Use them for ranking, not for official numbers.

**Rust arms, `mel-bench --limit 40 --passes 3`** (passes 1–3 timed, load ≈ 15,
`.build/rust-bench/b2/smoke1.jsonl`). Each cell is the median µs per row, then µs per second of
audio:

| arm | general96 (40 rows, 598 s) | jargon456 (40 rows, 180 s) | librispeech128 (40 rows, 1098 s) |
|---|---|---|---|
| `faithful` | 24038 / 2049.5 | 8295 / 1851.3 | 50459 / 1885.1 |
| `faithful-spawn` | 5465 / 452.3 | 1724 / 395.8 | 10082 / 384.4 |
| `faithful-mt` | 5483 / 449.2 | 1641 / 372.1 | 10205 / 382.4 |
| `sparse` | 2811 / 251.2 | 990 / 224.5 | 5831 / 217.6 |
| `best` | 375 / 33.7 | 130 / 30.2 | 666 / 26.0 |
| `realfft` | 372 / 31.8 | 135 / 31.1 | 692 / 26.6 |
| `vdsp` | 445 / 38.8 | 157 / 36.9 | 848 / 33.5 |

Paired geomean ratios against `faithful-mt` over all 120 rows (`paired_stats.py`, 95% BCa CI):

- `best` 0.0715 [0.0699, 0.0730], faster on 120/120 rows;
- `realfft` 0.0746 and `vdsp` 0.0893;
- `sparse` 0.585 [0.577, 0.593];
- `faithful-spawn` 1.031 [1.018, 1.046];
- `faithful` 4.92.

**Paired against the native frontend.** The in-process Swift harness ran jargon456's first 24
rows for 2 timed passes at load ≈ 10 (`.build/rust-bench/b2/harness-smoke-jargon.jsonl`).
`paired_stats.py --all-vs cpp` gives:

| candidate vs `cpp` (6 threads) | geomean ratio | 95% BCa CI | rows faster |
|---|---|---|---|
| `rust:best` | 0.0743 | [0.0507, 0.1018] | 24/24 |
| `rust:sparse` | 0.551 | [0.375, 0.704] | 22/24 |
| `rust:faithful-mt` | 0.854 | [0.547, 1.029], inside the A/A floor | 11/24 |
| `rust:faithful-spawn` | 1.403 | [1.176, 1.758] | 4/24 |
| `rust:faithful` (1 thread) | 3.04 | [2.29, 3.57] | 1/24 |
| `cpp@aa` | 1.175 | [0.818, 1.582] | 7/24 |

The native arm's median was 2214 µs per row, or 488 µs per audio second. `rust:best` had a median
of 165 µs, or 35 µs per audio second.

**Choosing `best-approx`.** In every smoke, `best` (exact) was as fast as or faster than `realfft`
and faster than `vdsp`, so `best-approx` resolves to `best`. Requiring bit-identity costs nothing
measurable here.

- *Per-frame microbenchmark* (single thread, 200k frames, load ≈ 13), ns for FFT plus power: exact
  365, `realfft` 410, `vdsp` 420.
- *Focused smoke*, 20 rows per corpus and 12 passes: `best` 26.3 / 43.7 / 29.0 µs per audio second,
  `realfft` 27.6 / 46.3 / 30.3, `vdsp` 32.9 / 53.6 / 35.7.

**Threads (`best`).** On jargon456's first 120 rows (median µs per row, load ≈ 7), time fell from
507 at 1 thread to 104 at 10 threads:

| threads | 1 | 2 | 4 | 6 | 8 | 10 |
|---|---|---|---|---|---|---|
| µs per row | 507 | 273 | 152 | 128 | 110 | 104 |

The arms keep the production count of 6.

**Single thread, same data** (`--threads 1`, 30 rows per corpus, load ≈ 24): `faithful`
1353–1411 µs per audio second, `sparse` 709–750, `best` 92–98.

## Where the native frontend's time goes

These estimates come from the Rust analogues, which run the same algorithm and are bit-identical.
Native numbers themselves need the harness.

- **Dense filterbank sum.** The dense sum evaluates 8192 groups per frame where 225 carry weight.
  - Single-threaded, removing the zero groups halves the frontend: `faithful` 1353–1411 → `sparse`
    709–750 µs per audio second. That is about 47% of the time.
  - At 6 threads, `faithful-mt` → `sparse` gives a geomean ratio of 0.585.
- **Per-call `std::thread` spawning.**
  - In Rust, spawning and joining 5 scoped threads costs 77 µs per call (microbenchmark, load ≈
    13).
  - `faithful-spawn` vs `faithful-mt` (same slices, same code) measured +3.1% geomean in
    `mel-bench` and +24% in the Swift-harness smoke.
  - Against the native arm, the literal port with a persistent pool (`faithful-mt`) is inside the
    A/A noise. The same port spawning per call (`faithful-spawn`) is 1.40× slower. So the language
    alone shows no measurable difference, and Rust's spawn path is heavier than libc++'s.
- **Single-threaded z-score.** It runs after the join, iterating bins in the outer loop and frames
  in the inner one. That costs 395 µs for a 10.56 s row (1057 frames), about 11% of the 3.49 ms
  stage-profile figure. `best`'s column-block version costs about 59 ns per frame (62 µs) on one
  thread, before splitting four ways.
- **Per-call signal copies.** Two copies (pre-emphasised, then padded) of 676 KB each cost 161 µs
  for a 10.56 s row, including allocation and page faults.
- **`best`'s own split** (one thread, ns per frame): window 29, exact FFT plus power ≈ 365, sparse
  groups plus 128 `log` calls ≈ 455, of which `log` is ≈ 230, z-score ≈ 59. libm `log` is kept
  deliberately, since it is the bit-identity anchor. It is now the largest single cost after the
  FFT.

**Scale.** The B0 smoke profile of one 10.56 s FLEURS row measured mel 3.49 ms out of 72 ms in
full. At the smoke rates above, `best` would take about 0.3 ms for that row and save about 3.2 ms,
roughly 4% of that row's latency. This is an inference: it needs the official paired run.

## Files

- `src/frontend.rs`: the tables (file filterbank and window, `__sincosf_stret` sin/cos table) and
  the sparse group layout.
- `src/faithful.rs`: the literal port (`faithful`, `faithful-spawn`, `faithful-mt`, `sparse`).
- `src/kernels.rs`: the dense, sparse and NEON-batched mel sums, and the finiteness guard.
- `src/exact.rs`: the iterative NEON FFT with the native arithmetic.
- `src/approx.rs`: the `realfft` and vDSP FFTs.
- `src/pipeline.rs`: the shared `best`/`realfft`/`vdsp` pipeline.
- `src/pool.rs`: the persistent pool.
- `src/engine.rs`: arms and the engine.
- `src/ffi.rs`: the `vm_` ABI.
- `src/wav.rs`: the port of `Sources/ASRSidecarCore/WAVFile.swift`.
- `src/bin/mel-bench.rs`: the bench.
- `tests/equivalence.rs`: the integration tests.
