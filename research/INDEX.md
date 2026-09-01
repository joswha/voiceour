# Three-bets research session — index

Branch `autoresearch/research-all-those-three-bets-you-have-unlimited-20260831`.
Read `research/CONTEXT.md` first; instrument spec in `research/harness.md`; final verdicts
at the end of each bet page.

## Mission
Juice the pinned Parakeet TDT weights and Apple-Silicon runtime: (1) contextual decoding
for vocabulary binding, (2) ANE/heterogeneous execution, (3) quantization + margin
stability theory. Primary `uwer_mix` (lower); guards p95≤300 ms, RTFx≥40, ≤2500 MB,
zero errors, determinism, term safety.

## Baseline (run 41, M4 Pro, macOS 26.6.2, f16)
uwer_mix .045995 · general .031135 · jargon .060861 · term recall .4653 (161/346) ·
false 0 · fwer_neg .00728 · p50/p95 128/208.75 ms · RTFx 153.5 · load 58 ms · 184 MB.

## Official run ledger
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
