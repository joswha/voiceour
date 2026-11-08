# Voiceour benchmarks

These benchmarks measure local speech recognition, deterministic cleanup, technical-term behavior, and latency through the production Swift path. The Python package under `bench/` prepares datasets, invokes `voiceour-bench`, scores rows, and writes reports under `benchmarks/results/`. It never ships.

This file is a supporting measurement appendix, not a product specification. [README.md](../README.md#model-and-network-contract) owns the recognizer and the network contract; [README.md](../README.md#verification) owns which gates a change must pass; [AGENTS.md](../AGENTS.md#developer-commands) owns command conventions. The tier, command, row-identity, metric, and gate sections describe the current tooling. Every dated section is a measurement record bound to its corpus, model pin, hardware, and OS: it is neither a product claim nor a promise about another Mac, and no experiment route described here changes the recognizer.

Preparation is deterministic first-N selection: two runs with the same `--tier` and `--n` cover the same rows. Hugging Face downloads stay in `benchmarks/data/hf-cache/`, never in `~/.cache/huggingface`; deleting that directory frees the space, and the next preparation downloads again. Latency measurements live in [performance-roadmap.md](performance-roadmap.md).

## Tiers

| tier | source | default size | purpose |
| --- | --- | ---: | --- |
| `smoke` | local macOS `say` synthesis | fixed fixture | Offline plumbing check. |
| `librispeech` | LibriSpeech `test.clean` + `test.other` from `hf-audio/open-asr-leaderboard` | 200 rows per split | Content accuracy and latency; `--n` applies per split. |
| `fleurs` | `google/fleurs`, `en_us`, `test` | 100 rows | Content plus human punctuation and casing references. |
| `techterms` | local macOS `say` synthesis | fixed fixture | Technical terms, acronyms, symbols, digits, hard negatives. Smoke evidence only. |

Those defaults apply to a direct `voiceour_bench.run` call. `make bench-stt` and `make bench-e2e` always pass `--n $(N)` with `N ?= 200`, so pass `N=100` to reproduce the FLEURS default through Make.

## Commands

From the repository root:

```sh
make bench-smoke
make bench-stt N=200
make bench-e2e N=100
make bench-techterms
make bench-gate BASELINE=benchmarks/results/<baseline>.json CANDIDATE=benchmarks/results/<candidate>.json
```

`make bench-stt`, `bench-e2e` and `bench-techterms` measure Granite, the recognizer, unless `BACKEND=fake` selects the fake path; `make bench-smoke` always uses `fake`. The runner records the loaded artifact as `model_file`.

Direct calls must pass `--no-config` so uv ignores user configuration:

```sh
cd bench
uv --no-config sync
uv --no-config run pytest
uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend granite --n 64
```

`--backend` is `fake` or `granite`, and defaults to `granite`; `voiceour-bench pipeline` without one runs the registry default, also `granite`. `--mode stt` and `--mode e2e` both run `voiceour-bench pipeline` (ASR, then `CleanupEngine` under the transcript's detected language); the mode records intent, not execution. Each row's `cleaned_text` is that glossary-free cleanup. Without `--vocabulary`, `final_text` equals it. With `--vocabulary <file>` (a repair vocabulary, or a `[{"term", "heard_as"}]` word list whose heard-as forms are text-stage aliases only), the run takes the production path: each transcribe request carries the file's spot terms (`TermSpotTargets`), and `final_text` is the app's `DictationTextStage` over the result — term spotting at `TermSpottingPolicy.frozen`, literal composition, cleanup with the file's terms as the Glossary, and the app's repair engine for those terms. `make bench-gate` refuses a cross-model pair; compare two models through the [paired gate](#paired-fixed-corpus-promotion-gate).

## Row identity

Every manifest row needs a unique string `id`, an `audio_path`, the exact `audio_bytes`, and the
lowercase `audio_sha256`; `reference`, `formatted_reference`, and `audio_s` are scored when present.
The native runner verifies size and digest immediately before ASR, then pins both the exact manifest
SHA-256 and a canonical ordered audio-manifest SHA-256 in `bench_meta`. The latter hashes a domain
separator followed by each row's length-prefixed id, byte length, raw digest, and the final row count.
`report.py` rejects missing, duplicate, or unknown ids and publishes `successful_row_ids` and
`error_row_ids`. `compare.py` refuses a comparison unless tier, backend, model id, model revision,
model file, and both id sets match. The model file is part of that tuple because one model repository
revision can hold several conversions under the same id and revision, whose reports would otherwise
compare as one model; a report written before that field existed reads as `unknown` and never matches
a named artifact.

## Metrics

Let $N(\cdot)$ be the Whisper English text normalizer and $d$ Levenshtein distance.

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
requires identical row sets, zero runtime/error rows, matching execution modes, and matching exact
manifest and audio-manifest pins. It hard-rejects a newly introduced contiguous multiword deletion.
A pass also needs at least a 0.5-point U-WER benefit at the point estimate, the less favorable of
BCa and bootstrap-t bounds to establish benefit and +0.35-point non-inferiority, the fixed-seed
whole-cluster sign-swap diagnostic, and case/punctuation lower bounds no worse than two points where
formatted references exist. Formatting F1 is recomputed from aggregate counts in every resample.

The gate deliberately refuses population claims. `--frozen-row-conditional` is a required
acknowledgement: `pass` applies only to those byte-pinned rows. Generalization requires a separately
sealed speaker/session-clustered design and a calibrated population analysis.

## Committed Parakeet baselines — 2026-08-15

Recorded by the maintainer on an Apple M4 Pro under macOS 26.5.2, before the macOS 27 / Swift 6.4 migration. Both runs used the default f16 artifact, identical deterministic row selection, and zero error rows.

| tier | rows | U-WER | CER | case F1 | punctuation micro F1 | ASR p50 / p95 | RTFx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| LibriSpeech | 128 | 2.807% | 0.882% | n/a | n/a | 201.0 / 274.3 ms | 112.96 |
| FLEURS | 64 | 4.416% | 1.929% | 0.9218 | 0.8380 | 90.5 / 125.3 ms | 99.93 |

Reports: `benchmarks/results/20260815T172106Z-librispeech-parakeet-stt.json` and `benchmarks/results/20260815T172117Z-fleurs-parakeet-stt.json`.

Corpus baselines, not universal product claims: corpus, size, model pin, hardware, and OS are part of the result. The reports carry no host metadata, and they predate the `model_file`, manifest, and audio-manifest pins. `compare.py` therefore reads their artifact as `unknown`, and a current report, which names its artifact, does not compare against them. Gate a change against a fresh baseline of the same tier and `N` on the same Mac.

## Noise robustness

`bench/src/voiceour_bench/noise.py` writes additive-Gaussian-noise copies of a 64-utterance LibriSpeech subset — rows `000001` through `000032` of each split — at 20, 10, 5, and 0 dB SNR. It reads the prepared `benchmarks/data/librispeech/manifest.jsonl`, so prepare LibriSpeech with at least 32 rows per split first. Seed `20260718` is hashed with each row id and SNR through SHA-256, so regeneration is stable.

```sh
cd bench
uv --no-config run python -m voiceour_bench.noise
```

It writes WAVs and one manifest per level under `benchmarks/data/librispeech-noise/snrNN/`; it runs no recognition. Run each manifest through the release runner from the repository root, then score it:

```sh
swift build -c release --product voiceour-bench
swift build -c release --product voiceour-asr
mkdir -p .build/noise
.build/release/voiceour-bench pipeline --backend granite \
  --input benchmarks/data/librispeech-noise/snr10/manifest.jsonl \
  --output .build/noise/snr10.results.jsonl
cd bench
uv --no-config run python -m voiceour_bench.report \
  ../.build/noise/snr10.results.jsonl ../benchmarks/data/librispeech-noise/snr10/manifest.jsonl \
  --tier librispeech-noise --mode stt
```

Compare SNR levels only when row ids match.

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

Dated 2026-09-15 record. A benchmark-only `voiceour-bench` route was built to compare a fixed 15 s
Core AI export of the Parakeet encoder with one CoreML tier, with the native mel and ggml tail
around it. `benchmarks/results/20260915T112526Z-coreai-encoder-experiment.json` records it as
`conversion blocked`: the NeMo export stage lived on the devbox and that host was intentionally
unreachable. The route and its adapter were unit-tested but never run against a real artifact.
The Core AI measurement that did land came through Apple's `coreai-models` Transformers recipe,
recorded in the section below.

## macOS 27 native model prototypes — 2026-09-16

`bench/apple27/` compares native macOS 27 model routes with the production recognizer on 140
frozen clips: FLEURS en_US (95), LibriSpeech test-other (29), and synthetic TechTerms (16). It
reuses `VoiceCore` cleanup but changes no production code, settings or signing. Reference text is
scoring-only; no model sees it.

Run from the repository root on Apple Silicon with macOS 27, Xcode 27 / Swift 6.4, `uv`,
Python 3.12, and `jq`. Core AI exports load Apple's exporters from a pinned `coreai-models`
checkout:

```sh
mkdir -p .build/apple27/upstream
git clone https://github.com/apple/coreai-models.git .build/apple27/upstream/coreai-models
git -C .build/apple27/upstream/coreai-models checkout --detach "$(jq -r '.coreai_models.revision' bench/apple27/dependencies.json)"
swift build --package-path bench/apple27 -c release
uv --no-config sync --project bench
```

Upstream and model revisions live in [dependencies.json](../bench/apple27/dependencies.json).
For each engine, review and execute both printed installation commands; the helper never
installs. Both Whisper models share `whisper`.

```sh
python3 bench/apple27/coreai_environments.py whisper
python3 bench/apple27/coreai_environments.py wav2vec2
```

Source preparation explicitly permits downloads; export is offline and verifies source and
upstream exporter digests. To export the measured static wav2vec2 candidate:

```sh
.build/apple27/envs/wav2vec2/bin/python bench/apple27/coreai_export.py prepare --download \
  --engine wav2vec2 --model wav2vec2_asr_base_960h --revision torchaudio-2.11.0 \
  --output .build/apple27/sources/wav2vec2
python3 bench/apple27/run_command.py --prefix .build/apple27/logs/export-wav2vec2 --minimum-free-gib 6 -- \
  .build/apple27/envs/wav2vec2/bin/python bench/apple27/coreai_export.py export \
  --engine wav2vec2 --model wav2vec2_asr_base_960h --revision torchaudio-2.11.0 \
  --source .build/apple27/sources/wav2vec2 --output .build/apple27/exports/wav2vec2 \
  --dtype float32 --static
```

Whisper model ids and revisions come from the same pins and use `--dtype float16` (optional
`--static` for the fixed 448-token attempt). Use separate source/output directories. See
[coreai_export.py](../bench/apple27/coreai_export.py) `prepare --help` and `export --help`;
`--local-source` replaces downloading with a locally asserted revision.

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
The baseline may acquire the pinned Granite model on its first run.

```sh
swift build -c release
RUN=.build/apple27/runs/$(date -u +%Y%m%dT%H%M%SZ)
python3 bench/apple27/run_command.py --prefix "$RUN/granite" --minimum-free-gib 6 -- \
  .build/release/voiceour-bench pipeline --backend granite \
  --input .build/apple27/corpus/primary.manifest.jsonl --output "$RUN/granite.jsonl"
uv --no-config run --offline --project bench python bench/apple27/summarize.py \
  --manifest .build/apple27/corpus/primary.manifest.jsonl \
  --baseline "$RUN/granite.jsonl" \
  --result granite="$RUN/granite.jsonl" \
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
owns the shared NDJSON contract.
PCC requires both its managed entitlement and `--allow-cloud`; these commands authorize no
cloud inference. Everything under `.build/apple27/` stays local; only curated reports are committed.

The [measured report](../benchmarks/results/20260916T075017Z-apple27-native-model-prototypes.json)
used an Apple M4 Pro, macOS 27.0, and a shared interactive desktop: exploratory, not a
promotion gate. Its baseline was the Parakeet f16 sidecar path, then the production recognizer;
its Core AI Parakeet candidate came from a static export of `nvidia/parakeet-tdt-0.6b-v3`. This
table aggregates all 140 clips; the report separates natural-speech tiers from synthetic
TechTerms. Term F1 is synthetic smoke evidence. Final U-WER and `asr_ms` p50/p95:

| candidate | U-WER | p50 | p95 | note |
| --- | ---: | ---: | ---: | --- |
| Parakeet f16 sidecar path (baseline) | 3.92% | 68 ms | 97 ms | 0 errors |
| Core AI Parakeet TDT v3 f16, static 15 s | 4.01% | 79 ms | 103 ms | 17/140 transcripts differ; encoder rel-L2 ≤ 1.8e-3 vs PyTorch |
| `SpeechTranscriber` | 5.65% | 148 ms | 289 ms | technical-term F1 0.43 vs 0.78 |
| `DictationTranscriber` + punctuation | 12.33% | 269 ms | 599 ms | glossary hints: 12.21%, term F1 0.59 |
| Core AI wav2vec2 base f32, CPU, static 15 s | 20.04% | 125 ms | 131 ms | fixed zero-padded window, so latency is length-independent; f16 export produced NaN emissions; default compute failed to load on the ANE |

Timing boundaries differed by backend and are recorded in each result file's metadata: the
Parakeet baseline's `asr_inference` excluded audio load and the Core AI Parakeet runner read PCM
before its timer started, while the two Speech rows time `transcribe` around the framework's own
file provider, decode and format conversion, so 148/289 ms is not pure inference. The scorer also
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

## Speech recognizer replacement screen — 2026-11-03

A benchmark-only screen compared Parakeet TDT 0.6B v3, then the default recognizer, with Nemotron
Labs Unified ASR 0.6B and other locally runnable recognizers available by 2026-11-03. The screen
changed no recognizer. The measurements used an Apple M4 Pro under macOS 27.0.1 on AC power, with
offscreen, file-based public and TTS audio only. Each arm is one checkpoint, precision,
runtime and frontend combination.

- Screen: 25 configurations × 1,495 rows. The rows are 1,000 human-speech rows (250 each from
  AMI IHM, FLEURS en-US, LibriSpeech clean and LibriSpeech other), 472 synthetic technical rows
  and 23 non-speech rows. Failed attempts count as empty hypotheses and were never retried.
- Confirmation: 9 configurations × 17,858 rows. These rows share no row id or audio with the
  screen, but the speakers and AMI meeting series overlap. Its corpus mix is 69% AMI, so compare
  it per corpus, not pooled against the screen.
- Performance: 80 files × 7 counterbalanced passes per arm with no other heavy local work,
  three fresh-process starts per arm, recovery probes, and ten 30–600 s concatenations.

Selected raw U-WER (%), M4 Pro warm model latency, and model-process measures:

| arm | screen human | screen jargon | confirm AMI / FLEURS / LS-clean / LS-other | p50 / p95 ms | speed vs prod | first result ms | footprint MiB | model files MB |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| production v3 f16 | 4.71 | 6.13 | 11.62 / 5.02 / 1.98 / 3.71 | 53.0 / 158.2 | 1.00× | 1,190 (696 excl. adapter hashing) | 165 | 2,512 incl. arena |
| production v3 q8_0 | 4.72 | 6.21 | 11.71 / 4.96 / 1.97 / 3.74 | 52.5 / 157.1 | 1.01× | 706 (453) | 165 | 1,337 incl. arena |
| Nemotron fp16, ANE | 4.37 | 6.78 | 10.97 / 4.83 / 1.79 / 3.38 | 54.1 / 151.6 | 0.92× | 197 | 71 | 1,222 |
| Nemotron int8, ANE | 4.40 | 6.70 | 10.95 / 4.96 / 1.79 / 3.44 | 54.6 / 154.9 | 0.91× | 297 | 75 | 626 |
| Granite 5 TurboCTC Oct-21 Q8 | 3.84 | 6.52 | 8.48 / 4.50 / 1.31 / 2.67 | 38.4 / 113.6 | 1.32× | 236 | 392 | 506 |
| Qwen3-ASR 1.7B Q8 | 4.27 | 5.06 | 11.05 / 3.39 / 1.64 / 3.48 | 326.7 / 1,032.7 | 0.19× | 1,840 | 449 | 2,185 |
| Parakeet Ultra, BN-corrected | 4.55 | 6.13 | 10.78 / 4.31 / 1.83 / 3.47 | 53.3 / 158.4 | 0.99× | 604 | 161 | 2,512 incl. arena |

- **Nemotron:** improves the human-speech corpora modestly. It is slower in median model latency
  through FluidAudio CoreML (ANE 0.92×; GPU route 0.67×) and loses ground on synthetic jargon. The
  int8 encoder halves its model files.
- **Granite:** gave the best accuracy, latency and model-size tradeoff measured. It is an
  integration candidate, not a cutover:
  - It emits the documented `<|nospeech|>` control token on noise.
  - Its tested transcribe.cpp runtime ignores cancellation once inference starts.
  - It failed five 0.04–0.06 s confirmation clips.
  - It has no cross-SoC qualification. The integrated backend is measured in
    [Granite evaluation backend](#granite-evaluation-backend--2026-11-03).
- **Qwen3 1.7B:**
  - Wins on FLEURS and on technical terms.
  - Fills 22 of 23 non-speech controls with words.
  - Stopped one decode on a repetition guard.
  - Is about 5× slower.
- **Parakeet derivatives:** native Ultra, v2 and Bark Pro needed reference BatchNorm epsilon
  folding. With that correction, Ultra had the lowest error on the long concatenations: 8.1% vs
  production's 20.0%.
- **Uncertainty:** the corrected analysis builds speaker, session and sentence groups once
  globally. AMI has only four meeting-series components, so it withholds pooled human-speech
  ranges.
- **Memory:** footprint is memory charged to the recognizer process. It excludes file-mapped
  weights and CoreML or ANE service memory, so it is not a whole-system RAM ranking.
- **Energy:** only the system GPU energy counter responded. CPU, ANE and total energy are
  unmeasured.

[Results](../benchmarks/results/20261103-asr-replacement-evaluation.json) carry exact model,
runtime and corpus pins, failures, uncertainty limits, storage accounting and research
exclusions. The [count proof](../benchmarks/results/20261103-asr-replacement-proof.json) holds
the per-row counts, the grouping labels, the reproduction sources and the input digests. None
of this satisfies the
[paired promotion gate](#paired-fixed-corpus-promotion-gate): the screen has no real-speaker
dictation holdout and no cross-SoC replication.

## Granite evaluation backend — 2026-11-03

This section measures the `granite` backend through the production path: release
`voiceour-asr` with the `CGranite` port and the pinned Q8_0 GGUF. It used the frozen corpora,
adapters and machine of the [replacement screen](#speech-recognizer-replacement-screen--2026-11-03):
an Apple M4 Pro under macOS 27.0.1 on AC power. Parakeet was the default during these runs.

| arm | screen human | screen jargon | confirm AMI / FLEURS / LS-clean / LS-other | long 30–600 s | p50 / p95 ms | speed vs Parakeet | first result ms | footprint MiB | GPU J per audio min |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| production Parakeet v3 f16 | 4.71 | 6.13 | 11.62 / 5.02 / 1.98 / 3.71 | 19.97 | 54.5 / 172.6 | 1.00× | 956 (446) | 165 | 8.58 |
| production Granite Q8_0 | 3.84 | 6.52 | 8.48 / 4.50 / 1.31 / 2.67 | 11.92 | 38.0 / 116.2 | 1.37× (1.33–1.40) | 363 (161) | 261 | 6.87 |

- **Columns.**
  - U-WER is raw %, measured before the text stages.
  - Speed is the geometric mean of per-file median model-latency ratios, with a 95% bootstrap
    range.
  - First result is spawn-to-first-result over three fresh processes. The figure in parentheses
    excludes the benchmark adapter's pre-spawn artifact hashing.
  - Footprint excludes file-mapped weights: Granite maps its GGUF and Parakeet maps its arena.
  - On disk Granite needs 506 MB; Parakeet f16 needs 2,512 MB including its arena.
- **Parity.**
  - Post-integration Parakeet text is byte-identical to the pre-integration production run on all
    1,495 screen rows.
  - Granite's production text equals the transcribe.cpp runtime it was ported from on every row
    except designed changes, and raw U-WER is unchanged on every corpus:
    - 25 outputs that were only `<|nospeech|>` become empty transcripts.
    - Five confirmation clips of 0.04–0.06 s that transcribe.cpp failed now decode.
    - Two comma near-ties differ.
- **Weak spots.**
  - One of 23 non-speech controls produced text ("Il." on 8 s of silence); Parakeet produced text
    on two.
  - Granite is worse on synthetic jargon (6.52 vs 6.13) and on the 16 technical-term fixtures
    (8.65 vs 6.73).
- **Acquisition.** `voiceour-asr --prove` into an empty `VOICEOUR_MODEL_CACHE` did four things:
  downloaded the 505,663,136-byte artifact, verified its digest, wrote the five-field manifest and
  transcribed the fixture.
- **Reliability.**
  - Missing-file and wrong-rate requests fail without ending the process.
  - A cancel sent 1 ms into a 30 s request answered `cancelled` in 6.3 ms.
  - After a SIGKILL of the process group, a fresh spawn reproduces the same text.
  - Cancellation is polled only at stage boundaries, so a cancel during graph compute waits for
    it. A whole 600 s decode takes 2.3–2.5 s.

The [paired gate](#paired-fixed-corpus-promotion-gate) ran on `voiceour-bench pipeline` results
for both backends, with zero error rows and identical manifest pins:

| subset | rows | resampling unit | U-WER Parakeet → Granite | upper bound | verdict |
| --- | ---: | --- | ---: | ---: | --- |
| AMI IHM + LibriSpeech | 17,139 | 89 speakers, corpus strata | 8.36 → 6.36 | −1.56 (unstable) | reject: new multiword deletions in 263 rows |
| FLEURS en-US | 719 | row (no speaker metadata) | 5.02 → 4.50 | −0.26 | reject: new multiword deletions in 6 rows; case F1 −2.29 points |

- **Deletions.** 258 of the 263 deletion rows are AMI. Most drop verbatim repetitions or
  disfluencies that AMI references keep, but some lose content: "I don't know." became "I'.".
- **Verdict.** The gate's hard reject stands. Both subsets are public corpora, not the
  real-speaker dictation holdout the promotion rule requires.
- **Promotion blockers:**
  - the gate verdict above;
  - a real-speaker dictation holdout;
  - cross-SoC replication;
  - a self-hosted or official IBM artifact in place of the personal Hugging Face repository.

[Results](../benchmarks/results/20261103-granite-backend-evaluation.json) carry:
- the release binary digests;
- parity counts;
- per-corpus and paired accuracy;
- both gate verdicts and their deletion profile;
- latency, cold start, memory and energy;
- reliability, including one retained failed run;
- input digests.

The same day the repository owners made Granite the default recognizer by explicit decision, with
every promotion blocker above still open; Parakeet remained selectable per launch.
[README.md](../README.md#model-and-network-contract) owns the resulting contract.

## Multilingual text stage — 2026-11-06

Granite transcribes French, German, Spanish, Portuguese, Italian and Japanese as well as English, and the
text stage reads each transcript's language before applying its English-only rules;
[README.md](../README.md#what-happens-to-the-words) owns that behavior. Measured with `voiceour-bench
granite-spot` (the production in-process decode and the app's `DictationTextStage`) on FLEURS `test`,
Granite Q8_0 at `bd7db273`, an Apple M4 Pro under macOS 27.3, with the bundled seven-term glossary.
*Before* is the text stage at `55e4b3a`, which applied the English rules to every transcript; *after* is the
language-aware stage. The recognizer's text is identical in both builds on every row. WER uses Whisper's
basic text normalizer (its English normalizer for `en`); Japanese is CER with spaces removed.

Held out, rows 201–500 of each language, none seen while the detector's word lists were tuned:

| language | rows | detected | undetermined | misdetected | metric | raw | before | after | rows rewritten, before → after |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| en | 300 | 298 | 2 | 0 | WER | 4.82 | 4.89 | 4.89 | 6 → 6 |
| fr | 300 | 300 | 0 | 0 | WER | 6.65 | 6.66 | 6.65 | 1 → 0 |
| de | 300 | 298 | 2 | 0 | WER | 5.38 | 5.80 | 5.38 | 27 → 0 |
| es | 300 | 298 | 2 | 0 | WER | 4.78 | 4.83 | 4.78 | 4 → 0 |
| pt | 300 | 294 | 6 | 0 | WER | 8.71 | 9.99 | 8.73 | 87 → 1 |
| it | 300 | 298 | 2 | 0 | WER | 4.13 | 4.17 | 4.13 | 3 → 0 |
| ja | 300 | 300 | 0 | 0 | CER | 4.59 | 4.59 | 4.59 | 0 → 0 |

- **What the English rules did.** Filler removal deleted the Portuguese article *um* and the German *um* of
  *um … zu*, repeat collapse merged German *die die*, and the `capital` command consumed the Spanish noun and
  uppercased the next word (`capital bilingüe` → `BILINGÜE`).
- **Tuning rows 1–200.** The same shape: detection 1,396 of 1,400 with none wrong; Portuguese 9.03 → 7.70
  against a raw 7.70, German 5.45 → 5.07, Spanish 4.27 → 4.23; English and Japanese unchanged.
- **English misrouting.** None on the 18,330 wave-1 English transcripts the lists were tuned against
  (12,812 English, 5,518 undetermined), and none on 6,985 fresh ones: the VoxPopuli, Earnings-22 and
  GigaSpeech rows of the wave-2 word-spotting record plus its 402 synthetic sentences (6,644 English, 341
  undetermined).
- **A larger glossary.** With the 141-term jargon vocabulary instead of the seven defaults every figure is the
  same, except Spanish *before*: 4.85 over 5 rewritten rows.
- **What remains.** An undetermined transcript keeps the English rules: 14 of the 2,100 held-out rows, of
  which one Portuguese row lost its article (`prometeu um novo` → `prometeu novo`).
- **Limits.** FLEURS is read speech, 300 held-out rows per language, on one Mac. A code-switched transcript is
  classified as a whole. The raw column is the recognizer's own accuracy on this corpus, not a product claim.
