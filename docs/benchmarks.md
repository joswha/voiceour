# Voiceour benchmarks

These benchmarks measure local speech recognition, deterministic cleanup, technical-term behavior, and latency through the production Swift path. The Python package under `bench/` prepares datasets, invokes `voiceour-bench`, scores rows, and writes reports under `benchmarks/results/`. It never ships.

Preparation is deterministic first-N selection: two runs with the same `--tier` and `--n` cover the same rows. Latency measurements live in [performance-roadmap.md](performance-roadmap.md).

## Tiers

| tier | source | default size | purpose |
| --- | --- | ---: | --- |
| `smoke` | local macOS `say` synthesis | fixed fixture | Offline plumbing check. |
| `librispeech` | LibriSpeech `test.clean` + `test.other` | 200 rows per split | Content accuracy and latency; `--n` applies per split. |
| `fleurs` | `google/fleurs`, `en_us`, `test` | 100 rows | Content plus human punctuation and casing references. |
| `techterms` | local macOS `say` synthesis | fixed fixture | Technical terms, acronyms, symbols, digits, hard negatives. Smoke evidence only. |

## Commands

From the repository root:

```sh
make bench-smoke
make bench-stt N=200
make bench-e2e N=100
make bench-techterms
make bench-gate BASELINE=benchmarks/results/<baseline>.json CANDIDATE=benchmarks/results/<candidate>.json
```

Direct calls must pass `--no-config` so uv ignores user configuration:

```sh
cd bench
uv --no-config sync
uv --no-config run pytest
uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend parakeet --n 64
```

`--backend` is `fake` or `parakeet`; parakeet is the default and only real backend. `--mode stt` and `--mode e2e` both run `voiceour-bench pipeline` (ASR then `CleanupEngine`); the mode records intent, not execution.

## Row identity

Every manifest row needs a unique string `id`, an `audio_path`, the exact `audio_bytes`, and the
lowercase `audio_sha256`; `reference`, `formatted_reference`, and `audio_s` are scored when present.
The native runner verifies size and digest immediately before ASR, then pins both the exact manifest
SHA-256 and a canonical ordered audio-manifest SHA-256 in `bench_meta`. The latter hashes a domain
separator followed by each row's length-prefixed id, byte length, raw digest, and the final row count.
`report.py` rejects missing, duplicate, or unknown ids and publishes `successful_row_ids` and
`error_row_ids`. `compare.py` refuses a comparison unless tier, backend, model id, model revision,
model file, and both id sets match. The model file is part of that tuple because every artifact of the
pinned repository shares its id and revision, so `f16` and `q8_0` reports would otherwise compare as
one model; a report written before that field existed reads as `unknown` and never matches a named
artifact.

## Metrics

Let $N(\cdot)$ be the published English text normalizer and $d$ Levenshtein distance.

- **U-WER**: word error rate after normalization, $d(N(r),N(h))/|N(r)|$.
- **CER**: character edit rate over normalized text.
- **Punctuation F1**: per-mark and micro/macro scores over `, . ? !`.
- **Case F1**: capitalization F1 over aligned normalized words, split into overall, sentence-initial, and non-sentence-initial buckets.
- **RTFx**: audio seconds divided by ASR wall-clock seconds; values above 1 are faster than real time.

Content metrics use `reference`; formatting metrics use only rows with a non-null `formatted_reference`. Error rows are reported, never scored as empty hypotheses.

The regression gate is candidate minus baseline U-WER <= `0.0035` (+0.35 percentage points), passed to `voiceour_bench.compare` as `--gate uwer_final:0.0035`. Read the printed provenance before trusting the delta.

### Paired fixed-corpus promotion gate

Aggregate reports are insufficient for promotion. Run the row-level paired gate on one frozen
manifest and two `voiceour-bench pipeline` result files:

```sh
cd bench
uv --no-config run voiceour-bench-paired-gate \
  ../path/manifest.jsonl ../path/incumbent.results.jsonl ../path/candidate.results.jsonl \
  --frozen-row-conditional --cluster-field speaker_id --stratum-field split \
  --seed 20260830 -B 100000 --permutation-samples 100000 \
  --ni-margin 0.0035 --benefit-margin 0.005 --format-margin 0.02 \
  --output ../path/paired-gate.json
```

