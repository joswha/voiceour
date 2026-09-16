# Preregistration — stateful-ane-encoder, Wave 1 (exported-layer recurrence probe)

Track `stateful-ane-encoder` (A-tier, workstream `runtime-speed`). Frontier of record `0ac7514`;
base source `d314b56`; contract `research/next-program.md`. This file precedes a candidate export
and any recurrence measurement. Its commit is the freeze; changing an input family, boundary,
endpoint, tolerance, state budget, or selection rule requires a new family and preregistration.

## Question

**BLOCKED.** Wave 0 found no stateful CoreML artifact: the current contract has two inputs, two
outputs, and no state declaration, while 0 of 71 public Parakeet APIs exposes an encoder cache
(`.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/verdict.md:21-30`). The probe
waits for the sole artifact below and its sealed digest and provenance in `run1/manifest.json`.

Question: can one causal/chunked FastConformer CoreML artifact process the same PCM either as
a whole utterance or across a retained state, then flush once, with bounded state, exact frame
accounting, numerically equivalent encoder values, no lost tail frames, and reset isolation?

## Hypothesis

H1: a speaker-kernel-family FastConformer with `att_context_size: [70,13]`, all-left convolution
padding, an online-compatible frontend, and explicit recurrent state can emit `concat(step
outputs, flush output)` equivalent to its whole-utterance encoder. State shape and bytes remain
constant as the prefix grows, and in-place reset removes every effect of the preceding utterance.

H0: at least one boundary changes state shape or byte count, changes the valid-frame count,
exceeds the frozen numeric tolerance, loses or duplicates a flush frame, or leaks utterance A
into utterance B after reset.

The premise is architectural, not a result. `spk_ff1_w` is a load-time artifact predicate created
only when all eight speaker-kernel records exist; it gates causal frame count and padding, all-left
depthwise roll, chunked attention, and `normalize: NA`
(`.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/verdict.md:135-166`). It is not
a runtime flag that can make incumbent v3 streamable.

## Immutable available inputs (sha256)

- `research/next-program.md` — program contract; `7ae119c644b01e0d3c3718ab6bd5b4d5ceb6e462214339f7f417d8a03d15a98f`
- `/Users/vlad/Documents/ObsidianVault/projects/voiceour/concepts/stateful-ane-encoder.md` — Wave 0 handoff; `67762779d3fdaff347e738799c87c7754ff9bdfcc296a2a1d750d94c5c961c85`
- `Sources/ASRSidecarCore/CoreMLEncoder.swift` — incumbent CoreML contract and Swift guard; `e4f9731beca48d596fbda9171471111c0c93ab14d50cf3c1dd3ac22f4f7051cb`
- `Vendor/parakeet/src/parakeet.cpp` — artifact predicate, frame-count functions, and tail guard; `a1705096608e8b7ff0474d7a1def754ec264f93577c27b4a77d659deef1301db`
- `research/bet2-ane-encoder.md` — prior ANE energy and ABBA evidence; `c9bec0f546e2d21ff7bede675e6d5b96839ae9dde938684e470bb99e7d414010`
- `research/bet2-promotion-packet.md` — sealed cross-SoC bars; `bd2721b9e67e92b3d93dfe222b0c66817013d9ff3dcdaab91e2dd0b13266eeec`
- `bench/autoresearch/score.py` — prior-instrument energy scorer; `84f6db8793f9a126ca202e0a5c258031547a618b242b46bbd3d2694027c4a8c6`
- `.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/state-inventory.txt` — `5cb6e27358b2133c253be42a8f17e7244a29bf9c6ff7e1e693a4c2aed0d5b9b1`
- `.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/verdict.md` — `4167668ad277b01d2d3b1f61cca46cac12402a65827f46d2e7fcc0e144cef662`
- `.build/asr-research/next/runtime-speed/streaming-pre-encoding/wave0/verdict.md` — `cc64678a74ab8bd03ea1cdf1e72d2e12c11db6bcfdc7ebfcc0f55def0708eeed`
- `benchmarks/data/jargon/manifest.jsonl` — fixture identity; `576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf`
- `benchmarks/data/jargon/audio/jg_0000_cloud_kubectl.wav` — utterance A; `77f17f4dbe7fe6358e2ca1e9cebcc92d771937f0a028840dcb360c853aca1740`
- `benchmarks/data/jargon/audio/jg_0001_cloud_kubectl.wav` — utterance B; `c42aed97948ca5c5c0946c4eca88ccf385b4391ff6051904657ba013fc67f56f`

