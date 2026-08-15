# Voiceour Benchmarks

Voiceour benchmarks measure speech-to-text accuracy, deterministic/optional refinement quality, and latency through the same production Swift paths used by the app. The Python package in `bench/` prepares datasets, invokes the Swift `voiceour-bench` runner, computes metrics, and writes JSON reports under `benchmarks/results/`.

## Tiers

| tier | source | default size | license and notes |
| --- | --- | ---: | --- |
| `smoke` | Local macOS `say` synthesis converted with `afconvert` to 16 kHz mono WAV | 8 utterances | Generated locally; deterministic and offline. Covers numbers, proper nouns, a question, filler words, command-as-text, and correction language. |
| `techterms` | Local macOS `say` synthesis (`Samantha`, rate 180) converted with `afconvert` to 16 kHz mono WAV | 16 utterances | Generated locally; deterministic and offline. Permanent technical-term comprehension tier: 11 positive term utterances across term classes (jargon, acronym, camelCase, symbols, digits, multiword name, coinage) plus 5 hard negatives (minimal pair, homophone, ordinary language). TTS only (`speaker_kind: tts`); smoke evidence for plumbing and regression tracking, never real-speaker proof. |
| `librispeech` | `hf-audio/open-asr-leaderboard`, config `librispeech`, splits `test.clean` and `test.other` | 200 per split | LibriSpeech content is distributed under CC-BY-4.0 through the Open ASR Leaderboard dataset. Used for STT accuracy sanity checks. |
| `fleurs` | `google/fleurs`, config `en_us`, split `test` | 100 rows | FLEURS is CC-BY-4.0. `transcription` is the unformatted/content reference; `raw_transcription` is the formatted reference. |
| refine fixture | `fixtures/bench/refine_cases.jsonl` | curated local rows | Cases were harvested from now-removed prototype refiner harnesses (see git history), their few-shot examples, and shared glossary terms; the live artifact is the fixture at `fixtures/bench/refine_cases.jsonl`. Rows without encoded expected output keep `formatted_reference: null`, so formatting metrics skip them. |

`--n` is per split for LibriSpeech, so `--n 200` produces 400 rows across `test.clean` and `test.other`.

Hugging Face downloads use `HF_HOME=benchmarks/data/hf-cache` so repeated runs can reuse the local cache. Prepared manifests and WAVs live under `benchmarks/data/<tier>/`.

## Commands

From the repository root:

```sh
make bench-smoke
make bench-stt N=200
make bench-refine
make bench-e2e N=100
make bench-techterms
```

Equivalent direct commands:

```sh
cd bench && uv --no-config run python -m voiceour_bench.run --tier smoke --mode e2e --backend fake
cd bench && uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend parakeet --n 200
cd bench && uv --no-config run python -m voiceour_bench.run --tier smoke --mode refine --refine deterministic
cd bench && uv --no-config run python -m voiceour_bench.run --tier fleurs --mode e2e --backend parakeet --n 100
cd bench && uv --no-config run python -m voiceour_bench.run --tier techterms --mode stt --backend parakeet
```

The registered backend ids are `fake`, `parakeet`, and `apple`. Both the benchmark runner and the
Make targets default to `parakeet`.

`--mode stt` maps to the Swift runner's `pipeline --refine off`. `--mode e2e` maps to `pipeline --refine deterministic` unless `--refine omp` is explicitly supplied. `--mode refine` uses the text-only Swift `refine` command and defaults to deterministic refinement; with `--tier fleurs` it derives refine cases from FLEURS `transcription` and `raw_transcription`, otherwise it uses `fixtures/bench/refine_cases.jsonl`.

