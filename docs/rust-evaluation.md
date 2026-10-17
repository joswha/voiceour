# Rust rewrite evaluation

## Conclusion

A selective rewrite can reduce Voiceour's warm speech-processing time. On the measured M4 Pro,
replacing the mel frontend and TDT decoder with the Rust implementations reduced **complete
PCM-to-cleaned-text computation by 22–30%**, with the native Metal encoder and pinned f16 weights
unchanged. The equivalent C decoder performs essentially the same. This is evidence for the
implementation changes, **not an intrinsic Rust-over-C++ advantage**.

The app's shipping path is unchanged. These are executable experiments under `bench/rust/` and
`voiceour-bench`, not a new production backend. This study does not establish that Voiceour is the
fastest or most accurate app on macOS. It establishes a reproducible improvement over this
repository's current default on the tested hardware and inputs.

## Primary evidence: complete warm computation

The `combined-bench` command starts every arm with the same decoded PCM. It measures mel generation,
per-utterance encoder shape preparation, native Metal encoding, any host/device copies, decoding,
real token-to-segment conversion, `TokenMapping`, `LiteralComposition`, and `CleanupEngine` with an
empty glossary. It never substitutes cached mel or encoder output for that work. There is no
untimed same-row full-decode primer. Input reading, hashing and output comparisons are outside every
arm's timer; one full warmup pass precedes five measured passes.

| Corpus | Rows | Native p50, ms | Rust mel + tail p50, ms | Total-time ratio, Rust/native | 95% BCa interval |
|---|---:|---:|---:|---:|---:|
| General speech | 96 | 122.330 | 84.576 | 0.7030 | 0.6972–0.7084 |
| Synthetic technical speech | 456 | 44.033 | 34.665 | 0.7839 | 0.7813–0.7863 |
| LibriSpeech | 128 | 142.370 | 98.131 | 0.6965 | 0.6924–0.7006 |

Percentiles use the per-row median across measured passes. The primary ratio is the sum of candidate
row medians divided by the sum of baseline row medians, not the ratio of the table's p50s.
The intervals use 10,000 paired row-bootstrap resamples. Native A/A total-time ratios were
1.0002, 1.0003 and 0.9996 respectively; every interval included 1.

All **24,480 arm invocations**, including warmup, completed without errors or identity failures.
Every candidate matched the native token ids, frame/duration decisions, transcript text, cleaned
text and segment timestamps on all 680 row instances. Those instances contain **627 unique audio
files**: General and LibriSpeech share 53. They are not independent replications and are not pooled.
Probability floats are not bit-identical: the harness records their differences separately.
Equal words and timestamps do not establish identical confidence or least-confident-word behavior.

The C-control arm uses the same Rust mel and replaces only the Rust decoder with its equivalent C11
implementation. Its total-time ratios were 0.7008, 0.7782 and 0.6967. Thus the decoder's gain does not
require adopting Rust. There is no C control for the optimized mel implementation.

Raw primary evidence is under `.build/rust-bench/official/20261017-combined/`. Every file carries the
native executable hash, Rust library hashes, model digest checked against its pin, dump/audio
provenance, source-state digests, host metadata, and a checked completion footer.
The [committed proof packet](../benchmarks/results/20261017-rust-combined-proof.json) preserves the
per-corpus analyses, A/A and C controls, completed-grid counts, runtime provenance and raw-file hashes.

### What this does not measure

- Microphone startup/finalization, focus inspection, journal persistence, sidecar IPC or paste delivery.
- The app's active glossary and vocabulary repair; those are evaluated separately by the text harness.
- Cancellation: the experimental Rust and C decoder ABIs do not implement it.
- Inputs longer than 34.955 seconds, scheduler growth above the 5,000-frame context, or real-time streaming.
- Cold download, disk-cold loading, energy, sustained thermal behavior, or interactive CPU contention.
- Population accuracy or technical-speaker generalization. The 456 jargon clips are synthetic speech.

This is **warm ASR computation**, not microphone-to-paste latency. Identical transcripts preserve the
existing recognition errors on these inputs; the rewrite does not improve jargon recognition.

## Experiments and attribution

