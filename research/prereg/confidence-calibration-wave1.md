# Preregistration — confidence-calibration, Wave 1 (cached span pilot)

Track `confidence-calibration` (A-tier, workstream `precision-recall`), family
`confidence-calibration-wave1-span-v1`. Frontier of record `0ac7514`; source checkout
`d314b56`; contract `research/next-program.md`. This file is written before the Wave 1
span table or any calibration map is produced. The commit adding it is the freeze. The
run records that commit in `wave1/run1/manifest.json`; changing a population, endpoint,
score, map, split, threshold rule, effect, or kill rule requires a new family and preregistration.

## Question

Can a deterministic, per-stratum calibration of cached greedy-lattice confidence support
useful selective acceptance of **term spans**, while preserving zero activation on the
ordinary-language spans that a phonetic repair replay would otherwise touch?

The old `.621` LibriSpeech and `.568` FLEURS ECE figures describe row-level confidence
on larger populations (`research/CONTEXT.md:43-44`). Wave 0 found that they are not a
falsifiable word- or span-level reference on these harvests: the 64/32-row replay gave
row ECE `.580164`/`.673037`, while pooled word ECE was `.017986`
(`.build/asr-research/next/precision-recall/confidence-calibration/wave0/verdict.md:33-53,77-86`).
This run therefore recomputes identity-map references on this exact population under the
sealed definitions below. It never tests a span result against `.621` or `.568`.

## Hypothesis

H1: per-stratum Platt or isotonic calibration produces a more useful probability scale
than the identity map in the extreme high-confidence region. At 1% selective risk it
will increase held-out jargon-positive span coverage without putting any hard-negative
repair span on the unsupported-activation side of the conformal decision.

H0: neither calibrated map produces the declared coverage gain over identity, its
accepted spans exceed 1% empirical risk, or at least one hard-negative repair span is
activated. A result under H0 kills calibration as a decision layer; raw confidence may
remain a diagnostic feature for `acoustic-glossary-verifier`.

## Data (immutable inputs; sha256)

All paths are relative to `/Users/vlad/Desktop/voiceoour` and are read-only during the run.

- `.build/asr-research/three-bets/margins/jargon456.lattice.jsonl` — 456 rows and
  13,097 lattice steps; `64980e8027867e17798800d947c446a673da7d1e3f4440b13ed098efad48cd25`.
- `.build/asr-research/three-bets/margins/general96.lattice.jsonl` — 96 rows and
  10,269 steps; `a82adf5b5884370af25a7f3ed5ef18496498c426d31f33a4d2152904b5cf6411`.
  The counts were independently replayed in Wave 0
  (`.build/asr-research/next/precision-recall/confidence-calibration/wave0/verdict.md:9-17`).
- `.build/asr-research/next/precision-recall/confidence-calibration/wave0/rows.jsonl` —
  552 row joins; `60822a3df228aeeca088641f9e145a8251ccdf0658d2705d9478e3ab705f99ba`.
- `.build/asr-research/next/precision-recall/confidence-calibration/wave0/calibration-screen.json`
  — frozen Wave 0 reference tables; `213bd88dc162259eb5d0955479714698a8b62550bba88a0352bb19b504601b69`.
- `.build/asr-research/next/precision-recall/confidence-calibration/wave0/calibration_screen.py`
  — posterior, word grouping, alignment, and Wave 0 metric semantics;
  `e7f202b9f53e45ba5db20074241a33b074bf3939e5dc365842b954314358d546`.
- `bench/autoresearch/jargon.terms.json` — 346 annotated positive rows and 110
  hard-negative rows; `2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5`.
- `bench/autoresearch/corpus.manifest.jsonl` — the 96 general-row identities, sources,
  references, and audio digests; `885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749`.
- `bench/autoresearch/replay_repair.py` — frozen `Vocabulary`, span scoring,
  `_resolve_longest`, and repair-event offsets; `b2a4360046ee614af4ef81f8bc323e1311cba11b2db41c6cbd0a3c734c7f6767`.
- `bench/src/voiceour_bench/metrics.py` — alignment and shared metric semantics;
  `307eb4f113bda8e72faa513fce4885befde425ed7a80036deab6354e8a50a539`.
