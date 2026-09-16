# Preregistration — acoustic-glossary-verifier, Wave 1, arm A (cached-evidence pilot)

Track `acoustic-glossary-verifier` (S-tier, workstream `precision-recall`). Frontier of
record `0ac7514`; contract `research/next-program.md`. Written before any candidate was
scored. The commit that adds this file is the freeze; the run records that commit in
`wave1/run1/manifest.json`. Changing any endpoint, bar, feature list, or split rule after
that commit requires a new preregistration under a new family identifier.

## Question

Does the decoder's own greedy-lattice evidence separate a *true* phonetic repair (a
taught term the model misheard) from a *false* one (an ordinary word that merely sounds
like a taught term) well enough that the phonetic threshold can drop from the shipped
`.95` toward `.70` with zero false activations?

The shipped strict repair reaches 246/346 (`.710983`) at zero false terms. The frozen
term-conditional frontier (`.build/asr-research/three-bets/repair/term-conditional-report.txt`)
shows the headroom that lower thresholds expose and the false terms they create, all of
which fall on ordinary-prose negative rows:

| θ | hits | false terms (all on negatives) |
|---|---|---|
| .95 | 246 | 0 |
| .80 | 279 | 7 |
| .70 | 293 | 33 |
| .60 | 303 | 191 |

A verifier that keeps the true repairs and rejects the false ones would lift recall
without a second model or any new weights: that is Route A of the program.

## Hypothesis

H1: candidate-level features taken from the greedy lattice at the repaired span — token
margin, chosen-token posterior, duration margin, and whether the canonical's pieces appear
among the top-8 alternatives — differ between true and false repairs, because a misheard
term leaves low-margin, low-posterior steps behind while a clearly heard ordinary word does
not. The 2026-09-02 Wave 0 calibration screen supports the premise (word-level AUROC
`.897641` for word errors from min-piece confidence).

H0: the features do not separate the two, or the separation does not survive
leave-one-canonical-out cross-validation.

## Data (immutable inputs; sha256)

- `.build/asr-research/three-bets/margins/jargon456.lattice.jsonl` — 456 rows, 13,097 steps; `64980e8027867e17798800d947c446a673da7d1e3f4440b13ed098efad48cd25`
- `.build/asr-research/three-bets/margins/general96.lattice.jsonl` — 96 real-speech rows (LibriSpeech clean/other, FLEURS), 10,269 steps; `a82adf5b5884370af25a7f3ed5ef18496498c426d31f33a4d2152904b5cf6411`
- `benchmarks/data/jargon/manifest.jsonl` — `576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf`
- `bench/autoresearch/jargon.terms.json` — 173 canonicals, 346 positives, 110 negatives; `2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5`
- `bench/autoresearch/repair.vocabulary.json` — `650dfc3fa02ebc7e2e8754066f0f9d4336d5113444154e1a27975139812fd1c8`
- `bench/autoresearch/replay_repair.py` — the exact candidate generator (`Vocabulary`, `phonetic_similarity`, `_resolve_longest`, boundary semantics); `b2a4360046ee614af4ef81f8bc323e1311cba11b2db41c6cbd0a3c734c7f6767`
- `.build/asr-research/three-bets/repair/miss-taxonomy.jsonl` — 185 baseline misses by category; `5cd611c7ed712f601537fc9c007d4e9e530c336e55f70a649ff151e632b5291a`
- Pinned model file, read only for its tokenizer table (`tokenizer.ggml.tokens` GGUF metadata; no decode): `ggml-parakeet-tdt-0.6b-v3-f16.bin`, `833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f`

No audio is decoded. No model is loaded for inference. No harness run. CPU only.

## Candidate generation (fixed)

For each row of jargon456 and general96, take the lattice `transcript`, apply the same
cleanup the harness applies before repair, and generate phonetic repair candidates with
`replay_repair.py`'s machinery at θ ∈ {.60, .70, .80} against the full repair vocabulary,
exactly as the term-conditional replay did (`_resolve_longest`, exact-alias-first,
ordinary-span and protected-surface guards unchanged). A **candidate** is one accepted
replacement `(row, span, canonical, θ_min)` where θ_min is the lowest threshold in the set
at which it is accepted. Candidates accepted at `.95` are the strict baseline and are
excluded from the verifier's decision (they ship today); the verifier decides only on
candidates with `.60 ≤ score < .95`.

## Labels (fixed)

- **true**: the row is a positive whose annotated canonical equals the candidate's
  canonical and the candidate span overlaps the reference term's position.
- **false**: every candidate on a negative row (jargon456 `_negative_` ids) and every
  candidate on a general96 row; also a candidate on a positive row whose canonical is not
  the row's annotated canonical.
- A positive row's candidate for the right canonical at the wrong span is **false**.

## Features (fixed list; nothing added after the freeze)