| Experiment | Implementation under test | Interpretation |
|---|---|---|
| B1: decoder | Fixed-shape NEON kernels, precomputed encoder projection, persistent CPU workers, raw-logit selection, deferred probability calculation | The C control matches Rust. Nine participants replace GPU graph-dispatch overhead; compare against the existing six-thread CPU tail as well as default Metal. |
| B2: mel | Exact FFT arithmetic/FMA order, sparse filter groups, vectorized execution, persistent workers | A literal Rust port is not the win. The native filterbank processes 8,192 groups per frame, only 225 nonzero. Exact arithmetic matters: approximate FFT variants changed some decoder decisions. |
| B3: text | Rust port of composition, cleanup, glossary and repair, plus optimized Swift controls | Allocation, regex construction, bridging and Levenshtein storage dominate the original Swift path. Optimized Swift captures the gain without a language migration. |
| B4: encoder | Candle Metal and Rust bindings over MLX, several precisions and fused kernels | Kernel/runtime and precision comparisons, not Rust-language controls. Numeric closeness alone does not establish recognition equivalence. |
| B5: sidecar shell | Existing stage and client round-trip instrumentation | Lower-priority than encoder/decoder work. Separate-process timing differences are noisy and cannot isolate IPC precisely. |
| B6: overlay | Literal Rust raster port, NEON redesign, equivalent Swift SIMD redesign | Rendering is not on the measured ASR path. `-Ounchecked` is a benchmark control, not a recommendation to remove production safety checks. |
| B7: combined | Exact Rust mel + native Metal encoder + Rust/C decoder + deterministic text rendering | Primary inference-speed proof above; measured directly rather than inferred from stage sums. |

The text differential suite compares composition, cleanup, final text, compiled vocabulary and repair
events including score bits. The renderer suite compares pixels across seeds, motion, poses and
accessibility states. Each crate's README records its algorithms, ABI, controls and development
measurements; development measurements are not substitutes for the qualified runs.

### Component results

The [component evidence packet](../benchmarks/results/20261017-rust-component-evaluation.json)
retains the paired analyses, controls, warnings, provenance and encoder transcript differences.
The qualified mel runs measured Rust/native total-time ratios of 0.0842, 0.0955 and 0.0853 across
General, jargon and LibriSpeech respectively. This roughly elevenfold **stage** acceleration
corresponds to only 2–3% less complete computation when replacing mel alone in B7.

Encoder ratios below compare each candidate with its **own process's** native encoder, with
three measured passes after warmup. They are not complete-ASR ratios:

| Encoder arm | General ratio | Jargon ratio | LibriSpeech ratio | Identical raw-text rows |
|---|---:|---:|---:|---:|
| Candle f16 weights / f32 activations, fused | 0.955 | 0.771 | 0.949 | 680/680 |
| Candle f16, fused | 0.835 | 0.729 | 0.832 | 678/680 |
| MLX f32 | 2.020 | 0.844 | 1.395 | 680/680 |
| MLX f32 with native-like f16 matmul rounding | 1.611 | 0.898 | 1.444 | 680/680 |
| MLX f16 | 1.504 | 0.717 | 2.003 | 680/680 |
| MLX compiled f16 | 1.588 | 0.691 | 2.362 | 680/680 |

Every encoder arm changed some token timing decisions, despite the mostly identical words.
Candle f16 changed `Metasploit` to `Metasploid` in one technical utterance. Its tiny aggregate
U-WER improvement hides that new jargon error: it is not a reason to promote the lower precision.
No encoder arm produced non-finite output or runtime errors in the qualified matrix.

**Memory qualification matters:** host swap usage reached about 5.3 GB during the variable-length
MLX runs even with one candidate per process. Some long-form p95s approached one second. The table
records what ran on this shared laptop; it does not isolate kernel throughput from memory pressure
or establish a universal Candle/MLX ranking. These encoder variants remain experimental.

Text results use 300 public-corpus transcript cases and five measured passes. Different glossary
sets contain different terms, so this is not a cost model depending only on vocabulary size:

| Active terms | Shipping Swift p50, µs | Rust through FFI p50, µs | Optimized Swift p50, µs |
|---|---:|---:|---:|
| 0 | 400.8 | 67.3 | 403.6 |
| 10 | 3882.6 | 1202.4 | 1324.1 |
| 50 | 11558.5 | 5132.4 | 4465.3 |
| 100, jargon glossary | 17801.0 | 8549.1 | 7073.1 |

The optimized Swift control is faster than the Rust port at 50–100 active terms. All candidates
matched the text differential corpus's 131,994 cases, including repair-event scores. The timing
harness's legacy native-executable fingerprint/footer limitation is recorded in the packet.

The renderer's 1,264-row, ten-pass timing run measured ratios of 0.778 for the literal Rust port,
0.434 for the Rust SIMD redesign, 0.668 for the Swift SIMD redesign and 0.489 for its unchecked
control. All four controls remained pixel-identical on the separate 1,552-state verification.
These are renderer CPU costs, not dictation latency savings.

### Verification

`make check` passed: 766 Swift tests, 132 Python tests, 26 semantic UI flows with 234 expectations,
the mercury performance gate, app self-test and fake-sidecar benchmark smoke. All seven Rust
experiment crates passed their release test commands, and the renderer equivalence check passed.
The full upstream vendor reapplication check reproduced all 72 manifest files.

## Measurement decisions

1. **Hold weights constant.** Use the existing pinned f16 Parakeet artifact, not a smaller or differently
   trained model disguised as a language improvement.
2. **Preserve output before pursuing speed.** Keep exact mel and decoder variants as the combined
   candidate. Quantized-tail and approximate-FFT output changes are not silently accepted.
