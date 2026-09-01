# Bet 3 — Quantization frontier + margin stability theory

Goal: shrink weights (1.26 GB f16 → ≤ q8's 669 MB, ideally ~400 MB mixed) and cold load
(3.5 s → ~1 s) with `uwer_mix` non-inferior — and make quantized decode *not slower*.

## Established facts

- **The anomaly**: q8_0 is 7–19% slower than f16 on Metal (docs/performance-roadmap.md:
  LS p50/p95 202.5/272.7 → 216.5/329.4 ms; FLEURS 90.5/125.4 → 109/156.5). A
  bandwidth-bound workload got slower at half the bytes ⇒ dequant/matmul kernel
  inefficiency for these shapes (d=1024, heads 8, FFN, LSTM 640, vocab 8192).
- Accuracy: q8 U-WER ≈ f16 (2.782 vs 2.807 LS; identical FLEURS) — accuracy is not the
  blocker, speed is.
- Metal config hardcoded: `n_cb=3` (ggml-metal.cpp:610-622,716-728), poll cap 50k
  iterations; `n_threads=4` in ParakeetContext.
- Speculative batching of the scalar TDT tail is a confirmed dead end (~2% whole-run
  ceiling, `tdt-batchability.json`) — decode share is only .245 of run time; the
  encoder dominates.
- Weight arena (v0.2.1) made load 58 ms warm / footprint 184 MB — quantization's
  footprint win now matters mostly for *disk + download + cold first-run*, and its
  speed win must come from bandwidth.

## Theory piece — margin stability of greedy TDT

Greedy decode flips only where a logit perturbation exceeds the local top-1/top-2
margin, at token argmax (vocab+blank) or duration argmax (5 slots). Plan:

1. Harvest per-step margins over general96+jargon456 (shared seam with Bet 1).
2. Model per-tensor quantization as bounded logit perturbation ‖Δℓ‖ ≤ ε(config);
   estimate ε empirically per layer via activation-aware sensitivity probes.
3. Predict transcript-flip probability per config from the margin distribution;
   validate the prediction against q8's actual transcript diffs vs f16.
4. Rank mixed-precision assignments analytically; evaluate only the frontier through
   the harness. Hypothesis: the 5-slot duration head is fragile (a flipped duration
   cascades frame skips) — keep f16; encoder FFN tolerates 4–6 bit.

## Open problems, ranked

1. Name the slow q8 kernels: per-kernel timing/occupancy on the real decode shapes
   (Metal capture, ggml perf logging, or bisection via layer-type timing).
2. Kernel parity fixes (fused dequant-matmul, simdgroup matrices, n_cb) — vendored
   patches with NOTICE.md ledger entries.
3. Margin harvest + flip-prediction validation (above).
4. Mixed-precision repack tooling for this GGUF (ggml quantize utilities coverage for
   parakeet tensors — unknown).
5. q8 artifact presence: cached? (check `~/Library/Caches/Voiceour/…q8_0` dir); if
   absent, one-time digest-verified acquisition as setup, never inside a measured run.

## Findings log

- 2026-08-31: page seeded from survey + prior-art digest.

### 2026-08-31 — Greedy-TDT margin lattice harvested

- Added the opt-in `voiceour-bench tdt-lattice` seam. The vendored callback fires after every
  greedy token/duration argmax, including blank steps; its default is null, and raw token logits
  are copied from Metal only when installed. Each JSON step retains top-8/8,193 token logits and
  all 5 duration logits. Harvest: **10,269 steps / 96 general rows** and **13,097 / 456 jargon
  rows**, with 0 raw-transcript drift against baseline pass 0. Artifacts:
  `.build/asr-research/three-bets/margins/{general96,jargon456}.lattice.jsonl`;
  run log `margins/harvest.log`.
- Step-level raw-logit margin quantiles (`p00/p01/p05/p50/p95/p99/p100`):
  - general token **.0017/.2403/1.2450/9.4061/16.8683/21.5870/31.7086**; duration
    **.0004/.0535/.2642/2.9216/11.0256/19.2495/29.4671**.
  - jargon token **.0005/.4456/2.2087/10.6138/17.8396/19.7187/24.1829**; duration
    **.000003/.0629/.3045/4.3958/14.5808/19.4180/24.5006**.
- Fraction of steps with margin `< ε` for `ε=.5/1/2/4/8`:
  - general token **2.21/4.12/7.94/14.71/35.77%**; duration
    **10.17/21.36/39.31/61.44/88.76%**.
  - jargon token **1.21/2.32/4.49/10.51/29.37%**; duration
    **8.19/15.65/27.88/46.55/79.03%**.
  Thus the duration head is locally much less stable: under per-logit error
  `|Δℓ|≤δ`, only steps with margin `>2δ` are argmax-guaranteed, so the table's `ε=2δ`
  column is the empirical vulnerable set. This supports keeping the 5-slot head at higher
  precision, while token-head risk must still be measured end-to-end because one flip cascades.
- Joined scorer-exact baseline outcomes (**185 misses, 161 hits**) to margins. Lower token
  margins are informative: row-min median **.7249 miss vs 1.6614 hit, AUROC .6633**; row-p05
  **2.0613 vs 3.4032, AUROC .7108**. A reference-position proxy window around each canonical
  term (midpoint mapped to decode frames, ±8 encoder frames/±640 ms) is stronger:
  token-min **.8867 vs 2.5417, AUROC .7000**, token-p05 **1.3679 vs 2.8823, AUROC .7221**.
  Duration is not a useful jargon-miss discriminator (row-min AUROC **.5235**; window-min
  **.5380**) despite its smaller absolute margins. Full quantiles, histograms, ε fractions,
  per-positive join, and method:
  `.build/asr-research/three-bets/margins/{margin-analysis.json,margin-analysis.txt,positive-margin-join.jsonl}`.

### 2026-08-31 — q8 slowdown does not reproduce; residual cost is encoder mul-mm

- Setup: the q8 cache was absent. A resumable, one-time acquisition through
  `VOICEOUR_MODEL_VARIANT=q8_0 .build/release/voiceour-asr --prove
  fixtures/audio/hello_16k_mono.wav` populated
  `~/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml-q8_0`; independent
  verification found exactly **668,757,119 B** and SHA-256
  `4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e`.
  This was setup, outside every timed region. Because a successful variant load retires its
  sibling cache, the timed runs used explicit, separate caches under `quant/model-cache-*`.
- Measurement: M4 Pro, macOS **26.6.2 (25G83)**, Xcode **26.6 (17F113)**, Swift
  **6.3.3**. Each variant ran one warmup plus two timed general96 passes in one persistent
  `voiceour-bench pipeline` process; 192 timed rows/variant, zero errors, zero cross-pass
  transcript drift. Linear percentiles match `voiceour_bench.metrics.percentiles`.

| duration bucket | timed n/variant | f16 p50 / p95 ms | q8 p50 / p95 ms | q8/f16 p50 | q8/f16 p95 |
|---|---:|---:|---:|---:|---:|
| `<8 s` | 22 | 49.5 / 53.00 | 49.0 / 52.95 | **0.990** | **0.999** |
| `8–14 s` | 22 | 73.0 / 86.90 | 72.5 / 86.80 | **0.993** | **0.999** |
| `14–20 s` | 64 | 121.0 / 129.00 | 120.0 / 126.85 | **0.992** | **0.983** |
| `20–26 s` | 44 | 150.0 / 169.85 | 148.0 / 164.85 | **0.987** | **0.971** |
| `≥26 s` | 40 | 194.5 / 226.05 | 190.5 / 220.00 | **0.979** | **0.973** |

- Verdict: the documented **7–19% q8 regression is obsolete on this code/OS/toolchain**.
  q8 is statistically tied in the two short buckets and 1–3% faster in the longer buckets.
  Raw results and exact analysis:
  `.build/asr-research/three-bets/quant/{f16-general96-passes3-arena.results.jsonl,q8_0-general96-passes3.results.jsonl,ab-summary.json}`.
- Attribution: stock `xctrace` **Metal System Trace** captures of the same 31.65 s row
  separated the request at the preload/request idle gap and the encoder from the steady
  sub-1 ms TDT command-buffer tail (exactly 160 tail intervals in each trace). Encoder GPU
  command time was **120.986 ms f16 vs 124.032 ms q8** (**1.025×**, q8 +3.046 ms);
  LSTM prediction + joint tail was **34.963 vs 26.295 ms** (**0.752×**, q8 −8.667 ms);
  total request GPU command time was **155.949 vs 150.328 ms** (**0.964×**) and client
  inference **245 vs 242 ms**. Thus LSTM/pred/joint is falsified as the slowdown source.
  The only residual q8 cost is the FastConformer encoder weight-matmul aggregate; this trace
  cannot separate FFN, attention projections, and pointwise conv because they share the same
  Metal mul-mm pipeline.
- Current ggml already fuses dequantization: encoder weight-by-time matrices dispatch to
  `kernel_mul_mm_q8_0_f32`; scalar TDT matrices dispatch to
  `kernel_mul_mv_q8_0_f32`. There is no standalone dequant graph to fuse away. If the last
  encoder +2.5% matters, the concrete experiment is a q8-specific mul-mm tile/dispatch for
  Parakeet's 1024/4096-wide matrices instead of the generic pre-M5 `nr0=64, nr1=32`
  geometry—do not change the already-faster decoder path. Captures, exported intervals,
  phase analysis, and a **not-applied** node-label instrumentation patch:
  `.build/asr-research/three-bets/quant/{f16-metal.trace,q8_0-metal.trace,f16-gpu-intervals.xml,q8_0-gpu-intervals.xml,metal-attribution.json,instrumentation.patch}`.
- Repack tooling verdict (superseded 2026-09-01, see below): the historical claim that no
  quantizer product existed and that a mixed repack would dequantize selected F16 tensors is
  obsolete. The repository now ships `parakeet-mixed-quantize` and the loader allocates
  allowlisted matrices from each record's own type.

### 2026-09-01 — dual-source mixed quantizer shipped; f16 is NOT the quant source

- **Provenance resolved.** Official q8 (`4d64e9e9…`, 668,757,119 B) is the pinned original
  NVIDIA checkpoint (`nvidia/parakeet-tdt-0.6b-v3` rev `541d1f99…`) converted to an F32
  stream (`b17956ca…`, 2,508,463,079 B) by the pinned upstream converter with `--use-f32`,
  then quantized. Re-quantizing the published f16 payloads instead produces `ea8000f1…`
  with 10,718,248 differing payload bytes across all 273 Q8 records. **Selected F16 tensors
  must never be dequantized as the quant source**: correct repacks quantize the F32 stream
  while copying unselected records from the pinned f16 byte-for-byte. Full pins, hashes,
  and controls: `research/bet3-mixed-quantize-provenance.json`.
- **Tooling shipped.** `parakeet-mixed-quantize` (SwiftPM product over the vendored `CGgml`
  `ggml_quantize_chunk`) consumes an exact-name dual-pin plan-v2 minted by
  `scripts/generate_parakeet_mixed_plan.py`. The generator validates full preamble identity
  (except the nominal ftype word), name/shape/order identity, and exact F32→F16 rounding of
  every selected payload before publishing the plan/inventory pair failure-consistently. The
  converter opens both sources once, sizes/hashes those exact descriptors, rejects any plan
  name outside the loader's mixed-v1 allowlist, and publishes output+report durably
  (temp fsync, exclusive rename, directory fsync, deterministic byte-identical rerun).
- **Controls.** No-op plan reproduces official f16 SHA exactly; all-q8 plan reproduces
  official q8 SHA exactly; the encoder-FFN-Q6 candidate (96 Q6_K records, fused head F16)
  is deterministic at `4a7e6379…`, 780,892,391 B, and passes regular/cold/warm loader smoke.
  Focused suite: `scripts/tests/test_parakeet_mixed_quantize.py`. The official harness run
  for the candidate is still pending.
