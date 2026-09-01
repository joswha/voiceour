# Bet 1 — Contextual decoding (vocabulary binding at decode time)

Goal: raise `jargon_term_recall` (baseline **.4653**, 161/346) and lower `uwer_jargon`
(**.0609**) without moving `jargon_false_terms` (0), `fwer_negative` (.0073), or
`uwer_general` (.0311). Primary lever on `uwer_mix` (.0460).

## Established facts (verified prior art)

- **Selection cannot fix jargon.** TDT k-best oracle (beam 8, `.build/asr-research/
  tdt-kbest-techterms16-oracle.json`): canonical term recall is 7/11 at every K∈1..8.
  The oracle's own gains are function words. General-corpus oracle headroom: FLEURS
  1.21 pp at K=8 (K=4 captures ~all), LibriSpeech 0.27 pp. → Candidates must be
  **created** (decode-time bias / constrained re-walk), or repaired post hoc.
- **Flat boosting is poison.** Archived: 20k-list bias WER 9.86→11.42; flat phrase-trie
  boost recall unchanged, hard-negative FRR 0→.4, WER +12.5 pp. Bias must be
  confidence-localized and per-term calibrated.
- **Post-correction floor exists.** Prior session's deleted pipeline
  (`.build/autoresearch/jargon.metrics.txt`, 1475 compiled terms, same 456-row corpus):
  term_recall **.7341**, false_jargon 0, jargon_wer .5245→.2527 raw→corrected,
  prose_wer improved (.0410→.0272), correction cost p50 6.5 ms / p95 9.8 ms.
  Case-damage (the "72 re-casings" memory) was invisible to those metrics; this
  session's `fwer_negative` + `jargon_false_terms` close that blind spot.
- Confidence on the wire is uncalibrated (LS ECE .621) but *relative* per-word minima
  may still rank suspect spans; calibration quality for span localization is an open
  question this session must measure.
- Decoder internals: greedy TDT, per-token p/plog/t0/t1 exposed; full logits + token
  callbacks exist unused in the vendored header (`parakeet_full_get_logits`, token
  callbacks) — a seam may need no vendor patch at all.

## Plan

1. **W1-A (seam + harvest)**: research subcommand in `voiceour-bench` (pattern:
   prior `tdt-kbest`) emitting per-decode-step top-K token+duration logits, top-2
   margins, frame indices, chosen path. Harvest general96+jargon456 →
   `.build/asr-research/three-bets/margins/`. Shared with Bet 3.
2. **W1-B (floor)**: offline replay of baseline jargon transcripts through
   lexical/phonetic contextual repair sweeps (thresholded), rescored with the harness
   scorer → recall/FRR/fwer frontier without touching Swift. Quantifies what decode-time
   work must beat.
3. **W1-C (span re-decode)**: cached encoder states + constrained TDT re-walk over
   low-confidence spans with a token-trie over the 173 surfaces; per-term boost λ
   tuned as max-recall s.t. zero false terms on negatives.
4. Gate every candidate through `bash autoresearch.sh` (never trade guards).

## Findings log

- 2026-08-31: baseline domain split — apple 17/68 (worst: casing-heavy identifiers),
  cloud 33/72, security 31/68, dataweb 39/66, langs 41/72. First misses: kubectl,
  kubeadm, runc.

## Decode-loop analysis for span re-decode (2026-08-31, Main)

Read of `Vendor/parakeet/src/parakeet.cpp:3431-3599` (greedy loop) and `:3092-3341`
(`parakeet_step`/batch):

- Frame-sync greedy: each step = one joint(+deferred predictor) graph over
  (encoder frame `t`, predictor state); token argmax over vocab+blank
  (`pstate.logits`, log-softmax), duration argmax over 5 raw slots
  (`duration_logits_raw`, VOICEOUR PATCH). Blank advances t (min 1); non-blank may
  stay (duration 0, max 10 tokens/frame). Margins are directly readable per step.
