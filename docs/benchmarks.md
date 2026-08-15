# Voiceour benchmarks

Voiceour benchmarks measure local speech recognition, deterministic cleanup, technical-term behavior, and latency through the production Swift path. The Python package under `bench/` prepares datasets, invokes `voiceour-bench`, scores rows, and writes reports under `benchmarks/results/`. It never ships.

## Tiers

| tier | source | default size | purpose |
| --- | --- | ---: | --- |
| `smoke` | local macOS `say` synthesis | fixed local fixture | Fast, deterministic offline plumbing check. |
| `librispeech` | LibriSpeech `test.clean` + `test.other` | 200 rows per split | English content accuracy and latency. `--n` applies independently to each split. |
| `fleurs` | `google/fleurs`, `en_us`, `test` | 100 rows | English content plus human punctuation and casing references. |
| `techterms` | local `say` synthesis | fixed local fixture | Technical names, acronyms, symbols/digits, multiword terms, and hard negatives. Smoke evidence only, not a real-speaker release claim. |

LibriSpeech and FLEURS preparation is deterministic first-N selection. Use identical `--tier` and `--n` values whenever two reports may be compared.

## Commands

From the repository root:

```sh
make bench-smoke
make bench-stt N=200
make bench-e2e N=100
make bench-techterms
make bench-gate BASELINE=benchmarks/results/<baseline>.json CANDIDATE=benchmarks/results/<candidate>.json
```

Direct package invocations must keep uv isolated from user configuration:

```sh
cd bench
uv --no-config sync
uv --no-config run pytest
uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend parakeet --n 64
uv --no-config run python -m voiceour_bench.run --tier fleurs --mode e2e --backend parakeet --n 64
uv --no-config run python -m voiceour_bench.run --tier techterms --mode stt --backend parakeet
```

`voiceour_bench.run` accepts `--mode {stt,e2e}` and `--backend {fake,parakeet}`. Parakeet is the default and the only real backend. The mode is currently report provenance, not a different Swift command: both choices invoke `voiceour-bench pipeline`, which runs ASR followed by `CleanupEngine`. Use `stt` when the run is intended as a recognizer baseline and `e2e` when the report is intended to track cleaned final text; do not claim that selecting the flag changes execution.

The Python orchestrator builds both release products because `voiceour-bench` resolves `voiceour-asr` as a sibling executable.

## Manifest and result contract

A pipeline manifest row contains at least:

- `id` — stable and unique within the manifest;
- `audio_path` — a local WAV path;
- `reference` — content reference when available;
- `formatted_reference` — punctuation/casing reference when available;
- `audio_s` — duration when available.

The Swift runner writes one metadata row followed by one result row per input. A result records the same id, raw transcript, cleaned/final text, ASR and cleanup timings, audio duration, error, and confidence basis.

`report.py` validates row identity before scoring. Missing/non-string ids, duplicate manifest ids, duplicate result ids, and result ids not present in the manifest are errors. Reports include sorted `successful_row_ids` and `error_row_ids` in addition to counts.

`compare.py` refuses a comparison unless all of these match:

- tier;
- backend;
- model id;
- model revision;
- the complete successful-id set; and
- the complete error-id set.

It also rejects reports that predate row-id evidence, duplicate ids within either set, overlap success/error sets, or counts that disagree with the sets. Equal row counts are not enough: a candidate that silently replaced one row is a different experiment.

## Metrics

Let $N(\cdot)$ be the published English text normalizer and $d$ Levenshtein distance.

- **U-WER**: word error rate after normalization, $d(N(r),N(h))/|N(r)|$.
- **CER**: character edit rate over normalized text.
- **F-WER**: word error rate against the formatted reference, preserving punctuation/casing distinctions used by that scorer.
- **Punctuation F1**: per-mark and micro/macro scores over `, . ? !`.
- **Case F1**: capitalization F1 over aligned normalized words, split into overall, sentence-initial, and non-sentence-initial buckets.
- **RTFx**: audio seconds divided by ASR wall-clock seconds; values above 1 are faster than real time.
- **Latency percentiles**: p50 and p95 for ASR, model load, inference, cleanup, and total wall time.
- **Confidence diagnostics**: distribution, reliability bins, and risk/coverage points grouped by the declared confidence basis. `greedy_token_prob` is not treated as a calibrated probability.