- `bench/src/voiceour_bench/normalizer.py` — English normalizer;
  `f46d632b7a6e73829ccd5b35b3b23b1f290a086cc0b563bbdf2ebad52ec1a182`.

Wave 0 observed 9,813 labelled words, 346 positive term joins (161 exact canonical
surfaces present), and 110 negative rows with zero unsupported surface
(`.build/asr-research/next/precision-recall/confidence-calibration/wave0/verdict.md:33-43,55-60`). Those are input-fidelity expectations, not Wave 1 results.
A count or digest mismatch stops before fitting and produces no scientific verdict.

## Decision units and labels (fixed)

The unit is a span, never a token and never an arbitrary whole word except in `general96`.
Every unit has `(row_id, stratum, start, end, surface, label)`; all character offsets are
half-open offsets into the cached lattice `transcript` before any repair.

- **`jargon-positive`**: exactly one unit for every row whose term annotation has a
  `canonical`. If that canonical occurs with the replay's case-sensitive boundaries, use
  its earliest exact occurrence. Otherwise project the canonical's reference-word interval
  through the repository jiwer alignment and take the smallest contiguous hypothesis-word
  interval touched by the intersecting equal/substitution chunks. A deletion-only interval
  takes the following hypothesis word, or the preceding word at end of transcript. A
  transcript with no normalized word gets `(0, 0)`, score `0`, and label `0`. Label `1`
  iff the selected raw surface equals the annotated canonical case-sensitively; otherwise `0`.
- **`jargon-negative`**: construct `Vocabulary` from the 173 positive canonicals
  (`.build/asr-research/next/precision-recall/confidence-calibration/wave0/verdict.md:55-60`) and run its frozen `phonetic` repair on the raw transcript at
  theta `0.60`, the replay's fixed minimum. Every emitted non-overlapping repair event is
  one unit at its original `(start, end)`; a row with no event has no span unit but remains
  in the 110-row safety denominator.
  A multiword unit is label `1` only when every normalized hypothesis token in it aligns
  to an identical reference token and no reference deletion falls inside the aligned interval;
  otherwise `0`.
- **`librispeech`** and **`fleurs`**: every normalized reconstructed word span is one unit.
  The former contains manifest sources `librispeech-clean` and `librispeech-other`; the
  latter contains `fleurs-en-us`. Label a unit by the exact Wave 0 rule: all normalized
  tokens it owns must align to identical reference tokens
  (`.build/asr-research/next/precision-recall/confidence-calibration/wave0/calibration_screen.py:79-135`).

No repaired or normalized text is used as a reference label. All units from one row stay
together in every split. Duplicate `(row_id,start,end)` events are collapsed, keeping the
repair event with highest phonetic score, then lexicographically smallest canonical.

## Raw score and same-population reference (fixed)

For each nonblank lattice step, compute the chosen-token point posterior by softmax over
its cached top-8 logits exactly as `.build/asr-research/next/precision-recall/confidence-calibration/wave0/calibration_screen.py:64-76`. Also compute that
function's 8,193-class worst-case lower posterior. The raw span score `q` is the minimum
point posterior over the nonblank pieces intersecting the span; the lower score is the
minimum lower posterior over the same pieces. Zero-length spans have both scores `0`.
The decision uses `q`; `q - q_lower` is reported as reconstruction slack. Wave 0 found
that top-8 slack was large (median `.015311`, p95 `.501058`), so the point score is an
explicit cached-evidence approximation, not Voiceour's product `p`
(`.build/asr-research/next/precision-recall/confidence-calibration/wave0/verdict.md:62-69,124-129`).

Before fitting, recompute the **uncalibrated reference** with the identity map on all units:
selective risk/coverage, the secondary metrics below, counts, and thresholds separately
for all four strata. Separately recompute row-level identity ECE for the 64 LibriSpeech
and 32 FLEURS rows from mean emitted-token point posterior versus normalized row exact
match, using 10 equal-mass bins. Row and span references are never pooled or compared.
These newly emitted harvest-population references replace `.621`/`.568` for this family.

## Calibration maps (the whole selection budget)

Fit each stratum independently. No cross-stratum pooling, feature addition, ensemble,
hyper-parameter search, or post-freeze retry is allowed.

