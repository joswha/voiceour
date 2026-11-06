# Granite CTC word spotting — wave 1 result, 2026-11-06

Preregistration `research/prereg/granite-ctc-word-spotting.md`, frozen at `645bbd7`. Run on one Apple M4
Pro, macOS 27.0.1, release build, production `GraniteContext` (Metal, 6 threads, mapped weights), Granite
`vladers/granite-speech-5.0-470m-turboctc-GGUF` @ `bd7db273` Q8_0. Tooling: `voiceour-bench granite-spot`
and `granite-tokenize`; analysis `research/prereg/tools/granite_ctc_spotting_analysis.py`.

## Verdict: INCONCLUSIVE

| measure | value |
| --- | ---: |
| jargon positives | 346 |
| baseline hits `H0` (greedy + the app's text stage, 173 terms active) | 253 |
| misses | 93 |
| cross-fitted hits | 274 |
| cross-fitted gain `G` (fold 0's point on fold 1 + fold 1's on fold 0) | +21 (+10, +11) |
| cross-fitted lost hits `L` | 0 |
| cross-fitted false activations `F`, over all 18,353 rows | 0 |
| PASS gain bar, `max(10, ⌈0.25·93⌉)` | 24 |
| KILL gain bar, `max(5, ⌈0.10·93⌉)` | 10 |

Fold 0 selected `(total 8, perToken 1.5, ordinaryScale 1)`, fold 1 `(6, 1.5, 1)`. Both are at the grid's most
permissive per-token and ordinary-scale values, and fold 0 at its most permissive total. By the frozen rule
only PASS justifies productizing, so nothing ships from this wave.

## Identity controls: all hold

- **I1** tokenizer: Voiceour's `GraniteBPEEncoder` equals IBM's `tokenizer.json` on all 18,800 strings (every
  reference sentence of the three manifests, all 438 variant strings, nine edge cases) and on every one of the
  194,559 scalars of planes 0–2 encoded alone. Getting there took the reference character map's exact
  exceptions to NFKC: 30 deleted controls, 13 scalars turned into spaces, and 162 scalars whose NFKC mapping
  postdates the map.
- **I2** decode: in-process greedy text equals `voiceour-bench pipeline --backend granite` (the sidecar) on
  all 1,495 compared rows.
- **I3** words: words joined by single spaces equal the greedy text on all 18,353 rows.
- **I4** determinism: a second pass over the 472 synthetic rows gave identical text and windows; the largest
  score difference was 0.0.

## Exploratory findings, not gating

- **No point on the grid ever activated falsely.** All 288 operating points have `F = 0` and `L = 0` over the
  full data. The full-data best is +23 at `(8, 1.5, 1)`. The grid stopped short of the safety boundary
  rather than at it.
- **Separation.** Over the 17,996 control and negative rows the spotter produced five candidates for a term the
  reference lacks, the strongest at −1.59 nats per token (`cave` → `CVE`, LibriSpeech), then `Run` → `runc`
  (−1.66), `c they` → `CVE` (−1.87), `runs` → `runc` (−2.39), `statuments.` → `Instruments` (−2.69). The
  grid's loosest per-token threshold, −1.5, sits just inside the first of them.
- **Reach.** Of the 93 misses, 59 have no candidate above the floors at all: the audio never comes near the
  term's spelling under Granite's posteriors. 24 have a candidate inside the grid's loosest corner and 10
  between −1.5 and −3 nats per token.
- **A rendering defect.** Of the 25 rows changed at `(8, 1.5, 1)`, 24 got strictly better (U-WER) and one got
  worse: `CSRF-protected actions` became `CSRF actions`, because the spot covered most of a hyphenated word and
  whole-word replacement dropped `-protected`. Neither preregistered measure counts it (the term was already
  present). Two rendering rules now refuse it: a covered word with a letter- or digit-bearing token entirely
  outside the window makes the spot unrenderable, and a span already holding any target's exact canonical is
  left alone. With them, the 472 synthetic rows give +22 at `(8, 1.5, 1)` and +20 at `(6, 1.5, 1)`, and every
  changed row is strictly better.
- **Cost.** Spotting 438 patterns (141 targets) takes 0.54 ms per utterance at the median, 2.0 ms at p95,
  beside a ~40 ms decode.
- **Tech terms.** 7 → 8 of 11 positives; no activation on the 5 hard negatives.
- **Language tags.** Granite emitted no special token but `<|nospeech|>` (22 non-speech clips, 3 AMI clips):
  the vocabulary's language tags are never produced, so they cannot identify a language.
- **Real-speech U-WER** at the exploration point equals the baseline, 6.2125%.
- **Baseline caveat.** M0 ran the text stage as frozen, whose glossary canonicalization then recased
  ordinary-word terms in prose (`go` → `Go`); `11a9fcc` since fixed that. The spotting measures compare M1 with
  M0 under the same stage and are unaffected.

## Decision

The spotter is safe on everything measured and cheap, but its preregistered gain fell three hits short of the
bar, and its reach is bounded by the 59 misses without a candidate. Wave 2 (`research/prereg/
granite-ctc-word-spotting-wave2.md`) tests one frozen operating point, with the two rendering rules, on fresh
synthetic voices and fresh real speech.
