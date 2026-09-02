# Harness specification — three-bets session

`bash autoresearch.sh` is the canonical offline, deterministic, exclusive-hardware
instrument. One `voiceour-bench pipeline` process and persistent `voiceour-asr`
sidecar run one warmup plus three timed general passes, then two identical jargon
passes. `bench/autoresearch/score_v5.py` enforces the gates and paired identity.

## Current fixed configuration

- Primary model: pinned Parakeet TDT v3 f16.
- Encoder: palettized 6-bit CoreML tiers at ≤6/≤8/≤15 s; native fallback above 15 s.
- Tail: persistent CPU pool with q8_0 repacked tail weights.
- Ordered concurrent assists: v2 f16, 1.1B f16, hybrid TDT-CTC 1.1B f16,
  unified RNNT 0.6B f16, multitalker RNNT 0.6B f16.
- Text stage: strict `.95` repair; exact whole-transcript assist arbitration; guarded
  `.80` diverse-form evidence repair; exact pre-clean C++ spoken-alias shelter.
- Every model, tier, corpus, annotation, vocabulary, sidecar, and bench binary is
  SHA-pinned or reported. The harness refuses competing Voiceour/ASR processes.

## Metrics and gates

| metric | definition | role |
|---|---|---|
| `jargon_term_recall` | exact case-sensitive canonical on 346 positives | **primary, higher** |
| `uwer_mix` | pooled final-text U-WER, general96 + jargon456 | guard ≤ .037509 |
| `uwer_general` / `uwer_jargon` | corpus U-WER | regression/effect attribution |
| `jargon_false_terms` | negative rows adding a taught surface absent case-insensitively from reference | must be 0 |
| `asr_inference_p95_ms` | median of three per-pass p95 values | guard ≤230 ms |
| `rtfx` | timed general audio seconds / ASR inference seconds | guard ≥100 |
| physical footprint | peak `proc_pid_rusage` physical footprint | guard ≤2500 MB |
| `error_rows` | failed rows across all passes | must be 0 |
| transcript hashes | timed general and paired jargon raw/final outputs | exact determinism |

The physical-footprint sampler does not count clean file-backed mappings as installed
bytes. Do not use its low number as a disk/cache claim.

## Corpora

- **general96**: 32 LibriSpeech clean, 32 LibriSpeech other, 32 FLEURS en-US;
  1,944 s, repeated four times.
- **jargon456**: 346 positives across five technical domains plus 110 hard ordinary-
  prose negatives; 1,943 s. Ground truth is `bench/autoresearch/jargon.terms.json`.
- Both manifests and the repair vocabulary are immutable SHA-pinned inputs.

Synthetic jargon is an optimization signal, not promotion evidence. Fresh safety
corpora and all preregistrations/verdicts are recorded in `research/final-report.md`;
large local artifacts remain under `.build/asr-research/three-bets/`.

## Operating notes

- Warm run: about 5–6 minutes on the measured M4 Pro.
- Stop the app first with `make stop`; the harness kills nothing.
- Run source changes through this exact command, then log the result. Do not infer
  output from a partial corpus or a parallel implementation.
- Final repository verification is `make check`.
