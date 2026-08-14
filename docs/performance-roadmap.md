# Performance: measured state and roadmap

Investigation began 2026-08-01. Measurements updated through 2026-08-14. Hardware: Apple M4 Pro (10P+4E, 24 GB), macOS 26.5.2 (25F84).
Runtime: `mlx==0.31.2`, `parakeet-mlx==0.5.2`, Python 3.12.12, FoundationModels module 1.5.2.

Every number below is measured unless tagged `[INFERRED]`. Roughly 1,000 timed on-device model calls
back this document. Raw timing artifacts were written to a scratch directory during the investigation
and are not committed; the per-claim numbers are reproduced here so the conclusions survive without them.

## Summary

Model computation is not the primary bottleneck. Decode runs at ~131 tok/s and ASR at RTFx 44.
Neither dominates measured total latency. Two factors do:

1. **Refinement is ~87% of post-speech latency**, and most of a refine call is *prefill*, not generation.
   The app sends **1,762 input tokens to produce ~59 output tokens**. This is a 30:1 input:output
   ratio against a 4,096-token context.
2. **The refiner re-emits the whole transcript to change almost none of it.** Correctly attributed,
   only **8.56%** of emitted words differ from the text the model was given. This is an **11.69x**
   over-generation ratio, and **29.2% of refines are byte-for-byte no-ops**.

Neither Rust nor hand-written Metal kernels address either source. The measurements below show why
both were rejected.

## Measured baseline

From 353 recorded dictation sessions on the hardware named above. These are real-usage percentiles
rather than a synthetic benchmark. That makes the capture-duration and refine distributions
meaningful, but also means they are **not reproducible from this repository**. The input was one
contributor's local session history, which is private user data and is not committed, published, or
derivable from anything here. Treat the table as evidence for the decisions below, not as a
benchmark to re-run.

To measure your own numbers, use the public corpora and gates in
[`docs/benchmarks.md`](benchmarks.md) (`make bench-stt`, `make bench-e2e`), which are reproducible by
anyone.

| stage | p50 | p90 | p95 | max | n |
|---|---:|---:|---:|---:|---:|
| ASR | 347 ms | 843 ms | 1052 ms | 2368 ms | 167 |
| **refine** | **2257 ms** | **3995 ms** | **5426 ms** | 11648 ms | 155 |
| insert | 4 ms | 32 ms | 43 ms | 98 ms | 188 |
| start latency | 188 ms | 219 ms | 231 ms | 1766 ms | 43 |
| capture (speech) | 10.0 s | 37.0 s | 46.0 s | 92 s | 141 |

Apple on-device refiner alone (n=123): p50 2052 ms, p95 3077 ms. Refinement runs on 137 of 242
eligible sessions (57%); `DictationPolicy.assessTranscript` already skips the rest.

Summing the marginal medians gives ≈2608 ms post-speech with refinement at 87%. **That sum is not a
measured span.** `SessionStageTimings` now persists `stopReleaseToInsertionOutcomeMs` alongside
`asrBackendId`, `asrLoadMs`, and `asrInferenceMs`, so new sessions carry a direct end-to-end
measurement. The 2608 ms figure and 87% share here remain arithmetic composites of the independently
measured stages; they preserve the observed scale and ranking but are not stopwatch readings.

### Refine-call timing breakdown

Measured with a standalone harness replicating the production prompt, glossary, options and session
lifecycle, on 10 real transcripts:

| quantity | value | source |
|---|---:|---|
| system prompt | 677 tokens | `SystemLanguageModel.tokenCount(for:)` |
| user message, default 8-term glossary | 307 tokens | same |
| **user message, real 58-term glossary** | **1085 tokens** | same |
| context size | 4096 tokens | `SystemLanguageModel.contextSize` |
| output for a 45-word transcript | ~59 tokens | measured |
| time to first token | 679 ms of ~1136 ms total | `streamResponse` first snapshot |
| full production-lifecycle repro | 1671.9 ms (p25 1480, p75 2099) | n=50 |

The frequently-quoted `refine_ms ≈ 1517 + 9.9 × words` is a **regression intercept over historical
sessions, not a timed component**. Treating it as a discrete 1,517 ms block of work is wrong; a
controlled reproduction of the same path lands at 1672 ms median with a ~380 ms unexplained residual
attributable to provider warm-state history.

The glossary is the largest single controllable input: going from 8 to 58 terms costs **+513 ms**
(paired median; +537.6 ms by difference of medians).

## Shipped in this change

**Stop awaiting the system-audio fade before transcribing.** `SystemAudioMuter.restore()` ramps the
user's volume back over `fadeDuration = 120 ms` and awaits every step, and `processStop` awaited it
immediately after `recorder.stop()`, before the ASR call. The journal quantifies the cost without
needing new instrumentation: taking `stopReleaseToInsertionOutcomeMs - asrMs` as non-ASR overhead,
restricted to `parakeet-mlx` sessions where refinement was skipped. `mutedDuringCapture` is the only
remaining variable. Splitting on it gives **199 ms p50 muted (n=92) against 72 ms unmuted (n=13)**.
The 127 ms difference is the fade. 80.1% of real-backend sessions were muted, so four out of five
dictations paid it, in front of an inference that takes 117.8 ms.

The fade now starts on the stop path and ramps under the transcription instead of in front of it
(`beginSystemAudioRestore()`), which is safe because the restore was already idempotent per session
and already stored its in-flight task for later joiners. Pinned by
`recordingStopDoesNotWaitForTheAudioFadeBeforeTranscribing`, which gates `restore()` and asserts the
coordinator reaches `.transcribing` while the fade is still parked; the test was confirmed to fail
when the `await` is put back. The aggregate muted-vs-unmuted figure across all backends is only
38 ms and is confounded by backend mix. Segmenting within one backend isolates the comparison. The
earlier ~120 ms figure was a reading of `fadeDuration` rather than a measurement.

**Prewarm the Foundation Models session at recording stop instead of at app launch.**

`DictationCoordinator` previously issued `Task { await refiner.warmUp() }` at construction
(HEAD:381). A session prepared then sits unused until the user dictates, typically minutes or hours
later. Measurement shows it keeps almost none of its value across that gap.

Measured decay curve (220 calls, 11 lead times × {prewarm, no-prewarm control}, 10 trials/cell,
**randomized and interleaved** arm order, real 58-term glossary):

| lead | prewarm | no-prewarm control | paired benefit |
|---:|---:|---:|---:|
| 0 s | 1637.6 ms | 1647.3 ms | −21.6 ms *(placebo consistent with null)* |
| 0.25 s | 1413.9 | 1646.1 | +244.2 |
| 0.5 s | 1340.0 | 1651.6 | +290.3 |
| **1 s** | **1318.8** | 1657.7 | **+299.5** (IQR 270–334) |
| 2 s | 1341.7 | 1640.6 | +308.8 |
| 3 s | 1399.5 | 1643.1 | +296.1 |
| 5 s | 1367.8 | 1812.6 | +435.2 |
| 10 s | 1892.5 | 1877.1 | −35.3 *(both cold)* |
| 30 s | 1852.8 | 1885.1 | +32.0 |
| 60 s | 1615.6 | 1928.5 | +90.3 |

