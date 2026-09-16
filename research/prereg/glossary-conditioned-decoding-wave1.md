# Preregistration — glossary-conditioned-decoding, Wave 1 (state-dump + cached-replay pilot)

Track `glossary-conditioned-decoding` (A-tier, workstream `precision-recall`). Frontier
of record `0ac7514`; contract `research/next-program.md`. Written before encoder states
were dumped or adapter scores were measured. The commit adding this file is the freeze;
`wave1/run1/manifest.json` records it. No endpoint, input rule, split, model, threshold
budget, or hyper-parameter below may change after that commit; a change is a new family.

## Question
Can one bounded, learned glossary-conditioning block use the frozen CoreML encoder state
and a dynamic 100-term `VocabularySnapshot` to emit the correct candidate ID or null,
then safely create at least one exact-canonical hit beyond the 295/346 frontier when the
unchanged TDT tail and deterministic exact renderer consume its decision?

The reference teacher reached 295/346 with `uwer_general = .030725`, zero corrected
jargon false rows, and deterministic/error-free output (`research/final-report.md:20-29`).
All 51 residual misses lack the canonical in every Parakeet source
(`research/final-report.md:99-101`), so flat score manipulation is not the tested family.

## Hypothesis
H1: a non-flat acoustic/glossary metric learned from paired technical and confusable
surfaces can select a bounded term ID, localize its acoustic frames, and perturb the
pre-decoder `[frames,1024]` state enough to yield a net safe exact-canonical gain. Paired
ordinary homophones will instead select null.

H0: held-out-template candidate selection and adapted-state replay do not exceed 295/346
at zero unsupported activations, or any gain requires a safety, identity, precision, or
`uwer_general` violation.

Wave 0 found two dimension-preserving seams: the optional learned residual block at
`pre_enc_out` and the shipping `parakeet_full_with_external_encoder` route
(`wave0/verdict.md:23-69`). Its exact precedent is eight tensors / 4,198,400 parameters
(`wave0/verdict.md:122-129`). Wave 1 uses the latter seam and changes no vendored code.

## Immutable source inputs (sha256)
- Wave 0 verdict `.build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave0/verdict.md` — `0d4ed3cefb4e62d3ed6875a43f793e467e5a78642a604e2366f6ca87dd8a99b6`.
- `Sources/ASRSidecarCore/ParakeetContext.swift` — `fd4409a7cfca0e9f6f4e3302da9ee5fd1b5a234db8e3288326b4304079dccaf4`.
- `Sources/ASRSidecarCore/CoreMLEncoder.swift` — `e4f9731beca48d596fbda9171471111c0c93ab14d50cf3c1dd3ac22f4f7051cb`.
- `Vendor/parakeet/include/parakeet.h` — `48c31e350e8179afc470920eb8e2d39f11b7c7a54cee4d5de73798576ba4e5ba`.
- `Vendor/parakeet/src/parakeet.cpp` — `a1705096608e8b7ff0474d7a1def754ec264f93577c27b4a77d659deef1301db`.
- `Vendor/parakeet/src/parakeet-arch.h` — `f5075fb00c10158cc694c3a3db0e591a159443b9ed17220015c8db7ce24b6c00`.
- `benchmarks/data/jargon/manifest.jsonl` (456 rows) — `576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf`.
- `bench/autoresearch/corpus.manifest.jsonl` (96 general rows) — `885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749`.
- `bench/autoresearch/jargon.terms.json` (173 canonicals, 346 positives, 110 negatives) — `2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5`.
- `.build/asr-research/three-bets/margins/jargon456.lattice.jsonl` — `64980e8027867e17798800d947c446a673da7d1e3f4440b13ed098efad48cd25`.
- `.build/asr-research/three-bets/margins/general96.lattice.jsonl` — `a82adf5b5884370af25a7f3ed5ef18496498c426d31f33a4d2152904b5cf6411`.
- `bench/autoresearch/repair.vocabulary.json` — `650dfc3fa02ebc7e2e8754066f0f9d4336d5113444154e1a27975139812fd1c8`.
- `bench/autoresearch/replay_repair.py` — `b2a4360046ee614af4ef81f8bc323e1311cba11b2db41c6cbd0a3c734c7f6767`.
- `bench/autoresearch/score_v5.py` — `bcd5c3fde5a2d5d9c2cdabdf59fe561ce03e9f7d0b522a435b6cf1f1a19e25de`.
- `bench/src/voiceour_bench/metrics.py` — `307eb4f113bda8e72faa513fce4885befde425ed7a80036deab6354e8a50a539`.
- `Sources/VoiceCore/Vocabulary.swift` — `a52fe0be262e025f275b765844e787a27f8433ff491744431bfc6c15cc6794b0`; `CandidateRetrieval.swift` — `7f74f75cd7aa0bc8301f26730ddeb6eb7fa233d4fbdde7a3c0498992e1ffc1b7`; `Glossary.swift` — `e677d272e9e20ce50eeea3af11eacffdacae71d3ab56bf05553ea99f3fa966d1`.
- Model `/Users/vlad/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin` — 1,255,897,319 bytes; `833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f`.
- Tiny encoder `/Users/vlad/Desktop/voiceoour/.build/asr-research/three-bets/palettize6/tiny/parakeet_encoder_6bit.mlmodelc` — `e77ac4a6fc6299868fce308b652b363a3fd98d7024a225b6920f691ff66add05`.
- Short encoder `/Users/vlad/Desktop/voiceoour/.build/asr-research/three-bets/palettize6/short/parakeet_encoder_6bit.mlmodelc` — `1d995f0ef5a92e14f92214b93af46126a78427513be7d6ea695cae421f6a16e6`.
- Standard encoder `/Users/vlad/Desktop/voiceoour/.build/asr-research/three-bets/palettize6/standard/parakeet_encoder_6bit.mlmodelc` — `adffa42216599bdb01611a6e06cb8f26448cb3a66078b8fbed66dbe8b6cb544d`.

