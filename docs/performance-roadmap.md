# Performance

Measurements were taken on an Apple M4 Pro (10 performance + 4 efficiency cores, 24 GB). Everything below is dated 2026-08-15 on macOS 26.5.2, except the 2026-09-01 quantization correction, which re-measures that one comparison on macOS 26.6.2.

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

## Capture latency and liveness

`AVCaptureSession.startRunning()` measures 134–216 ms, so it runs off the main actor. Start and stop share a serial queue, so stop cannot overtake a start in progress.

Buffers arrive before the microphone produces signal:

| selected input | first buffer | first non-zero buffer |
| --- | ---: | ---: |
| built-in MacBook microphone, lid open | 99 ms | 99 ms |
| built-in MacBook microphone, lid closed | 121 ms | never |
| AirPods Max, cold | 143 ms | 1,422 ms |
| AirPods Max, warm | 172 ms | 551 ms |
| Continuity iPhone microphone | 3,782 ms | 3,782 ms |

The 1.3-second Bluetooth gap is HFP/SCO warmup filled with digital zeros, so the overlay stays warming until the first non-zero buffer. A closed lid silences the built-in array permanently while every HAL and AVFoundation property reports a healthy device, so Bluetooth is never redirected to built-in with the lid closed. The warm-up deadline is 6 s, the smallest bound that cannot cut off the Continuity microphone.

At stop, the 120 ms `SystemAudioMuter.restore()` fade overlaps transcription instead of blocking inference.

## Why f16 is the default

Same tiers and revision, measured 2026-08-15; f16 first, q8_0 second. The f16 column here is the 2026-08-14 baseline this experiment was matched against, so its throughput differs slightly from the corpus baseline above:

- artifact size: 1,255,897,319 B, 668,757,119 B
- isolated cold load: 3,525 ms, 2,111 ms
- LibriSpeech ASR p50 / p95: 202.5 / 272.7 ms, 216.5 / 329.4 ms; RTFx 113.5, 103.4
- FLEURS ASR p50 / p95: 90.5 / 125.4 ms, 109.0 / 156.5 ms; RTFx 99.7, 84.1
- U-WER: LibriSpeech 2.807%, 2.782%; FLEURS 4.416%, 4.416%

Quantization saves 587 MB at effectively unchanged accuracy but lost 7–19% throughput on that toolchain, which is why f16 is the default and the compiled fallback. That is not a reason to withhold the trade: q8_0 ships as the user-selectable Compact option, because roughly half the footprint for that throughput is a choice only the reader can make. Reports: `20260815T143055Z-librispeech-parakeet-stt.json`, `20260815T143116Z-fleurs-parakeet-stt.json`. The throughput half of that rationale no longer reproduces on the current toolchain; the correction below measures it.

Weaker corroboration, 32 LibriSpeech rows: both artifacts scored U-WER 2.2422%, with 31 of 32 transcripts byte-identical. A run that short cannot resolve a difference this small — it sits below the corpus's resolution — so it agrees with the accuracy result above without independently establishing it.

### Correction — 2026-09-01: the throughput penalty does not reproduce on macOS 26.6.2

Re-measured on the same M4 Pro under macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Swift 6.3.3: one warmup plus two timed passes per variant inside one persistent `voiceour-bench pipeline` process, zero error rows, zero cross-pass transcript drift. q8_0 p50 lands at 0.979–0.993 of f16 across all five duration buckets — tied in the two short buckets, 1–3% faster in the long ones. A stock Metal System Trace of one 31.65 s row attributes the change: the LSTM prediction plus joint tail is 24.8% cheaper under q8_0 and the FastConformer encoder 2.5% dearer, so the net favors q8_0. A 552-row probe over both development corpora scored ΔU-WER +0.000307 with equal term metrics and p95 205.75 ms against f16's 208.0 ms, and 20 of those 552 transcripts still differ, so this is parity rather than dominance.

The 2026-08-15 table above stands as the historical record. It was measured correctly, the artifacts have not changed, and the pinned digests still match; what moved underneath it is the OS and toolchain. Treat the 7–19% figure as history, not as the current cost of Compact.

f16 remains the default, because this measurement cannot carry a default change: one Mac, one SoC, one OS, and development corpora — 96 general rows in `bench/autoresearch/corpus.manifest.jsonl` plus 456 synthetic `say` rows in `benchmarks/data/jargon/manifest.jsonl`, which is engineering evidence, not real speakers. Flipping the default is a product decision gated on cross-SoC replication and the paired real-speaker gate in [`benchmarks.md`](benchmarks.md). Full measurement record: `research/bet3-quantization.md`.

## Ranked next measurements

1. **Held-out real-speaker TechTerms corpus.** The synthetic tier cannot establish jargon recall, false replacement rate, or speaker generalization.
2. **Stop-to-delivery distribution.** Segment `SessionStageTimings.stopReleaseToInsertionOutcomeMs` by mute state, model load, target disposition, and capture device.
3. **Energy and thermal cost.** Compute-rail energy over the development corpora is measured in `research/bet2-ane-encoder.md`; thermal behavior, and energy for long single dictations, are not.
4. **Cold-cache first run.** Time download, cache verification, shader compilation, model load, and first delivery separately; one total cannot locate the wait.

## Non-candidates

- Rewriting Swift/C in Rust: inference already runs in Metal/Accelerate kernels.
- Hand-written Metal: no kernel hotspot has been demonstrated.
- A second recognizer: a parallel permission, model, and runtime surface.

## Reproducing evidence

```sh
swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav

cd bench
uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend parakeet --n 64
uv --no-config run python -m voiceour_bench.run --tier fleurs --mode stt --backend parakeet --n 64
```

Compare reports only through the row-id/provenance gate in [`benchmarks.md`](benchmarks.md). Corpus benchmarks never exercise the microphone; capture and device behavior need the opt-in physical-microphone tests.
