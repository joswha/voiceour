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

## FINAL — Bet 2 verdict (2026-09-01, Main)

**Root cause found (label-free):** the CoreML export preserved NeMo's reflect-centered
STFT padding while parakeet.cpp uses constant-zero centered padding
(`.build/.../coreml-rootcause/root-cause-report.json`). Full-FP32 "fidelity" faithfully
reproduced the wrong frontend contract — precision was never the problem. A second
residual difference (spelling normalization, `colourful` vs `colorful`) appeared even
with native mel injected: encoder-tail numerics still differ enough to flip lexical
variants. **Exact native identity through this export path is falsified**, at every
precision.

**The honest trade (NI contract, preregistered, run on all 552×2):** native-mel →
CPU_AND_NE CoreML encoder ≤15 s, native fallback above:
- Quality: pooled ΔU-WER +.000717 (NI ≤ +.0035), general +0, jargon +.001434, zero new
  false terms, fwer_negative improved, byte-deterministic across passes, zero errors.
- Energy: −47.0% active compute rails (locked ABBA, 64-row subset), DRAM .088 vs .115 J.
- Latency: routed median −10.5% (below the frozen −15% floor); all-row p95 −0.35%.
- Verdict: FAIL on the latency floor; energy objective met descriptively but the
  preregistered 32-general stratum was impossible (only 27 eligible ≤15 s rows).
- One repair attempt (fused native-frontend export): mel inside CoreML is catastrophic
  (+264% routed median). Closed.