`--backend apple` runs the native macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` batch client through the identical harness, report, and scorer, so an Apple-vs-Parakeet comparison is two invocations of the same command over the same manifest rather than a hand-driven Swift-runner call. Row matching is deterministic: `prepare_tier` uses the first N rows, so passing the same `--tier` and `--n` to both backends guarantees identical rows:

```sh
cd bench && uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend parakeet --n 64
cd bench && uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend apple --n 64
```

Run them one at a time: concurrent Metal work distorts the latency percentiles. Punctuation and case F1 need a tier that carries `formatted_reference`, which LibriSpeech does not. Use `--tier fleurs` for any formatting comparison.

`--refine omp` measures the shipping cloud path: the runner builds its refiner through the same `RefinerProviderRegistry.live` the app uses, so it cannot drift into measuring a refiner the app does not ship. `--refiner-model` picks an OMP model (empty means the provider default) and is the only refiner option there is. The runner holds no credential because OMP owns them. Apple's on-device provider has no benchmark mode: it depends on Apple Intelligence being enabled on the host, which is not a condition a reproducible benchmark can assert.

## Metrics

Let $r$ be the reference, $h$ the hypothesis, $d(\cdot,\cdot)$ be Levenshtein edit distance, and $|r|$ be the number of reference units for the metric.

- **U-WER**: unformatted word error rate after Whisper English normalization: $d(\text{words}(N(r)), \text{words}(N(h))) / |\text{words}(N(r))|$. This is the primary STT content metric.
- **CER**: character error rate after the same English normalization: $d(\text{chars}(N(r)), \text{chars}(N(h))) / |\text{chars}(N(r))|$.
- **F-WER**: formatted WER over case- and punctuation-preserving tokens. Words retain case, and punctuation marks are tokens, so capitalization and punctuation changes count as edits.
- **Punctuation F1**: per-mark precision/recall/F1 for `.`, `,`, `?`, and `!`. The implementation aligns Whisper-normalized word streams with jiwer, attaches the trailing punctuation label after each aligned word, counts inserted hypothesis punctuation as false positives and deleted reference punctuation as false negatives, then reports per-mark, macro, and micro F1.
- **Case F1**: binary capitalization F1 over jiwer-aligned normalized words. A positive label means the original word starts with an uppercase cased character. Reports overall, sentence-initial, and non-sentence-initial buckets.
- **Over-edit rate**: normalized word edit distance between `raw_transcript` and `final_text`: $d(\text{words}(N(raw)), \text{words}(N(final))) / |\text{words}(N(raw))|$. This catches refiners that rewrite content too aggressively.
- **RTFx**: total audio seconds divided by total ASR wall-clock seconds. Values above 1 mean faster than real time.
- **Latency percentiles**: linear-interpolated p50 and p95 for Swift-reported `asr`, `asr_load`, `asr_inference`, `cleanup`, `refine`, and `total` milliseconds.

Formatting metrics use only rows with non-null `formatted_reference`. Content metrics use `reference` when present, falling back to `formatted_reference` only for rows that lack a separate content reference.

## Normalization and methodology caveats

The Python package uses the published `whisper-normalizer` package (`whisper_normalizer.english.EnglishTextNormalizer`) rather than vendoring normalizer files. It was import-tested on numbers, fillers, and contractions during setup.

U-WER is computed with jiwer. The Open ASR Leaderboard uses kaldialign with compound-merge behavior, so Voiceour numbers can differ slightly from leaderboard figures even on the same transcripts. Treat the LibriSpeech anchors as sanity checks rather than exact reproduction targets: NVIDIA NeMo reports `parakeet-tdt-0.6b-v3` at 1.93 WER on test-clean and 3.59 WER on test-other. Voiceour runs the GGUF-converted weights through the vendored parakeet.cpp C/Metal runtime, not the NeMo implementation, so model-runtime differences are expected.

FLEURS refine metrics use `raw_transcription` as the formatted reference because FLEURS separates normalized `transcription` from the human-formatted source text. That gives the refiner a realistic target for punctuation and case without mixing ASR errors into the text-only benchmark.

## Noise robustness sweep

`bench/src/voiceour_bench/noise.py` regenerates the 64-utterance LibriSpeech baseline subset with deterministic additive Gaussian noise (seed 20260718, per-file RNG derived via SHA-256) at 20, 10, 5, and 0 dB SNR into `benchmarks/data/librispeech-noise/snr{XX}/`. It only writes the noisy WAVs and manifests and prints each manifest path; it does not invoke a runner, select a backend, or write results:

```sh
(cd bench && uv --no-config run python -m voiceour_bench.noise)
```

Sweep a backend separately with the prebuilt runner. This is the `run.py` pipeline invocation repeated over the four generated manifests:

```sh
for snr in 20 10 05 00; do
  .build/release/voiceour-bench pipeline \
    --input "benchmarks/data/librispeech-noise/snr${snr}/manifest.jsonl" \
    --output "benchmarks/results/manual-librispeech-apple-stt-noise-snr${snr}.results.jsonl" \
    --backend apple \
    --timeout-ms 120000 \
    --refine off