**Do not derive the production delta from that table.** Its design makes lead time and provider idle
time the same variable: every trial ran `create → maybe prewarm → wait(lead) → respond` back to back,
so a short-lead cell also had a provider that was generating moments earlier. The table shows the
benefit saturating at roughly `min(lead, 300 ms)`. This result sizes the hook, but the shipped regime
(long idle, *then* prewarm, *then* a short lead) is not a cell in it. An earlier revision of this
document published +224 ms from `prewarm@60s − prewarm@250ms`; that contrast moves idle time and
prewarm placement together and has been retired.

A second experiment isolated prewarm **placement** by holding idle time constant at 30 s across all
arms. It included 240 accepted trials, a globally shuffled schedule, 8 trials per transcript × arm,
nominal thermal state throughout, and no competing model process:

| arm | what it models | median |
|---|---|---:|
| A | prewarm **before** the idle (old production) | 1849.6 ms |
| B | prewarm **after** the idle, then ~400 ms lead (shipped) | **1455.6 ms** |
| C | no prewarm at all (cold control) | 1888.0 ms |

**The shipped delta is B − A = −383.5 ms paired median** (mean −380.3, 95% CI [−399.0, −361.6],
negative on 10/10 transcripts, sign p = 0.002). Against never prewarming, B − C = −419.1 ms.

The pre-idle prepared session retains a measured benefit. A − C = −37.2 ms, so it retains about
37 ms of its benefit across 30 s. But that is roughly a tenth of what a freshly-timed prewarm
delivers. The evidence supports "by 30 s idle, most of the benefit is gone", **not** "the provider
evicts after 5–10 s". This experiment does not locate an eviction threshold, and 30 s is a lower
bound on real-world idle for a menu-bar app.

On the default MLX/sidecar path recorder finalization plus ASR supplies 350–500 ms of lead, which
matches the tested ~400 ms. The hook is fired unstructured so it adds no `await` to the post-ASR
critical path.

Implementation: `SingleUsePrewarmedSessionSlot.prepareFresh()` replaces an unused stale spare rather
than no-op'ing when one is already `ready` (the old `warmUp()` could not refresh a ready slot, so
merely adding a call site would have done nothing). One fresh session per utterance is preserved, so
the no-cross-utterance-contamination privacy contract is unchanged. At the time of this experiment,
`swift build` was clean and **279/279 tests passed**.

### Caveats

- **Backend-dependent.** On the opt-in Apple ASR backend post-stop work is only ~16 ms. The hook
  gets almost no lead, so the measured prewarm benefit does not apply. This optimization is specific
  to the MLX path.
- **43% of sessions skip refinement**, so the prewarm is sometimes paid for nothing. The caller-side
  return is 0.066 ms, but the asynchronous preparation work's energy cost is **unmeasured**
  (`powermetrics` requires superuser).
- **It is not strictly output-invariant.** All 220 sweep calls produced byte-identical output per
  transcript, as expected under `.greedy`/temperature 0.0. Production wraps refine in a 3000 ms
  timeout (`Models.swift:149`) while Apple's p95 is 3077 ms, so
  a slice of refines currently times out into deterministic fallback. Saving ~384 ms moves that
  boundary and *will* change final text on those sessions. The expected direction is from
  deterministic fallback to completed refinement, but it remains an output change.

## Ranked open candidates, not yet shipped

| # | Candidate | Measured result | Blocker |
|---|---|---:|---|
| 1 | Cut glossary prompt tokens | 55–464 ms | **Quality.** Every trim tested produced ≥1 worse output |
| 2 | INT8 quantized Parakeet | 32 ms @10 s, 41 ms @20 s, −1.05 GiB peak | No accuracy validation; needs a new model pin |
| 3 | Drop per-request `mx.clear_cache()` | 8–9 ms | Retains ~1 GiB Metal cache |

**1. Glossary tokens.** Measured options were: drop derived aliases (−91 tokens, −54.8 ms), dedupe
canonical-equivalent aliases (−9 tokens, −5.3 ms), cap at two aliases per term (−159 tokens,
−110.8 ms), cap at one (−322 tokens, −219.0 ms), or canonical-only (−701 tokens, −464.0 ms). All
were rejected: over 49 real transcripts plus 32 curated fixtures, **every nonzero trim produced at
least one manually-classified WORSE output**, though none lost a locked protected term.
Transcript-scoping is invalid because it matches glossary terms against text ASR has *already
mangled*, which is precisely the case the glossary exists to fix. Results were 10/49 worse outputs
and 2/32 new guard fallbacks. App-scoping via `VocabularyCompiler` saves no tokens on a glossary
that is entirely `scope: global`, which every observed target compiled all 58.

**2. INT8.** 8-bit affine, group size 64, over the real pinned model. It was faster than INT4, but
no accuracy, alignment, confidence-calibration or bias validation was run. The repo treats model id +
revision as a compatibility contract. A 32 ms reduction on a ~2600 ms path does not justify a new pin
without the full ASR suite behind it.

## Evaluated alternatives and rejection evidence

Documented to record why each alternative was rejected.

| Idea | Result |
|---|---|
| **`@Generable` diff/patch output** instead of full rewrite | **+873 ms (+88% SLOWER)**, 30/50 patch-application failures. Constrained-decoding overhead and schema tokens exceed the decode saving |
| **Streaming Parakeet** (`transcribe_stream`, already in the installed 0.5.2) | Closed 2026-08-14 with a 9-config sweep, FLEURS n=64. There is **no operating point**. See "Streaming Parakeet has no operating point" below for the full grid. The only config whose accuracy survives (`L256 R256`, U-WER 5.840% against batch 4.416%) has a **179 ms** residual against batch's 118 ms, and every config with a residual below batch costs 50-80 pp of U-WER. Supersedes the earlier one-line result (66 ms slower, 5.56% of words changed) |
| **Session reuse for KV-prefix caching** | Turns 2–4 were 250–290 ms faster, but the transcript grows and **exceeds the 4096-token context by turn 10**, degrading quality. Also violates the no-contamination contract |
| **Deferred replacement-prewarm blocking the critical path** | Hypothesis falsified: costs **0.292 ms** |
| Moving that replacement prewarm off-path | 2.4% *slower* |
| `prewarm(promptPrefix:)` called immediately | 0 ms |
| **Short (144-token) system prompt** | −331 ms but **2/32 command-as-text execution failures**. This is a safety bug, not a tradeoff |
| **Raising the `>= 40` refine trigger to `>= 100`** | 20,960 ms saved across the corpus, but only **2/10 skipped sessions were true no-ops**; the rest silently lose real edits. 137 rows, one speaker, in-sample |
| Multi-feature no-op classifier | 93.75% in-sample precision, rejected as overfit |
| Encoder `mx.compile` | Fixed-shape reduction 1.7 ms; unseen-shape penalty 5.9 ms. Net negative for variable dictation lengths. Padding buckets were 3.7–6.7 ms slower *and* changed transcripts |
| `mx.set_wired_limit` / residency | 0.3–1.4 ms **slower** |
| MLX 0.31.2 → 0.32.0 | 0.35 ms/request, classified as noise. The v0.32 NAX path does not gate on this M4 (`applegpu_g16s`) |
| Precomputing log-mel during capture | Log-mel is 0.56–1.13% of inference; ~1 ms |
| **Sidecar IPC / wire-contract rewrite** | Total Swift-side overhead outside inference is **1.2–1.6 ms**. In-memory sample passing would save <0.3 ms. NDJSON health round-trip is 0.09 ms |
| **Lengthening the MLX warm-up** to a realistic utterance | The 0.5 s silence warm-up was alleged to leave the first real request paying 2.2× inference. Refuted by an ABBA probe over four fresh processes on one 13.20 s clip: 0.5 s warm gave first/second/third of 179.3/152.5/148.2 ms in the very first process but **147.0/147.8/147.4 ms in a later one**, while 13.2 s warm gave 148.8/147.4/148.0 and 151.5/146.2/146.8. The one elevated run is attributable to cold page cache rather than warm-up shape. Its `_load_model` took 772 ms against ~510 ms everywhere after. A 13.2 s warm-up also costs 300–500 MB more peak (2188–2379 MB vs 1873–2053 MB) |