Alignment: rebuild the transcript from the lattice's chosen pieces and map candidate
character spans to step indices; span steps = steps whose pieces intersect the span,
extended by one non-blank step on each side.

1. `margin_min` — min `token_margin` over span steps.
2. `margin_mean` — mean `token_margin` over span steps.
3. `post_min` — min softmax posterior of the chosen token over its top-8 logits.
4. `post_mean` — mean of the same.
5. `dur_margin_min` — min `duration_margin` over span steps.
6. `support` — fraction of the canonical's pieces (greedy longest-match over the GGUF
   tokenizer table, deterministic) that appear among `top_tokens` ids at any span step.
7. `support_logit_gap` — for supported pieces, mean (chosen logit − supported piece logit);
   0 when unsupported.
8. `phonetic` — the candidate's phonetic score from `replay_repair.py`.
9. `span_steps` — number of non-blank span steps.
10. `len_ratio` — canonical character length / span character length.

Row-level covariates recorded, not used as features: corpus (jargon/general), category
from `miss-taxonomy.jsonl` where the row is a baseline miss, θ_min.

## Models (fixed)

- **M0, rule**: accept iff `margin_min ≤ τ` and `support > 0`. τ is chosen on training
  folds only (see below).
- **M1, logistic regression** on standardized features 1–10, L2 penalty λ = 1.0,
  numpy gradient descent (lr 0.05, 5,000 iterations, deterministic), seed 20260830 for the
  standardization of nothing random — the model is deterministic; the seed applies to the
  bootstrap only.

No other model, feature transform, or hyper-parameter is tried. Reporting two models is
the whole model-selection budget.

## Evaluation (fixed)

- **Split**: leave-one-canonical-out. All candidates whose canonical is C form the test
  fold for C; general96 candidates are assigned to folds by round-robin over sorted row id
  so every fold has ordinary-speech negatives. A canonical never appears in both sides.
- **Operating point**: on each training fold choose the most permissive threshold
  (τ for M0; probability cut for M1) that yields **zero false accepts on training-fold
  negatives**. Apply it unchanged to the test fold.
- **Primary endpoint**: `recall_hits_verified` = 246 + number of held-out true candidates
  accepted across all folds (a positive counts once). Reported with `false_accepts_heldout`
  = number of held-out false candidates accepted across all folds.
- **Meaningful effect (declared)**: `recall_hits_verified ≥ 262` (≥ +16 over strict) with
  `false_accepts_heldout = 0`, for at least one of M0/M1.
- **Strong effect**: `≥ 279` at zero false accepts (matches θ=.80 recall with its seven
  false terms removed).
- **Kill**: both models < 254, or every zero-false operating point admits ≥ 1 held-out
  false accept. A kill closes arm A; arm B (encoder-state accessor) is then not attempted
  on the grounds that finer evidence from the same decoder is unlikely to beat coarser
  evidence that showed no signal — that inference is recorded as such.
- **Secondaries** (reported, never promoted to primary): candidate-level AUROC for M1
  scores pooled over folds; risk–coverage curve (false-accept rate vs accepted-true
  fraction) with the shipped `.95` point marked; recall by miss category (case-only,
  lexical, near, far/absent); results at each θ_min separately; a "general96-only
  negatives" false-accept count, because those are real speech.
- **Uncertainty**: percentile bootstrap over rows, B = 10,000, seed 20260830, for
  `recall_hits_verified` and for AUROC; Clopper–Pearson 95% upper bound on the false-accept
  rate over all held-out negative candidates. With ~200 negative candidates a zero count
  bounds the rate near 1.5%, which is stated, not hidden.

## What this pilot cannot show

jargon456 is synthetic TTS; general96 is real but term-free. A pass here says the
mechanism exists on cached evidence and licenses a Wave 2 implementation in the sidecar
path under the canonical harness, ≤ 3 runs. It says nothing about real-speaker term
recall, latency, or the fresh-audio false-activation rate at the product's scale.

## Artifacts

`/Users/vlad/Desktop/voiceoour/.build/asr-research/next/precision-recall/acoustic-glossary-verifier/wave1/`:
`prereg.md` (copy of this file + freeze commit), `verdict.md`; `run1/`: `command.txt`,
`manifest.json` (all contract keys plus `screen_inputs` with the digests above and the
prereg commit), `metrics.jsonl` (`recall_hits_verified`, `false_accepts_heldout`,
`false_accepts_general96`, `auroc_m1`, per-θ and per-category counts, all track-local
except `recall_hits`), `rows.jsonl` (one record per candidate: row id, span, canonical,
θ_min, label, features, fold, M0/M1 decision), `candidates.jsonl`, and the script that
produced them, verbatim.

## Stop rule

One run. No re-tuning against these rows. A defect in the script (crash, misaligned
spans detected by the alignment check failing on more than 1% of candidates) is fixed
and the run repeated once, with the defect recorded; a second defect stops the pilot.
