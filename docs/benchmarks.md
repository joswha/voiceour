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
requires identical row sets, zero runtime/error rows, matching execution modes, and matching exact
manifest and audio-manifest pins. It hard-rejects a newly introduced contiguous multiword deletion.
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