done
```

Measured 2026-07-18 on macOS 26.5.2 (M4 Pro), Apple SpeechTranscriber batch path, U-WER: clean 3.07%, 20 dB 3.05%, 10 dB 6.07%, 5 dB 12.77%, 0 dB 28.86%. Accuracy is unaffected in quiet rooms (20 dB), roughly doubles around 10 dB, and collapses at or below 5 dB. Reports live under `benchmarks/results/*-noise-snrXX*`.

## Paired capture matrix

`voiceour_bench.capture_matrix` plans and collects the Stage 0 microphone matrix around the
`voiceour-capture-bench` executable. `standard` is the production baseline and tracks whatever
production records through, which is now `MicrophoneRecorder` over `MicrophoneCapture`. It uses an
`AVCaptureSession` pinned to a chosen input device (`docs/architecture.md`, *Microphone capture*)
rather than the `AVAudioRecorder` the matrix was originally designed against. Rows collected
before that swap are therefore not paired with rows collected after it, and the
`implementation` field distinguishes them: `production-av-audio-recorder` against
`production-microphone-recorder`. `native` is the experimental hardware-native
`AVAudioEngine` path. The remaining modes are `voice-processing`,
`voice-processing-no-agc`, `sound-isolation`, and
`sound-isolation-high-quality`. Check availability without requesting microphone permission:

```sh
voiceour-capture-bench --list-modes
```

The default matrix crosses all six modes with 100/200 ms pre-roll, 300/500 ms post-roll, two
takes, and the condition labels `quiet`, `fan-keyboard`, `echo`, `distance`, `clipping`,
`bluetooth`, and `route-change`. A pair id deliberately excludes capture mode: every mode in a
pair has the same prompt id, exact prompt text, take id, condition, and roll settings. Bluetooth
and route-change rows remain marked hardware-dependent. Every row is marked manual because a
person must set up the condition and speak the prompt; an absent row is reported
`missing-manual`, never as a successful result.

Prompts are JSONL objects with `prompt_id` (or `id`) and `prompt` (or `reference`):

```json
{"prompt_id":"kubectl-01","prompt":"Run kubectl get pods in the staging namespace."}
```

Planning is deterministic and does not open the microphone. The following writes a stable
manifest and prints the exact commands it would run:

```sh
cd bench && uv --no-config run python -m voiceour_bench.capture_matrix plan \
  --prompts ../benchmarks/data/techterms/capture-prompts.jsonl \
  --manifest ../benchmarks/data/techterms/capture-matrix.jsonl \
  --output-dir ../benchmarks/data/techterms/real-speaker-audio \
  --speaker-id speaker-001 --speaker-kind real --takes 2 --dry-run
```

Each printed command has the fixed executable contract:

```sh
voiceour-capture-bench --mode MODE --duration-ms 8000 \
  --pre-roll-ms PRE --post-roll-ms POST --output PATH
```

After preparing each labeled condition, collect the planned rows. Real-speaker execution is
blocked unless the operator explicitly acknowledges consent:

```sh
cd bench && uv --no-config run python -m voiceour_bench.capture_matrix run \
  --manifest ../benchmarks/data/techterms/capture-matrix.jsonl \
  --results ../benchmarks/results/techterms-capture.results.jsonl \
  --consent-confirmed
```

The runner requires exactly one JSON object from the executable, verifies that its output path
matches the plan, and decorates it with the pair, prompt, take, mode, and condition identities.
Report ingestion rejects unknown/duplicate captures or mismatched prompt, take, pair, mode, or
condition identities:

```sh
cd bench && uv --no-config run python -m voiceour_bench.capture_matrix report \
  --manifest ../benchmarks/data/techterms/capture-matrix.jsonl \
  --results ../benchmarks/results/techterms-capture.results.jsonl \
  --output ../benchmarks/results/techterms-capture.report.json
```

The report preserves every planned row, including missing manual and unavailable
hardware-dependent captures. `collection_status: complete` means every row was captured; it is
not an audio-quality verdict. The report always uses `quality_verdict: not-evaluated`.

### Consented real-speaker collection

1. Explain what prompts will be recorded, why the audio is needed, where the benchmark dataset
   will live, who can access it, and the retention/deletion procedure. Record affirmative,
   revocable consent outside the audio itself before using `--consent-confirmed`.
2. Assign a pseudonymous `speaker_id`; do not put a name, email, or other direct identifier in
   the manifest or filename. Keep speaker and acoustic splits held out by this id.
3. Use the same written prompt and take id across every mode in a pair. Keep microphone, angle,
   distance, playback/noise levels, and route fixed except for the condition variable being
   tested. Do not reuse ordinary Voiceour session recordings: production session audio remains
   ephemeral and is never persisted.
4. In Control Center, record the selected system Mic Mode before collection and hold it constant
   across the entire paired set. System Mic Mode can override app-level processing. If it or the
   input route changes unintentionally, invalidate and repeat the whole pair rather than mixing
   settings. Also retain the executable telemetry for actual input/output formats and route
   changes.
5. Set up and annotate fan/keyboard noise, loudspeaker echo, distance/angle, clipping level,
   Bluetooth HFP, and planned route changes consistently. Bluetooth and route-change rows are
   hardware-dependent and must stay visibly missing until that hardware procedure is completed.
6. Store only the explicitly consented benchmark takes under the controlled benchmark dataset
   path, apply the agreed retention policy, and delete withdrawn or rejected takes and their
   derived artifacts.

Locally synthesized TTS may exercise file plumbing and command/report smoke coverage only. Plan
it with `--speaker-kind tts`, which labels every row `evidence_scope: smoke-only`. TTS is not
real speech and must not be used as evidence for capture quality, speaker variation, technical
term accuracy, or the production gate.

Once paired capture results have been transcribed into comparable benchmark reports, enforce the
project-policy maximum regression of +0.35 percentage points U-WER (`0.0035` in fractional
units):

```sh
cd bench && uv --no-config run python -m voiceour_bench.compare \
  ../benchmarks/results/techterms-standard.report.json \
  ../benchmarks/results/techterms-candidate.report.json \
  --gate uwer_final:0.0035
```

## TechTerms tier

The permanent `techterms` tier measures technical-term comprehension: whether jargon, acronyms, camelCase identifiers, symbol/digit tokens, multiword names, and coinages survive transcription, and whether ordinary language that merely sounds like a term is left alone. It is prepared like `smoke` (local `say` synthesis, deterministic and offline) and runs through the production Swift STT path via `make bench-techterms`. Every row is synthesized, so the tier is smoke-only.

### Row schema

The techterms manifest keeps the standard pipeline input contract (`id`, `audio_path`, `reference`, `formatted_reference`, `audio_s`) and adds per-term labels:

- `canonical_term`: the exact target orthography (e.g. `kubectl`, `audioBufferSize`, `C++`, `IPv6`).
- `term_id`: stable identifier shared between a positive utterance and its hard negatives (e.g. `term-kubectl`), so a positive and its confusable are scored against the same term.
- `term_class`: orthographic family, one of `jargon`, `acronym`, `camel_case`, `symbols`, `digits`, `multiword_name`, `coinage`.
- `expect_term`: whether `canonical_term` should appear in the output.
- `hard_negative_kind`: `null` for positives; `minimal_pair`, `homophone`, or `ordinary_language` for negatives that must not trigger a term replacement.
- `speaker_id` / `speaker_kind`: provenance; every synthesized row is `macos-say-samantha` / `tts`.
- `condition`: acoustic condition, `clean` for the synthesized tier.
- `project_scope`: vocabulary scope for the term (`global`, or a project id such as `voiceour`).

Because every row is `speaker_kind: tts`, the tier exercises the term-comprehension plumbing and metric wiring end to end but is not evidence of real-speaker accuracy.

### Term, candidate, and calibration metrics

On top of the shared U-WER/CER/latency metrics, techterms reports add the following (defined in `metrics.py`, assembled in `report.py`):

- **Canonical term P/R/F1**: exact-term precision, recall, and F1 over the positive rows.
- **Hard-negative false-replacement rate**: fraction of observed hard-negative opportunities where the canonical term wrongly appears, with a per-10k-opportunity scaling.
- **No-op preservation**: exact-preservation rate on rows the terminology layer should leave untouched.
- **Candidate Recall@K**: whether the expected `term_id` is among the retrieved candidate ids at K = 1 and K = 5.
- **Per-mode reliability / ECE / risk-coverage**: Brier score, expected calibration error, equal-width reliability bins, and risk/coverage points bucketed by the transcript `confidenceMode`.

Current runner output rows do not emit a `hypotheses` field. Report compatibility code reads that
field only from historical committed results under `benchmarks/results/`.

### U-WER regression gate

`voiceour_bench.compare` prints metric deltas between two reports and fails any gate expressed as `metric:max_delta`. Enforce the project maximum regression of +0.35 percentage points U-WER (`0.0035` in fractional units) between a baseline and a candidate techterms report:

```sh
cd bench && uv --no-config run python -m voiceour_bench.compare \
  ../benchmarks/results/techterms-baseline.report.json \
  ../benchmarks/results/techterms-candidate.report.json \
  --gate uwer_final:0.0035
```

A candidate whose gated metric rises by more than `max_delta` exits non-zero; `--gate` may be repeated to enforce several budgets at once.

### Analyses

- `voiceour_bench.disagreement` compares two backend runs for transcript disagreement and the term-recovery routing signal (which utterances one run gets and the other misses):

  ```sh
  cd bench && uv --no-config run python -m voiceour_bench.disagreement \
    --run-a-results ../benchmarks/results/techterms-parakeet.results.jsonl \
    --run-a-manifest ../benchmarks/data/techterms/manifest.jsonl \
    --run-b-results ../benchmarks/results/techterms-apple.results.jsonl \
    --run-b-manifest ../benchmarks/data/techterms/manifest.jsonl
  ```

## Adding a dataset tier

1. Add a `prepare_<tier>()` function in `bench/src/voiceour_bench/datasets_prep.py` that writes 16 kHz mono WAVs under `benchmarks/data/<tier>/audio/` and a `manifest.jsonl` matching the pipeline input contract: `id`, `audio_path`, `reference`, `formatted_reference`, and `audio_s`.
2. Register the tier in `prepare_tier()` and in `voiceour_bench.run` argparse choices.
3. Document the dataset source, license, default row count, and reference-field semantics in this file.
4. Add a Make target only if the tier becomes a standard workflow.