Omit cluster and stratum fields only when the manifest has no honest grouping metadata. The gate
requires identical row sets, zero runtime/error rows, matching execution modes (or the explicit
`raw-decode`/`external-encoder` comparison family), and matching exact manifest and audio-manifest
pins. It hard-rejects a newly introduced contiguous multiword deletion.
A pass also needs at least a 0.5-point U-WER benefit at the point estimate, the less favorable of
BCa and bootstrap-t bounds to establish benefit and +0.35-point non-inferiority, the fixed-seed
whole-cluster sign-swap diagnostic, and case/punctuation lower bounds no worse than two points where
formatted references exist. Formatting F1 is recomputed from aggregate counts in every resample.

The gate deliberately refuses population claims. `--frozen-row-conditional` is a required
acknowledgement: `pass` applies only to those byte-pinned rows. Generalization requires a separately
sealed speaker/session-clustered design and a calibrated population analysis.

## Current Parakeet baselines — 2026-08-15

Hardware: Apple M4 Pro, macOS 26.5.2. Both runs used the default f16 artifact, identical deterministic row selection, and zero error rows. Select another artifact with `VOICEOUR_MODEL_VARIANT`, which the runner records as `model_file`.

| tier | rows | U-WER | CER | case F1 | punctuation micro F1 | ASR p50 / p95 | RTFx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| LibriSpeech | 128 | 2.807% | 0.882% | n/a | n/a | 201.0 / 274.3 ms | 112.96 |
| FLEURS | 64 | 4.416% | 1.929% | 0.9218 | 0.8380 | 90.5 / 125.3 ms | 99.93 |

Reports: `benchmarks/results/20260815T172106Z-librispeech-parakeet-stt.json` and `benchmarks/results/20260815T172117Z-fleurs-parakeet-stt.json`.

Corpus baselines, not universal product claims: corpus, size, model pin, hardware, and OS are part of the result.

## Noise robustness

`bench/src/voiceour_bench/noise.py` writes additive-Gaussian-noise copies of a 64-utterance LibriSpeech subset at 20, 10, 5, and 0 dB SNR. Seed `20260718` is hashed with each file through SHA-256, so regeneration is stable.

```sh
cd bench
uv --no-config run python -m voiceour_bench.noise
```

It writes WAVs and manifests only; run those through the release `voiceour-bench` pipeline runner and score with `voiceour_bench.report`. Compare SNR levels only when row ids match.

Digital noise added after capture isolates recognition robustness; it does not model microphone directivity, room reverberation, AGC, Bluetooth routes, or clipping.

## TechTerms tier

Rows carry the canonical term, its id and class, whether the term is expected in the output, the hard-negative kind, and the synthetic speaker's id, kind and condition beside the standard pipeline fields. Term analyses add exact-canonical recall and precision, preservation, no-op behavior, candidate coverage, selector accuracy, and hard-negative false-replacement rate when the report carries that evidence.

One macOS voice synthesizes every utterance, so the tier is an engineering smoke test. Promoting a vocabulary mechanism needs held-out real speakers, microphones, acoustic conditions, and hard negatives.

## Adding a tier

1. Add preparation in `bench/src/voiceour_bench/datasets_prep.py`, then register the tier in `prepare_tier()` and `run.py`.
2. Emit 16 kHz mono WAVs with stable, unique manifest ids; preparation records each file's byte
   length and SHA-256.
3. State source, license, split, selection order, and default size.
4. Add scorer behavior only when the manifest carries its evidence.
5. Test malformed ids, missing references, and new metric boundaries.
6. Produce a report with complete row-id evidence before baselining.

## Core AI encoder experiment

This is a benchmark-only, fixed 15 s encoder experiment. It never changes the app's recognizer.
Stage 1, `bench/coreai/export_encoder.py`, runs in the devbox's existing NeMo project and verifies
the pinned checkpoint before exporting a `.pt2` plus its `.export.json` provenance. Stage 2 runs
in the separate `bench/coreai` uv project on macOS 27; the main benchmark environment stays
torch-free. The converter is pinned to an exact `coreai-torch` git revision in that project.

