> Archived 2026-08-25. Historical measurement record: the macOS system-recognizer backend compared below was deleted on 2026-08-15 and is not a selectable backend; current measurement contracts live in [benchmarks.md](../benchmarks.md) and current Parakeet baselines in [performance-roadmap.md](../performance-roadmap.md).

# Apple recognizer A/B verdict

This preserves the row-matched evidence that settled one product decision: whether Voiceour should offer the macOS system recognizer beside local Parakeet. It did not. Parakeet won content accuracy, character accuracy, casing and latency on both tiers, and lost only FLEURS punctuation — which deterministic cleanup does not depend on the recognizer to supply. A second recognizer would also have meant a second permission, model and runtime surface for that one metric.

Measured 2026-08-15 on an Apple M4 Pro running macOS 26.5.2. Identical deterministic row selection on both sides, zero error rows: 128 LibriSpeech rows and 64 FLEURS rows. The Parakeet column is the default `f16` artifact of `ggml-org/parakeet-GGUF`; the system column is `apple/SpeechTranscriber`, Version 26.5.2 (Build 25F84).

| tier / metric | Parakeet | retired system recognizer |
| --- | ---: | ---: |
| LibriSpeech U-WER | **2.807%** | 3.133% |
| LibriSpeech CER | **0.882%** | 1.137% |
| LibriSpeech ASR p95 | **274.3 ms** | 760.0 ms |
| FLEURS U-WER | **4.416%** | 6.125% |
| FLEURS CER | **1.929%** | 2.882% |
| FLEURS case F1 | **0.9218** | 0.8481 |
| FLEURS punctuation micro F1 | 0.8380 | **0.8701** |
| FLEURS ASR p95 | **125.3 ms** | 223.9 ms |

The published numbers come from four retained reports. System recognizer: `benchmarks/results/20260815T172225Z-librispeech-apple-stt.json` and `benchmarks/results/20260815T172240Z-fleurs-apple-stt.json`. Parakeet: `benchmarks/results/20260815T172106Z-librispeech-parakeet-stt.json` and `benchmarks/results/20260815T172117Z-fleurs-parakeet-stt.json`.

Corpus results, not universal product claims: corpus, size, model pin, hardware and OS are part of the result. Reports from a deleted backend cannot pass the current provenance gate, so these two rows can no longer be recompared — they are evidence for a closed decision, not a baseline.
