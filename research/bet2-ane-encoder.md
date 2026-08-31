# Bet 2 — Heterogeneous execution (CoreML/ANE encoder, native TDT tail)

Goal: same transcripts, less time/energy. Guards: `uwer_mix` non-inferior, p95 ≤ 300 ms,
footprint ≤ 2500 MB, determinism (cross-pass identity — a nondeterministic engine
cannot ship through the harness).

## Established facts (verified prior art, `.build/asr-research/`, 2026-08-30, this Mac)

- **A working FP16 CoreML fused mel+encoder exists** (`coreml-parakeet-fp16/`,
  15 s / 240k-sample fixed window, 1×128×1501 mel → 1×1024×188 states).
  Compute-unit sweep (median): **CPU_AND_NE 27.711 ms (98.85% ANE)**, ALL 29.337 ms,
  CPU_AND_GPU 50.354 ms, CPU_ONLY 77.133 ms.
- **Hybrid = CoreML encoder + native GGML TDT tail** measured on 16 FLEURS rows:
  hybrid p50 47.308 ms vs native 66.971 ms (**~29.4% faster**); U-WER identical
  (5.6426% both), case F1 identical; FWER +0.27 pp, punct −0.011; 3/16 raw transcripts
  differ (proper noun, spelling variant, punctuation).
- **All-CoreML TDT decode rejected**: fused joint-decision head disagreed with Torch on
  token/duration and was slower (66.17 ms) than CoreML joint + CPU decision (41.25 ms).
  Encoder-only offload is the viable seam.
- **Long shapes are the wall**: dedicated 35 s graph — CPU_AND_NE **fails to load**
  (MPSGraphExecutable error), ALL 124.9 ms (98.98% ANE) but CPU_AND_GPU 107.0 ms beats
  it; hybrid gain shrinks to ~13.9%. **Naive 15 s chunking corrupts transcripts**
  (truncation/divergence after chunk boundary) despite 33.8% speedup.
- 15 s single-row memory probe: hybrid process peaks 196.7 MB footprint / 126.8 MB RSS —
  modest, but not an incremental-cost A/B.
- **2026-08-31 validation now closes the two promotion blockers**: CPU_AND_NE is
  byte-deterministic across fresh processes and unprivileged IOReport shows a large
  system-energy advantage. See the dated findings and raw artifacts below.

## Remaining problems, ranked

1. **Variable length**: a production bucket policy vs overlap-stitched chunking; the 35 s
   CPU_AND_NE load failure still rules out treating the long graph as a drop-in.
2. **Integration shape**: compile/env-gated encoder path inside `voiceour-asr` (same helper,
   same weights family), followed by the full quality/latency/memory harness gate.

## Findings log

- 2026-08-31: prior-art digest complete; artifacts under `coreml-parakeet-fp16*/`
  reusable — do NOT reconvert until energy/determinism verdicts are in.

### 2026-08-31 — CPU_AND_NE determinism, rail energy, contention, padding

**Artifact/load validation.** The existing 15 s fused mel+encoder at
`.build/asr-research/coreml-parakeet-fp16/.compiled/parakeet_mel_encoder.mlmodelc`
loaded and predicted with `MLComputeUnitsCPUAndNeuralEngine` on macOS 26.6.2 / M4 Pro.
The first observed load was **13,212.986 ms** (compiled artifact reused, but CoreML/ANE
cache state was not reset); three later fresh-process loads were **90.565 / 85.140 /
80.614 ms**. A warmed single prediction was **27.676 ms**; first predictions in those
fresh processes were **39.237 / 39.188 / 38.542 ms**. The path therefore requires a
persistent/preloaded helper; one-shot cold launch is not viable.

**Determinism verdict: PASS at byte level.** Fixed row
`fleurs-en_us-test-000005` produced one SHA-256
`6a086320071828687123d774150f5caa1b710f145f326d5a7ada58c0ed6c47cc`
for the valid CoreML encoder bytes in **60/60 hybrid runs**: 20 repeats in each of
three fresh processes. All 60 transcripts were also identical. The native GGML/Metal
encoder contrast produced one SHA-256
`c56cc8aec770100b785145568b96948cca2742758259391863878c5074fe4ed6`
in **20/20** runs. ANE execution can satisfy the harness identity requirement on this
artifact/machine; no tolerance or transcript-only exception is needed.

