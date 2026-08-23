# Performance: measured state and roadmap

Measurements were updated through 2026-08-15 on an Apple M4 Pro (10 performance + 4 efficiency cores, 24 GB) running macOS 26.5.2. Current runtime is the Swift `voiceour-asr` executable linked to vendored parakeet.cpp/ggml with Metal and Accelerate.

This is a decision record for the app that ships now. Historical experiments that no longer have a product path belong under `docs/archive/`.

## Current model and runtime

- model: `ggml-org/parakeet-GGUF`
- revision: `35156454d1a39de06863303dd209fd2bed6ee079`
- artifact: `ggml-parakeet-tdt-0.6b-v3-f16.bin`
- size: 1,255,897,319 bytes
- decode: greedy TDT through the persistent Swift sidecar
- processing after ASR: deterministic cleanup and glossary canonicalization only

The first launch downloads the artifact; later dictation is offline. The model stays resident while active and may unload after the sidecar's idle policy. A successful reload clears any prior load-failure latch.

## Current corpus baseline

The 2026-08-15 row-matched f16 reports used zero error rows:

| tier | rows | U-WER | CER | ASR p50 | ASR p95 | RTFx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| LibriSpeech | 128 | 2.807% | 0.882% | 201.0 ms | 274.3 ms | 112.96 |
| FLEURS | 64 | 4.416% | 1.929% | 90.5 ms | 125.3 ms | 99.93 |

FLEURS formatting on the same run measured case F1 0.9218 and punctuation micro-F1 0.8380.

Reports:

- `benchmarks/results/20260815T172106Z-librispeech-parakeet-stt.json`
- `benchmarks/results/20260815T172117Z-fleurs-parakeet-stt.json`

These corpus timings exclude speech duration and model acquisition. They measure one warm process over each manifest; one recorded load value therefore represents the run's load event rather than a per-row cost.

## Capture latency and liveness

`AVCaptureSession.startRunning()` measured 134–216 ms and is intentionally off the main actor. Start and stop share a dedicated serial queue so stop cannot overtake an in-progress start.

The input path distinguishes “buffer arrived” from “microphone produced signal”:

| selected input | first buffer | first non-zero buffer | all-zero buffers |
| --- | ---: | ---: | ---: |
| built-in MacBook microphone, lid open | 99 ms | 99 ms | 0 / 375 |
| built-in MacBook microphone, lid closed | 121 ms | never | 552 / 552 |
| AirPods Max, cold | 143 ms | 1,422 ms | 64 / 197 |
| AirPods Max, warm | 172 ms | 551 ms | 19 / 292 |
| Continuity iPhone microphone | 3,782 ms | 3,782 ms | 0 / 21 |

The 1.3-second Bluetooth gap is HFP/SCO warmup filled with digital zeros. It is why the overlay remains in its warming state until the first non-zero buffer instead of declaring the microphone live on callback arrival.

The clamshell row is a different failure and is permanent, not slow: a closed lid silences the built-in array while every HAL and AVFoundation property still reports a healthy device. It sets both the device policy (no Bluetooth-to-built-in redirect with the lid closed) and the need for a warm-up deadline. The Continuity row sets that deadline's floor: 6 s is the smallest bound that cannot cut off a real microphone measured here.

A private historical corpus of 353 dictations measured these capture distributions:

| span | p50 | p90 | p95 | max | n |
| --- | ---: | ---: | ---: | ---: | ---: |
| capture duration | 10.0 s | 37.0 s | 46.0 s | 92 s | 141 |
| start latency | 188 ms | 219 ms | 231 ms | 1,766 ms | 43 |

The source history is private and not committed, so these values are design evidence, not a repository-reproducible benchmark. They remain useful for sizing the overlay, auto-stop, timeouts, and cancellation tests.

## Stop-path overhead

A historical within-backend comparison isolated system-audio mute state:

- muted: 199 ms p50 non-ASR overhead, n=92;
- unmuted: 72 ms p50, n=13;
- measured difference: 127 ms;
- configured fade duration: 120 ms;
- muted share of real sessions in that corpus: 80.1%;
- representative inference in that cohort: 117.8 ms.

The fix starts `SystemAudioMuter.restore()` at stop and lets its fade overlap transcription instead of awaiting it before ASR. The path remains idempotent and records whether muting actually occurred. Do not put this await back in front of inference.

The aggregate muted/unmuted difference across all historical backends was only 38 ms and was confounded by backend mix. The within-backend 127 ms comparison is the useful evidence.

## Swift sidecar result

The Swift sidecar replaced the earlier Python runtime on 2026-08-14. Against the same rows and scorer it preserved or improved accuracy while reducing latency:

| tier / metric | earlier runtime | Swift sidecar | delta |
| --- | ---: | ---: | ---: |
| LibriSpeech U-WER | 2.845% | **2.812%** | -0.03 pp |
| LibriSpeech CER | 0.923% | **0.884%** | -0.04 pp |
| LibriSpeech ASR p50 | 255.0 ms | **202.5 ms** | -20.6% |
| LibriSpeech ASR p95 | 348.0 ms | **272.7 ms** | -21.6% |
| LibriSpeech load p50 | 886 ms | **314 ms** | -64.6% |
| FLEURS U-WER | 4.416% | 4.416% | 0.00 pp |
| FLEURS CER | 1.972% | **1.930%** | -0.04 pp |
| FLEURS ASR p50 | 122.5 ms | **90.5 ms** | -26.1% |
| FLEURS RTFx | 61.7 | **99.7** | +61.6% |

