# Performance: measured state and roadmap

Investigation date: 2026-08-01. Hardware: Apple M4 Pro (10P+4E, 24 GB), macOS 26.5.2 (25F84).
Runtime: `mlx==0.31.2`, `parakeet-mlx==0.5.2`, Python 3.12.12, FoundationModels module 1.5.2.

Every number below is measured unless tagged `[INFERRED]`. Roughly 1,000 timed on-device model calls
back this document. Raw timing artifacts were written to a scratch directory during the investigation
and are not committed; the per-claim numbers are reproduced here so the conclusions survive without them.

## Bottom line

The model math is not the bottleneck. Decode runs at ~131 tok/s and ASR at RTFx 44; neither is where
the latency lives. Two things dominate:

1. **Refinement is ~87% of post-speech latency**, and most of a refine call is *prefill*, not generation.
   The app sends **1,762 input tokens to produce ~59 output tokens** — a 30:1 input:output ratio against
   a 4,096-token context.
2. **The refiner re-emits the whole transcript to change almost none of it.** Correctly attributed,
   only **8.56%** of emitted words differ from the text the model was given — an **11.69x**
   over-generation ratio, and **29.2% of refines are byte-for-byte no-ops**.

Neither Rust nor hand-written Metal kernels address either one. Both were investigated seriously and
are documented as dead ends below, with the numbers that kill them.

## Measured baseline

