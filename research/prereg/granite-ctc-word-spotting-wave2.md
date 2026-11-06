# Preregistration — Granite CTC word spotting, wave 2 (fresh-data confirmation)

Written on 2026-11-06 after wave 1 (`research/granite-ctc-word-spotting-2026-11-06.md`) and before any wave 2
data existed. The commit adding this file is the freeze: no endpoint, input rule, operating point or bar
below may change after it. Code: `e337e1d40383d181d2a85b929928de269f0679e3` (spotter, both rendering rules,
heard-as variants). Data and analysis: `research/prereg/tools/granite_ctc_spotting_wave2_data.py` and
`granite_ctc_spotting_wave2_analysis.py`, frozen in the same commit.

## Question

Wave 1 measured +21 cross-fitted hits (bar 24) with no false activation anywhere on its grid. Does one
operating point, fixed by wave 1's own rule before any wave 2 data exists, reproduce at least a quarter fewer
misses on fresh synthetic voices, with no unsupported term and no damaged row on fresh real speech?

## Operating point, frozen

`(total 6, perToken 1.5, ordinaryScale 1)`: wave 1's shipping rule, the componentwise minimum of its two
folds' selections. Everything else is wave 1's definitions (`research/prereg/granite-ctc-word-spotting.md`),
with the two rendering rules recorded in wave 1's result: a covered word with a letter- or digit-bearing
token entirely outside the window makes a spot unrenderable, and a span already holding any target's exact
canonical is left alone. Same model, context settings, glossary (the 173 repair-vocabulary canonicals, 141
of them targets), text stage and grid encoding.

## Fresh data, generated after this freeze

- **Positives (282).** Each of the 141 targets, in target order `i`, in two sentences: templates
  `(i mod 8)` and `(i + 3) mod 8` of the eight in the data script, spoken by voices `(2i + slot) mod 4` of
  Daniel, Karen, Moira and Rishi, none of which produced wave 1's audio. macOS `say` writes each sentence to
  a file (no playback) and `afconvert` makes it 16 kHz mono 16-bit. The reference is the sentence.
- **Hard negatives (120).** The data script's 60 ordinary sentences, most built on sound-alikes of targets
  (`cave`/CVE, `quick`/QUIC, `view`/Vue, `cider`/CIDR, `launched`/launchd, `I am`/IAM, …), each spoken by
  voices `j mod 4` and `(j + 2) mod 4`.
- **Real speech.** The `test` splits of `hf-audio/open-asr-leaderboard` `tedlium`, `voxpopuli` and
  `earnings22` in full and the first 2,000 rows of `gigaspeech`, none used in wave 1.
- **Non-speech.** Wave 1's 23 clips, re-run with this code.

## Measures

As wave 1 over the positives: hits `H0` (M0) and `H1` (M1 at the frozen point), gain `G = H1 − H0`, lost hits
`L`; false activations `F` over every row of all four sets. New: **damage** `D`, rows whose M1 text differs
from M0's and whose U-WER against the reference rises.

## Bars

- **PASS**: `F = 0`, `L = 0`, `D = 0` and `G ≥ max(10, ⌈0.25·(282 − H0)⌉)`.
- **KILL**: `F > 0`, `L > 0`, `D > 1`, or `G < max(5, ⌈0.10·(282 − H0)⌉)`.
- **INCONCLUSIVE** otherwise. Only PASS justifies productizing, at this operating point.

## Exploratory, not gating

- The same measures at `(8, 1.5, 1)`, wave 1's full-data best.
- **Teach once.** A heard-as form per wave 1 baseline miss, derived by the data script from wave 1's M0 text
  (the hypothesis words aligned to the term), as a user would teach it from History; the spotter reads the
  glossary in the app's import shape, so the text stage repairs exact heard-as forms and the spotter searches
  them as variants. Hits, `F` and `D` for the taught baseline and for spotting at both points, on the same
  four sets.
- Hits per voice, false activations per set and per real-speech corpus, spotting time.

## Limits stated in advance

Positives remain macOS text-to-speech. A different voice and sentence frame test generalization beyond wave 1's
recordings, not real dictation. Real speech bounds false activations only for these corpora and this glossary.