The model header is read without inference using the checked record layout at
`parakeet.cpp:2193-2338,963-1071`. `decoder.prediction.embed.weight` is the declared
prediction embedding (`parakeet-arch.h:177`; allocation at `parakeet.cpp:2871`): F16
`[640,8193]`, payload offset 1,219,620,741, 10,487,040 bytes, payload sha256
`3173388aaf6b5b4ae292d8777940bb8fb5c7c02e30adf708b9dde4d909c2000f`.
Those values and the extracted payload digest must match or the pilot stops.

## Stage 1 — parent-serialized state dump (fixed)
This is the only GPU/ANE step: **parent-serialized, exclusive hardware**, one process,
one pass, one CoreML encode and one unchanged-tail decode for each of the 456 jargon
rows. No harness and no download. The research-only `glossary-conditioning dump-states`
subcommand must only expose the buffer already lent at `CoreMLEncoder.swift:301-382` and
call the existing external seam at `ParakeetContext.swift:400-443`; its source and binary
sha256 enter the run manifest. After a central release build, the exact command is:

```sh
cd /Users/vlad/Desktop/voiceoour && make stop && env VOICEOUR_COREML_ENCODER_TINY="$PWD/.build/asr-research/three-bets/palettize6/tiny/parakeet_encoder_6bit.mlmodelc" VOICEOUR_COREML_TINY_MAX_S=6.0 VOICEOUR_COREML_ENCODER_SHORT="$PWD/.build/asr-research/three-bets/palettize6/short/parakeet_encoder_6bit.mlmodelc" VOICEOUR_COREML_SHORT_MAX_S=8.0 VOICEOUR_COREML_ENCODER="$PWD/.build/asr-research/three-bets/palettize6/standard/parakeet_encoder_6bit.mlmodelc" VOICEOUR_COREML_MAX_S=15.0 .build/release/voiceour-bench glossary-conditioning dump-states --input benchmarks/data/jargon/manifest.jsonl --lattice .build/asr-research/three-bets/margins/jargon456.lattice.jsonl --model "$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin" --output .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/state-dump
```

`state-dump/states.f32` is concatenated little-endian frame-major F32. Its
`index.jsonl` has one row per ID with byte offset/count, frame count, width 1024,
audio sha256, per-row state sha256, baseline raw/final text and transcript hashes.
`baseline-rows.jsonl` records the unmodified external-state TDT result. There are no
retries: any missing/duplicate ID, non-finite value, width mismatch, digest mismatch,
decode error, or row count other than 456 stops the track. The aggregate state/index
sha256 values become immutable inputs to Stage 2. Execution is blocked until this dump
exists; this preregistration does not claim it exists.