From 353 recorded dictation sessions on the hardware named above. These are real-usage percentiles, not
a synthetic benchmark, which is what makes the capture-duration and refine distributions meaningful --
and also what makes them **not reproducible from this repository**: the input was one contributor's
local session history, which is private user data and is not committed, published, or derivable from
anything here. Treat the table as evidence for the decisions below, not as a benchmark to re-run.

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
measured span.** No end-to-end stop→insert timing is persisted (see [Telemetry gap](#telemetry-gap)),
so the 2608 ms figure is an arithmetic composite of independently-measured stages, and the 87% share
inherits that caveat. It is the right order of magnitude and the right ranking; it is not a stopwatch
reading.

### Where a refine call actually goes

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

**Prewarm the Foundation Models session at recording stop instead of at app launch.**

`DictationCoordinator` previously issued `Task { await refiner.warmUp() }` at construction
(HEAD:381). A session prepared then sits unused until the user dictates — typically minutes or hours
later — and measurement shows it keeps almost none of its value across that gap.

Measured decay curve (220 calls, 11 lead times × {prewarm, no-prewarm control}, 10 trials/cell,
**randomized and interleaved** arm order, real 58-term glossary):

| lead | prewarm | no-prewarm control | paired benefit |
|---:|---:|---:|---:|
| 0 s | 1637.6 ms | 1647.3 ms | −21.6 ms *(placebo — clean null)* |
| 0.25 s | 1413.9 | 1646.1 | +244.2 |
| 0.5 s | 1340.0 | 1651.6 | +290.3 |
| **1 s** | **1318.8** | 1657.7 | **+299.5** (IQR 270–334) |
| 2 s | 1341.7 | 1640.6 | +308.8 |
| 3 s | 1399.5 | 1643.1 | +296.1 |
| 5 s | 1367.8 | 1812.6 | +435.2 |
| 10 s | 1892.5 | 1877.1 | −35.3 *(both cold)* |
| 30 s | 1852.8 | 1885.1 | +32.0 |
| 60 s | 1615.6 | 1928.5 | +90.3 |

**Do not derive the production win from that table.** Its design makes lead time and provider idle
time the same variable: every trial ran `create → maybe prewarm → wait(lead) → respond` back to back,
so a short-lead cell also had a provider that was generating moments earlier. The table shows the
benefit saturating at roughly `min(lead, 300 ms)` — useful for sizing the hook — but the shipped
regime (long idle, *then* prewarm, *then* a short lead) is not a cell in it. An earlier revision of
this document published +224 ms from `prewarm@60s − prewarm@250ms`; that contrast moves idle time and
prewarm placement together and has been retired.

A second experiment isolated prewarm **placement** by holding idle time constant at 30 s across all
arms — 240 accepted trials, globally shuffled schedule, 8 trials per transcript × arm, thermal state
nominal throughout, no competing model process:

| arm | what it models | median |
|---|---|---:|
| A | prewarm **before** the idle (old production) | 1849.6 ms |
| B | prewarm **after** the idle, then ~400 ms lead (shipped) | **1455.6 ms** |
| C | no prewarm at all (cold control) | 1888.0 ms |

**The shipped delta is B − A = −383.5 ms paired median** (mean −380.3, 95% CI [−399.0, −361.6],
negative on 10/10 transcripts, sign p = 0.002). Against never prewarming, B − C = −419.1 ms.

The pre-idle prepared session is *not* worthless — A − C = −37.2 ms, so it retains about 37 ms of its
benefit across 30 s. But that is roughly a tenth of what a freshly-timed prewarm delivers. The honest
statement is therefore "by 30 s idle, most of the benefit is gone", **not** "the provider evicts after
5–10 s" — this experiment does not locate an eviction threshold, and 30 s is a lower bound on
real-world idle for a menu-bar app.

On the default MLX/sidecar path recorder finalization plus ASR supplies 350–500 ms of lead, which
matches the tested ~400 ms. The hook is fired unstructured so it adds no `await` to the post-ASR
critical path.

Implementation: `SingleUsePrewarmedSessionSlot.prepareFresh()` replaces an unused stale spare rather
than no-op'ing when one is already `ready` (the old `warmUp()` could not refresh a ready slot, so
merely adding a call site would have done nothing). One fresh session per utterance is preserved, so
the no-cross-utterance-contamination privacy contract is unchanged. `swift build` clean;
**279/279 tests pass**.

### Caveats that must travel with this change

- **Backend-dependent.** On the opt-in Apple ASR backend post-stop work is only ~16 ms, so the hook
  gets almost no lead and the win largely evaporates. This is an MLX-path optimization.
- **43% of sessions skip refinement**, so the prewarm is sometimes paid for nothing. The caller-side
  return is 0.066 ms, but the asynchronous preparation work's energy cost is **unmeasured**
  (`powermetrics` requires superuser).
- **It is not strictly output-invariant.** All 220 sweep calls produced byte-identical output per
  transcript, but that is near-tautological under `.greedy`/temperature 0.0. The real falsifier:
  production wraps refine in a 3000 ms timeout (`Models.swift:149`) while Apple's p95 is 3077 ms, so
  a slice of refines currently time out into deterministic fallback. Saving ~384 ms moves that
  boundary and *will* change final text on those sessions — in the user's favour, but it is a change.

## Ranked candidates, not yet shipped

| # | Candidate | Measured win | Blocker |
|---|---|---:|---|
| 1 | Cut glossary prompt tokens | 55–464 ms | **Quality.** Every trim tested produced ≥1 worse output |
| 2 | INT8 quantized Parakeet | 32 ms @10 s, 41 ms @20 s, −1.05 GiB peak | No accuracy validation; needs a new model pin |
| 3 | Drop per-request `mx.clear_cache()` | 8–9 ms | Retains ~1 GiB Metal cache |

**1 — Glossary tokens.** The cost is real and large, and a graded menu exists: drop derived aliases
(−91 tokens, −54.8 ms), dedupe canonical-equivalent aliases (−9 tokens, −5.3 ms), cap at two aliases
per term (−159 tokens, −110.8 ms), cap at one (−322 tokens, −219.0 ms), canonical-only (−701 tokens,
−464.0 ms). All were rejected: over 49 real transcripts plus 32 curated fixtures, **every nonzero trim
produced at least one manually-classified WORSE output**, though none lost a locked protected term.
Transcript-scoping — matching glossary terms against the transcript — is a category error and the
worst performer: it matches against text ASR has *already mangled*, which is precisely the case the
glossary exists to fix (10/49 worse outputs, 2/32 new guard fallbacks). App-scoping via
`VocabularyCompiler` saves no tokens on a glossary that is entirely `scope: global`, which every
every observed target compiled all 58.

**2 — INT8.** 8-bit affine, group size 64, over the real pinned model. Faster than INT4. But no
accuracy, alignment, confidence-calibration or bias validation was run, and the repo treats model id +
revision as a compatibility contract. A 32 ms win on a ~2600 ms path does not justify a new pin
without the full ASR suite behind it.

## Dead ends, with the numbers that killed them

Documented so nobody re-litigates them.

| Idea | Result |
|---|---|
| **`@Generable` diff/patch output** instead of full rewrite | **+873 ms (+88% SLOWER)**, 30/50 patch-application failures. Constrained-decoding overhead and schema tokens swamp the decode saving |
| **Streaming Parakeet** (`transcribe_stream`, already in the installed 0.5.2) | At the production-median 10.5 s: **66 ms slower** than batch and **5.56% of words changed**. Wins only on 45 s+ audio and only at 27% WER. No depth setting achieved byte parity |
| **Session reuse for KV-prefix caching** | Turns 2–4 were 250–290 ms faster, but the transcript grows and **blows the 4096 context by turn 10**, degrading quality. Also violates the no-contamination contract |
| **Deferred replacement-prewarm blocking the critical path** | Hypothesis falsified: costs **0.292 ms** |
| Moving that replacement prewarm off-path | 2.4% *slower* |
| `prewarm(promptPrefix:)` called immediately | 0 ms |
| **Short (144-token) system prompt** | −331 ms but **2/32 command-as-text execution failures** — a safety bug, not a tradeoff |
| **Raising the `>= 40` refine trigger to `>= 100`** | 20,960 ms saved across the corpus, but only **2/10 skipped sessions were true no-ops**; the rest silently lose real edits. 137 rows, one speaker, in-sample |
| Multi-feature no-op classifier | 93.75% in-sample precision, rejected as overfit |
| Encoder `mx.compile` | Fixed-shape win 1.7 ms; unseen-shape penalty 5.9 ms. Net negative for variable dictation lengths. Padding buckets were 3.7–6.7 ms slower *and* changed transcripts |
| `mx.set_wired_limit` / residency | 0.3–1.4 ms **slower** |
| MLX 0.31.2 → 0.32.0 | 0.35 ms/request — noise. The v0.32 NAX path does not gate on this M4 (`applegpu_g16s`) |
| Precomputing log-mel during capture | Log-mel is 0.56–1.13% of inference; ~1 ms |
| **Sidecar IPC / wire-contract rewrite** | Total Swift-side overhead outside inference is **1.2–1.6 ms**. In-memory sample passing would save <0.3 ms. NDJSON health round-trip is 0.09 ms |

### The Rust and Metal question, answered directly

The request specifically asked about Rust components and driving Metal harder. The honest answer is
that neither targets the bottleneck, and the evidence is:

- **The dominant cost is inside Apple's closed-source, Swift-only Foundation Models framework.**
  `objc2`'s own contributing guide puts Swift-only frameworks out of scope; reaching it from Rust
  requires a Swift shim, which adds FFI and removes nothing. Expected win against the 87% stage: **0 ms**.
- **No Rust ML runtime ships Parakeet/TDT credibly on Metal.** `candle` 0.11 has no Conformer/TDT
  model at all, and its Metal GEMM is an explicit port of MLX's `steel_gemm_fused` — so hand-written
  Rust kernels would be racing MLX's own kernels. `burn` has the backends but no model. `mistral.rs`
  and `ratchet` have neither. The one credible spike is `parakeet-rs` 0.3.7 on ONNX Runtime, whose own
  README warns "CoreML is unstable with this model" and steers to WebGPU or CPU.
- **The Rust-shaped wins are real but tiny.** The Python sidecar is already persistent, preloaded, and
  runs MLX on a dedicated thread, so a Rust rewrite reclaims only interpreter startup that is already
  off the hot path — measured total non-inference overhead is **1.2–1.6 ms**. Audio DSP, WAV I/O and
  VAD are all sub-millisecond here.
- **The cost is not zero.** Adding cargo to a SwiftPM build means universal-binary builds, nested
  signing and notarization for a menu-bar app whose TCC grants are already sensitive to re-signing.

`metal-rs` is deprecated in favour of `objc2-metal`; `objc2-metal` 0.3.2 does expose `MTL4*`, but even
`wgpu` 30 only *detects* `MTLGPUFamily::Metal4` without using MTL4 encoders. There is no evidence a
hand-written kernel beats MLX for anything in this pipeline.

**Verdict: no Rust component is justified.** Keep Foundation Models in Swift and ASR in MLX.

### Backend choice: keep `mlx` as default

Apple's fused streaming engine is genuinely faster post-stop — **15.9 ms vs 119 ms** for a warm MLX
sidecar on an identical 10.56 s WAV (86.6% lower), because it transcribes during capture.

It stays opt-in anyway, but the evidence is weaker than it first appeared and this document will not
overstate it:

- LibriSpeech head-to-head is **+0.2247 pp U-WER** (`20260717T132024Z` mlx, 2.845%, 128 rows vs
  `20260717T132040Z` apple-speech, 3.070%, 64 rows) against a +0.35 pp gate. That is a pass, but the
  runs are not row-matched and the delta is inside noise at that sample size.
- The TechTerms regression (+6.73 pp, canonical-term recall 7/11 → 3/11) is **inadmissible under the
  repo's own policy**: `docs/benchmarks.md` states TTS rows "must not be used as evidence for …
  technical term accuracy, or the production gate", and exact McNemar on a 4-utterance difference
  gives p ≥ 0.125.
- A production-data comparison suggesting Apple was 8.5x faster (58 ms vs 492.5 ms) is **confounded and
  must not be repeated**: those 43 sessions record no `captureMs`, average 19 words vs 40, and come
  from a 3-day July evaluation window.

So: keep `mlx` as **status quo, not as a demonstrated accuracy win** — the only admissible comparison
is a non-row-matched LibriSpeech pass inside noise, and the jargon evidence that would actually
justify a preference is inadmissible. Treat the default question as **unsettled pending the consented
real-speaker TechTerms corpus** that `docs/benchmarks.md` already says does not exist.



## What would actually move the needle next

Ranked by expected value, not by ease:

1. **Make the 29.2% no-op refines free.** They are the largest identified waste and no shipped change
   touches them. A cheap classifier was rejected as overfit on 137 single-speaker rows — the blocker is
   *data*, not technique. Persisting per-session refiner-input text plus the corrected labels would
   build the corpus as a by-product of normal use.
2. **Attack prefill, not decode.** 1,762 in / 59 out is the real structural inefficiency. Every
   prompt-shrink tested traded quality; the untested lever is a **trained LoRA adapter**
   (`SystemLanguageModel.Adapter`, present in the 26.5 SDK) to replace the 677-token instruction block
   with weights. Apple explicitly recommends adapters "for lower inference latency when a
   prompt-engineered solution requires lengthy prompts". Costs are real: ~160 MB, Background Assets
   packaging, retraining per system-model version, and the 26.0.0 toolkit is explicitly incompatible
   with OS 27+.
3. **Instrument before optimizing further.** *Done (2026-08):* the end-to-end span (defect 4) and the
   sidecar's `timings_ms`/`backend_id` are both persisted per session. Several days of this
   investigation went into reconstructing numbers the app could simply have recorded.
4. **Question the premise.** p95 refine is 5426 ms while p50 is 2257 ms; the tail is where users
   actually suffer, and nothing here targets it. More fundamentally: with 29.2% no-ops and 8.56% of
   emitted words differing, it is worth asking whether refinement earns 2 seconds on every utterance,
   or whether it should become an explicit on-demand action for the transcripts that need it.

## Reproducing this

- Stage latencies: run the app and read your own `SessionStageTimings`, which every session persists.
  The 353-session table above came from one contributor's private history and cannot be reproduced from
  this repository; nothing here reads or ships a session store.
- Single-utterance ASR latency without a corpus: `scripts/make_fixture.sh`, then
  `cd asr && uv --no-config run python ../scripts/phase0_asr_proof.py ../fixtures/audio/hello_16k_mono.wav`.
- Accuracy/latency tiers and gates: `docs/benchmarks.md`; compare with
  `voiceoour_bench.compare … --gate uwer_final:0.0035`.
- Foundation Models timing: build a standalone harness against the `FoundationModels` framework and
  replicate `RefinerPolicy.onDeviceSystemPrompt` + `RefinerPolicy.ompUserMessage` verbatim; use
  `SystemLanguageModel.tokenCount(for:)` for token counts rather than character estimates.
- **Run one model benchmark at a time.** Concurrent Metal work distorted results by 130 → 230 ms
  during this investigation. Every headline number here was re-run under an exclusive hardware window.