- **Encoder states persist in `pstate` for the whole utterance** (`batch.i_time`
  selects the frame) → span re-decode needs NO re-encode. The expensive pass-1
  artifact is already cached by construction.
- **`parakeet_step` is n_tokens-batched end to end** (token input tensor, logits
  n_tokens×n_logits, per-token duration slots) — this is what the prior session's
  speculative-batching probe exploited. Caveat: the LSTM predictor state is
  single-hypothesis in `pstate`; a diverging beam needs either per-hypothesis state
  slots (invasive) or serial stepping per hypothesis.
- Cost model: ~160 µs/step (772 ms / 4825 steps, prior measurement). Serial beam-4
  over a 2 s span (~25 frames) ≈ 100–400 steps ≈ 16–64 ms/span. Budget: p95 guard
  300 ms − baseline 209 ms ≈ 90 ms → 1–2 flagged spans per utterance is affordable
  serially; batching buys more.
- Predictor-state seeding for a window re-walk: replay predictor over the committed
  prefix tokens (≤~100 sequential LSTM steps, ms) — no checkpointing patch needed
  for a prototype.
- Any custom search loop needs `pstate` access → lives as an additive vendored
  research API (new file + NOTICE.md entry + `vendor_parakeet.sh --check` expected-set
  update) or a patched export; bench subcommand drives it. Wire protocol untouched.

## Offline post-ASR repair floor (2026-08-31)

CPU-only replay of baseline run 41 `final_text` through the 173-surface vocabulary.
`RECASE` is case-insensitive exact canonical matching; `LEXICAL` adds mechanically
derived case/digit/separator, acronym, symbol, and numeronym aliases; `PHONETIC`
adds deterministic 1–5-word G2P-lite/RapidFuzz matching. Strategies are cumulative,
one-pass, and resolve overlaps deterministically. Safety means `false_terms=0` and
`fwer_negative <= .009282` (baseline `.007282` + `.002`).

| strategy | θ | hits/346 | recall | false terms | FWER negative | U-WER jargon | U-WER mix |
|---|---:|---:|---:|---:|---:|---:|---:|
| **★ BASELINE (best safe)** | — | 161 | .465318 | 0 | .007282 | .060861 | .045995 |
| RECASE | — | 195 | .563584 | 17 | .021036 | .060861 | .045995 |
| LEXICAL | — | 247 | .713873 | 17 | .021036 | .039754 | .035444 |
| PHONETIC | .60 | 322 | .930636 | 252 | .262136 | .249385 | .140238 |
| PHONETIC | .70 | 313 | .904624 | 59 | .065534 | .064959 | .048043 |
| PHONETIC | .75 | 307 | .887283 | 46 | .052589 | .050205 | .040668 |
| PHONETIC | .80 | 297 | .858382 | 24 | .027508 | .032377 | .031756 |
| PHONETIC | .85 | 288 | .832370 | 19 | .023463 | .030533 | .030834 |
| PHONETIC | .90 | 276 | .797688 | 18 | .021845 | .033197 | .032166 |
| PHONETIC | .95 | 261 | .754335 | 17 | .021036 | .035041 | .033087 |

**Safe operating point:** baseline/no repair — recall `.465318`, false terms `0`,
FWER negative `.007282`, U-WER jargon `.060861`, U-WER mix `.045995`. No active
repair point is safe: even exact re-casing changes 17 ordinary meanings (`go`,
`rust`, `swift`, `metal`, etc.), and every cumulative point inherits that floor.
LEXICAL gains 86 hits and cuts mix U-WER to `.035444`, but its `.713873` recall is
`.0202` below the prior `.7341` reference and it fails safety. PHONETIC `.95`
exceeds that reference (`.754335`) but still has 17 false terms and `.021036`
negative FWER. The lowest mix U-WER is PHONETIC `.85` (`.030834`), also unsafe.

Baseline miss taxonomy (185 rows; first matching class wins):