```sh
uv --no-config sync --project bench/coreai
uv --no-config run --project bench/coreai python bench/coreai/convert_encoder.py \
  --program .build/coreai/encoder-15s.pt2 \
  --output .build/coreai/parakeet-encoder-15s.aimodel
swift build -c release --product voiceour-bench
.build/release/voiceour-bench external-encoder --engine coreai \
  --input .build/coreai/fleurs.le15.manifest.jsonl \
  --output .build/coreai/fleurs.coreai.results.jsonl \
  --model /path/to/ggml-parakeet-tdt-0.6b-v3-f16.bin \
  --coreai-model .build/coreai/parakeet-encoder-15s.aimodel \
  --coreai-compute default --coreai-cache default
```

`--engine coreml` instead takes exactly one existing `VOICEOUR_COREML_ENCODER`,
`VOICEOUR_COREML_ENCODER_SHORT`, or `VOICEOUR_COREML_ENCODER_TINY` compiled `.mlmodelc`.
Multiple tiers are refused because one metadata row cannot identify several routed artifacts.
The experiment uses the standard 15 s, 6-bit palettized tier; Core AI weights are unquantized.
All candidates must receive the same manifest filtered to `audio_s <= 15.0`; the runner also
refuses actual sample counts above 240,000.

Each external run emits `bench_meta`, `encoder_meta`, then ordinary rows with an optional
`encoder` timing/digest object. Core AI `encode_ms` includes its array bridge but not native mel;
CoreML `encode_ms` includes native mel. Core AI `tail_ms` also includes the unchanged tail's
extra mel computation. State hashing is outside the stage timing windows in both routes.
Core AI load/specialization timings are measured directly; CoreML `load_function_ms` is an
explicitly labelled independent preflight load, and its context's lazy load remains inside
the first row's encoding time. Compute values are requested preferences, not measured device
residency; a fresh process alone does not prove a cold system specialization cache.

Native `raw-decode` keeps its row stream unchanged and writes `<results>.meta.json` alongside
it. The paired gate accepts that provenance only when `results_sha256` binds the exact row
bytes. It recognizes `encoder_meta` as metadata, permits the native/external encoder family,
and retains all missing-pin, mismatched-pin, stale-sidecar, and unrelated-mode refusals.

`bench/coreai/summarize.py` is stdlib-only. It reports per-engine p50/p95, error counts,
row-aligned transcript identity, supplied fresh-process determinism witnesses, load metadata,
and `--gate LABEL=PATH` paired-gate references. `--manifest` is the conversion artifact JSON;
`--corpus-manifest` is the optional filtered corpus JSONL. A conversion blocker produces a
report with no model measurements, not a synthetic substitute for the Parakeet encoder.

`benchmarks/results/20260915T112526Z-coreai-encoder-experiment.json` records this experiment as
`conversion blocked`: the NeMo export stage lives on the devbox and that host was intentionally
unreachable. The Core AI measurement that did land came through a different conversion path —
Apple's `coreai-models` Transformers recipe, exercised end to end in the section below — so the
`voiceour-bench external-encoder --engine coreai` route and its `CoreAIEncoder` adapter are
unit-tested but have not yet run against a real artifact.

## macOS 27 native model prototypes — 2026-09-16

`bench/apple27/` compares native model routes with shipping Parakeet on 140 frozen clips:
FLEURS en_US (95), LibriSpeech test-other (29), and synthetic TechTerms (16). It reuses
`VoiceCore` cleanup but changes no production code, settings or signing. Reference text is
scoring-only; no model sees it.

Run from the repository root on Apple Silicon with macOS 27, Xcode 27 / Swift 6.4, `uv`,
Python 3.12, and `jq`. The local-path SwiftPM dependency must exist before building:

```sh
mkdir -p .build/apple27/upstream
git clone https://github.com/apple/coreai-models.git .build/apple27/upstream/coreai-models
git -C .build/apple27/upstream/coreai-models checkout --detach "$(jq -r '.coreai_models.revision' bench/apple27/dependencies.json)"
swift build --package-path bench/apple27 -c release
uv --no-config sync --project bench
```

Upstream and model revisions live in [dependencies.json](../bench/apple27/dependencies.json).
For each engine, review and execute both printed installation commands; the helper never
installs. Keep Parakeet and Whisper environments separate; both Whisper models share `whisper`.

```sh
python3 bench/apple27/coreai_environments.py parakeet
python3 bench/apple27/coreai_environments.py whisper
python3 bench/apple27/coreai_environments.py wav2vec2
```