## Stage 2 — cached CPU training and replay (fixed)
After Stage 1, no audio is decoded and no CoreML model is loaded. Training is numpy-only
under `bench/.venv` and tail replay uses the same prebuilt helper with `useGPU=false`,
`tailBackendCPU=true`. The exact command is recorded verbatim in `run1/command.txt`:

```sh
cd /Users/vlad/Desktop/voiceoour && env PYTHONHASHSEED=0 VECLIB_MAXIMUM_THREADS=6 bench/.venv/bin/python .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/glossary_conditioned_replay.py --states .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/state-dump/states.f32 --index .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1/state-dump/index.jsonl --terms bench/autoresearch/jargon.terms.json --jargon-lattice .build/asr-research/three-bets/margins/jargon456.lattice.jsonl --general-lattice .build/asr-research/three-bets/margins/general96.lattice.jsonl --contrastive-rows .build/asr-research/next/data-foundation/contrastive-homophone-training/wave1/run1/rows.jsonl --model "$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin" --tail-runner .build/release/voiceour-bench --output .build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/run1
```

The script and upstream contrastive rows are run artifacts; their observed sha256 values
are pinned in `manifest.json` before the first optimizer step. The contrastive file is
accepted only if its producer preregistration is frozen and every consumed row carries
`positive_id`, canonical/category, emitted surface and span, globally unique provenanced
negative counterpart ID/source/surface/span, input digests, and pair status. A missing,
ambiguous, or unprovenanced counterpart is excluded and reported; zero usable pairs
stops before training. No label is inferred from accepted paste or prior model output.

## Active glossary and tokenizer (fixed)
The 173 canonical surfaces become `.manualImport` terms. Stable term ID is the first 16
lowercase hex digits of `sha256("Voiceour/Wave1/" + canonical UTF-8)`. For each row, rank
all terms by `sha256("20260830|" + row_id + "|" + term_id)` ascending. A positive's
annotated target is forced into the first 100 by replacing rank 100 when necessary; a
negative takes ranks 1–100. The resulting set is sorted by term ID before indexing, so
target position leaks nothing. Limit 100 and the trust/quota rules are those at
`Vocabulary.swift:74-140`. Empty glossary means a structural block skip.

Tokenization reproduces `sentencepiece_normalize` plus greedy longest match exactly
(`parakeet.cpp:608-635,5223-5253`) over the pinned header table. A surface containing
`<unk>` is unrepresentable and always null. The frozen unrepresentable set is exactly
`C++`, `C#`, `io_uring`; no spelling exception or post-freeze tokenizer is allowed.
A term vector is the F32 mean of its non-control decoder-embedding rows, L2-normalized,
then zero-padded from 640 to 1024. Contrastive emitted surfaces use the same rule.

## Split, labels, and localization (fixed)
Two-fold cross-fitting uses the corpus's two rows per canonical: model A fits the lower
numeric row ID and tests the higher; model B reverses them. Negative jargon rows are fit
for A/test for B when the low bit of `sha256(row_id)` is 0, and reversed otherwise.
This is deterministic, not a drawn split; no repeated-random-split selection occurs.
Every positive is scored once out of fold. Bootstrap and permutation units remain the
173 canonical clusters because two templates for one term are correlated.

Positive target label is the annotated canonical. Wrong canonical and null are failures.
Negative target is null; any taught surface absent from its reference is unsupported.
The contrastive emitted span supplies the acoustic window for baseline misses; an
already-exact transcript uses its exact canonical span. Character spans map to the
cached lattice's nonblank pieces; the selected center is the earliest intersecting step,
and failure to map uniquely stops. At inference, localization is the earliest frame at
the candidate's maximum score, with a clipped ±4-frame adaptation window.

## One model and training budget (fixed)

For frame state `x` and padded term vector `t`, both in R1024:

- `a(x) = norm(Wa2·ReLU(Wa1·LN(x)+ba1)+ba2)`;
- `g(t) = norm(Wg2·ReLU(Wg1·t+bg1)+bg2)`;
- frame score is `a(x)·g(t)`; row score is its maximum, earliest-frame tie;
- null logit is 0; candidate logits are row score / temperature `.07`.

