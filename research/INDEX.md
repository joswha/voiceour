# Three-bets research session — index

Branch `autoresearch/research-all-those-three-bets-you-have-unlimited-20260831`.
**Final conclusions and current metrics: `research/final-report.md`.** Read that first.
The remainder of this index is the chronological experiment ledger; older sections
retain their then-current metrics and are not the final product recommendation.

## Mission
Juice the pinned Parakeet TDT weights and Apple-Silicon runtime: (1) contextual decoding
for vocabulary binding, (2) ANE/heterogeneous execution, (3) quantization + margin
stability theory. Final segment primary: jargon term recall (higher); fixed guards:
mix U-WER≤.037509, p95≤230 ms, RTFx≥100, footprint≤2500 MB, zero corrected false rows,
zero errors, deterministic paired outputs.

## Baseline (run 41, M4 Pro, macOS 26.6.2, f16)
uwer_mix .045995 · general .031135 · jargon .060861 · term recall .4653 (161/346) ·
false 0 · fwer_neg .00728 · p50/p95 128/208.75 ms · RTFx 153.5 · load 58 ms · 184 MB.

## Final verified frontier

Recall **.852601 (295/346)** · mix/general/jargon U-WER
**.028068/.030725/.025410** · corrected false rows 0 · p50/p95
127.5/174 ms · RTFx 155.21 · physical footprint 310 MB · deterministic/error0.
This includes the post-review source-independence, punctuation-normalization, and
unapproved-event guards. It is a bench-only research ensemble; see the final report
for safety evidence and the decision not to productize it.

## Segment 4 (ABBA ratio) — certified, then product-wired
Runs 61–63: ladder certified 0.5679 drift-immune; then the wiring pair landed —
app-glossary vocabulary repair (inert to instrument, app gates green) + lazy tier
loading (real energy win, C median 227±1 J) → ratio best 0.4335. Hybrid advantage
grows under ambient load (ANE isolation). ANE shipping blocked on 3.3 GB artifacts.

### (original certification note)
energy_ratio **0.5679** (run 61): ANE ladder = 56.8% of native compute-rail energy,
self-referenced 8-block ABBA with contamination gate; R-median 435.8 J cross-validates
era-1 native 444.6 J. Run 60 caught a real foreign-burst contamination (instrument
hardened to median+gate before baselining).

## Segment 3 (energy-primary) — ANE encoder ladder landed
| run | config | energy_j | verdict |
|---|---|---:|---|
| 52 | native Metal | 444.58 | baseline |
| 53/54 | 15 s ANE hybrid | 272.3 / 262.8 | keep (−41%, 19× noise) |
| 55 | + 8 s bucket | 204.2 | keep (−22.3%) |
| 56 | CPU tail | 250.2 | discard — energy +22.5% BUT p95 −11% at byte-identity: latency/energy dial preserved |
| 57 | + 6 s bucket | **187.5** | keep (−8.2%; **−57.8% total**) |

All kept configs transcript-byte-identical to each other on all 552 rows; accuracy
guards never moved (uwer_mix .034112, NI ceiling .037509). Four-tier routing
≤6/≤8/≤15 s CoreML (CPU_AND_NE) / native; vendor patches 0016(+0017 evidence);
env-gated, fail-closed, env-off byte-inert. Commits 0a7271db, 947e708f, 5f25a63c.
Product notes: startup load 72→707 ms (lazy-load tiers), per-power-source tail dial.

## Segment 2 (repair engaged)
Baseline run 50: **uwer_mix .034009** (−26.1% vs segment 1), recall .7052, false 0,
fwer_negative exact, general byte-untouched; port proven 552/552 + digit-exact
prediction match. Harness v2.1 pins repair.vocabulary.json (650dfc3f…).

## Official run ledger (segment 1)
| run | disposition | what |
|---|---|---|
| 41 | keep | baseline; cross-process byte determinism proven |
| 42 | keep | patch 0014 decode-step observer + `tdt-lattice`; byte-inert; 23,366-step margin harvest |
| 43 | discard* | q8_0 official probe: ΔU-WER +.000307 (NI), tied/faster — 7–19% penalty falsified |
| 44 | discard | C1 λ=4 contextual bias killed per prereg (2 net hits; controls passed) |
| 45 | keep | patch 0015 record-authoritative loader + dual-source mixed repacker; byte-inert |
| 46 | crash | FFN-Q6 setup (missing caller-cache manifest → 404); no measurement |
| 47 | discard | FFN-Q6: U-WER improved (.045585) but p95 1.0349× > 1.03 kill gate |
*evidence probe by design — instrument stays f16.

## Bet verdicts (development evidence, one Mac, synthetic corpora)
| bet | verdict |
|---|---|
| 1 — contextual decoding | Decode-time candidate creation CLOSED on these weights (bias, forced scoring, beam all killed with controls). Deterministic vocabulary repair survives OOD: sealed 996-row holdout — policy added 0 false terms, fixed 134/broke 0, recall .422→.616, U-WER −1.04 pp; formal .75/zero-false bar unreachable by policy geometry (risky exclusion + model's own adversarial behavior). Risky surfaces belong to the Teach flow. |
| 2 — ANE encoder | Root cause of transcript drift: reflect-vs-zero STFT padding contract, not precision. Exact identity falsified at every precision. NI trade measured: −47% energy, −10.5% routed latency (< −15% floor), quality NI, deterministic. Needs an energy-primary segment + corrected export to land. |
| 3 — quantization | q8 penalty falsified; q8 is NI, tied/faster, −587 MB (official probe). Official-q8 provenance = original F32 (f16 re-quantization diverges) — reproduced byte-exactly. Mixed-precision loader/repacker landed byte-inert; FFN-Q6 killed on latency. Margin theory: near-perfect local flip locator, useless as harm oracle. |

## Sealed instruments built
- `bench/autoresearch/` two-corpus harness: uwer_mix + term/safety/latency/memory guards.
- `jargon.terms.json` ground truth (346 pos/110 neg, 173 surfaces) + derivation script.
- Holdout v1: 996 rows, 8 voices, 6 locales, 3 conditions, preregistered endpoints,
  sealed before generation, opened exactly once (`.build/asr-research/three-bets/holdout-v1/`).
- q8 promotion preregistration (cross-SoC ABBA design).
- Margin/lattice harvests f16+q8 for both corpora; forced-score DP runner; CoreML
  fidelity/root-cause/NI evidence chains.

## Session log
- 08-31: five-scout survey; harness v2; baseline runs 41–42; Wave A (seam, CoreML energy,
  q8 falsification, repair floor); q8 official probe; Wave B (6 tracks + 4-judge panel);
  Wave C preregistered — C1 killed (44), C2 killed at FP32 sentinel, C3 infrastructure
  kept (45) + FFN-Q6 killed (46–47).
- 09-01: Wave D (holdout build+seal, forced-score design, CoreML root cause, q8 prereg);
  holdout opened once → formal fail, attribution analysis → mechanism safe; forced-score
  probe killed; ANE NI policy measured; fused-native-frontend killed; scheduler sweep;
  final synthesis.

- 09-01 (cont.): segment 2 — ordinary-span guard derived and measured (2-event cost,
  0 general events), Swift port landed with 552/552 differential, harness v2.1,
  run 50 keep at .034009. Runs 49 (stale process, abandoned) / 50.
