# Preregistration — Granite CTC word spotting for taught terms

Written on 2026-11-06 before any spotter output existed. The commit adding this file is the
freeze. No endpoint, input, split, rule, grid value or bar below may change after it; a change
is a new preregistration. Repository state at writing: `5e02d99d7345916aa753c240809334c6e3b0fd7e`.

## Question

Granite is a pure CTC model: every utterance leaves a frame-by-vocabulary matrix of CTC logits
behind on the host. Can a word spotter over that matrix, looking only for the user's own glossary
terms, render taught terms that greedy decoding and the shipped text stages miss — without a
single unsupported term on real speech?

The archived exploration (`docs/archive/keyword-comprehension-exploration.md`) found CTC word
spotting blocked on Parakeet because that checkpoint had no CTC head. Every Parakeet route to
higher term recall was closed at Wave 1 (`research/wave1-2026-09-02.md`); the binding failure
was false acceptance on ordinary real speech. This pilot asks whether Granite's own posteriors
avoid that failure.

## Hypotheses

- H1: at some operating point the spotter adds exact-canonical hits on the synthetic jargon set
  with zero unsupported activations on 17.9 hours of real speech, the non-speech controls and the
  synthetic hard negatives, and loses no hit the baseline makes.
- H0: every operating point that gains hits also activates on a control row or loses a hit.

## Immutable inputs (sha256)

- Model: `vladers/granite-speech-5.0-470m-turboctc-GGUF` @ `bd7db273aa69a26fc81e370c84597fa738fe2ad0`,
  `granite-speech-5.0-470m-turboctc-Q8_0.gguf` — `fc34cbe71f979a6aeb8bea08bfac88d5c62c1736c0bc845827e37c90f28e336c`.
  Production context settings: Metal, 6 threads, mapped weights (`GraniteContext` defaults).
- Tokenizer reference: IBM `tokenizer.json` at `1dd23f46` — `a1c3ca763ce0690faf0df3456365358547acfdf766122c9e4a69be8e8708042e`.
  Its vocabulary and 20,731 merges equal the GGUF's `tokenizer.ggml.tokens` and `tokenizer.ggml.merges` (checked).
- Terms: `bench/autoresearch/jargon.terms.json` — `2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5`
  (456 rows: 346 positives over 173 canonicals, 110 negatives).
- Glossary: `bench/autoresearch/repair.vocabulary.json` — `650dfc3fa02ebc7e2e8754066f0f9d4336d5113444154e1a27975139812fd1c8`
  (141 `surfaces` + 32 `protected_surfaces` = the 173 canonicals).
- Ordinary words: `Sources/VoiceCore/Resources/ordinary-words.txt` — `77d73723bd06ae5b848d8c7fc66347fb4347719a74fa35e531a0ff1c8e3e7ea9`.
- Manifests, restored from the 2026-11-03 evidence archive with audio paths rewritten to this
  checkout; every row's audio SHA-256 verified on restore:
  - synthetic jargon + tech terms, 472 rows — `42aa11af4365f10df62d366b878c792e3aae587c07b6233a9eb4687dd006f78f`
  - confirmation (AMI IHM, LibriSpeech clean/other, FLEURS en-US; 17,858 rows, 17.89 h) — `3fe546ab60bd4defde1f5771d72ec0660b84426a9650adeb13b1b0e6418f8035`
  - non-speech, 23 rows — `2d6a52e3ccfb5df4f8a4a812d91147b65a6ad1b67aaecdbb438aeda0dd90aab4`

## Arms

Both arms decode every row once with the production Granite context and run the app's text stage
in the app's order: `LiteralComposition.apply`, then `CleanupEngine.clean(_, glossary:)`, then the
strict `VocabularyRepairEngine` built by `RepairVocabulary.fromActiveTerms(_, ordinaryWords:
bundledOrdinaryWords)`. The active terms are one `ProtectedTerm(canonical:)` per glossary
canonical in file order, no aliases, default case policy, cleanup enabled. Deviation from the app,
on purpose: all 173 terms are active at once, past the app's 100-term snapshot cap, which can only
raise false activations.

- **M0** — baseline: the text stage over the greedy transcript.
- **M1** — spotter: accepted detections are rendered into the greedy words first; the same text
  stage then runs over the result.

## Definitions

**Targets.** A canonical is a spotting target iff `RepairVocabulary.fromActiveTerms` makes it an
eligible repair surface (not an ordinary word after lowercasing, more than two characters). Every
other canonical is protected: never a target, and a span holding one of its whole-word occurrences
(case-insensitive) is never replaced.

**Variants.** For target `c`: `c`; `c` with its first scalar uppercased; `c` lowercased; each
`Glossary.derivedAliases(for: c)` entry and that entry with its first scalar uppercased. Each
variant is encoded with Voiceour's BPE encoder; identical id sequences are kept once.