The four `[1024,1024]` F32 matrices and four `[1024]` F32 biases are all trainable:
exactly eight tensors and `4·1024² + 4·1024 = 4,198,400` parameters. Matrices initialize
to identity plus `Normal(0, .001)`; biases initialize to zero. PCG64 seed 20260830 consumes A then B.
Each fold runs exactly 256 AdamW updates, batch 8, seven snapshot distractors per positive;
contrastive negative surface replaces distractor seven where available. Loss is mean
cross-entropy over target ID plus fixed null; negative rows target null. AdamW is lr
`.0001`, betas `(.9,.999)`, epsilon `1e-8`, weight decay `.0001`, global gradient-norm
clip `1.0`; all arithmetic and optimizer state are F32. No early stopping or scheduler.

For a selected ID at frame `f`, frames `f-4` through `f+4` become
`x' = x + eta·channel_std·tanh(a(x) * g(t))`; `channel_std` is computed on that fold's
fit states only. Structural null returns the original bytes without evaluating the block.
The complete amplitude budget is `eta ∈ {.05,.10,.20}`. For each fold, cache all three
fit replays and choose `(eta, tau)` maximizing fit `recall_hits` subject to zero fit
unsupported activations, zero lost fit hits, and `changed_span_precision = 1.0`; `tau`
is one of the unique fit maximum probabilities plus the always-null sentinel. Ties choose
larger `tau`, then smaller `eta`. Apply the pair unchanged to that fold's test rows.
There is no other architecture, loss, transform, amplitude, threshold, or model trial.

The adapter emits `(term_id, frame_window)` or null. The unchanged greedy TDT tail decodes
`x'`; the minimal contiguous token span overlapping the frame window is replaced only by
the selected canonical through deterministic exact rendering. This is not free-form text
generation. M0 is the structural-null identity control; M1 is the sole learned model.

The state pack is about 95 MiB for the 23,787 expected jargon encoder frames; verify the
actual count rather than gating on that estimate. Each fold is trained sequentially,
never concurrently: one F32 state memmap, one ~16.8 MB parameter set, ~33.6 MB Adam
moments, batches of eight, six Accelerate threads, then one CPU-tail replay. The fixed
256-update × two-fold plan is allowed up to eight wall-clock hours. Crossing eight hours
kills for impractical offline compute; it does not license fewer updates or a smaller block.

## Evaluation and decision

- **Primary endpoint:** cross-fitted `recall_hits` / `jargon_term_recall`, exact
  case-sensitive canonical containment over all 346 positives after the bounded renderer,
  using `score_v5.py:189-195` semantics.
- **Meaningful effect:** cross-fitted `recall_hits >= 262` (≥ +16 over the shipped
  strict `.95` repair's 246, the same pilot bar as the verifier's arm A) with
  `unsupported_activations_per_1k = 0`, `jargon_false_terms = 0`, no lost M0 hit,
  `changed_span_precision = 1.0`, and both identity controls exact. Parity with the
  teacher (`recall_hits >= 296`) is the Wave 2 development gate, not a pilot bar.
- **Strong effect:** `recall_hits >= 279` under the same zero-harm conditions.
- **Kill:** `recall_hits < 254`; any unsupported activation, false term, lost M0
  hit, wrong accepted span, critical syntax corruption, or identity mismatch; no
  zero-activation fit operating point; zero usable contrastive pairs; or runtime > 8 h.
  Any kill ends this track at Wave 1. It does not authorize a different threshold.
- **General guard:** reconstruct final text for all cached general96 rows with the frozen
  cleanup/repair semantics and the structural empty-glossary branch; require
  `uwer_general <= .034225`. General active-glossary safety is not claimed here.
- **Identity:** I0 (empty glossary) and I1 (nonempty glossary, tau forced above 1) must
  reproduce Stage 1 state bytes, raw/final transcript hashes, and timings input exactly.
- **Secondaries, never promoted:** `candidate_id_accuracy` (correct out-of-fold ID / 346),
  `adapter_pair_rank_accuracy` (positive score > paired negative, ties fail),
  `state_identity_mismatches`, changed rows from the adapted TDT tail, recall by domain,
  and recall for representable versus forced-null canonicals. These names are track-local
  and have only the definitions in this bullet.