### Rust and Metal evaluation

Rust components and additional Metal optimization were evaluated. Neither targets the bottleneck:

- **The dominant cost is inside Apple's closed-source, Swift-only Foundation Models framework.**
  `objc2`'s own contributing guide puts Swift-only frameworks out of scope; reaching it from Rust
  requires a Swift shim, which adds FFI and removes nothing. Expected reduction in the 87% stage: **0 ms**.
- **No Rust ML runtime ships Parakeet/TDT credibly on Metal.** `candle` 0.11 has no Conformer/TDT
  model at all. Its Metal GEMM is an explicit port of MLX's `steel_gemm_fused`, so hand-written Rust
  kernels would duplicate MLX's own kernels. `burn` has the backends but no model. `mistral.rs` and
  `ratchet` have neither. The evaluated alternative is `parakeet-rs` 0.3.7 on ONNX Runtime. Its
  README warns "CoreML is unstable with this model" and steers to WebGPU or CPU.
- **A Rust rewrite affects only existing non-inference overhead.** The Python sidecar is already
  persistent, preloaded, and runs MLX on a dedicated thread, so a Rust rewrite reclaims only
  interpreter startup that is already off the hot path. Measured total non-inference overhead is
  **1.2–1.6 ms**. Audio DSP, WAV I/O and VAD are all sub-millisecond here.
- **A Rust component adds build and signing work.** Adding cargo to a SwiftPM build means
  universal-binary builds, nested signing and notarization for a menu-bar app whose TCC grants are
  already sensitive to re-signing.

`metal-rs` is deprecated in favour of `objc2-metal`; `objc2-metal` 0.3.2 does expose `MTL4*`, but even
`wgpu` 30 only *detects* `MTLGPUFamily::Metal4` without using MTL4 encoders. There is no evidence that
a hand-written kernel has lower latency than MLX for anything in this pipeline.

**Result: no Rust component is justified.** Keep Foundation Models in Swift and ASR in MLX.

### Backend choice: keep `mlx` as default

Apple's fused streaming engine had lower measured post-stop latency: **15.9 ms vs 119 ms** for a
warm MLX sidecar on an identical 10.56 s WAV (86.6% lower). It transcribes during capture.

The backend remains opt-in because the current evidence does not support a default change:

- LibriSpeech head-to-head, **row-matched** at n=128 (2026-08-11, `20260811T114019Z` mlx 2.845% vs
  `20260811T114143Z` apple-speech 3.133%): **+0.288 pp U-WER**, a pass against the +0.35 pp gate.
  This replaces the 2026-07-17 pass, which compared 128 mlx rows against 64 Apple rows.
- FLEURS, row-matched at n=64 (`20260811T114301Z` mlx vs `20260811T114320Z` apple-speech): **+1.71 pp
  U-WER** (4.416% vs 6.125%), F-WER 10.284% vs 12.997%, case F1 0.921 vs 0.848. This fails the same
  gate and reverses the n=8 FLEURS result that previously read as an Apple pass. Apple's punctuation
  micro-F1 is higher, 0.870 vs 0.833.
- Current measurements show no Apple batch-latency advantage: ASR p95 is now 348 ms (mlx) vs 802 ms
  (Apple) on LibriSpeech and 167 ms vs 236 ms on FLEURS. The 2327 ms Parakeet tail recorded in July
  predates the persistent preloaded sidecar and requires remeasurement before reuse.
- The TechTerms regression (+6.73 pp, canonical-term recall 7/11 → 3/11) is **inadmissible under the
  repo's own policy**: `docs/benchmarks.md` states TTS rows "must not be used as evidence for …
  technical term accuracy, or the production gate", and exact McNemar on a 4-utterance difference
  gives p ≥ 0.125.
- A production-data comparison suggesting Apple was 8.5x faster (58 ms vs 492.5 ms) is **confounded and
  must not be repeated**: those 43 sessions record no `captureMs`, average 19 words vs 40, and come
  from a 3-day July evaluation window.

Keep `mlx` based on **row-matched read-speech evidence** rather than status quo alone. It has lower
U-WER, CER, F-WER and batch latency on both tiers, and higher case F1. Apple has higher punctuation
micro-F1. What is still missing is the axis that decides a dictation default: neither tier is
real-speaker dictation audio, and the jargon evidence that would settle it remains inadmissible.
Treat *jargon and real-speaker accuracy* as **unsettled pending the consented real-speaker TechTerms
corpus** that `docs/benchmarks.md` already says does not exist.

### ASR model swap: ARK-ASR 0.6B and 3B, measured, shipped opt-in, not promoted to default

Investigated 2026-08-13 on the same M4 Pro, `mlx==0.32.0`, because ARK-ASR-3B sits at **4.636%** avg
cleaned WER on the live HF Open ASR Leaderboard against **5.661%** for our pinned
`parakeet-tdt-0.6b-v3`, a 1.03 pp leaderboard advantage that motivated evaluation of 3B weights.
That advantage is not reproduced on this app's corpora or within its latency budget.

Both sizes were run through the community MLX conversions `leope/ark-asr-0.6B-mlx` and
`leope/ark-asr-3B-mlx` (Apache-2.0, BF16, parity-validated against upstream PyTorch: identical greedy
token IDs, initial-logit cosine 0.9999). Every row was scored with this repo's own
`voiceour_bench.metrics`, and Parakeet was re-run in-process with identical staging so the
comparison comes down to the models. That control reproduced the committed FLEURS row exactly:
U-WER 4.416%, F-WER 10.284%, case F1 0.921. It validates the staging used for the ARK columns.

The latency figures were later re-confirmed through the **production path** rather than in-process,
by driving the real sidecar over its real stdio protocol (FLEURS, n=32, warm): Parakeet round trip
p50 **119.9 ms**, ARK-0.6B **322.3 ms**. ARK is 2.7x slower on the identical transport. The mechanism
tax is 0.8-0.9 ms p50 for both, so the sidecar is not confounding the comparison in either direction;
see `docs/architecture.md` for that measurement.