Source preparation explicitly permits downloads; export is offline and verifies source and
upstream exporter digests. To export the measured static Parakeet candidate:

```sh
.build/apple27/envs/parakeet/bin/python bench/apple27/coreai_export.py prepare --download \
  --engine parakeet --model nvidia/parakeet-tdt-0.6b-v3 \
  --revision "$(jq -r '.model_pins["nvidia/parakeet-tdt-0.6b-v3"].revision' bench/apple27/dependencies.json)" \
  --output .build/apple27/sources/parakeet
python3 bench/apple27/run_command.py --prefix .build/apple27/logs/export-parakeet --minimum-free-gib 6 -- \
  .build/apple27/envs/parakeet/bin/python bench/apple27/coreai_export.py export \
  --engine parakeet --model nvidia/parakeet-tdt-0.6b-v3 \
  --revision "$(jq -r '.model_pins["nvidia/parakeet-tdt-0.6b-v3"].revision' bench/apple27/dependencies.json)" \
  --source .build/apple27/sources/parakeet --output .build/apple27/exports/parakeet \
  --dtype float16 --static
```

Other model ids/revisions come from the same pins: Whisper uses `--dtype float16` (optional
`--static` for the fixed 448-token attempt); measured wav2vec2 uses `--dtype float32 --static`.
Use separate source/output directories. See [coreai_export.py](../bench/apple27/coreai_export.py)
`prepare --help` and `export --help`; `--local-source` replaces downloading with a locally asserted revision.

Prepare public audio without recognition: first 200 LibriSpeech rows per split, first 100
FLEURS rows, and synthesized TechTerms. Filter to 15 seconds, then freeze the corpus:

```sh
uv --no-config run --project bench python -c \
  'from voiceour_bench.datasets_prep import prepare_librispeech, prepare_fleurs, prepare_techterms; prepare_librispeech(n=200); prepare_fleurs(n=100); prepare_techterms()'
mkdir -p .build/coreai
jq -c 'select(.audio_s <= 15.0)' benchmarks/data/librispeech/manifest.jsonl > .build/coreai/librispeech.le15.manifest.jsonl
jq -c 'select(.audio_s <= 15.0)' benchmarks/data/fleurs/manifest.jsonl > .build/coreai/fleurs.le15.manifest.jsonl
uv --no-config run --project bench python bench/apple27/prepare_corpus.py --output .build/apple27/corpus
```

Inspect `corpus.json` for source hashes, counts and tiers. Dataset revisions and the synthesis
voice are not independently pinned; absolute audio paths also make regeneration a new
measurement, not a promise of identical bytes or scores. The measured natural-speech subsets
retained 29 LibriSpeech and 95 FLEURS rows. Use a new run directory; outputs refuse overwrite.
The baseline may acquire the pinned ggml model on its first run.

```sh
swift build -c release
RUN=.build/apple27/runs/$(date -u +%Y%m%dT%H%M%SZ)
python3 bench/apple27/run_command.py --prefix "$RUN/parakeet" --minimum-free-gib 6 \
  --env VOICEOUR_MODEL_VARIANT=f16 -- \
  .build/release/voiceour-bench pipeline --backend parakeet \
  --input .build/apple27/corpus/primary.manifest.jsonl --output "$RUN/parakeet.jsonl"
EXPORT=.build/apple27/exports/parakeet
BUNDLE=$(jq -r '.details.bundle' "$EXPORT/export.json")
python3 bench/apple27/run_command.py --prefix "$RUN/coreai-parakeet" --minimum-free-gib 6 -- \
  bench/apple27/.build/release/apple27-coreai \
  --model "$EXPORT/$BUNDLE" --metadata "$EXPORT/export.json" --maximum-audio-seconds 15 \
  --input .build/apple27/corpus/primary.manifest.jsonl --output "$RUN/coreai-parakeet.jsonl"
uv --no-config run --offline --project bench python bench/apple27/summarize.py \
  --manifest .build/apple27/corpus/primary.manifest.jsonl \
  --baseline "$RUN/parakeet.jsonl" \
  --result parakeet="$RUN/parakeet.jsonl" --result coreai-parakeet="$RUN/coreai-parakeet.jsonl" \
  --output "$RUN/summary.json"
```