The WAVs must parse as mono, 16-bit little-endian PCM at 16,000 Hz; any mismatch blocks before
CoreML load. Wave 1 downloads, regenerates, resamples, and decodes no audio.

## Missing candidate artifact (reopening condition)

Exactly one candidate is admitted at `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/
runtime-speed/stateful-ane-encoder/wave1/run1/stateful-fastconformer.mlmodelc`: one causal/chunked
FastConformer CoreML export from a pinned speaker-kernel-family checkpoint, not incumbent v3.
Before prediction, `manifest.json` must record and the runner must verify:

1. Source checkpoint repository/model id, immutable revision, path, bytes, and SHA-256; all eight
   speaker-kernel tensors must be present.
2. Conversion source path/SHA-256, exact command, Python and Core ML Tools versions, conversion
   tool/version, deployment target, precision, and compute unit. This pilot authorizes no conversion/download.
3. One artifact with callable whole-utterance, stateful-step, and flush semantics; the manifest
   maps roles to feature/function names. No second export is compared.
4. Every state field's name, dtype, shape, initialization bytes, reset rule, and I/O mapping.
   Opaque or undeclared carry means explicit state I/O is absent.
5. `att_context_style: chunked_limited`, `att_context_size: [70,13]`: one 14-frame chunk plus five
   preceding chunks, not a per-frame band
   (`.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/verdict.md:90-99`).
6. Three-stage causal subsampling and all-left pre-encoder/depthwise padding at every layer.
7. Exactly `normalize: NA`, or declared count/sum/sum-of-squares and all tensors for one fixed
   online normalizer used identically by whole and stepped paths; whole-utterance `per_feature`
   normalization is inadmissible
   (`.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/verdict.md:100-109`).
8. `coreml_encoder_digest`: SHA-256 over bytewise-sorted regular files represented as
   `relative-path NUL byte-count NUL file-sha256 LF`. Symlinks are forbidden; tree and digest
   become immutable at preflight.

Absence of any item blocks before measurement; it does not admit another export.

## Frame-count prerequisite

The speaker-kernel branch applies `n = n / 2 + 1` three times; the current external handoff and
Swift validator use `ceil(n/8)` (`Vendor/parakeet/src/parakeet.cpp:1350-1359,6236-6254`;
`Sources/ASRSidecarCore/CoreMLEncoder.swift:350-360`). They disagree for 1,313 of 1,501 mel
lengths and yield 189 versus 188 at 1,501
(`.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/verdict.md:168-190`).

Before TDT decode, energy/latency, or Wave 2, one predicate-aware frame-count function must serve
the export, Swift validator, and `parakeet_full_with_external_encoder`. Exhaustively test mel
lengths 1...1,501: conflicts = 0 and causal 1,501 = 189 accepted frames. This exported-layer
probe emits no transcript and avoids the broken handoff; a pass cannot waive the prerequisite.

## Selection budget and operating point

There is no training, feature selection, random split, or learned operating point. The whole
budget is one digest-pinned artifact, `.cpuAndNeuralEngine`, three fixed boundaries, and the
tolerances below. No CPU-only comparison, alternate chunk/context/normalizer, precision sweep,
or threshold sweep is tried. Admission uses only pre-output provenance; all cases are evaluated.

## Fixed PCM cases

Utterance A is split into exactly two chunks in each of three fresh-state cases:

| case | split after PCM sample | alignment role |
|---|---:|---|
| `aligned-16` | 20,480 | 16 × 1,280-sample subsampling periods |
| `unaligned` | 32,123 | not divisible by the 160-sample mel hop or 1,280-sample period |
| `aligned-40` | 51,200 | 40 × 1,280-sample subsampling periods |