3. **Separate language from design.** Include a C decoder control and optimized Swift text/raster controls.
   MLX is largely C++/Metal beneath its Rust bindings; credit its kernels accordingly.
4. **Measure the complete path.** The isolated B1 Metal tail was substantially slower than the tail
   immediately following a production encoder. GPU state/carryover is a plausible explanation, not
   a measured causal diagnosis. A/A can share that bias. Never convert B1's isolated speedup into
   an app-latency prediction; B7 measures the actual combined computation.
5. **Reject incomplete evidence.** A reboot interrupted the first encoder run; its Candle arms also
   failed runtime Metal compilation. That file is retained as failure evidence and excluded from
   successful encoder comparisons. Candle now pins MSL 3.2 through a checksum-verified dependency patch.
6. **Control resources and power.** Run one encoder candidate per process against its own native
   baseline/A/A, rather than keeping roughly 8.5 GiB of candidate weights resident together. Check
   AC power before and after measurements and record swap usage. Earlier battery/mixed-power runs
   remain labeled exploratory instead of being represented as AC-qualified.
7. **Offload only portable work.** SHA-verified timing files were analyzed on `ubuntu-devbox`, with
   niced CPU jobs. All Apple-Silicon/Metal/Swift timing remained on the Mac. Linux GPU timings cannot
   substantiate macOS latency.
8. **Do not promote an unqualified runtime.** Keep the app unchanged. Shipping would additionally need
   cancellation/lifecycle, memory/energy, clean-bundle and cross-SoC qualification. The C-control and
   optimized Swift results argue against adding a Rust toolchain merely for speed.

Confidence intervals are conditional on these frozen rows and this run. They do not include
between-machine, reboot or power-state variability. Synthetic jargon rows share terms, natural speech
rows may share speakers, and no population or multiple-comparison-adjusted superiority claim is made.

## Reproduction

Prerequisites: Apple Silicon, the repository's macOS/Swift baseline, Rust 1.97 or later, the verified
model cache, and the frozen corpus audio matching the manifests. The committed General manifest is
`bench/autoresearch/corpus.manifest.jsonl`; the measured jargon and LibriSpeech manifests/audio live
under `benchmarks/data/`. Regenerated public data or synthesized audio is a **new measurement**, not
a guarantee of reproducing the original audio hashes.

Build the shipping benchmark and standalone experiments before measuring:

```sh
swift build -c release --product voiceour-bench -Xswiftc -warnings-as-errors
swift build -c release --product voiceour-asr
bench/rust/encoder-candle/patches/vendor-candle-metal-kernels.sh
for crate in parakeet-model tdt-tail mel-frontend voiceour-text mercury-raster encoder-candle encoder-mlx; do
    cargo build --release --locked --manifest-path "bench/rust/$crate/Cargo.toml"
done
swift build -c release --package-path bench/rust/swift-text-harness
swift build -c release --package-path bench/rust/swift-mercury-harness
```

The Candle bootstrap reads a checksum-matched crate cache or an explicit `--crate` file; `--fetch`
opts into dependency acquisition. MLX needs CMake and Apple's Metal toolchain; its build fetches
MLX/metal-cpp and installs a local `~/.mlx/lib/.../mlx.metallib`. These are development-only
requirements; neither Rust nor MLX is added to the shipping app build.

Create fresh dumps; the commands refuse overwriting old evidence:

```sh
.build/release/voiceour-bench dump-states --input bench/autoresearch/corpus.manifest.jsonl --output-dir .build/rust-bench/dumps/general96
.build/release/voiceour-bench dump-states --input benchmarks/data/jargon/manifest.jsonl --output-dir .build/rust-bench/dumps/jargon456
.build/release/voiceour-bench dump-states --input benchmarks/data/librispeech/manifest.jsonl --output-dir .build/rust-bench/dumps/librispeech128
```

Run the primary proof in a new directory, then analyze each corpus separately:

```sh
RUST_BENCH_OUT=.build/rust-bench/reproduction PASSES=5 bench/rust/run_official.sh combined
uv --no-config run --project bench python bench/rust/analysis/paired_stats.py \
    --check .build/rust-bench/reproduction/b7.jargon456.jsonl --all-vs native
```

The same runner exposes `ledger`, `cold`, `tail`, `mel`, `encoder`, `text` and `mercury` sections.
Prepare text cases with `bench/rust/voiceour-text/target/release/text-bench gen-inputs` and run
the [text parity script](../bench/rust/voiceour-text/scripts/b3-parity.sh) before its timing section. Renderer verification is
`bench/rust/swift-mercury-harness/.build/release/swift-mercury-harness verify`.

The analyzer refuses incomplete declared grids, required missing completion footers and invalid
outputs. Legacy files without a completion contract are identified as such. Sub-resolution zero
times are reported, never replaced with a fabricated epsilon. Use `--stage-parts mel,encode,tail`
with `--stage-profile`: WAV loading, assembly, cleanup and repair are outside the native `full` timer.