Two of the four tiers are admissible as accuracy evidence. `techterms` and `smoke` are local macOS
`say` synthesis, which `docs/benchmarks.md` labels `evidence_scope: smoke-only` and forbids as
evidence for "technical term accuracy, or the production gate"; they appear below for plumbing and
latency only, and no conclusion here rests on them. The LibriSpeech row is **row-matched at n=112**.
ARK rejects audio over 30 s, so Parakeet is re-scored on the same 112 rows rather than compared
across corpora of different size. Those excluded 16 rows have higher Parakeet error: 3.518% on them
against 2.716% on the 112 it keeps. Including them only for Parakeet would bias the result toward ARK.

| tier (n) | metric | Parakeet TDT 0.6B | ARK 0.6B | ARK 3B |
|---|---|---:|---:|---:|
| FLEURS (64, p50 9.8 s) | U-WER | 4.416% | **4.202%** | **3.632%** |
| | F-WER | **10.284%** | **9.590%** | 23.470% |
| | case F1 | **0.921** | 0.914 | **0.000** |
| | ASR p50 / p95 | **155 / 195 ms** | 310 / 454 ms | 1181 / 2162 ms |
| LibriSpeech (112 row-matched, p50 22.9 s) | U-WER | **2.716%** | 2.925% | **2.194%** |
| | CER | **0.889%** | 1.057% | **0.767%** |
| | ASR p50 / p95 | **307 / 714 ms** | 858 / 1880 ms | 2773 / 3717 ms |
| TechTerms (16, TTS, smoke-only) | U-WER | 6.731% | 8.654% | 10.577% |
| | ASR p50 | 87 ms | 102 ms | 348 ms |
| Smoke (8, TTS, smoke-only) | U-WER | 12.281% | 12.281% | 21.053% |
| | ASR p50 | 88 ms | 118 ms | 410 ms |
| any | MLX peak memory | **1.9–2.6 GB** | 2.3–2.9 GB | 7.1–7.7 GB |

Four independent findings support rejection:

1. **The leaderboard edge does not transfer.** On the two admissible tiers ARK-0.6B has mixed
   results: +0.214 pp on FLEURS (4.202% vs 4.416%) and −0.209 pp on LibriSpeech (2.925% vs 2.716%),
   two similar-magnitude deltas pointing opposite ways. The published 0.52 pp advantage is not
   visible. ARK-3B has lower U-WER on both by 0.784 pp and 0.522 pp. Findings 2 to 4, rather than
   word error, still disqualify it. The TTS tiers happen to run the same direction (ARK-0.6B
   −1.92 pp on TechTerms, level on Smoke) but are inadmissible and are not counted.
2. **Parakeet is faster on every tier**, by 1.2x on short utterances up to 2.8x on read speech, and
   this is structural rather than an artifact of the port: ARK's audio preprocessing is ~7 ms once
   warm, and its cost is a 32-layer 1280-dim Whisper encoder plus autoregressive decode, against a
   transducer that emits in one pass. ARK-3B is 4x to 9x slower.
   Quantizing the decoder does not offset this. The FLEURS stage split shows why: ARK-0.6B spends
   6.9 ms in preprocessing and **146.8 ms in encoder-plus-prefill** before it emits a single token,
   against **154.7 ms for all of Parakeet**. Even with decode driven to zero the encoder alone costs
   what the incumbent costs end to end. Quantizing the encoder is also unavailable:
   mlx-audio's `model_quant_predicate` for this model family deliberately excludes `audio_tower` and
   the projector and quantizes only the decoder, so the tower stays BF16 by convention.
3. **ARK-3B does not emit capitalization**, spells numbers as words, and drops most internal
   punctuation: "twenty-five to thirty" for "25 to 30", case F1 **0.000**. Its U-WER is the lowest
   measured here at 3.632%, while its *user-visible* F-WER is the highest of the three at 23.470%
   against Parakeet's 10.284%. This is upstream behaviour, not a conversion defect; the port's
   `VALIDATION.md` reference output is itself lowercase and unpunctuated. A dictation app pastes the
   string verbatim, so F-WER is the metric that matters and restoring case and digits would cost
   another model pass.
4. **ARK-3B needs 7.1–7.7 GB resident** on a 24 GB machine that also has to hold the refiner.

Two capability losses would apply to either size. ARK returns plain text only: no word alignments,
no per-word or aggregate confidence, and no n-best. `RiskAuthorizer` requires calibrated confidence
plus n-best agreement before it will replace a term, so an ARK backend disables automatic term
correction and degrades to suggest/keep. This preserves the safety path but removes automatic
replacement. The phrase-trie shallow-fusion glossary path has no transducer beam to hook into. ARK
also hard-rejects audio over
30 s with no chunking or VAD of its own; 16 of 128 LibriSpeech rows had to be skipped, where Parakeet
transcribed all 128.

**Both sizes are shipped as opt-in backends because the measurements above do not cover operational
use.** Select `ARK 0.6B` or `ARK 3B` in the Voice pane, or run `--asr-backend ark-0.6b`; `mlx`
remains the default and nothing changes unless you pick one. Benchmark them against the incumbent on
identical rows with `make bench-stt BACKEND=ark-0.6b N=64`. Reports are named per backend, so an A/B
of the same tier no longer collides on timestamp alone.

The shape is a second Python backend in the existing sidecar (`asr/src/voiceour_asr/backends/ark.py`
behind `VOICEOUR_ASR_BACKEND=ark-0.6b|ark-3b`), with the ARK MLX runtime **vendored verbatim** under
`backends/ark_mlx/` rather than imported from the model repo, so the app never executes code
downloaded from Hugging Face. Model identity became per-descriptor along the way, which removed three
standing assumptions that there is exactly one model: `cache.py`'s single `MODEL_ID`,
`SidecarASRClient`'s hardcoded `ASRModelContract` (it was telling even the `fake` backend to expect
Parakeet), and `BenchMain.meta`'s Apple-or-Parakeet ternary, which would have labelled every ARK
benchmark run as Parakeet.

Not native Swift/MLX. MLX Swift cannot build its Metal shaders under the SwiftPM CLI at all; it
requires Xcode, which this repo's shell-first build avoids, and on this host the Metal compiler is not
even installed (measured in the 2026-08-14 pass below). Its swift-tools **6.3** manifest is no longer
the blocker recorded here: the installed toolchain is 6.3.3. No licensed Swift ARK implementation
exists to vendor; the one the model card links is absent from the repository, and that repository
carries no licence. Not GGUF or Rust either: llama.cpp's `mtmd` has no `arkasr` graph or converter,
and Candle's own Voxtral example forces CPU on non-CUDA builds.

**Re-evaluation criteria.** An ARK release that emits punctuation and case at 3B quality *and* lands
under ~350 ms p50 on 10 s of audio, or the consented real-speaker TechTerms corpus showing a jargon
improvement large enough to justify the latency. Current leaderboard candidates for further
evaluation are `ibm-granite/granite-speech-4.1-2b-nar` (4.95% WER at RTFx 2079, a
non-autoregressive CTC-plus-LLM editor, i.e. one forward pass rather than a decode loop) and
`Qwen/Qwen3-ASR-1.7B` (4.98%, streaming, with a companion forced aligner for the timestamps ARK
cannot give us).