1. **M0 identity**: `p(q) = q`; no fit.
2. **M1 Platt**: clip `q` to `[1e-6, 1-1e-6]`, take its logit, and standardize with the
   training-half mean and population standard deviation (floor `1e-12`). Fit
   `sigmoid(a*x+b)` by numpy Newton updates to mean binary cross-entropy plus
   `1e-6 * (a*a+b*b) / 2`. Initialize `(a,b)=(1,0)`; run at most 100 iterations;
   stop when the infinity norm of the update is below `1e-10`; use at most 30 deterministic
   step halvings to obtain a non-increasing objective. Non-finite or non-convergent fit
   stops the run as an implementation defect; there is no fallback.
3. **M2 isotonic**: sort training pairs by `(q,row_id,start,end)`, collapse equal `q` with
   unit weight per span, then run weighted pool-adjacent-violators until block means are
   nondecreasing. At inference, use the first block whose maximum `q` is at least the input;
   clamp below/above the fitted range to the endpoint block. No smoothing or interpolation.

## Splits, thresholds, and primary endpoint (fixed)

Use `numpy.random.default_rng(20260830)` once. For each of 200 repeats and each stratum,
permute sorted row IDs; the first half is training/calibration and the second half is test.
The four row counts are even, so the halves are exact. Fit maps and choose every threshold
on the first half only; apply them unchanged to every unit in the test rows.

For declared coverage targets `C = {0.50, 0.65, 0.80}`, set each per-stratum threshold
to the training score at descending rank `ceil(C*n)` and accept all ties; also report
`C = 0.90` for `jargon-negative`. Separately, the risk-constrained operating point is the
unique training-score threshold with maximum coverage among thresholds whose cumulative
training risk is at most `.01`; ties choose the higher threshold. Apply every threshold
unchanged to test. Accepted means trusted correct (`p >= threshold`); selective risk is
accepted errors / accepted spans, coverage is accepted / all spans, and an empty set fails.

The **primary endpoint** is the held-out selective-risk vector for every
`(map, stratum, C)` above, aggregated across the 200 test halves by summing accepted errors
and accepted spans. Threshold, test coverage, and test risk distributions across repeats
are all reported; no pooled four-stratum primary is permitted.

## Split-conformal diagnostic (fixed)

For each fitted map and split, set `p_1=p` and `p_0=1-p`. On the training/calibration
half, the true-label nonconformity is `A_i = 1 - p_{y_i}`. At alpha `.01`, let
`k = min(n, ceil((n+1)*(1-alpha)))` and `qhat` be the kth sorted `A_i`. For each test unit,
form the binary conformal set from labels whose `1-p_y <= qhat`; accept as correct only
for the singleton set `{1}`, classify `{0}` as incorrect, and abstain on `{0,1}` or empty.
Report the 200-value distribution of `qhat` (min, p05, median, p95, max), singleton-correct
coverage, and empirical singleton-correct selective risk on the test half.

A negative repair event whose set is `{0}` is an **unsupported activation** for this pilot,
because calibration alone would have declared its ordinary span wrong strongly enough to
hand the taught-term candidate forward. Count a negative row once if any event activates;
rows without events remain in the denominator. The script changes no text.

This is a repeated cached development split. Because the same first half estimates the
map and its nonconformity quantile, the conformal outputs are diagnostics, not a fresh-set
coverage guarantee; formal split-conformal validation needs a separately sealed fit,
calibration, and test population.

## Secondary endpoints and uncertainty

- `ece`: within each stratum's highest raw-`q` decile, selected by the training-half raw
  90th-percentile cutoff and applied to test, sort test units by `(p,row_id,start,end)` and
  divide them into 10 equal-mass bins whose sizes differ by at most one. ECE is the
  count-weighted absolute gap between mean `p` and label mean. This replaces equal-width
  deciles, which put 8,762/9,813 Wave 0 words in one bin (`.build/asr-research/next/precision-recall/confidence-calibration/wave0/verdict.md:110-118`).
- `brier_score`: mean `(p-label)^2` over all test span units, per stratum.
- `span_auroc`: Mann-Whitney AUROC of `p` for span correctness, with mid-ranks for ties.
- Report reliability-bin counts, the complete risk-coverage curve, raw/lower-score slack,
  and row counts. Secondaries are never promoted to primary.

