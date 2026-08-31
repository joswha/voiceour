# Three-bets research session — index

Session started 2026-08-31 on branch `autoresearch/research-all-those-three-bets-you-have-unlimited-20260831`.
Read `research/CONTEXT.md` before anything else. Harness: `research/harness.md`.

## Mission

Juice the pinned Parakeet TDT weights and the Apple-Silicon runtime: (1) contextual
decoding for vocabulary binding, (2) ANE/heterogeneous execution, (3) quantization +
margin stability theory. Primary metric `uwer_mix` (lower); guards on latency, RTFx,
memory, term safety.

## Baseline (run 1, 2026-08-31, M4 Pro, macOS 26.6.2)

| metric | value |
|---|---:|
| uwer_mix | **0.045995** |
| uwer_general | 0.031135 |
| uwer_jargon | 0.060861 |
| jargon_term_recall | 0.465318 (161/346) |
| jargon_false_terms | 0 |
| fwer_negative | 0.007282 |
| asr_inference p50/p95 | 128.0 / 208.75 ms |
| rtfx | 153.5 |
| load_ms | 58 (warm arena) |
| peak footprint / RSS | 177.0 / 114.5 MB |

Term recall by domain: apple 17/68, cloud 33/72, dataweb 39/66, langs 41/72,
security 31/68. First misses: kubectl, kubeadm, runc.

## Bet status

| bet | page | state |
|---|---|---|
| 1 — contextual decoding | `bet1-contextual-decoding.md` | baseline measured; awaiting logit/encoder-cache seam |
| 2 — ANE encoder | `bet2-ane-encoder.md` | prior CoreML probes under digest (`.build/asr-research/`) |
| 3 — quantization | `bet3-quantization.md` | q8-slower anomaly confirmed in docs; margin harvest pending |

## Session log

- 2026-08-31: Five-scout system survey (latency, decode, bench, glossary, archive).
- 2026-08-31: Harness v2 built — two-corpus design, term metrics, guards; golden-identity
  retired (session changes transcripts by design). Validated: exit 0, 13 metrics, 103 s.
- 2026-08-31: `jargon.terms.json` derived (346 positives/110 negatives, 173 surfaces).