| class | misses | share | representative observed forms |
|---|---:|---:|---|
| case-only | 34 | 18.4% | `envoy`→`Envoy`, `terraform`→`Terraform`, `MTLS`→`mTLS` |
| lexical variant | 52 | 28.1% | `Open telemetry`, `HTTP slash two`, `SHA 256` |
| phonetic-near (score ≥ .80) | 52 | 28.1% | `kubedom`, `rank`, `containered` |
| phonetic-far/absent | 47 | 25.4% | `Quebecal` (.706), `QBEM` (.583), `Xcl` (.550) |

Thus 86/185 misses (46.5%) are orthographic/derived-form binding, 52/185 (28.1%)
have a local phonetic candidate, and 47/185 (25.4%) need candidate creation beyond
this matcher. Decode-time work must beat the `.713873` lexical recall while solving
the 17-common-word casing ambiguity; thresholding phonetic similarity alone cannot
reach the zero-false-term guard.

Artifacts: replay implementation `bench/autoresearch/replay_repair.py`; full metrics
and input digests `.build/asr-research/three-bets/repair/frontier.json`; compact
table `frontier.csv`; all 185 classifications `miss-taxonomy.jsonl`; every repaired
transcript and accepted edit `replay.outputs.jsonl`; console table `report.txt`.

## Greedy-TDT margin harvest (2026-08-31)

- Added `voiceour-bench tdt-lattice`, backed by an opt-in vendored callback at every greedy
  token/duration decision (blank steps included). The ordinary path installs no callback; the
  research path emits only top-8/8,193 raw token logits plus all 5 raw duration logits. Harvest:
  **10,269 steps / 96 general rows** and **13,097 / 456 jargon rows**, with 0 raw-transcript
  drift against baseline pass 0. Artifacts:
  `.build/asr-research/three-bets/margins/{general96,jargon456}.lattice.jsonl`;
  run log `margins/harvest.log`.
- Step-level margin quantiles (`p00/p01/p05/p50/p95/p99/p100`):
  - general token **.0017/.2403/1.2450/9.4061/16.8683/21.5870/31.7086**; duration
    **.0004/.0535/.2642/2.9216/11.0256/19.2495/29.4671**.
  - jargon token **.0005/.4456/2.2087/10.6138/17.8396/19.7187/24.1829**; duration
    **.000003/.0629/.3045/4.3958/14.5808/19.4180/24.5006**.
- Fraction of steps with margin `< ε` for `ε=.5/1/2/4/8`:
  - general token **2.21/4.12/7.94/14.71/35.77%**; duration
    **10.17/21.36/39.31/61.44/88.76%**.
  - jargon token **1.21/2.32/4.49/10.51/29.37%**; duration
    **8.19/15.65/27.88/46.55/79.03%**.
- Scorer-exact join over the **185 missed / 161 hit** positive rows confirms a useful but
  incomplete localization signal. Lower row token margins predict a miss: min median
  **.7249 miss vs 1.6614 hit, AUROC .6633**; row-p05 **2.0613 vs 3.4032,
  AUROC .7108**. In a diagnostic reference-position window (canonical midpoint mapped to the
  decode frame range, ±8 encoder frames/±640 ms), token-min is **.8867 vs 2.5417,
  AUROC .7000** and token-p05 is **1.3679 vs 2.8823, AUROC .7221**. Duration margins add almost
  no miss discrimination (row-min AUROC **.5235**, window-min **.5380**).
- Consequence for W1-C: token margin can rank suspect spans, but cannot be the sole gate. Even
  the deployable row-p05 threshold that recalls 80% of misses (`≤3.6277`) flags **54.66% of hit
  rows** (precision **.6271**); the ground-truth-only window proxy still flags 45.34%. Combine
  local token margin with term-candidate evidence and calibrate on hard negatives rather than
  globally boosting every low-margin region. Full quantiles/histograms, operating points,
  per-positive join, and method:
  `.build/asr-research/three-bets/margins/{margin-analysis.json,margin-analysis.txt,positive-margin-join.jsonl}`.