### Streaming Parakeet has no measured operating point

Measured 2026-08-14, M4 Pro, FLEURS n=64, one process, batch and every streaming config warmed
before timing, audio decoded up front so no `ffmpeg` lands inside a measurement.

The earlier entry compared *total* streaming compute against one batch pass. That is the wrong
metric because streaming runs the encoder while the user is still talking. The measured wait is the
**residual**, which is the last `add_audio()` call after the hotkey is released. This sweep reports
both and also sweeps `context_size`, which the earlier attempt left at the default `(256, 256)`, a
20.48 s unfinalized tail because the units are 80 ms encoded frames.

| config | U-WER | CER | residual p50 | total p50 | finalization lag | RTFx |
|---|---:|---:|---:|---:|---:|---:|
| batch, one pass | **4.416%** | **1.966%** | 117.8 ms | 117.8 ms | — | 80.5 |
| stream L256 R256 c640 | 5.840% | 2.980% | 179.4 ms | 2295.4 ms | 20480 ms | 4.1 |
| stream L128 R32 c640 | 56.695% | 43.309% | 86.3 ms | 1271.0 ms | 2560 ms | 7.5 |
| stream L64 R16 c640 | 54.843% | 40.119% | 63.9 ms | 984.2 ms | 1280 ms | 9.9 |
| stream L64 R8 c640 | 60.684% | 43.445% | 57.2 ms | 898.2 ms | 640 ms | 10.7 |
| stream L32 R4 c640 | 72.009% | 52.276% | 48.7 ms | 802.2 ms | 320 ms | 12.0 |
| stream L32 R4 c1280 | 64.886% | 50.297% | 52.9 ms | 449.1 ms | 320 ms | 21.2 |
| stream L32 R4 d2 c640 | 63.818% | 46.179% | 53.8 ms | 843.4 ms | 640 ms | 11.3 |
| stream L16 R2 c640 | 84.900% | 71.927% | **46.1 ms** | 769.3 ms | 160 ms | 12.7 |

Two findings:

**Streaming reduces residual latency.** Residual falls from 117.8 ms to **46 ms** as the context
shrinks, and every streaming config runs at 4-21x real time, so the encoder keeps up during capture.
The architecture overlaps the encoder with capture and pays only the last chunk at release. This is
within Apple SpeechTranscriber's measured 66 ms ASR latency.

