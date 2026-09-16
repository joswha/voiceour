# Preregistration — contrastive-homophone-training, Wave 1 (measured-pair pilot)

Track `contrastive-homophone-training` (A-tier, workstream `data-foundation`). Frontier
of record `0ac7514`; contract `research/next-program.md`. Written before the measured
surface extractor is run. The commit that adds this file is the freeze; the run records
that commit in `wave1/run1/manifest.json`. Changing an endpoint, denominator, alignment,
matching rule, score, or bar after that commit requires a new preregistration under a new
family identifier.

## Question

Can a deterministic alignment of the 185 frozen baseline misses recover what the baseline
actually emitted at each canonical span, then join at least 40 of those surfaces to a
distinct, provenanced ordinary-speech row so that later acoustic contrastive work has real
positive/negative labels rather than the hand-written over-fire trigger table?

Wave 0 found 2 trigger-table rows and 110 unpaired ordinary rows
(`wave0/verdict.md:17-28`), but neither row had a distinct negative counterpart id
(`wave0/verdict.md:70-80`). Its 147 denominator counted only positives whose canonical was
casefold-absent from `raw_transcript` (`wave0/verdict.md:23-27`). This pilot instead freezes
all 185 records in `miss-taxonomy.jsonl:1-185`, including case-only and lexical-variant
misses, and never substitutes the old denominator after measurement.

## Hypothesis

H1: reference-to-raw alignment will expose measured substitution surfaces such as
`runc` → “rank”, `CALayer` → “CA layer”, `C++` → “C”, `Redis` → “dispire”, and
`kqueue` → “Quo”/“Ku”, documented in `wave0/verdict.md:54-68`, and at least 40 misses
will have a one-to-one ordinary counterpart across at least three of the six standing
classes present in the frozen taxonomy.

H0: fewer than 40 misses can be paired, or fewer than three present standing classes can
be covered. In that case the cached corpora are not a sufficient pair foundation and the
current pair-mining family stops before training.

The extractor produces offline labels only. It is never a Voiceour shipping component,
recognizer, runtime module, sidecar path, model artifact, or wire-protocol field; that
boundary is fixed by the track record at
`contrastive-homophone-training.md:41-54,231-235`.

## Data (immutable inputs; sha256)

- `.build/asr-research/three-bets/repair/miss-taxonomy.jsonl` — exactly 185 input misses,
  with `id`, `canonical`, category, transcript, `best_span`, and spans where available
  (`:1-185`); `5cd611c7ed712f601537fc9c007d4e9e530c336e55f70a649ff151e632b5291a`
- `.build/autoresearch/jargon.1.results.jsonl` — cached raw transcripts; bench metadata and
  the first joined row are at `:1-2`;
  `003708c001f483323c071ed5100995d6568bb732c89cff2965394e0a6af00f7d`
- `benchmarks/data/jargon/manifest.jsonl` — 456 manifest rows; positive references and
  audio provenance begin at `:1-8`, ordinary `_negative_` rows at `:347-456`;
  `576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf`
- `bench/autoresearch/jargon.terms.json` — the positive-row canonical/domain map
  (`:1-33`); `2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5`
- `.build/asr-research/three-bets/margins/general96.lattice.jsonl` — 96 real-speech
  ordinary rows with stable ids and cached `transcript` fields (`:1-96`);
  `a82adf5b5884370af25a7f3ed5ef18496498c426d31f33a4d2152904b5cf6411`
- `.build/asr-research/next/data-foundation/contrastive-homophone-training/wave0/pair-inventory.json`
  — the frozen two-row prior inventory (`:1-29`), used only to report Wave 0 overlap;
  `69065ed2f0cfb9fe16fca6b8a91669b57385a8f97520579ff6cd2d1724424259`
- `bench/autoresearch/replay_repair.py` — the only scorer; its grapheme and phonetic keys
  are fixed at `:278-314` and its blend at `:317-339`;
  `b2a4360046ee614af4ef81f8bc323e1311cba11b2db41c6cbd0a3c734c7f6767`

The cached result model revision is
`35156454d1a39de06863303dd209fd2bed6ee079` (`wave0/manifest.json:41-45`). No audio is
decoded, no model is loaded, no download occurs, no harness runs, and no GPU or ANE is
used. The run is CPU-only in `bench/.venv` with Python 3.12, `regex`, and `rapidfuzz`.
There is no missing prerequisite.

## Join and population checks (fixed)

Read JSONL in file order, but make every selection below on explicit sorted keys. Join each
taxonomy `id` to manifest `id`, term annotation `id`, and cached result `id + "#j0"`.
Require all 185 joins; require taxonomy canonical = term canonical, taxonomy transcript =
`raw_transcript`, and manifest reference to contain the exact case-sensitive canonical
exactly once. A violated requirement is a script defect, not a silently dropped row.

The population is the 185 taxonomy rows. `candidate_pair_recall` is therefore
`confusable_pair_rows / 185`; it is track-local and is not `jargon_term_recall` or
`real_speaker_recall` (`research/next-program.md:199-244`).