## FINAL — Bet 1 verdict (2026-09-01, Main)

Arc: safe deterministic floor → λ-bias kill → forced-scoring kill → sealed holdout.

**Decode-time candidate creation is closed on these weights.** Three mechanisms, three
preregistered kills, no rescues:
- λ=4/U137 trie-localized bias (run 44): I0/I1 identity controls exact, but 2 net safe
  hits vs ≥14 required; one nonlocal rejection.
- TDT forced forward scoring (24-row probe, `.build/.../forced-score/`): mathematically
  sound (exact per-history DP, certified omitted-mass ≤.05), yet **0/16 positives** chose
  the canonical — the model's own evidence prefers its mishearing; p95 89.8 ms > 60.
  With N8 8/8 safe. The weights do not contain the missing terms as rankable hypotheses;
  no decoding cleverness can extract what isn't there.
- k-best/beam (prior art, reconfirmed): misses absent from whole beam.

**The deterministic repair mechanism survived out-of-distribution.** Sealed holdout v1
(996 rows, 8 voices, 6 locales, clean/noise/room; prereg SHA e57fb400…, opened once):
- Formal result: FAIL (recall .6156 < .75; false terms 8 > 0; U-WER benefit +.01045 ≥ .005 PASS).
- Attribution (Main, from asr-results + repair evidence): **all 8 false terms are raw-ASR
  output on adversarial near-phonetic scripts** (Go, pip, Ruby, semaphore×3, Swift×2);
  the frozen policy added ZERO false terms, fixed 134 rows, broke 0.
- Recall decomposition: raw .4220 → repaired .6156. Risky positives (128, ineligible by
  the safety rule) hit .625 raw-only; unambiguous .376 → .613. Eligibility-capped ceiling
  = .9306. All 28 case-only residual misses are risky surfaces — the exclusion that keeps
  `rust`→`Rust` from firing is exactly what blocks them. The .75 bar was unreachable by
  policy geometry, not by mechanism failure.