**This checkpoint does not meet both latency and accuracy requirements.** Accuracy degrades from
4.4% to 55-85% U-WER. This is not a harness artifact; the output degrades into coherent-but-wrong
phonetics ("All nouns I world say for you always begin with a cap little letter of a scent with a
sea"), which is a model decoding out of distribution rather than crashing. `parakeet-tdt-0.6b-v3`
is **full-context trained** (non-causal ALiBi), and `transcribe_stream` swaps the encoder to
`rel_pos_local_attn` with the given window. Only `L256 R256` keeps accuracy, and it does so precisely
because 256 frames x 80 ms = 20.48 s is longer than the whole utterance. It is not really streaming
and is slower than batch. This checkpoint has no configuration that meets both requirements.

**Requirement for lower streaming residuals.** Apple's latency requires a checkpoint **trained** for
streaming. The measured residual range above is ~46-64 ms. The evaluated streaming-trained
candidates runnable on this Mac were:

| candidate | size | lookahead | licence | Apple runtime | timestamps / confidence |
|---|---|---|---|---|---|
| `moonshine-ai/moonshine-streaming-medium` | 245M / ~289 MB ORT | 80 ms | MIT | official C++ core + ONNX Runtime 1.23.2 arm64 | word timestamps real; **confidence is a hardcoded 1.0** (see below) |
| `nvidia/nemotron-speech-streaming-en-0.6b` | ~700 MB q8_0 GGUF | 80-1120 ms | NVIDIA Open Model | NeMo-Speech.cpp, Apache-2, Metal | timestamps yes; **word confidence is a 1.0 placeholder** |
| `kyutai/stt-1b-en_fr-mlx` | ~1 GB BF16 | 500 ms delay | CC-BY-4.0 | MLX-native (`moshi-mlx`) | word timestamps; no confidence |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` | 4.42 GB int4 | 80-2400 ms | Apache-2 | ExecuTorch Metal | neither |

**Moonshine was built and probed 2026-08-14, and it is not ready.** Upstream commit
`06f74196`, native C++ core with a bundled ONNX Runtime 1.23.2 arm64 dylib, MIT, model release
`medium-streaming-en/quantized_26_07_30` (291 MiB core, 431 MiB total download, warm RSS 1.5 GB,
first session load 240 ms). It had the lowest measured latency: smoke residuals of **4.5, 4.5 and
37.2 ms** against our 117.8 ms, and ~750 ms total for a 10 s clip, so ~14x real time. Word timestamps
are real (19-20 aligned words per utterance) and volatile partials exist. Two findings prevent
adoption:

1. **Its reported confidence is hardcoded, as Nemotron's is.** The public header documents a 0..1
   per-word confidence, but `core/word-alignment.cpp:366-369` unconditionally assigns
   `tw.confidence = 1.0f; // default confidence`, and every observed word was 1.0. This invalidates
   the earlier claim in this document that Moonshine was the one candidate whose confidence could
   keep `RiskAuthorizer`'s replace path alive. Hardcoded confidence prevents that replacement path.
2. **Sequential utterances in one process produce corrupted output.** The third clip decodes
   truncated and garbled when it follows two others in the same process, and is correct when run
   alone. Disabling word timestamps, disabling speculative decoding, reusing the stream, and warming
   on the longest clip all failed to fix it. That is an upstream inter-utterance state or reset
   defect. A persistent dictation process transcribes one utterance after another, so no corpus sweep
   was run.

**Capability claims require source or falsification checks.** Moonshine and Nemotron advertise
per-word confidence in their public API and both hardcode 1.0 in the implementation. Any backend's
evidence claims must be verified against its source or against a falsification probe (constant
confidence, uniformly spread timestamps), never against its header. Nemotron has lower WER and the
same confidence defect.

**Kyutai was built and measured 2026-08-14 and fails its stated target.**
`kyutai/stt-1b-en_fr-mlx` is MLX-native, so it needed no new runtime here. Its central risk was the
documented 500 ms delay. Measurement shows that the tail **can** be flushed faster than real time.
`moshi_mlx` stepping has no clock at all. `LmGen._step` counts an integer `step_idx`
(`moshi_mlx/models/generate.py:60-114`), upstream's own file script drives it with a bare unpaced
loop, and the only pacing anywhere in the tree is the microphone. Feeding zero-padding drains the
delay at **~17.6 ms per 80 ms block, i.e. 4.5x real time**, independently reproducing Kyutai's own
"500 ms becomes ~125 ms at 4x" claim. Words emerge from the pad steps at the indices the 6.25-block
delay predicts.

With 7 flush blocks x 17.6 ms, residual is **141 ms**, compared with Parakeet batch inference at
**117.8 ms**. Indicative accuracy on 3 rows was 9.59% against Parakeet's 4.416% U-WER. Two
operational notes apply: the flush must be bounded at `ceil(500/80) = 7` blocks, because padding past
~13 makes it hallucinate text out of pure silence. Its confidence is discarded rather than absent.
`sampling.py:147` computes a full log-softmax and `lm.py:465` throws it away into `_`, so it is
recoverable through the private `_step` plus one extra `text_linear` matmul.

**Results across all four evaluated candidates.** The 9-config Parakeet sweep measured a residual
reduction from 117.8 ms to **46 ms** at 4-21x real time, but U-WER rises from 4.4% to 55-85% because
the checkpoint is full-context trained. A whole-utterance decode costs 117.8 ms once; a streaming
model must instead drain its trained delay, and Kyutai's measured 4.5x flush still lands at 141 ms.
Moonshine was the only candidate with a residual below batch at 4.5-37 ms, and it is blocked on
hardcoded confidence and corrupt sequential utterances. Nemotron has lower WER and the same
confidence defect.

**Current measurements do not support pursuing streaming for the current utterance profile.**
Revisit only if capture lengths grow substantially, if a streaming checkpoint appears with both real
confidence and clean sequential behaviour, or if live partial text becomes a product feature with
requirements independent of latency.

### Runtime comparison across Python/MLX, Rust/Metal, C/Metal, and CoreML/ANE

Measured 2026-08-13, M4 Pro, FLEURS n=64, every leg run **serially under an exclusive hardware
window** and scored with `voiceour_bench.metrics`. Warm in every case: model resident, kernels
compiled, two discarded warm-up passes, model load reported separately and never inside a row.

**Framework comparison.** Whisper large-v3-turbo is the one non-trivial ASR architecture MLX, Candle
and whisper.cpp all implement, so it is the controlled comparison. Decoding was matched leg-by-leg
against Candle's actual behaviour: greedy, no beam, language forced to `en`,
`condition_on_previous_text` off, `suppress_blank` off, and `compression_ratio_threshold` disabled
because Candle sets that field to `NaN` and never computes it, making its fallback branch dead code.

| runtime | U-WER | ASR p50 |
|---|---:|---:|
| **MLX (Python)** | 4.274% | **435 ms** |
| whisper.cpp (C/Metal) | 3.989% | 495 ms |
| Candle (Rust/Metal) | 4.274% | **960 ms** |

Candle is **2.2x slower than Python/MLX on identical weights and identical decoding**. GPU execution
was confirmed: the same binary on `--cpu` at the same dtype takes 8145 ms against 999 ms on Metal.
The f32-to-f16 result also indicates kernel quality rather than configuration. It improves Candle by
only ~10%. A compute-bound GPU would be expected to improve by more. Candle and MLX agreeing to three
decimal places on U-WER confirms that the A/B used matched output accuracy.

Two additional facts reject Rust as a migration path. Candle 0.11.0 **does not compile its own
Whisper example** as released: `candle-examples` requests symphonia 0.6 while its `audio.rs` is
written against the 0.5 module layout. Rust also has **no Parakeet TDT and no ARK implementation at
all**. `candle-transformers` audio is csm, dac, encodec, metavoice, mimi, parler_tts, snac, voxtral,
whisper; mistral.rs has no C ABI and no transducer; `parakeet-rs` is an ONNX Runtime wrapper, not
native. A Rust migration would require a new model implementation and a runtime measured slower
than Python/MLX.

**Same-model, different-runtime.** whisper.cpp upstream now ships a native Parakeet TDT
(`libparakeet`, MIT, plain C ABI, Metal) running the same `parakeet-tdt-0.6b-v3` checkpoint we
ship, and FluidAudio ships it as CoreML for Swift. Both are directly comparable to production.

| runtime | U-WER | CER | p50 | p95 | Python? |
|---|---:|---:|---:|---:|---|
| MLX sidecar (today) | 4.416% | 1.966% | 119.9 ms | — | yes |
| parakeet.cpp (C/Metal) | 4.416% | 1.929% | **88.4 ms** | 123.1 ms | no |
| FluidAudio (CoreML/ANE) | **3.989%** | **1.892%** | **71.5 ms** | 86.3 ms | no |

**Ordering-controlled 2026-08-14.** The five legs above ran serially in one long window, so later
legs encountered more accumulated thermal load. Re-measured MLX and parakeet.cpp in ABBA order,
three rounds, six runs each: parakeet.cpp p50s spanned 87.6-89.5 ms (spread **1.9 ms**), MLX
142.3-146.2 ms (spread **3.9 ms**). The effect is **7.5x the worst within-tool spread**, so it is not
thermal drift. That re-run also exposed a confound that inflates any in-process MLX comparison: the
harness called `parakeet_mlx.audio.load_audio`, which **shells out to `ffmpeg`** (28.6 ms p50 here),
while production uses the `load_pcm16_mono_wav` fast path and parakeet.cpp reads the WAV directly in
0.19 ms. Comparing inference only, MLX is 117.3 ms against parakeet.cpp 88.0 ms. This 25.0% gap
matches the 119.9/88.4 row, so the table stands.

Both have lower latency than the incumbent and remove the Python dependency. `parakeet.cpp`
reproduces our U-WER to three decimals. It is the same model with the same greedy TDT decode, and it
still exposes word timestamps and real per-token posteriors, so `RiskAuthorizer` would keep working.
FluidAudio has the lowest U-WER, CER and median-latency values in the table. It runs on the Neural
Engine rather than the GPU, which may reduce battery use.

One caveat remains: across 64 rows FluidAudio has **one more contiguous multi-word dropout** than
parakeet.cpp (2 runs vs 1). Its aggregate word-operation counts are 34 substitutions / 14 deletions /
8 insertions against 39/15/8. The 4-word dropout on
`fleurs-en_us-test-000048` occurs in *both* runtimes and is therefore the model, not the runtime.
Silent deletion at high reported confidence can create undetected transcript omissions, so this
requires a larger sample before FluidAudio is trusted as a default.

### Removing Python: second pass, measured 2026-08-14

The first pass asked which runtime is fastest. This one asks what the Python dependency actually
costs and which no-Python runtime can carry the shipping contract. Latency turns out to be the
smallest of the three answers.

**The bundle cannot ship.** `scripts/bundle.sh:25-28` copies the Swift executable, `Info.plist` and
the icon, and nothing else. Real dictation resolves its sidecar through `DictationCoordinator.live()`
(`--asr-dir`, then `VOICEOUR_ASR_DIR`, then `<repoRoot>/asr`) and launches
`/usr/bin/env uv --no-config run --project <dir> python -m voiceour_asr`
(`SidecarASRClient.swift:26-35`). `.build/Voiceour.app` copied to another Mac therefore has no real
backend — and no `fake` one either, because `fake` is a sidecar backend too
(`ASRBackendRegistry.swift:131-137`), so `scripts/run_dev.sh --self-test` and the sidecar Swift tests
need `uv` and a synced venv as well. No measurement of the transport addresses that, and the
transport is the only thing the 0.8 ms figure ever measured.

**Same-machine A/B on the production path.** `fixtures/audio/hello_16k_mono.wav` (4.13 s), warm, one
process per runtime, f16-class weights on both sides:

| runtime | warm inference | first inference | peak RSS | weights on disk | Python |
|---|---:|---:|---:|---:|---|
| MLX sidecar (today) | 74.5 ms | 833 ms | 1.15 GB | 2.51 GB | yes |
| parakeet.cpp f16 (C/Metal) | **50.2 ms** | 58-348 ms | 1.34 GB | **1.26 GB** | no |

Both produced the byte-identical transcript `Hello world testing NVIDIA Parakeet NN spaceport.`,
including the same mistake on the fixture's "and NSPasteboard". Identical output on identical input is
stronger evidence of equivalence than matching aggregate WER.

Method: MLX was driven through the production sequence `load_pcm16_mono_wav` → `get_logmel` →
`generate`, not `parakeet_mlx`'s own entry point. Measured through the latter it reads 104 ms, because
it shells out to `ffmpeg` — the same confound the ordering-controlled re-run above found. parakeet.cpp
is the sum of its own reported mel, encode, predict and decode for the second and third of three files
passed to one context (35.2 + 6.5 + 7.1 + 1.3 ms); model load is reported separately and its first
encode of a process is 58-348 ms while Metal pipelines materialise. So the honest claim is **1.48x on
the ASR stage, saving ~24 ms**, which is ~8% of the 316 ms release-to-inserted with refinement skipped
and ~1% with refinement on. Latency is not the reason to do this.

**parakeet.cpp builds with Metal from the command line on a host with no Metal compiler.** This is the
decisive integration fact and it was verified first-hand rather than read. On this machine
`xcrun -sdk macosx metal --version` fails with `cannot execute tool 'metal' due to missing Metal
Toolchain`. Upstream whisper.cpp at 592feef (v1.9.2) nevertheless configures and builds
`-DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON` with plain cmake and
AppleClang, and the resulting binary reports `PARAKEET : MTL : EMBED_LIBRARY = 1` and initialises
`Apple M4 Pro` at runtime: `ggml/src/ggml-metal/CMakeLists.txt:27-58` embeds the shader *source* via
an ASM `incbin` section and `ggml-metal-device.m:125-134,229-235` compiles it with
`newLibraryWithSource`. Only the non-embedded path (`:93-101`) needs `xcrun metal`. The static
`parakeet-cli` is 2.9 MB and links Accelerate, Foundation, Metal, MetalKit, libc++ and libSystem —
system frameworks only, no nested dylibs, so nothing new to sign inside the bundle.

**Model artifact.** `ggml-org/parakeet-GGUF` publishes prebuilt f32/f16/q8_0/q4_0/q4_k conversions, so
there is no conversion step and therefore no maintainer-side Python either. Pinnable and pinned in
this measurement: revision `35156454d1a39de06863303dd209fd2bed6ee079`,
`ggml-parakeet-tdt-0.6b-v3-f16.bin`, sha256
`833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f`. That is a stronger contract than
today's, which pins repo and revision but not content. The card declares
`base_model: nvidia/parakeet-tdt-0.6b-v3` and does not name a source revision, so lineage is verified
and byte-equivalence to our pinned `ed2b7e8c…` is **UNVERIFIED**.

**Why the other four candidates lose.**

- **Rust: no, and for a different reason than last time.** Two crates reach Parakeet and neither is a
  native implementation. `parakeet-rs` 0.3.7 wraps ONNX Runtime, and its own `src/execution.rs` states
  CoreML is *slower* than CPU for Parakeet because the dynamic ONNX graph blocks ANE/GPU optimisation,
  with WebGPU documented as returning incorrect results. `sherpa-rs` 0.6.8 is deprecated in favour of
  upstream's own Rust API. `candle-transformers` 0.11 audio is still csm, dac, encodec, metavoice, mimi,
  parler_tts, snac, voxtral, whisper — no Conformer, no TDT, and no fused LSTM Metal kernel; `burn` 0.22
  has no ASR model. The Whisper leg above already measured Candle 2.2x slower than Python/MLX on
  identical weights and matched decoding.
- **Pure Swift MLX: no, and the stated blocker has moved.** The toolchain objection recorded elsewhere
  in this document is stale: the installed toolchain is Swift 6.3.3, so a swift-tools 6.3 dependency is
  consumable. The Metal objection is the live one, measured above. `mlx-swift-examples` contains no ASR
  example at all, and the only public Swift Parakeet, `FluidInference/swift-parakeet-mlx` (3,070 LOC,
  HEAD 2025-07-18), is described by its own README as v2-only, resource-intensive and superseded by that
  author's CoreML path; it is greedy-only, its `AlignedToken` carries no confidence, and its attention
  cache calls are commented out. A production-complete port was estimated at 35-55 engineer-days.
- **sherpa-onnx: shelved, not rejected.** It is the only candidate with real decode-time biasing —
  per-stream hotwords compiled into an Aho-Corasick `ContextGraph` whose scores fuse before top-k — and
  it ships a first-party SwiftPM package with prebuilt xcframeworks plus an exported
  `parakeet-tdt-0.6b-v3-int8` archive with genuine TDT duration decoding. Two facts keep it off the
  default: `cmake/onnxruntime-osx-universal-static.cmake:60-62` compiles the shipped static Apple build
  with `-DSHERPA_ONNX_DISABLE_COREML`, so the default Apple product is CPU-only, and its Swift wrapper
  exposes text/timestamps/durations while discarding the `ys_probs` and tokens the C++ hypothesis
  carries. 21 MB + 44 MB of arm64 archives. This is where biasing lives if biasing ever becomes a
  product requirement.
- **WhisperKit: no.** The open-source model enum is Whisper and distil-Whisper only, and its
  `BeamSearchTokenSampler.update` is a `fatalError` stub. Parakeet exists only in Argmax's commercial
  Pro SDK, which requires an API key plus an internet check at first use and at least once every
  30 days. A local-first dictation app cannot take a license heartbeat.
- **FluidAudio: opt-in, still not default.** Fastest and most accurate leg in the table above,
  Apache-2.0, no external Swift dependencies. Three things block promotion. It resolves weights from
  `resolve/main` with no revision pin (`ModelRegistry.swift:42-50`), which contradicts the model-pin
  contract. Its v3 accuracy defects are exactly the failure mode this app must not have: five open
  upstream issues report silent word loss from window composition, #850 deleting a 7.5 s opening at a
  reported confidence of 0.993, which independently corroborates the extra multi-word dropout measured
  above. And its TDT path gives token timings plus a mean-token-probability confidence, but no n-best.
  One mitigation is untested: batch mode uses a 15 s full-attention window, so a short dictation should
  take exactly one window and never reach the composition path.

**Recommended shape: keep the process boundary, replace the language.** The sidecar becomes a second
SwiftPM executable target in this repository that links `libparakeet` and speaks protocol v1
unchanged. The boundary earns its 0.8 ms three times over. Cancellation in parakeet.cpp is
cooperative and weaker than the header suggests — `src/parakeet.cpp:184-208` installs no abort
callback on the scheduler paths encode, predict and joint actually use, so an in-flight Metal graph
cannot be interrupted and only a killable child gives the client a hard timeout. A ggml abort takes
its process with it, and #3933 was a load-time stack overflow. The 342 MB encode and 67 MB decode
compute buffers plus weights stay reclaimable by killing an idle child rather than resident in a
menu-bar app. And reuse is the smaller diff: `SidecarASRClient`, the nine `fixtures/protocol/` files,
the health and preload semantics and every Swift transport test survive untouched, while both ends
finally import the same `VoiceCore.ASRProtocol` types instead of maintaining 400 Swift and 179 Python
lines of the same wire in parallel.

**What it deletes, and what it costs.** `asr/` is 2,896 source and 1,605 test lines. Gone with it:
`huggingface_hub` (`cache.py`'s 134 lines become a pinned `URLSession` GET plus a sha256 check), the
two opt-in ARK backends with their vendored 675-line runtime, and 830 lines of trie bias and beam
n-best. That last item is a real capability loss and is recorded as one: upstream parakeet.cpp is
greedy-only with no bias hook, so `RiskAuthorizer.appearsInNBest` loses the only path by which it
could stop being a tautology. Both features are off by default and neither discriminates on the
shipping path today. `bench/` stays Python deliberately: it drives the Swift `voiceour-bench` binary
and scores with jiwer and whisper-normalizer, it never ships, and rewriting WER scoring in Swift would
trade a trusted reference implementation for a novel one. The boundary is no Python in the app, not no
Python in the lab.

**Three gates before the default flips.** Reproduce accuracy through `voiceour_bench` on LibriSpeech
n=128 and FLEURS n=64 against `--gate uwer_final:0.0035`, not on one fixture. Choose f16 (1.26 GB)
versus q8_0 (669 MB) by measurement. And settle open issue #3932 before trusting the word timings:
duration argmax runs over log-probs, underflowed slots compare against a -1e10 sentinel with a strict
`>`, and duration index 0 is then selected silently — 16 of 786 tokens on the upstream sample, shifting
timestamps. It is a one-line comparison bug in a file we would be vendoring anyway.


**Why streaming appeared to offer a larger latency reduction.** From 500 real sessions on this
machine, segmented by whether refinement ran, release-to-inserted with refinement skipped is 316 ms
for `mlx` against **184 ms for `apple`**, whose ASR stage is 66 ms because SpeechAnalyzer transcribes
*during* capture rather than after the key is released. This comparison suggested that overlapping
ASR could save more than the 30-40% available from a runtime swap. The evaluations above show why
neither the current Parakeet checkpoint nor the four streaming-trained candidates can realise that
advantage for this utterance profile.



## Ranked next steps

Ranked by estimated engineering value, not implementation ease:

0. **Replace the sidecar's language, not its shape.** Keep protocol v1 and the child process; make the
   child a SwiftPM executable that links upstream whisper.cpp's MIT `libparakeet` and drop `asr/`
   entirely. Measured on the production path: 50.2 ms against 74.5 ms warm, byte-identical transcript,
   half the weights on disk, and a 2.9 MB static library that builds with plain cmake on a host with no
   Metal compiler. The reason is not the 24 ms. It is that `scripts/bundle.sh` produces an app that
   cannot transcribe on any machine without this source tree and `uv`. Do not make FluidAudio the
   default: it pins no model revision and has five open upstream issues about silently deleted words.
   Gates and the retained-capability losses are in the 2026-08-14 pass above.
1. **Avoid work for the 29.2% no-op refines.** No shipped change addresses them. A cheap classifier
   was rejected as overfit on 137 single-speaker rows. The missing prerequisite is a broader labeled
   dataset. Persisting per-session refiner-input text plus the corrected labels would build the
   corpus as a by-product of normal use.
2. **Reduce prefill rather than decode.** 1,762 in / 59 out is the measured structural inefficiency.
   Every prompt-shrink tested traded quality; the untested lever is a **trained LoRA adapter**
   (`SystemLanguageModel.Adapter`, present in the 26.5 SDK) to replace the 677-token instruction
   block with weights. Apple explicitly recommends adapters "for lower inference latency when a
   prompt-engineered solution requires lengthy prompts". Requirements include ~160 MB, Background
   Assets packaging, retraining per system-model version, and the 26.0.0 toolkit is explicitly
   incompatible with OS 27+.
3. **Instrument before optimizing further.** *Done (2026-08):* the end-to-end span (defect 4) and the
   sidecar's `timings_ms`/`backend_id` are both persisted per session. The investigation required
   reconstructing data that future sessions now record directly.
4. **Evaluate the refinement policy.** p95 refine is 5426 ms while p50 is 2257 ms; none of the
   changes above targets tail latency. With 29.2% no-ops and 8.56% of emitted words differing,
   evaluate whether refinement justifies 2 seconds on every utterance or should become an explicit
   on-demand action for the transcripts that need it.

## Reproducing this

- Stage latencies: run the app and read your own `SessionStageTimings`, which every session persists.
  The 353-session table above came from one contributor's private history and cannot be reproduced from
  this repository; nothing here reads or ships a session store.
- Single-utterance ASR latency without a corpus: `scripts/make_fixture.sh`, then
  `cd asr && uv --no-config run python ../scripts/phase0_asr_proof.py ../fixtures/audio/hello_16k_mono.wav`.
- Accuracy/latency tiers and gates: `docs/benchmarks.md`; compare with
  `voiceour_bench.compare … --gate uwer_final:0.0035`.
- ARK-ASR comparison: the harness was a scratch package outside this repository and is not committed,
  in line with the other raw artifacts here. To rebuild it, `uv` a Python 3.12 env with
  `mlx==0.32.0`, `transformers==4.57.6`, `librosa`, `jiwer` and `whisper-normalizer`; `snapshot_download`
  `leope/ark-asr-0.6B-mlx` and `leope/ark-asr-3B-mlx`; put each snapshot's bundled `src/` on
  `sys.path` and drive `ark_asr_mlx.api.ArkASR`. Iterate `benchmarks/data/<tier>/manifest.jsonl`,
  skipping rows over 30 s because ARK raises on them, and score with `voiceour_bench.metrics`
  (`uwer`, `cer`, `fwer`, `case_f1`, `percentiles`) so the numbers stay comparable to the tables above.
  Two setup requirements affect timing. Warm up on a clip of representative length because the
  first `librosa.load` triggers a multi-second numba import that otherwise appears in row one as
  23 s of "preprocessing". Warm up on a row under 30 s, or the warm-up itself throws.
- Foundation Models timing: build a standalone harness against the `FoundationModels` framework and
  replicate `RefinerPolicy.onDeviceSystemPrompt` + `RefinerPolicy.ompUserMessage` verbatim; use
  `SystemLanguageModel.tokenCount(for:)` for token counts rather than character estimates.
- **Run one model benchmark at a time.** Concurrent Metal work distorted results by 130 → 230 ms
  during this investigation. Every reported number here was re-run under an exclusive hardware window.