Content metrics use `reference` where present. Formatting metrics include only rows with a non-null `formatted_reference`. Error rows are reported, never scored as empty hypotheses.

The formal regression gate is candidate minus baseline U-WER <= `0.0035`, or +0.35 percentage points:

```sh
cd bench
uv --no-config run python -m voiceour_bench.compare \
  ../benchmarks/results/<baseline>.json \
  ../benchmarks/results/<candidate>.json \
  --gate uwer_final:0.0035
```

The Make target wraps the same comparison. Read the printed baseline/candidate provenance before trusting the delta; the display exists because an inverted comparison once exited successfully.

## Current Parakeet baselines — 2026-08-15

Hardware: Apple M4 Pro, macOS 26.5.2. Both runs used the pinned f16 artifact, identical deterministic row selection, and zero error rows.

| tier | rows | U-WER | CER | case F1 | punctuation micro F1 | ASR p50 / p95 | RTFx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| LibriSpeech | 128 | 2.807% | 0.882% | n/a | n/a | 201.0 / 274.3 ms | 112.96 |
| FLEURS | 64 | 4.416% | 1.929% | 0.9218 | 0.8380 | 90.5 / 125.3 ms | 99.93 |

Reports:

- `benchmarks/results/20260815T172106Z-librispeech-parakeet-stt.json`
- `benchmarks/results/20260815T172117Z-fleurs-parakeet-stt.json`

These are corpus baselines, not universal product claims. Dataset composition, first-N size, model pin, hardware, and OS remain part of the result.

## Retired Apple recognizer A/B verdict

A row-matched 2026-08-15 experiment used the same 128 LibriSpeech and 64 FLEURS rows. It answered a product decision; it is not a selectable backend now.

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

The system recognizer's only win was punctuation micro-F1. It lost content accuracy, character accuracy, case, and latency. It neither beat Parakeet U-WER on a corpus nor halved p95 without an accuracy regression, so it was removed rather than retained as product complexity.

Historical reports remain committed for auditability:

- `benchmarks/results/20260815T172225Z-librispeech-apple-stt.json`
- `benchmarks/results/20260815T172240Z-fleurs-apple-stt.json`

## Noise robustness

`bench/src/voiceour_bench/noise.py` generates deterministic additive-Gaussian-noise versions of a 64-utterance LibriSpeech subset at 20, 10, 5, and 0 dB SNR. Seed `20260718` is combined with each file through SHA-256, so regeneration is stable. The command writes WAVs and manifests only; it does not select or run a backend.

```sh
cd bench
uv --no-config run python -m voiceour_bench.noise
```

Run a generated manifest through the current production runner:

```sh
swift build -c release --product voiceour-bench
swift build -c release --product voiceour-asr
.build/release/voiceour-bench pipeline \
  --input benchmarks/data/librispeech-noise/snr10/manifest.jsonl \
  --output benchmarks/results/noise-snr10.results.jsonl \
  --backend parakeet \
  --timeout-ms 120000
```

Then generate a report with the Python report command, using the matching manifest. Do not compare noise levels unless their row ids are identical.

Noise is added digitally after capture, so this isolates recognition robustness. It does not model microphone directivity, room reverberation, AGC, Bluetooth route changes, or clipping.

## TechTerms tier

The TechTerms tier records labels such as canonical term, term id/class, intended use, hard-negative status, and speaker id alongside the standard pipeline row. Shared content metrics still apply; term analyses add exact-canonical recall/precision, preservation, no-op behavior, candidate coverage, selector accuracy, and hard-negative false-replacement rate where the report has the required evidence.

Because its utterances are synthesized by one macOS voice, the tier is a deterministic engineering smoke test. Promotion of any vocabulary mechanism requires held-out real speakers, microphones, acoustic conditions, intended-term cases, and confusable hard negatives.

## Adding a tier

1. Add preparation in `bench/src/voiceour_bench/datasets_prep.py` and register the choice in `prepare_tier()` and `run.py`.
2. Emit 16 kHz mono WAVs plus stable, unique manifest ids.
3. Keep source, license, split, selection order, and default size explicit.
4. Add scorer behavior only when the manifest carries the evidence it needs.
5. Add Python tests for malformed ids, missing references, and any new metric boundary.
6. Produce a report with complete row-id evidence before establishing a baseline.