The production path already kept audio conversion outside inference, so the corpus improvement was 20–26%, not the larger gap suggested by an isolated runtime harness.

The bundle proof copied `.build/Voiceour.app` to `/tmp` and launched it without repository context. Its bundled sibling helper loaded to 1,284 MB resident and transcribed the fixture with no Python or uv. The first run of a binary spent 7.5 s compiling the embedded Metal library; the OS shader cache reduced later startup to 9 ms. `leaks --atExit` reported zero leaks for a complete proof run.

Two lifecycle constraints came from corpus-scale failures:

1. Constructing two Parakeet contexts concurrently and freeing the loser destroyed ggml's shared Metal device; the failed run produced 256/256 errors. Context construction is serialized under a dedicated load lock.
2. An unbounded Darwin `Process.waitUntilExit()` could hang after the child had already exited. Shutdown uses bounded polling/join behavior and never follows it with an unbounded wait.

## f16 remains the pin

The 2026-08-15 q8_0 evaluation used identical tiers and the same model revision:

| metric | f16 | q8_0 | delta |
| --- | ---: | ---: | ---: |
| artifact size | 1,255,897,319 B | 668,757,119 B | -46.7% |
| LibriSpeech U-WER | 2.807% | 2.782% | -0.025 pp |
| LibriSpeech ASR p50 / p95 | 202.5 / 272.7 ms | 216.5 / 329.4 ms | +14.0 / +56.7 ms |
| LibriSpeech RTFx | 113.5 | 103.4 | -10.1 |
| FLEURS U-WER | 4.416% | 4.416% | 0 |
| FLEURS ASR p50 / p95 | 90.5 / 125.4 ms | 109.0 / 156.5 ms | +18.5 / +31.1 ms |
| FLEURS RTFx | 99.7 | 84.1 | -15.6 |

Quantization saved 587 MB and shortened an isolated cold load (2,111 ms versus 3,525 ms) but lost 7–19% throughput on both corpora. Accuracy was effectively unchanged. Unified memory was not bandwidth-bound enough for dequantization work to pay for itself, so f16 remains the compiled contract.

Reports for this experiment are `20260815T143055Z-librispeech-parakeet-stt.json` and `20260815T143116Z-fleurs-parakeet-stt.json`, compared with the committed f16 baselines from 2026-08-14.

## Capture correctness before speed

Capture failures can otherwise look like successful silence. The shipping path now:

- latches runtime errors and active-device disconnects;
- rejects a failed or zero-frame recording;
- counts frames only after successful WAV writes;
- removes a created WAV when capture startup fails;
- identity-checks recorder teardown;
- gives the finalization pipeline sole ownership of discard;
- runs audio telemetry analysis away from the main actor.

These choices may spend a small amount of cleanup time but prevent an invalid recording from reaching a recognizer and producing a confident hallucination. They are correctness constraints, not optimization candidates.

## Ranked next measurements

1. **Held-out real-speaker TechTerms corpus.** The synthetic tier is useful for deterministic smoke but cannot establish jargon recall, false replacement rate, microphone effects, or speaker generalization.
2. **End-to-end stop-to-delivery distribution on the current pipeline.** Old session distributions include removed paths. Use `SessionStageTimings.stopReleaseToInsertionOutcomeMs` and segment by mute state, model load, target disposition, and capture device.
3. **Energy and thermal cost.** Measure long dictations and repeated short dictations with Instruments or `powermetrics`; no current number supports an energy claim.
4. **Cold-cache user experience.** Record download throughput, cache verification, shader compilation, model load, and first successful delivery separately. A first-run percentage without these spans cannot identify the wait.
5. **Bluetooth/device-route matrix.** Repeat first-buffer, first-signal, dropout, and disconnect measurements across AirPods generations, USB devices, and built-in microphones.
6. **Memory after idle unload/reload.** Verify resident-size recovery and first-decode latency across the sidecar's actual idle policy.

## Non-candidates

- Replacing Swift/C with Rust does not target a measured bottleneck. The current hot work is model inference already running in Metal/Accelerate kernels.
- Hand-written Metal without a demonstrated kernel hotspot adds maintenance and vendor divergence without evidence.
- Moving work back into the app process removes crash isolation and does not reduce model compute.
- Reintroducing a second recognizer creates a parallel permission/model/runtime surface without beating the current content or latency baseline.
- Optimizing away the capture failure latch, cache manifest checks, protocol-version checks, or target identity checks is prohibited; each protects correctness or safety rather than incidental overhead.

## Reproducing current evidence

```sh
swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav

cd bench
uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend parakeet --n 64
uv --no-config run python -m voiceour_bench.run --tier fleurs --mode stt --backend parakeet --n 64
```

Compare reports only through the row-id/provenance gate documented in [`benchmarks.md`](benchmarks.md). For capture startup and device behavior, use the opt-in physical-microphone tests or a recorded manual protocol; corpus STT benchmarks do not exercise the microphone.