PCM indices count channel frames after the data header from zero; splits add no overlap, fill, or
duplication, and each starts from fresh state. For reset isolation, A uses `unaligned`, flushes,
resets the same allocation to declared initial bytes, then processes B in one whole step + flush.
A newly allocated cold state processes B by the same schedule.

## Four track-local equivalence quantities

1. **`state_shape`** — ordered `(name, dtype, dimensions)` tuples after every call. Units: tensor
   elements plus dtype. Tolerance: exact manifest equality and equality across all boundaries.
2. **`valid_frame_count`** — reported valid `[time,1024]` frames for whole, each step, flush, and
   concatenation. Units: frames. Tolerance: `chunked_minus_whole = 0`; all counts nonnegative.
3. **`encoder_error`** — over aligned cells, whole `w` versus stepped+flush `s`:
   `max_abs=max(|s-w|)` and `max_rel=max(|s-w|/max(|w|,0.01))`. Tolerances: `max_abs <= 0.0005`,
   `max_rel <= 0.05`, nonfinite count = 0 in every case.
4. **`tail_frame_loss`** — `max(0, whole_frames-preflush_valid_frames-flush_valid_frames)`.
   Units: frames; tolerance: 0. A second flush must emit 0; exact total count rejects duplication.

`recurrence-probe.json` holds structured quantities. Scalar `metrics.jsonl` names
`state_shape_match`, `valid_frame_count_delta`, `encoder_max_abs_error`,
`encoder_max_relative_error`, and `tail_frame_loss`, with the definitions above.

## Bounded-state predicate and reset isolation

`state_total_bytes` sums `product(dimensions) × dtype bytes` once per logical carry field; paired
I/O aliases are not double-counted, and emitted frames/runner files are excluded.
`state_total_bytes_range` is max minus min across the three boundary snapshots.

Wave 0 sizes 70-frame K/V across 24 × 1,024 at 13,762,560 B and convolution history at
393,216 B, 14,155,776 B combined
(`.build/asr-research/next/runtime-speed/stateful-ane-encoder/wave0/verdict.md:65-99`). Require
`state_total_bytes <= 16,777,216 B` and range = 0; the remaining 2,621,440 B covers declared
frontend/right-context/counters/alignment, never utterance-length output history.

Reset requires `reset_output_byte_mismatches = 0`: reused/reset B and cold-state B have equal
valid counts and every valid output byte. Reused post-reset shape and initialization bytes equal
the original declaration; a replacement allocation disguised as reset fails.

## Fixed procedure and authorized command

1. Create `run1/manifest.json`, pin every input, runner/candidate field, and required environment
   key (`research/next-program.md:169-182`); copy this preregistration + freeze commit to `prereg.md`.
2. Verify digests, WAV headers, provenance, state schema, and model properties before CoreML load;
   any absent value records a block and stops.
3. Run `make stop`; the parent obtains exclusive ownership. This is a **parent-serialized,
   exclusive hardware** ANE run.
4. Load once with `.cpuAndNeuralEngine`; run fresh-state whole A, three two-chunk A cases + flush,
   then reset isolation and cold B.
5. Record schema/bytes after every call, valid counts, float32 outputs, errors, loss, second-flush
   count, step/flush times, nonfinites, and reset bytes. Atomically write outputs and verdict.
   No transcript, harness, download, conversion, energy, or latency flight is permitted.

The exact authorized command is:

```sh
cd /Users/vlad/Desktop/voiceoour && make stop && /usr/bin/xcrun swift -O .build/asr-research/next/runtime-speed/stateful-ane-encoder/wave1/run1/recurrence-probe.swift --model .build/asr-research/next/runtime-speed/stateful-ane-encoder/wave1/run1/stateful-fastconformer.mlmodelc --audio-a benchmarks/data/jargon/audio/jg_0000_cloud_kubectl.wav --audio-b benchmarks/data/jargon/audio/jg_0001_cloud_kubectl.wav --boundaries 20480,32123,51200 --reset-boundary 32123 --compute-units cpuAndNeuralEngine --seed 20260830 --output .build/asr-research/next/runtime-speed/stateful-ane-encoder/wave1/run1/recurrence-probe.json
```

The runner is a run artifact, not production code. Its SHA-256 is sealed in `manifest.json`
before CoreML load, and its behavior must implement this procedure exactly.