`unsupported_activations_per_1k` uses the 110 negative jargon rows as 110 opportunities;
an activation is an accepted taught term absent from the reference, including `IAM` from
"I am"/"I'm", `Redis` from radios/radius, `runc` from run/runs, `Credit Swift` for
Credit Suisse, `CALayer` from color/colour, `C++` from CI/secret, `kqueue` from queue(s),
and measured QUIC/CUDA cases when present. Missing acoustic classes are reported, never
synthesized or silently treated as passes. `critical_syntax_corruption` counts any accepted
change that damages a code, identifier, number, or operator span.

## Uncertainty (fixed)
Percentile bootstrap, B = 10,000, seed 20260830, resamples canonical clusters for
`recall_hits`, `candidate_id_accuracy`, and pair-rank accuracy; clustering keeps the two
same-term templates together. It resamples utterance rows for `uwer_general`, because the
96 references are distinct utterances. Report 2.5/97.5 percentiles.

For the required zero unsupported activations, report the exact one-sided 95%
Clopper-Pearson upper rate `1 - .05^(1/n)` over negative-row opportunities and multiply
by 1,000; do not report zero as certainty. The claimed recall improvement receives a
one-sided paired permutation test over 173 canonical gain clusters: 100,000 Rademacher
sign flips, seed 20260830, statistic mean candidate-minus-M0 hit count, plus-one p-value
correction. No row-level permutation is allowed.

## Dependencies
`contrastive-homophone-training/wave1/run1/rows.jsonl` owns emitted-surface extraction,
paired counterpart IDs, provenance, and rank labels; this track consumes but never edits
those labels. `acoustic-glossary-verifier` shares candidate ID/span/accept-or-abstain
semantics and frozen lattice-span alignment, but not model scores. `confidence-calibration`
owns any later product risk-coverage threshold; this pilot's tau cannot become its product
threshold. `real-speaker-techterms-corpus` owns speaker/session/template-disjoint training
and sealed validation. `VocabularySnapshot` owns bounded trust ordering; `Glossary` owns
exact spelling. Any future contrastive loss or verifier must depend on these same IDs,
spans, tokenizer/model digest, negative provenance, split clusters, and null definition,
not recreate a second convention.

## What this pilot cannot show

The 346 positives and 110 negatives are one synthetic TTS voice. The cached general96
set is evaluated only through structural empty-glossary identity; it does not test an
active glossary on long real speech. Two-template cross-fitting permits term identity in
both fit and test, so it tests acoustic/template transfer, not unseen terminology. A pass
does not establish real-speaker recall, calibration, production latency, memory, CoreML
export, one-resident-artifact packaging, or a fresh false-activation rate. Those remain
Wave 2–4 gates. The current repository also has no CoreML export producer
(`wave0/verdict.md:116-120`); product integration remains blocked on it.

## Artifacts

Root `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/precision-recall/glossary-conditioned-decoding/wave1/`:
`prereg.md` (this file plus freeze commit), `verdict.md`; `run1/command.txt`,
`manifest.json`, `metrics.jsonl`, `rows.jsonl`, `state-dump/command.txt`,
`state-dump/states.f32`, `state-dump/index.jsonl`, `state-dump/baseline-rows.jsonl`,
fold weights/optimizer reports, extracted embedding metadata, and the replay script verbatim.
`metrics.jsonl` uses `glossary-conditioned-decoding/wave1/1`; `rows.jsonl` records row ID,
fold, snapshot IDs, label/provenance, selected ID/null, score, tau, eta, frame/span,
M0/M1 texts and hashes, correctness, and every safety flag. No file is overwritten.

## Stop rule

One exclusive Stage 1 pass and one Stage 2 run. No harness run, download, or retuning.
A script defect that violates a preregistered invariant may be fixed and the entire
affected stage repeated once with both commands and artifacts retained; a second defect
stops. Statistical failure, a hard-guard failure, or a missing dependency is not a script
defect and stops immediately. A pass licenses one frozen Wave 2 family; a failure kills
this family and no alternate adapter is tried against these rows.