**Scores.** For frame-major logits `Z[t][v]`, `A[t][v] = Z[t][v] − max_u Z[t][u]` (≤ 0; the
log-softmax normalizer cancels). For a variant `y` of `K` tokens the spotter runs CTC Viterbi over
the label states with blanks between labels: free start at any frame (score 0 before entering the
first label), the standard stay/advance moves, the blank skip only between differing labels, and
an end at the last label. `S(t)` is the best path score ending at frame `t`; its window runs from
that path's first label frame to `t`. Ties take the later start. `S ≤ 0`, and `S = 0` exactly when
the greedy path itself spells `y` over the window. Candidates need `S ≥ −12` and `S/K ≥ −3`.
Within one term (all its variants) candidates are suppressed by score, then shorter window, then
lower variant index: a candidate is kept unless its window shares a frame with a kept one.

**Rendering.** A greedy word is covered by a window when at least half of its tokens' CTC-run
frames lie inside it. A detection renders only if it covers one or more contiguous words; others
(including pure insertions) are recorded as unrenderable. The covered words are replaced by the
canonical verbatim. A leading run of `( [ { " ' « “ ‘ ¿ ¡` on the first covered word and a trailing
run of `. , ; : ! ? … ) ] } " ' » ” ’` on the last are kept around it.

**Policy.** Operating point `(a, b, r)`. A detection is accepted iff `S ≥ −a·m` and `S/K ≥ −b·m`,
where `m = r` when every covered word is ordinary and `m = 1` otherwise. A covered word is ordinary
when its letters, lowercased and stripped of the punctuation above, form an ordinary word or are
`a` or `i`; words with digits are not ordinary. A detection whose covered words contain a protected
canonical, or a different target's exact canonical, is rejected. Accepted detections are then
suppressed across terms by `S`, then larger `K`, then lower term index, over covered-word ranges,
and applied right to left.

Grid, 288 points: `a ∈ {0.25, 0.5, 1, 1.5, 2, 3, 4, 6, 8}`, `b ∈ {0.05, 0.1, 0.2, 0.3, 0.5, 0.75,
1, 1.5}`, `r ∈ {0, 0.25, 0.5, 1}`.

## Measures

- **Hit**: `contains_exact_term(final_text, canonical)` (`bench/src/voiceour_bench/metrics.py`),
  case-sensitive, over the 346 jargon positives. `H0`, `H1` = hits of M0, M1.
- **Gain** `G = H1 − H0`. **Lost hit**: a positive M0 hits and M1 misses; `L` counts them.
- **False activation**: a row whose M1 final text contains a target canonical exactly, while the
  M0 final text does not contain it exactly and the casefolded reference does not contain it
  casefolded. Counted over every row of every manifest, positives included (a wrong term on a
  positive row counts). `F` counts rows.

## Folds and selection

`fold(key)` = first byte of SHA-256 of the UTF-8 key, mod 2. Keys: jargon positive
`term:<canonical>`; jargon negative and tech-term row `row:<id>`; confirmation AMI and LibriSpeech
`spk:<corpus>:<speaker_id>`; FLEURS `sent:<sentence_id>`; non-speech `row:<id>`.

For each fold the selected point maximizes that fold's hits subject to that fold's `F = 0` and
`L = 0`; ties take the smallest `a`, then `b`, then `r`. With no such point gaining a hit the fold
selects no spotting. Each selected point is evaluated on the other fold; cross-fitted `G`, `F`,
`L` sum the two held-out halves.

## Bars

- **PASS**: cross-fitted `F = 0`, `L = 0` and `G ≥ max(10, ⌈0.25·(346 − H0)⌉)`.
- **KILL**: cross-fitted `F > 0` or `L > 0`, or `G < max(5, ⌈0.10·(346 − H0)⌉)`.
- **INCONCLUSIVE** otherwise. Only PASS justifies productizing.

On PASS the shipping point is the componentwise minimum of the two selected points; it must also
show `F = 0` and `L = 0` over all rows, or the result is KILL. Its full-data `G` is reported.

## Identity controls

The run is invalid, and repeated after a fix, unless all hold:

- **I1** tokenizer: Voiceour's encoder equals the reference tokenizer, token for token, on every
  variant string and every reference sentence of the three manifests.
- **I2** decode: the spotting command's greedy text equals `voiceour-bench pipeline --backend
  granite` `raw_transcript` on the 472 synthetic rows, the 23 non-speech rows and the first 1,000
  confirmation rows.
- **I3** words: words joined by single spaces equal the greedy text on every row. Rows that fail are
  not spotted (M1 = M0) and counted; more than 0.1% of rows invalidates the run.
- **I4** determinism: a second pass over the 472 synthetic rows gives identical greedy text and
  detection windows; the largest `|ΔS|` is reported.

## Exploratory, not gating

The 16 tech-term rows (11 positives, 5 hard negatives); hits per domain; unrenderable detections;
spotting time per row; false activations on the confirmation rows with only the seven bundled
default terms as the glossary at the shipping point; special tokens the model emits, per corpus
(language tags in particular).

## Limits stated in advance

The positives are macOS text-to-speech, not human dictation: recall measured here may not carry
over to real speakers. Safety is measured on real speech. Zero activations over the 17,996
control and negative rows bounds the per-utterance rate below about 1 in 6,000 (one-sided 95%,
rule of three) for this 173-term glossary on these corpora, not in general.