**Latency confirmation (16 prior-probe FLEURS rows × 5, interleaved, one warmup/row,
uninstrumented):** hybrid p50/p95 **47.106 / 60.389 ms** versus native
**66.648 / 95.391 ms**; hybrid p50 is **29.32% lower**. The current compiled artifact's
raw transcript differed from native on 7/16 rows (the same seven on every repetition),
so determinism is closed but promotion still requires the full quality gate.

**Energy method and error model.** `sudo -n powermetrics --samplers
cpu_power,gpu_power,ane_power -i 200 -n 1` failed (`sudo: a password is required`).
`proc_pid_rusage` v6 was populated (busy-self delta **15.028 J/2.0 s**, busy-child
**18.485 J/2.5 s**), but its combined process estimate cannot decompose CPU/GPU/ANE
and delegated CoreML attribution is uncertain. `ioreg` exposed IOReport legends rather
than sampled rail values. The selected unprivileged method is direct **IOReport Energy
Model** deltas for aggregate `CPU Energy` (1 mJ resolution), `GPU Energy` (nJ), and
`ANE*` (1 mJ). These are system-wide counters: results include the sampler, idle work,
other processes, and—under contention—the deliberate contender. Thus the numbers below
are system compute-rail joules per completed utterance, not process-attributed joules.
Variants were interleaved; raw ping floors and 100 ms background samples are retained.

| scenario (16 rows × 5) | hybrid mean / p50 J | native mean / p50 J | mean saving | instrumented wall p50 |
|---|---:|---:|---:|---:|
| quiet | **0.366 / 0.341** | **1.225 / 1.211** | **70.11%** | 56.338 vs 67.731 ms |
| continuous Metal contender (16.707 W baseline compute rails) | **1.629 / 1.579** | **3.185 / 3.178** | **48.84%** | 66.341 vs 121.117 ms |

Quiet mean rail split (CPU / GPU / ANE) was hybrid **0.111 / 0.113 / 0.142 J**
versus native **0.164 / 1.060 / 0.000 J**. Contended split was hybrid
**0.195 / 1.259 / 0.175 J** versus native **0.346 / 2.838 / 0.000 J**. Contended
raw joules include the competing kernel, so they measure time-to-completion system
cost; they must not be presented as isolated recognizer energy.

**Short-utterance padding cost (encoder only, p50 of 5):**

| audio | 15 s CoreML padded | native GGML encoder | CoreML − native |
|---:|---:|---:|---:|
| 4.32 s | 28.173 ms | 32.777 ms | **−4.604 ms** |
| 5.04 s | 28.199 ms | 27.887 ms | **+0.311 ms** |
| 5.76 s | 27.670 ms | 34.321 ms | **−6.651 ms** |
| 6.42 s | 27.659 ms | 35.062 ms | **−7.403 ms** |

The 15 s graph is effectively constant-cost over these rows. Padding loses narrowly
on one 5.04 s encoder-only row (1.1%), but hybrid end-to-end still wins there
(38.571 vs 40.244 ms); it wins encoder latency by 14–21% on the other three.

**Integration recommendation.** Use `CPU_AND_NE`, preload it in the persistent sidecar,
and ship an initial bucket set of **{15 s} only**, with native GGML for inputs above
15 s or any CoreML load/prediction failure. Do not use the failing 35 s CPU_AND_NE
artifact and do not chunk naively. A future `{5, 10, 15}` set is justified only if
newly compiled smaller graphs show additional joule savings—the 15 s graph already has
no meaningful short-row latency tax. Hybrid loses on cold one-shot startup, is a
near-tie in the one 5.04 s encoder case, and has no valid >15 s path; otherwise it is
both faster and lower-energy here, with an even larger latency advantage under GPU
contention. Full-corpus quality remains the promotion gate.

Artifacts: `.build/asr-research/three-bets/coreml/{summary.json,bet2-raw.json,
determinism.json,latency-only.json,energy-raw.json,padding-raw.json,
powermetrics-sudo.txt,rusage-energy-probe.json,ioreport-energy-probe.json}`.