All intervals use percentile bootstrap with `B=10,000` and seed `20260830`. Resample
**rows within stratum**, retaining all their spans and all repeat-level test appearances;
for repeated-split comparisons first average each row's contributions over repeats in
which it was test. Rows are the unit because 9,813 Wave 0 words came from only 552 rows
and their errors cluster (`.build/asr-research/next/precision-recall/confidence-calibration/wave0/verdict.md:121-123`). Report two-sided 95% intervals.

Every claimed Platt/identity or isotonic/identity improvement also gets a paired row-level
Monte Carlo sign-flip permutation test with 10,000 permutations and seed `20260830`.
Holm-correct the two map comparisons at familywise alpha `.05`. For any observed zero
unsupported-activation count, report the one-sided 95% exact Clopper-Pearson upper bound
on the **negative-row** rate; for `0/n` this is `1 - .05^(1/n)`. Repeated appearances are
never treated as independent binomial trials.

## Meaningful effect and kill rule

A meaningful effect requires at least one of M1/M2 to satisfy all of:

1. at the risk-constrained operating point, aggregated held-out `jargon-positive`
   coverage is at least `0.05` absolute above M0 while held-out risk is at most `.01`;
2. the row-bootstrap 95% interval for that paired coverage difference excludes `0`, and
   the Holm-adjusted paired permutation result rejects at `.05`;
3. its fixed-coverage `jargon-positive` risk at `C=.65` is at most `.01`; and
4. hard-negative unsupported activations are exactly `0` rows and
   `unsupported_activations_per_1k = 0`.

Kill the track if neither calibrated map meets that complete effect, if any hard-negative
row activates under the otherwise qualifying map, if any conformal threshold is non-finite,
or if all three maps have undefined singleton-correct risk in any stratum. A failed pilot
stops the track; results cannot be used to tune another threshold on these rows.

## What this pilot cannot show

The jargon audio is synthetic TTS, general96 contains no spoken target terms, the score
renormalizes truncated top-8 logits rather than reading product `p`, and 200 splits reuse
one cached development population. Passing shows only that a stable span-level calibration
signal exists and yields frozen thresholds for `acoustic-glossary-verifier`. It does not
show real-speaker recall, fresh-audio false-activation rate, formal conformal coverage,
latency, product accuracy, or product-facing safety. The pilot changes neither Voiceour
text nor wire confidence and ships nothing.

## Execution and artifacts

This is cached, CPU-only, read-only computation over the inputs. There is no decode,
download, model load, GPU/ANE action, harness invocation, build, or test. Any later decode,
GPU/ANE, or harness action is `parent-serialized, exclusive hardware`; none is part of
this Wave 1 command.

Run exactly once from the primary checkout after the runner has frozen the verbatim script:

```bash
cd /Users/vlad/Desktop/voiceoour && PYTHONPATH=bench/src bench/.venv/bin/python .build/asr-research/next/precision-recall/confidence-calibration/wave1/run1/calibration_pilot.py > .build/asr-research/next/precision-recall/confidence-calibration/wave1/run1/stdout.txt 2>&1
```

Under `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/precision-recall/confidence-calibration/wave1/`,
write `prereg.md` (this file plus freeze commit) and `verdict.md`. Under `run1/`, write
`command.txt`, `manifest.json` (all repository-contract pin/environment keys, every digest
above, seed, split count, family, and prereg commit), `metrics.jsonl`, `rows.jsonl`,
`spans.jsonl`, `splits.jsonl`, `uncalibrated-reference.json`, `thresholds.json`,
`calibration_pilot.py`, and `stdout.txt`. `metrics.jsonl` uses the contract record schema;
map/stratum/coverage-qualified track-local identifiers are declared as
`selective_risk__<map>__<stratum>__c<percent>`, `calibration_coverage__...`,
`conformal_risk__...`, `brier_score__...`, and `span_auroc__...`.

## Stop rule

One run means the 200 sealed splits above, not 200 tuning attempts. No threshold, map,
label, span, or target changes after output is inspected. A digest/count mismatch or script
crash produces no result. A mechanical defect may be corrected only under a new freeze
commit and new family identifier; a completed run that misses the meaningful effect or
hits any kill clause closes the track as diagnostic-only.