For other routes, use the same manifest and fresh outputs. Python scripts expose `--help`;
the Swift argument parsers are in their linked sources:

- [SpeechLab.swift](../bench/apple27/Sources/SpeechLab/SpeechLab.swift): `speech`, `dictation`, and `dictation-vocabulary` engines; the latter takes `--vocabulary .build/apple27/corpus/vocabulary.json` (12 frozen public terms in the measured run). Use `--download-assets` only to install locale assets.
- [FoundationLab.swift](../bench/apple27/Sources/FoundationLab/FoundationLab.swift): on-device AFM over baseline `--transcripts`, `--mode format|glossary`, and `--guardrails transformations`; glossary mode requires the corpus vocabulary.
- [coreai_python.py](../bench/apple27/coreai_python.py): Whisper/wav2vec2 in their matching environments, using the export's `model.aimodel` and `export.json`; measured wav2vec2 uses `--compute cpu`.

Wrap every model command with [run_command.py](../bench/apple27/run_command.py): it isolates
`TMPDIR`, records wall/CPU/RSS, enforces the free-disk floor, and removes only its child's
MPSGraph compiler scratch. [PrototypeSupport](../bench/apple27/Sources/PrototypeSupport/Support.swift)
owns the shared NDJSON contract; [CoreAILab.swift](../bench/apple27/Sources/CoreAILab/CoreAILab.swift)
verifies static bundle provenance and refuses over-window audio rather than truncating it.
PCC requires both its managed entitlement and `--allow-cloud`; these commands authorize no
cloud inference. Everything under `.build/apple27/` stays local; only curated reports are committed.

The [measured report](../benchmarks/results/20260916T075017Z-apple27-native-model-prototypes.json)
used an Apple M4 Pro, macOS 27.0, and a shared interactive desktop: exploratory, not a
promotion gate. This table aggregates all 140 clips; the report separates natural-speech
tiers from synthetic TechTerms. Term F1 is synthetic smoke evidence. Final U-WER and `asr_ms` p50/p95:

| candidate | U-WER | p50 | p95 | note |
| --- | ---: | ---: | ---: | --- |
| Parakeet f16 sidecar path (baseline) | 3.92% | 68 ms | 97 ms | 0 errors |
| Core AI Parakeet TDT v3 f16, static 15 s | 4.01% | 79 ms | 103 ms | 17/140 transcripts differ; encoder rel-L2 ≤ 1.8e-3 vs PyTorch |
| `SpeechTranscriber` | 5.65% | 148 ms | 289 ms | technical-term F1 0.43 vs 0.78 |
| `DictationTranscriber` + punctuation | 12.33% | 269 ms | 599 ms | glossary hints: 12.21%, term F1 0.59 |
| Core AI wav2vec2 base f32, CPU, static 15 s | 20.04% | 125 ms | 131 ms | fixed zero-padded window, so latency is length-independent; f16 export produced NaN emissions; default compute failed to load on the ANE |

Timing boundaries differ by backend and are recorded in each result file's metadata: the
Parakeet baseline's `asr_inference` excludes audio load and `apple27-coreai` reads PCM before
its timer starts, while the two Speech rows time `transcribe` around the framework's own file
provider, decode and format conversion, so 148/289 ms is not pure inference. The scorer also
counts `empty_transcripts` — completed rows with no text on a clip that has speech — beside
`errors_or_missing`, so a recognizer that returns nothing cannot read as a clean run.
The recorded baseline ran without the wrapper, so it has no client RSS or wall measurement.

AFM 3 post-processing of the baseline transcripts leaves U-WER within noise (3.89% format,
3.86% glossary) at ~0.5 s p50 / ~0.85 s p95 added per utterance under the documented
`permissiveContentTransformations` guardrails; default guardrails refused 10–11 of 140 public
sentences as unsafe. Its edits were punctuation, case and rare-word spelling, with zero number
or negation token changes flagged. Whisper large-v3-turbo and large-v3 stopped at functional
CPU smokes (10–48 s per clip) because the dynamic decoder graph triggered per-length ANE
compilation that exhausted disk and the fixed 448-token graph failed ANE program load; their
failure records sit beside the report's run directory. Private Cloud Compute was hardware
available but blocked by the missing entitlement, and no cloud request was sent.
