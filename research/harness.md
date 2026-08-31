# Harness specification — three-bets session

`bash autoresearch.sh` is the canonical measurement instrument. Offline, deterministic,
exclusive-hardware. One `voiceour-bench pipeline` process (one persistent `voiceour-asr`
sidecar) runs 1 warmup + 3 timed passes over the general corpus, then 1 pass over the
jargon corpus. Scoring: `bench/autoresearch/score.py` (imports `voiceour_bench.metrics`
so definitions cannot drift from published reports).

## Metrics

| metric | corpus | definition | role |
|---|---|---|---|
| `uwer_mix` | general ∪ jargon | pooled final-text U-WER | **primary, lower** |
| `uwer_general` | general96 | U-WER | regression sentinel |
| `uwer_jargon` | jargon456 | U-WER | Bet 1 headroom |
| `jargon_term_recall` | 346 positives | exact case-sensitive canonical surface, `[A-Za-z0-9_]` boundaries | Bet 1 headline |
| `jargon_false_terms` | 110 negatives | (row,surface) pairs present in hyp, absent in ref, case-sensitive | binding safety |
| `fwer_negative` | 110 negatives | case-preserving formatted WER | re-casing/prose damage guard (U-WER is case-folded and blind to it) |
| `asr_inference_p95_ms` / `p50` | general timed passes | median across passes of per-pass percentile of sidecar `asr_inference` | guard ≤ 300 ms (p95) |
| `rtfx` | general timed | audio s / client asr s | guard ≥ 40 |
| `load_ms` | process | sidecar model load | cold-start tracking |
| `peak_phys_footprint_mb` / `peak_rss_mb` | whole run | 20 ms `proc_pid_rusage` sampler peaks | guard ≤ 2500 MB |
| `error_rows` | all | undecoded rows | must be 0 |

Hard failures: model pin mismatch (f16 by SHA), corpus/annotation SHA mismatch, missing
audio, competing processes, error rows, cross-pass transcript drift on the general
corpus (determinism), non-constant `asr_load`, <200 memory samples, guard breaches.

## Why the primary is `uwer_mix`

- Bet 1 (contextual decoding) lowers it through jargon rows (term errors are word errors).
- Bets 2/3 (ANE, quantization) must hold it while their wins land in guards/secondaries
  (latency, memory, energy, load time). Any accuracy damage from numerics or kernel work
  raises the primary immediately — non-inferiority is built into the metric.
- Case-folding blindness is covered by `jargon_term_recall` (orthographic binding) and
  `fwer_negative`/`jargon_false_terms` (re-casing damage on ordinary prose), judged
  per-run alongside the primary.

## Baseline expectations (pre-run estimates, replace with run 1 actuals)

- `uwer_general` ≈ .029 (mixed LS+FLEURS at committed baselines)
- `uwer_jargon` raw was ≈ .077 in the stale prior-session artifact [stale-risk]
- `jargon_term_recall` baseline unknown; prior-session raw term recall ≈ .465 [stale-risk]
- p95 ≈ 206–215 ms on the 96-row corpus; footprint ≈ 180 MB; load ≈ 300–500 ms

## Corpus anatomy

- **general96**: 32 LibriSpeech test.clean + 32 test.other + 32 FLEURS en_us rows,
  duration-bucketed (edges 0/8/14/20/26 s), 1944 s total. SHA-pinned manifest.
- **jargon456**: synthetic `say` speech, 1943 s. 346 positives over 5 domains with
  canonical surfaces in cased references (`kubectl`, `SwiftUI`, …, 187 distinct);
  110 hard negatives: ordinary prose using term words in ordinary senses
  (`rust on the gate`, `a swift bird`, `the metal spoon`, `commit to dinner`).
  Annotations: `bench/autoresearch/jargon.terms.json` (regenerate only via
  `derive_jargon_terms.py`; SHA-pinned).

## Operating notes

- Run time ≈ 3–4 min warm (build cached), plus cold release build on first run.
- The harness kills nothing: stop the app first (`make stop`) or the exclusive-hardware
  gate fails the run before timing.
- Changing decode behavior changes transcripts — that is the point; determinism is
  enforced only *within* a run (cross-pass identity). There is no golden transcript
  file anymore; accuracy is judged against references, not yesterday's output.
- Model-variant experiments (Bet 3) edit the harness's pin in the same run diff;
  the metric definition (same rows, same formulas) stays fixed.