## Measured confusion-surface extraction (fixed)

Token tables are recorded for inspection, but alignment is character-level. For each row:

1. Set `reference` from the manifest and `raw` from cached `raw_transcript`; locate the
   canonical's unique half-open character span `[c0,c1)` in `reference`.
2. Run Python 3.12 `difflib.SequenceMatcher(None, reference.casefold(), raw.casefold(),
   autojunk=False)` and call `get_opcodes()`. This is the deterministic Ratcliff–Obershelp
   (gestalt) sequence matcher; no RapidFuzz search or similarity threshold chooses a span.
3. For every `equal` opcode overlapping `[c0,c1)`, map only the overlapped characters
   one-to-one into the raw side. For every `replace` opcode overlapping the canonical,
   take its complete raw-side interval. A `delete` contributes no raw characters. Include
   an `insert` only when its reference boundary lies strictly inside `(c0,c1)`.
4. If characters were collected, the emitted interval is their minimum raw start through
   maximum raw end, and `emitted_surface` is that raw substring with edge whitespace
   removed. If none were collected, the interval is empty at the preceding opcode boundary
   and `emitted_surface = ""`.
5. Record all opcodes, emitted offsets, taxonomy `best_span`, taxonomy span offsets, and
   whether the extracted interval overlaps the taxonomy span when that span exists.
   `best_span` is diagnostic only and never replaces or expands the aligned surface.

This rule preserves case and symbols in the label. The alignment is run once with no
alternative tokenizer, local window, fuzzy cutoff, manual correction, or post-measurement
exception.

## Ordinary counterparts and labels (fixed)

Define `WORD_RE` exactly as
`regex.compile(r"(?V1)[\p{L}\p{N}_]+(?:['’][\p{L}\p{N}_]+)*")`; words are casefolded.
The emitted word sequence is the ordered `WORD_RE` matches in `emitted_surface`.

Eligible ordinary rows are only:

- jargon manifest ids containing `_negative_`, using their cached `raw_transcript`; or
- all general96 ids, using the lattice `transcript`.

An edge from a miss to an ordinary row exists iff the emitted word sequence is nonempty,
appears contiguously in the ordinary transcript's casefolded word sequence, and the exact
canonical surface is absent under case-insensitive Unicode letter/number/underscore
boundaries. The negative span is the raw character interval of the leftmost matching word
sequence. Jargon negatives sort before general96, then by row id and span start.

Counterpart ids are source-qualified: `jargon:<result-id>` or `general96:<row-id>`. Enforce
a one-to-one assignment: no counterpart id may appear in two retained pairs and it must
differ from the positive id. Compute a deterministic maximum-cardinality bipartite
matching with the standard augmenting-path (Kuhn) algorithm: visit misses by
`(eligible-counterpart-count, positive_id)`, visit each adjacency list in the source/id/span
order above, clear the visited-right set for each outer DFS, and allow recursive
reassignment. No greedy remainder or manual matching is tried.

A retained **confusable pair row** is `(positive_id, canonical, emitted_surface)` plus its
matched ordinary counterpart id and span. `confusable_pair_rows` counts retained rows only.
A miss with no emitted words, no eligible ordinary occurrence, or no unique counterpart
after maximum matching is **counterpart-less**, excluded from the primary and rank
accuracy, and counted in `counterpart_less_rows` with one of those three fixed reasons.
Every one of the 185 misses remains in `rows.jsonl`.

Provenance per retained pair is mandatory: positive and negative ids, source kind, source
record path, whole-input digest, transcript, span offsets, manifest audio path and SHA when
present, taxonomy category, canonical, and emitted surface. Missing provenance invalidates
the run; it does not become a counterpart-less label.

## Standing-class coverage (fixed)

Report misses, extracted surfaces, eligible counterparts, retained pairs, and
counterpart-less rows separately for:

- `IAM` (`miss-taxonomy.jsonl:21-22`)
- `Redis` (`miss-taxonomy.jsonl:162`)
- `runc` (`miss-taxonomy.jsonl:4-5`)
- `CALayer` (`miss-taxonomy.jsonl:142-143`)
- `C++` (`miss-taxonomy.jsonl:87-88`)
- `queue/kqueue`, covered by either canonical (`kqueue` misses at
  `miss-taxonomy.jsonl:127-128`)

These are the six present standing classes. `Credit Swift` is recorded as absent, never
synthesized (`wave0/verdict.md:43-52`). `standing_classes_covered` counts a class only when
at least one retained pair has a distinct counterpart id.

## Scorer and selection budget (fixed)

There is one diagnostic scorer and no learned model:
`replay_repair.py::phonetic_similarity`. For each retained pair compute
`positive_score = phonetic_similarity(emitted_surface, canonical)` and
`negative_score = phonetic_similarity(negative_surface, canonical)`, where
`negative_surface` is exactly the matched ordinary substring. `rank_win = 1` only when
`positive_score > negative_score`; ties fail. `pairwise_rank_accuracy` is mean `rank_win`.