**What ships-able knowledge remains:** a vocabulary-driven deterministic repair pass
(unambiguous surfaces, PHONETIC θ=.95) is safe OOD and buys ~+19 pp exact-term recall and
−1.0 pp pooled U-WER on jargon-dense speech, on top of raw ASR. Risky-surface recall is
reachable only through explicit user teaching (the product's existing heard-as Teach flow)
— not through automatic decode/repair. Real-speaker validation remains required for any
product promotion (all holdout audio is TTS).

## Segment 2 — repair engaged (2026-09-01)

Harness v2.1 (commit fc125c674f1e) engages the SHA-pinned repair vocabulary
(`bench/autoresearch/repair.vocabulary.json`, 650dfc3f…) via `voiceour-bench
--vocabulary`. Run 50 (keep, segment-2 baseline):

| metric | seg-1 baseline | seg-2 baseline |
|---|---:|---:|
| uwer_mix | .045995 | **.034009** (−26.1% rel) |
| uwer_jargon | .060861 | .036885 |
| uwer_general | .031135 | .031135 (untouched) |
| jargon_term_recall | .4653 | **.7052** |
| jargon_false_terms | 0 | 0 |
| fwer_negative | .007282 | .007282 (exact) |
| per-domain recall | apple 17/68 | apple 50/68 · security 48/68 · dataweb 53/66 · cloud 47/72 · langs 46/72 |

Mechanism: `Sources/VoiceCore/VocabularyRepair.swift` — exact Swift port of the
frozen replay policy (lexical + phonetic θ=.95, unambiguous-only, risky surfaces
protected) **plus the ordinary-span guard** (reject phonetic candidates whose span
is entirely ordinary words; single letters ordinary iff a/i). Guard is
tightening-only: dev cost 2 events (`I am`→IAM, `hash cut`→Hashcat); it kills the
measured `I am`→IAM hazard on general text (0 surviving general events).
Proofs: 552/552 byte-exact differential vs Python (incl. events); official run
matched the offline prediction digit-for-digit on all six accuracy metrics; raw
ASR transcript SHAs byte-identical to segment 1 (text-stage-only change);
engine p95 5.2 ms/utterance off the ASR timing path.

Residual 102 misses = risky-ineligible raw misses (Teach-flow territory) +
phonetic-far mishearings (kubectl→"Quebecal" class — closed at decode level).
App-side engagement remains an explicit product decision; bench-side capability
and OOD safety evidence (sealed holdout: +134/−0 rows, 0 policy false terms) are
the session deliverables.

### Real-speech repair safety — sealed holdout endpoint PASSED (2026-09-01)

Within `fleurs-holdout-941-real-speaker-validation-v1` (see bet2 for the full
evaluation): on 941 real-speaker FLEURS rows, the shipping vocabulary path (N)
versus cleanup-only (N0) produced **zero repair-attributable insertions of the 141
eligible surfaces — and zero rows where the vocabulary stage changed final text at
all** (N ≡ N0, U-WER equal to the last digit). The frozen PHONETIC θ=.95
unambiguous-only policy is exactly as conservative on out-of-distribution real
English as designed: it fires never when no technical term is present. Combined
with holdout-v1 (0 false terms OOD synthetic, fixed 134/broke 0), repair now
carries both synthetic and one-Mac real-speech safety evidence. Cross-SoC and
real-dictation acoustics remain the open promotion prerequisites.

### Disfluent-speech repair safety — sealed AMI endpoint PASSED (2026-09-01)

Within `ami-holdout-12643-spontaneous-speech-v1` (bet3 holds the full record): on
12,643 rows of heavily disfluent spontaneous meeting speech — fillers, restarts,
fragments, the natural attack surface for a phonetic repair gate — the shipping
vocabulary path produced **zero repair-attributable insertions and zero changed
rows** versus cleanup-only (N ≡ N0). Combined with holdout-v1 (synthetic OOD) and
fleurs-holdout-941 (read speech), the frozen θ=.95 unambiguous-only policy has now
been silent on every corpus class it could plausibly damage.

### FINAL — decode-side recall family closed by its own preregistration (recorded 2026-09-01)

Recovered from `.build/asr-research/three-bets/context-search/` (a prior session ran
the staged cells; the reports were never transcribed here): the token-DAG
logit-fusion cached-replay experiment — the last unexplored decode-side mechanism —
was implemented behind the staged C seam and measured. **I0/I1 both PASS** (NULL
callback changes nothing; λ0 cached replay byte-identical to pass 1; replay p50/p95
14.1/16.5 ms, ≤45 steps). **The λ4 center cell KILLED per preregistration**: 4
accepted candidates, net +2 safe hits, one nonlocal prefix/suffix change (criterion
4), composite contextual+safe recall .716763 below the .75 bar. Per its own kill
rules — no λ6/λ8 rescue, no gate-flattening, no risky-term widening.

With this, every decode-side recall mechanism is a preregistered kill: global λ-bias
(segment 1), forced scoring (segment 1), scalar k-best selection (no kubectl through
K=8; eight "cubectal" variants), and DAG-bias cached replay (+2 net at λ4 with an
integrity violation). The frozen θ=.95 repair holds the safe floor. The ~.70 recall
on the jargon corpus is the pinned 0.6b model's measured ceiling for this audio:
the acoustic evidence diverges from the canonical surfaces mid-token, and no bounded
decode-time intervention manufactures the completion without collateral damage.

What would move recall materially, in order of expected yield: a larger pinned model
(a mission-contract change — the three bets are defined against the 0.6b pin),
model-vocabulary surgery for the unencodable surfaces (`C#`, `C++`, `io_uring`), or
re-recorded jargon audio (the TTS pronunciations bound what any decoder can recover).
All three are maintainer decisions, not harness candidates.