## Primary endpoint, meaningful effect, and kill rule

Primary endpoint: `recurrence_cases_passed`, the boundary cases satisfying all four quantities
and bounded state, reported with reset isolation.

**Meaningful effect:** 3/3 cases, state-byte range 0 B, state <= 16,777,216 B, reset mismatches 0,
and every numeric/flush tolerance passing. This is structural licensing, not a population claim.

**Kill:** declared state-field count 0; shape change; state range > 0 B or total > 16,777,216 B;
nonzero frame delta/loss; second flush >= 1 frame; max absolute error > 0.0005; max relative error
> 0.05; any nonfinite; or reset mismatches >= 1 byte. Kill stops the family: no moved threshold,
boundary, state budget, or artifact, and naive 15 s chunk concatenation is never an interim result.

## Uncertainty

Pass/fail is deterministic and conjunctive. For description, percentile bootstrap B = 10,000,
seed 20260830, resampling the three boundary trajectories for frame delta, both errors, loss, and
state bytes. A trajectory is the unit because its frames/channels share state; cells are dependent.

Report one-sided exact 95% Clopper–Pearson upper bounds: 0/3 boundary failures = 63.2%; 0/1 reset
leaks = 95.0%. Show these weak bounds. No split is drawn, so repeated random splits do not apply.

## Energy and latency only after a passing probe

Wave 1 measures no energy/product latency. A pass licenses a separately frozen Wave 2 run after
the frame-count fix, with the same artifact digest/configuration and no retuning.

Follow-on energy uses the prior contamination-gated eight-block order `R C C R C R R C`
(`research/bet2-ane-encoder.md:205-220`): R native, C stateful. `energy_ratio` is median candidate
compute joules / median reference compute joules; `energy_j` is median candidate compute-rail
joules (`bench/autoresearch/score.py:296-303`). Meaningful effect: `energy_ratio <= 0.55`, also
the sealed second-SoC bar (`research/bet2-promotion-packet.md:49-66`). `energy_j` has no absolute
gate because the ABBA ratio controls drift.

Context only: native run 52 = 444.579 J, ladder run 57 = 187.5 J, and run 61
`energy_ratio = 0.5679` (`research/bet2-ane-encoder.md:154-164,195-220`); none is Wave 1 evidence.

Follow-on latency reports paired per-row `asr_inference_p50_ms`, `asr_inference_p95_ms`, `rtfx`;
require p95 <= 230 ms and RTFx >= 100 plus global gates (`research/next-program.md:255-266`).
Bootstrap B = 10,000, seed 20260830: utterance rows for latency, four chronological ABBA R/C
pairs as energy clusters. A row supplies one paired observation; adjacent blocks share conditions.

Claimed differences use paired sign-flip permutation: 10,000 seeded row-latency permutations and
all 16 assignments for four ABBA pairs. No energy/latency command is authorized here: the current
harness pins the old ladder. Wave 2 freezes the real parent-serialized command after integration.

## What this pilot cannot show

A pass shows recurrence on two cached synthetic utterances, three boundaries, one M4 Pro. It does
not show transcript/U-WER/recall/safety, capture ownership, stop latency, energy, Voiceour memory,
long-run/cancellation/cold behavior, hosting, or a second SoC; it cannot promote the artifact or
supersede native full-utterance decode.

## Artifacts

Root: `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/runtime-speed/stateful-ane-encoder/
wave1/`: wave-level `prereg.md` and `verdict.md`; `run1/` has `manifest.json`, `command.txt`,
`recurrence-probe.swift`, `recurrence-probe.json`, `metrics.jsonl`, and `rows.jsonl`. The candidate
stays at its named path. Rows cover three boundaries plus reset; scalar metrics use run id
`stateful-ane-encoder/wave1/1`.

## Stop rule

While the artifact is absent, write only preregistration and blocked verdict; do not create
`run1/` or consume the run. Once artifact and runner are sealed, execute once. Preflight failure
stays blocked; observed failure kills. No repair, retuning, or second candidate. Energy, latency,
TDT, and harness stay forbidden until recurrence and predicate-aware frame count pass.