Because containment ordinarily makes the two text surfaces identical after scorer
normalization, ties are expected and are informative: this is the current phonetic-only
floor that a future preregistered acoustic contrastive objective must beat, not a reason to
widen the negative span. Wave 0's proposed `.90` rank bar applies to a future pair-aware
ranker (`contrastive-homophone-training.md:169-173`), not to this baseline diagnostic.

No model, threshold, feature transform, margin, or hyper-parameter is selected. There is no
training/calibration split and no operating point. The whole selection budget is the one
alignment, one maximum matching, and one frozen scorer above; nothing is chosen on these
outcomes.

## Evaluation (fixed)

- **Primary endpoint:** `confusable_pair_rows`, the number of 185 misses receiving a
  one-to-one distinct, provenance-complete ordinary counterpart.
- **Meaningful effect:** `confusable_pair_rows >= 40` and
  `standing_classes_covered >= 3` of the six present classes, with zero duplicate
  counterpart ids and zero provenance failures.
- **Strong effect:** `confusable_pair_rows >= 80` and at least five of six present classes.
- **Kill:** `confusable_pair_rows < 40` **or** `standing_classes_covered < 3`. A valid run
  meeting either condition kills this cached pair-mining family; no contrastive training,
  download, decode, GPU/ANE step, or dependent claim follows.
- **Secondaries, never promoted:** `candidate_pair_recall`, `counterpart_less_rows` and its
  three reasons, `pairwise_rank_accuracy`, mean paired score difference, source counts,
  Wave 0 overlap, taxonomy-category counts, and all per-standing-class counts.
- `critical_syntax_corruption` is structurally not applicable: the extractor writes labels
  and never changes a transcript. No activation threshold exists, so this pilot makes no
  hard-negative activation-rate claim.

## Uncertainty and comparisons (fixed)

Use seed 20260830 everywhere. For `candidate_pair_recall`, percentile-bootstrap the 185
miss rows B = 10,000; the resampling unit is a miss row because the endpoint asks whether a
frozen miss can acquire a unique counterpart. Recompute the maximum matching inside every
bootstrap replicate, with repeated sampled misses assigned synthetic replicate ids so row
multiplicity is preserved.

For `pairwise_rank_accuracy` and mean score difference, percentile-bootstrap retained
pairs B = 10,000. The resampling unit is the complete pair because positive and negative
scores are paired and counterpart ids are unique. Test the claimed positive-versus-negative
score comparison with a two-sided paired sign-flip permutation test, B = 10,000 random sign
vectors: statistic = mean score difference and
`p = (1 + count(|T_perm| >= |T_obs|)) / 10001`. Zero differences remain zero.

For every reported zero-count empirical rate, report the exact one-sided 95% binomial
Clopper–Pearson upper bound `1 - .05**(1/n)` over its declared row or pair denominator.
Counts over the frozen census are also reported exactly. No split is drawn, so repeated
random splits do not apply; no subgroup p-values or post-hoc comparisons are made.

## What this pilot cannot show

The 456-row jargon corpus is synthetic TTS, and general96 supplies real speech only on the
negative side. A pass shows that cached evidence can supply provenance-complete labels; it
does not show that an acoustic objective learns, that ranking generalizes to a human
speaker, or that Voiceour recall, false activations, syntax, latency, memory, or installed
size improve. Fresh promotion evidence still requires the sealed real-speaker corpus and
one-opening rules in `research/next-program.md:315-327`.

## Artifacts

`/Users/vlad/Desktop/voiceoour/.build/asr-research/next/data-foundation/contrastive-homophone-training/wave1/`:
`prereg.md` (copy of this file plus freeze commit), `verdict.md`; `run1/`:
`command.txt`, `manifest.json`, `metrics.jsonl`, `rows.jsonl`, and `extract.py` verbatim.
The waves-1–4 `run1/` layout is fixed by `research/next-program.md:146-167`.

`manifest.json` records all input digests above, Python and package versions, freeze commit,
model revision, required program pin/environment keys, and absent values for every unused
model or binary. `metrics.jsonl` uses run
`contrastive-homophone-training/wave1/1` and contains the primary and named secondaries,
one metric per record. `rows.jsonl` contains all 185 labels, opcodes, spans, counterpart
status, provenance, scores, and class. No `metrics.txt` is produced because this is not a
harness run.

The exact run command is:
`cd /Users/vlad/Desktop/voiceoour && /Users/vlad/Desktop/voiceoour/bench/.venv/bin/python .build/asr-research/next/data-foundation/contrastive-homophone-training/wave1/run1/extract.py`.
It is a cached CPU-only replay. Any future decode, download, GPU/ANE training, or harness
step is **parent-serialized, exclusive hardware** and is forbidden by this pilot.

## Stop rule

One run. No manual relabeling, thresholding, alternate alignment, alternate matching, or
re-ranking against these rows. A crash, failed join/invariant, digest mismatch, duplicate
counterpart, or missing provenance is a script defect: record it, fix only that defect, and
repeat once under `run2/` without changing this contract. A second defect stops the pilot.
A valid run below either kill bar stops the track immediately; a pass licenses only the
next preregistration, never training or shipping by itself.