**Standing evidence:** ANE is byte-deterministic (60/60 across processes), reaches 98.85%
ANE dispatch, and cuts dictation decode energy roughly in half at NI accuracy on this
M4 Pro. Landing it as a product path requires an energy-primary experiment segment (this
segment's primary is accuracy), a mel-contract-correct export, and cross-SoC evidence.
The complete runner/policy/evidence chain lives under `.build/asr-research/three-bets/
{coreml*,ane-ni,ane-fused-native}/`.

## Segment 3 — energy-primary: ANE encoder LANDED (2026-09-01)

Harness v3 (commit 8b95aa521c9b): general96 latency block + jargon456 ×3 reps inside an
unprivileged IOReport Energy Model window; primary `energy_j` = compute rails
(CPU+GPU+ANE) per rep. Accuracy is a hard guard (uwer_mix ≤ .037509 = seg-2 baseline
+ NI .0035; p95 ≤ 230 ms; RTFx ≥ 100) — energy cannot be bought with accuracy/speed.

| run | config | energy_j | rails (CPU/GPU/ANE J per 3 reps) | verdict |
|---|---|---:|---|---|
| 52 | native Metal | 444.579 | 286 / 996 / 52 | baseline |
| 53 | **ANE hybrid** | **272.300 (−38.8%)** | 321 / 201 / 295 | keep (prereg ≥20%) |
| 54 | replication | 262.808 | 293 / 202 / 293 | keep; noise band ±3.5%; 19.1× floor |

Guards under the hybrid: uwer_mix .034112 (+.000103, well inside NI), general U-WER
value unchanged, recall −2 rows (.6994), false terms 0, fwer_negative improved,
p95 207.75–210 ms, deterministic across passes/reps AND across processes (SHAs
identical between runs 53/54).

Integration (committed 0a7271db0f74): vendor patch 0016 (native-mel read seam +
capacity-checked external encoder-state injection) + `CoreMLEncoder.swift` persistent
CPU_AND_NE client in ASRSidecarCore; env-gated `VOICEOUR_COREML_ENCODER`
(+`VOICEOUR_COREML_MAX_S`, default 15 s; longer audio routes native); fail-closed
startup; env-off byte-inert. Artifact pinned by directory digest 2892a84e….

Open in-segment item: in-sidecar hybrid costs ~55 ms/row on jargon rows vs ~45 native
and ~39.5 in the scratch runner — ~10–15 ms/request integration overhead (CPU rail
+35 J signature). Overhead fix in flight; identity-pinned (numerics must not change).

Promotion caveats unchanged: one M4 Pro, TTS corpora, system-wide rail attribution
under exclusive-hardware discipline; product adoption needs cross-SoC + real speakers
+ an explicit product decision on the second inference runtime (CoreML) in the sidecar.

### Runs 56–57 — tail dial + 6 s bucket (2026-09-01)

**Run 56 (discard, evidence kept):** CPU tail (patch 0017, VOICEOUR_TAIL_BACKEND=cpu)
inverted the trade: GPU 177→27 J but CPU 314→617 J → energy_j +22.5%. Yet transcripts
stayed byte-identical on all 552 rows and latency improved sharply (p95 210→187.5,
p50 129.5→113.5, RTFx +14%). It is a pure latency/energy dial; re-landable diff at
.build/asr-research/three-bets/tail-cpu/relard/. Product option: per-power-source
tail policy (mains→CPU tail, battery→Metal tail).

**Run 57 (keep):** 6 s tiny bucket (mel 1×128×601 → 76 frames, digest 6ee06a31…,
450/456 jargon rows ≤6 s): energy_j 204.2→**187.5 (−8.2%; −57.8% vs native)**.
Rails ANE 122→91, GPU 177→129, CPU 314→342, DRAM →33. Transcripts byte-identical
again (SHAs equal runs 53–56 across all 552 rows) — three window sizes, one output.
Wrinkle: per-row inference +2.5 ms on the tiny graph (ANE tiling), yet power drops
more than time grows. Startup load now 707 ms (three MLModels) — cold-start cost
climbing with each tier; product wants lazy/async model loads.

Four-tier routing: ≤6 s tiny / ≤8 s short / ≤15 s standard / native.

## Segment 4 — drift-immune ABBA certification (2026-09-01)

Segment 3's plateau ended in measurement-validity failure: identical configs drifted
187→229→261 J (CPU/GPU rails climb with workstation activity; ANE rock-stable 86-91 J).
Harness v4 makes every run self-referenced: 8 balanced jargon blocks R C C R C R R C
(R = native reference, C = candidate ladder), each in its own IOReport window; primary
**energy_ratio = median(C)/median(R)**; wall-time contamination gate (>1.5× family
median window ⇒ run rejected — wall is a pure interference signal at fixed workload).

- Run 60 (discard): first ABBA flight caught a real contamination event — one C block's
  window stretched 19→61 s under a foreign CPU burst; sum-ratio had no outlier
  tolerance. Instrument hardened to median + gate before any baseline was logged.
- Run 61 (keep, baseline): **energy_ratio 0.5679** — the ANE ladder consumes 56.8% of
  native compute-rail energy (−43.2%), certified drift-immune on a live workstation.
  Cross-validation: R-family median 435.8 J ≈ era-1 quiet-machine native 444.6 J;
  C blocks uniform (16.1–16.6 s windows, ANE 28–29 J); zero gate trips.

The certification closes the segment-3 era ambiguity: the ladder's honest aggregate
effect is **−43% energy at NI accuracy**, with the 8 s/6 s rung fine-structure absorbed
into one robust self-referenced number. The v4 instrument remains available for any
future energy candidate; no candidate with a predicted effect above its gate remains
on this Mac.

### Runs 62–63 — product wiring pair (2026-09-01)

Both standing in-machine wiring decisions executed and gated:

1. **Vocabulary repair in the app** (commit 9139bc2f): TranscriptProcessingPipeline now
   applies the frozen θ=.95 repair after CleanupEngine, driven by the user's ACTIVE
   taught glossary — corpus-independent risk rule (baked ordinary-words VoiceCore
   resource + generator; single-letter a/i rule), per-snapshot engine cache (cold
   21.8 ms, hit 3.4 µs). Proven inert to the instrument (repair-verify 552/552, all
   transcript SHAs unchanged) and green on app gates: `make self-test`, `make ui-flow`
   23/23 no drift, `make verify-bundle` (bundle.sh now ships the SwiftPM resource
   bundle + assertion).
2. **Lazy per-tier CoreML loading**: startup stats/validates fail-closed, defers
   MLModel loads to first routed use. Real energy win — C blocks stop paying for
   unused tier loads: C median 247.5→227.9→226.5 J (0.6% spread across runs).

energy_ratio 0.5679 → 0.4664 → 0.4335 (best). The C-side absolute cost is highly
reproducible; the ratio's denominator (R native) climbs with ambient contention
(436→489→523 J) — contention hits the GPU-heavy native path harder than the isolated
ANE path, so the hybrid's advantage GROWS under load. Conservative certified claim
remains the quiet-anchored 0.568; live-conditions band 0.43–0.47.

**ANE artifact-shipping constraint measured:** each tier's .mlmodelc is 1.1 GB
(3.3 GB for the ladder) — product distribution needs palettization/weight-sharing
research or a single-tier compromise before this leaves env-gated status.

### Runs 67–69 — frontier bounds + deployment decision evidence (2026-09-01)

- **4-bit palettization: KILLED on NI** (run 68). Size passed spectacularly (917 MB =
  25.9% of FP16, faster loads/predictions) but uwer_mix .037800 > .037509 — the 24-row
  probe's warning (13/24 changed, +1.43 pp) scaled corpus-wide. Frontier conclusion:
  **6-bit grouped-32 is the operating point** — 38.4% size at +.0002 U-WER; 25.9% costs
  +.0035. One config, no rescue, exactly as preregistered.
- **Single-tier decision probe** (run 69, evidence discard): standard-tier-only
  (459 MB) measured ratio 0.7726 vs the ladder's 0.31–0.37. Caveat recorded: two C
  blocks carried ambient CPU interference; the cleanest block implies ~0.50. Honest
  ladder-vs-single-tier factor: **1.5–2.5×** — the 1.36 GB ladder earns its bytes
  when energy matters; single-tier remains an acceptable floor (still ≥23% better
  than native) where download size dominates.
- Run 67 (checks_failed): my own contamination gate correctly rejected a probe whose
  window was poisoned by concurrent k-means conversions — lock protocol extended to
  cover ALL heavy work, not just model execution.

Deployment menu this leaves the product:
| option | bytes | energy vs native | note |
|---|---:|---|---|
| native only | 0 | 1.0 | today's default |
| single 6-bit tier | 459 MB | ~0.5–0.77 | one artifact, one ~20 s first compile |
| 6-bit ladder | 1.36 GB | **0.31–0.37** | the certified optimum |

### Closing negatives — thread re-tune (2026-09-01)

Thread count under the standing config (ANE ladder + CPU tail): **threadCount=6
stands.** Position-balanced 20-run flight (the naive ordered sweep's apparent 11.95%
t12 win was a position/cold-cache artifact the sweep itself caught and discarded):
jargon wall is a flat 4/6/8 plateau (between-config spread 1.3% < replicate sd
1.8-7.0%); general96 p95 degrades monotonically above 8 threads; 6 owns the best
general and >15 s-row p95. 30/30 passes byte-identical to the pinned SHAs.

Adoption-checklist gap (user-owned Makefile): `make run` does not forward
`VOICEOUR_COREML_*`/`VOICEOUR_TAIL_BACKEND`; one forward line + `.env` entries are
needed before real-app ANE testing.

### Real-speaker validation — sealed evaluation PASSED (2026-09-01)

`fleurs-holdout-941-real-speaker-validation-v1`: 941 FLEURS en_us test rows 101+
(disjoint from every development corpus), 484 speakers, 9,199 s of real human
speech, per-file SHA verified 941/941. Preregistration sealed before any ASR
(`.build/asr-research/three-bets/holdout-real/preregistration.json`, sha
fdbc96b5…); four passes at HEAD `96ecd2126843` release binaries — N0 native
cleanup-only, N native shipping path, H standing hybrid (palettized 6-bit ladder +
CPU tail), H2 = H repeat. Zero error rows. Opened once; never reopened.

| endpoint | rule | measured | verdict |
|---|---|---|---|
| ANE NI on real speech | pooled ΔU-WER ≤ +.0035 AND speaker-clustered bootstrap (B=10000, seed 20260901) 95% upper ≤ +.005 | Δ = **−0.000435** (H .050505 vs N .050939), upper = **+0.000408** | **PASS** |
| repair safety | 0 repair-attributable insertions of the 141 eligible surfaces (N vs N0) | **0** — and 0 rows where vocabulary changed final text at all | **PASS** |
| determinism | H vs H2 byte-identical raw+final | 941/941 identical | **PASS** |

Secondary diagnostics (no pass/fail attached): FWER .11448 N vs .11469 H;
punct micro-F1 .8091 vs .8061; case F1 .90513 vs .90564; per-gender U-WER
symmetric (H ≤ N in both genders); 188/941 raw transcripts differ H-vs-N — the
palettized encoder perturbs one row in five at zero pooled accuracy cost.

What this upgrades: the ANE ladder + CPU tail configuration now carries
**real-speech validation on this Mac** — non-inferior (measured slightly better)
on out-of-distribution recorded human speakers, deterministic cross-process, with
the repair stage proven silent on ordinary English. What it does not: cross-SoC
evidence, real dictation acoustics (FLEURS is read speech), other languages.
Promotion prerequisites unchanged: cross-SoC replication, artifact hosting +
background warm, Makefile env forwarding.

Artifacts: `.build/asr-research/three-bets/holdout-real/{preregistration.json,
score_holdout.py,evaluation.json,N0.results.jsonl,N.results.jsonl,H.results.jsonl,
H2.results.jsonl}`. The provenance's recorded aggregate-SHA recipe could not be
reproduced (per-file recipe undocumented); the 941/941 individual file SHA matches
are the substantive integrity basis and are so recorded.

### KEEP — q8_0 tail repack (vendor patch 0019, run 81, 2026-09-01): 0.3053, best of session

`VOICEOUR_TAIL_QUANT=q8_0`: the seven 2-D f16 matmul records of the prediction/joint
tail (LSTM ih/hh × 2 layers + three joint linears; embedding excluded) are quantized
to q8_0 at load — tensor q8_0 in memory, record f16 on disk, every SHA pin intact,
cold arena caches the quantized image under `.tail-q8`, zero-conversion runs fail
loudly. 25.73 → 13.67 MB (−47%), which moves the whole tail inside the shared cache
the f16 tail overflowed. Result: energy_ratio **0.3053** (band was 0.3263–0.3399;
prereg bar 0.3235 cleared by 5.6%), C-median 126.3 J (−19%), DRAM rail 16.4 J,
p95 179 ms, p50 107 ms, RTFx 190.7, RSS 158.7 MB — and accuracy improved on every
metric: uwer_mix .034009 (f16 tail: .034317), jargon .037295, recall .702312,
fwer_negative .006472, false terms 0. The batch-1 tail is a memory-bound matvec
stream reading every weight once per emitted token; halving the bytes is pure win on
this substrate. Fourth substrate-dependence instance: whole-model q8 lost on Metal
(kill, segment 1) while tail-only q8 wins strictly on the CPU tail.

Three runs preceding the keep (78/79/80) were rejected by the contamination gate for
20–25 s first-routing rows. Root cause was NOT ambient: the data volume hit 98% full
and macOS began purging the (purgeable) ANE/E5 specialization cache per-process, so
every fresh block re-specialized cold. Freed ~55 GB of superseded model blobs
(killed/superseded lanes only; findings retained), verified cross-process
specialization persistence (302/102/123 ms fresh-process tier rows vs 17 s cold),
then measured cleanly. Instrument lesson recorded: the specialization cache is
disk-pressure-volatile, so low disk can masquerade as ambient contamination.

### Pool question closed on both substrates (run 83, 2026-09-01)

Patch 0018 re-preregistered under the q8 tail (fresh bar 0.3025 vs new band
0.3039/0.3053): measured **0.3205 — discard**. Under the f16 tail spin == churn
(neutral, run 77); under the cheaper q8 tail spin > churn (+5% energy). The
persistent pool is an energy-negative, latency-positive dial everywhere tested —
question closed. The latency dividend replicated and strengthened: p95 165.25 ms,
p50 97.5 ms (first sub-100 of the session), RTFx 207, digits pinned identically
under both tails. Product option recorded at
`.build/asr-research/three-bets/cpu-pool-q8/` (prereg, verdict, full diff vs the
0019 tree, tests): `VOICEOUR_CPU_POOL=persistent` buys p95 −7% / p50 −8% for ~+5%
dictation-window energy — a defensible trade for a dictation app, but not this
segment's metric. The kept research config remains ladder + CPU tail + q8 tail at
0.3039–0.3053.

### q8-tail config real-speech validated (2026-09-01)

See bet3 for the sealed `librispeech-holdout-5159` evaluation: the kept
ladder + CPU tail + q8 tail configuration is non-inferior on 5,159 held-out
real-speech rows (Δ −0.000035, clustered upper +0.000438) and cross-process
deterministic there. Both hybrid generations are now real-speech validated on this
Mac: f16 era via fleurs-holdout-941, q8 era via librispeech-holdout-5159.
