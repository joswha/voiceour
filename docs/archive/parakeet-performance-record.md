> Archived 2026-11-06. Historical measurement record: the Parakeet recognizer and its f16/q8_0 variants measured below were deleted on 2026-11-06; current performance guidance lives in [performance-roadmap.md](../performance-roadmap.md) and current measurement contracts in [benchmarks.md](../benchmarks.md).

# Parakeet performance record

Measurements were taken on an Apple M4 Pro (10 performance + 4 efficiency cores, 24 GB). Everything below is dated 2026-08-15 on macOS 26.5.2, except the 2026-09-01 quantization correction, which re-measures that one comparison on macOS 26.6.2, and the 2026-09-04 Core ML encoder comparison.

## Model and runtime

- runtime: Swift `voiceour-asr` with vendored parakeet.cpp/ggml, Metal, and Accelerate
- model: `ggml-org/parakeet-GGUF`
- revision: `35156454d1a39de06863303dd209fd2bed6ee079`
- artifact: `ggml-parakeet-tdt-0.6b-v3-f16.bin`, 1,255,897,319 bytes — the default, and what every measurement here used unless it says otherwise
- decode: greedy TDT in the persistent sidecar
- after ASR: deterministic cleanup, glossary canonicalization, and glossary-driven vocabulary repair only

## Corpus baseline

The 2026-08-15 row-matched f16 reports had zero error rows:

| tier | rows | U-WER | CER | ASR p50 / p95 | RTFx |
| --- | ---: | ---: | ---: | ---: | ---: |
| LibriSpeech | 128 | 2.807% | 0.882% | 201.0 / 274.3 ms | 112.96 |
| FLEURS | 64 | 4.416% | 1.929% | 90.5 / 125.3 ms | 99.93 |

Reports: `benchmarks/results/20260815T172106Z-librispeech-parakeet-stt.json`, `benchmarks/results/20260815T172117Z-fleurs-parakeet-stt.json`.

## Why f16 was the default

Same tiers and revision, measured 2026-08-15; f16 first, q8_0 second. The f16 column here is the 2026-08-14 baseline this experiment was matched against, so its throughput differs slightly from the corpus baseline above:

- artifact size: 1,255,897,319 B, 668,757,119 B
- isolated cold load: 3,525 ms, 2,111 ms
- LibriSpeech ASR p50 / p95: 202.5 / 272.7 ms, 216.5 / 329.4 ms; RTFx 113.5, 103.4
- FLEURS ASR p50 / p95: 90.5 / 125.4 ms, 109.0 / 156.5 ms; RTFx 99.7, 84.1
- U-WER: LibriSpeech 2.807%, 2.782%; FLEURS 4.416%, 4.416%

Quantization saved 587 MB at effectively unchanged accuracy but lost 7–19% throughput on that toolchain, which is why f16 was the default and the compiled fallback. q8_0 shipped as the user-selectable Compact option, because roughly half the footprint for that throughput was a choice only the reader could make. Reports: `20260815T143055Z-librispeech-parakeet-stt.json`, `20260815T143116Z-fleurs-parakeet-stt.json`. The throughput half of that rationale did not reproduce on a later toolchain; the correction below measures it.

Weaker corroboration, 32 LibriSpeech rows: both artifacts scored U-WER 2.2422%, with 31 of 32 transcripts byte-identical. A run that short cannot resolve a difference this small — it sits below the corpus's resolution — so it agrees with the accuracy result above without independently establishing it.

### Correction — 2026-09-01: the throughput penalty does not reproduce on macOS 26.6.2

Re-measured on the same M4 Pro under macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Swift 6.3.3: one warmup plus two timed passes per variant inside one persistent `voiceour-bench pipeline` process, zero error rows, zero cross-pass transcript drift. q8_0 p50 lands at 0.979–0.993 of f16 across all five duration buckets — tied in the two short buckets, 1–3% faster in the long ones. A stock Metal System Trace of one 31.65 s row attributes the change: the LSTM prediction plus joint tail is 24.8% cheaper under q8_0 and the FastConformer encoder 2.5% dearer, so the net favors q8_0. A 552-row probe over both development corpora scored ΔU-WER +0.000307 with equal term metrics and p95 205.75 ms against f16's 208.0 ms, and 20 of those 552 transcripts still differ, so this is parity rather than dominance.

The 2026-08-15 table above stands as the historical record. It was measured correctly, the artifacts had not changed, and the pinned digests still matched; what moved underneath it was the OS and toolchain.

f16 remained the default, because this measurement could not carry a default change: one Mac, one SoC, one OS, and development corpora — 96 general rows in `bench/autoresearch/corpus.manifest.jsonl` plus 456 synthetic `say` rows in `benchmarks/data/jargon/manifest.jsonl`, which is engineering evidence, not real speakers. Full measurement record: `research/bet3-quantization.md`.

## Core ML encoder export headroom — 2026-09-04

Benchmarked against Desert Ant Labs' Voz, an independent export of the same checkpoint: its encoder runs p50 25.07 ms against the palettize6 standard tier's 30.50 ms on this M4 Pro (ratio 0.822, three runs), while additionally applying the joint's 1024→640 projection and returning 240,640 bytes instead of 770,048. The three candidate causes, in order: re-export on the current toolchain (coremlc 3520.5.1 against Voz's 3600.25.2), fp16 Core ML IO, and fusing the joint projection into the graph. Full measurement: [`research/external-voz-evaluation.md`](../../research/external-voz-evaluation.md).

Voz itself was a non-candidate: the same Parakeet TDT 0.6B v3 weights in a 6-bit palettized graph this repository already built. Adopting it would have cost the macOS 14 fallback, a second vendor patch for its 640-channel output, a second pinned model family with four files the Hub publishes no digest for, and CC BY 4.0 traded for a source-available licence with an audit clause — to buy one stage.
