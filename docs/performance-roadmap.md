# Performance

Measurements were taken on an Apple M4 Pro (10 performance + 4 efficiency cores, 24 GB). Each section names its date and OS.

## Model and runtime

- runtime: Swift `voiceour-asr` with vendored ggml and the Granite port (`CGranite`), Metal, and Accelerate
- model: the pinned Granite Speech 5 TurboCTC Q8_0 GGUF; [README.md](../README.md#model-and-network-contract) owns its id, revision, file and digest
- decode: greedy CTC in the persistent sidecar
- after ASR: deterministic cleanup, glossary canonicalization, and glossary-driven vocabulary repair only

## Recognizer measurements

The [Granite evaluation backend](benchmarks.md#granite-evaluation-backend--2026-11-03) record, measured 2026-11-03 on macOS 27.0.1 through the production path, holds the current accuracy, warm model latency (p50 38.0 ms / p95 116.2 ms), first result, memory, GPU energy and reliability figures. Its paired-gate verdicts and open promotion blockers are part of that record.

## Capture latency and liveness

Measured 2026-08-15 on macOS 26.5.2.

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

## Ranked next measurements

1. **Held-out real-speaker TechTerms corpus.** The synthetic tier cannot establish jargon recall, false replacement rate, or speaker generalization.
2. **Stop-to-delivery distribution.** Segment `SessionStageTimings.stopReleaseToInsertionOutcomeMs` by mute state, model load, target disposition, and capture device.
3. **Energy and thermal cost.** Only the system GPU energy counter has been measured for the recognizer; CPU, ANE and total energy, thermal behavior, and energy for long single dictations are not.
4. **Cold-cache first run.** Time download, cache verification, shader compilation, model load, and first delivery separately; one total cannot locate the wait.

## Non-candidates

- Rewriting Swift/C in Rust: inference already runs in Metal/Accelerate kernels.
- Hand-written Metal: no kernel hotspot has been demonstrated.
- A second recognizer: another parallel permission, model, and runtime surface.

## Reproducing evidence

```sh
swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav

cd bench
uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --n 64
uv --no-config run python -m voiceour_bench.run --tier fleurs --mode stt --n 64
```

Compare reports only through the row-id/provenance gate in [`benchmarks.md`](benchmarks.md). Corpus benchmarks never exercise the microphone; capture and device behavior need the opt-in physical-microphone tests.
