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

**Stop awaiting the system-audio fade before transcribing.** `SystemAudioMuter.restore()` ramps the
user's volume back over `fadeDuration = 120 ms` and awaits every step, and `processStop` awaited it
immediately after `recorder.stop()`, before the ASR call. The journal quantifies the cost without
needing new instrumentation: taking `stopReleaseToInsertionOutcomeMs - asrMs` as non-ASR overhead,
restricted to `parakeet-mlx` sessions where refinement was skipped, and splitting on
`mutedDuringCapture` — the only variable left — gives **199 ms p50 muted (n=92) against 72 ms
unmuted (n=13)**. The 127 ms difference is the fade. 80.1% of real-backend sessions were muted, so
four out of five dictations paid it, in front of an inference that takes 117.8 ms.

The fade now starts on the stop path and ramps under the transcription instead of in front of it
(`beginSystemAudioRestore()`), which is safe because the restore was already idempotent per session
and already stored its in-flight task for later joiners. Pinned by
`recordingStopDoesNotWaitForTheAudioFadeBeforeTranscribing`, which gates `restore()` and asserts the
coordinator reaches `.transcribing` while the fade is still parked; the test was confirmed to fail
when the `await` is put back. Note the aggregate muted-vs-unmuted figure across all backends is only
38 ms and is confounded by backend mix — segmenting within one backend is what makes this legible,
and is why the earlier ~120 ms figure was a reading of `fadeDuration` rather than a measurement.

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
| **Streaming Parakeet** (`transcribe_stream`, already in the installed 0.5.2) | Closed 2026-08-14 with a 9-config sweep, FLEURS n=64. There is **no operating point**. See "Streaming Parakeet has no operating point" below for the full grid; the short version is that the only config whose accuracy survives (`L256 R256`, U-WER 5.840% against batch 4.416%) has a **179 ms** residual against batch's 118 ms, and every config fast enough to beat batch costs 50-80 pp of U-WER. Supersedes the earlier one-line result (66 ms slower, 5.56% of words changed) |
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

- LibriSpeech head-to-head, **row-matched** at n=128 (2026-08-11, `20260811T114019Z` mlx 2.845% vs
  `20260811T114143Z` apple-speech 3.133%): **+0.288 pp U-WER**, a pass against the +0.35 pp gate.
  This replaces the 2026-07-17 pass, which compared 128 mlx rows against 64 Apple rows.
- FLEURS, row-matched at n=64 (`20260811T114301Z` mlx vs `20260811T114320Z` apple-speech): **+1.71 pp
  U-WER** (4.416% vs 6.125%), F-WER 10.284% vs 12.997%, case F1 0.921 vs 0.848 — a clear fail against
  the same gate, and a reversal of the n=8 FLEURS result that previously read as an Apple win.
  Punctuation micro-F1 is the one axis Apple still takes, 0.870 vs 0.833.
- Apple's batch-latency advantage has **evaporated**: ASR p95 is now 348 ms (mlx) vs 802 ms (Apple) on
  LibriSpeech and 167 ms vs 236 ms on FLEURS. The 2327 ms Parakeet tail recorded in July predates the
  persistent preloaded sidecar; measuring it again is the only way that claim stays true.
- The TechTerms regression (+6.73 pp, canonical-term recall 7/11 → 3/11) is **inadmissible under the
  repo's own policy**: `docs/benchmarks.md` states TTS rows "must not be used as evidence for …
  technical term accuracy, or the production gate", and exact McNemar on a 4-utterance difference
  gives p ≥ 0.125.
- A production-data comparison suggesting Apple was 8.5x faster (58 ms vs 492.5 ms) is **confounded and
  must not be repeated**: those 43 sessions record no `captureMs`, average 19 words vs 40, and come
  from a 3-day July evaluation window.

So: keep `mlx`, now on **row-matched read-speech evidence** rather than status quo alone — it wins
U-WER, CER, F-WER, case F1 and batch latency on both tiers, and loses only punctuation micro-F1. What
is still missing is the axis that actually decides a dictation default: neither tier is real-speaker
dictation audio, and the jargon evidence that would settle it remains inadmissible. Treat *jargon and
real-speaker accuracy* as **unsettled pending the consented real-speaker TechTerms corpus** that
`docs/benchmarks.md` already says does not exist.

### ASR model swap: ARK-ASR 0.6B and 3B, measured, shipped opt-in, not promoted to default

Investigated 2026-08-13 on the same M4 Pro, `mlx==0.32.0`, because ARK-ASR-3B sits at **4.636%** avg
cleaned WER on the live HF Open ASR Leaderboard against **5.661%** for our pinned
`parakeet-tdt-0.6b-v3` — a 1.03 pp edge that looked worth 3B of weights. It does not survive contact
with this app's corpora or its latency budget.

Both sizes were run through the community MLX conversions `leope/ark-asr-0.6B-mlx` and
`leope/ark-asr-3B-mlx` (Apache-2.0, BF16, parity-validated against upstream PyTorch: identical greedy
token IDs, initial-logit cosine 0.9999). Every row was scored with this repo's own
`voiceoour_bench.metrics`, and Parakeet was re-run in-process with identical staging so the comparison
comes down to the models. That control reproduced the committed FLEURS row exactly — U-WER 4.416%,
F-WER 10.284%, case F1 0.921 — which is what makes the ARK columns trustworthy.

The latency figures were later re-confirmed through the **production path** rather than in-process,
by driving the real sidecar over its real stdio protocol (FLEURS, n=32, warm): Parakeet round trip
p50 **119.9 ms**, ARK-0.6B **322.3 ms** — ARK 2.7x slower, on the identical transport. The mechanism
tax is 0.8-0.9 ms p50 for both, so the sidecar is not confounding the comparison in either
direction; see `docs/architecture.md` for that measurement.

Two of the four tiers are admissible as accuracy evidence. `techterms` and `smoke` are local macOS
`say` synthesis, which `docs/benchmarks.md` labels `evidence_scope: smoke-only` and forbids as
evidence for "technical term accuracy, or the production gate"; they appear below for plumbing and
latency only, and no conclusion here rests on them. The LibriSpeech row is **row-matched at n=112**:
ARK rejects audio over 30 s, so Parakeet is re-scored on the same 112 rows rather than compared
across corpora of different size. Those excluded 16 rows are the hard ones — Parakeet scores 3.518%
on them against 2.716% on the 112 it keeps — so leaving them in would have flattered ARK.

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

Four findings kill it, and they are independent:

1. **The leaderboard edge does not transfer.** On the two admissible tiers ARK-0.6B is a wash:
   +0.214 pp on FLEURS (4.202% vs 4.416%) and −0.209 pp on LibriSpeech (2.925% vs 2.716%), two
   near-identical deltas pointing opposite ways. The published 0.52 pp advantage is not visible.
   ARK-3B *does* win accuracy on both — 0.784 pp and 0.522 pp — and is disqualified by findings 2 to
   4 rather than by word error. The TTS tiers happen to run the same direction (ARK-0.6B −1.92 pp on
   TechTerms, level on Smoke) but are inadmissible and are not counted.
2. **Parakeet is faster on every tier**, by 1.2x on short utterances up to 2.8x on read speech, and
   this is structural rather than an artifact of the port: ARK's audio preprocessing is ~7 ms once
   warm, and its cost is a 32-layer 1280-dim Whisper encoder plus autoregressive decode, against a
   transducer that emits in one pass. ARK-3B is 4x to 9x slower.
   Quantizing the decoder cannot rescue this, and the FLEURS stage split says why: ARK-0.6B spends
   6.9 ms in preprocessing and **146.8 ms in encoder-plus-prefill** before it emits a single token,
   against **154.7 ms for all of Parakeet**. Even with decode driven to zero the encoder alone costs
   what the incumbent costs end to end. Quantizing the encoder instead is not the escape hatch either:
   mlx-audio's `model_quant_predicate` for this model family deliberately excludes `audio_tower` and
   the projector and quantizes only the decoder, so the tower stays BF16 by convention.
3. **ARK-3B does not emit capitalization**, spells numbers as words, and drops most internal
   punctuation: "twenty-five to thirty" for "25 to 30", case F1 **0.000**. Its word accuracy is
   genuinely the best measured here, and its *user-visible* error rate is the worst of the three —
   F-WER 23.470% against Parakeet's 10.284%. This is upstream behaviour, not a conversion defect;
   the port's `VALIDATION.md` reference output is itself lowercase and unpunctuated. A dictation app
   pastes the string verbatim, so F-WER is the metric that matters and restoring case and digits
   would cost another model pass.
4. **ARK-3B needs 7.1–7.7 GB resident** on a 24 GB machine that also has to hold the refiner.

Two capability losses would apply to either size. ARK returns plain text only — no word alignments,
no per-word or aggregate confidence, no n-best. `RiskAuthorizer` requires calibrated confidence plus
n-best agreement before it will replace a term, so an ARK backend silently disables automatic term
correction (it degrades to suggest/keep, which is safe but strictly less useful), and the phrase-trie
shallow-fusion glossary path has no transducer beam to hook into. ARK also hard-rejects audio over
30 s with no chunking or VAD of its own; 16 of 128 LibriSpeech rows had to be skipped, where Parakeet
transcribed all 128.

**Both sizes are shipped as opt-in backends, because the measurement above is not the same thing as
living with a model.** Select `ARK 0.6B` or `ARK 3B` in the Voice pane, or run
`--asr-backend ark-0.6b`; `mlx` remains the default and nothing changes unless you pick one.
Benchmark them against the incumbent on identical rows with
`make bench-stt BACKEND=ark-0.6b N=64` — reports are now named per backend, so an A/B of the same
tier no longer collides on timestamp alone.

The shape is a second Python backend in the existing sidecar (`asr/src/voiceoour_asr/backends/ark.py`
behind `VOICEOOUR_ASR_BACKEND=ark-0.6b|ark-3b`), with the ARK MLX runtime **vendored verbatim** under
`backends/ark_mlx/` rather than imported from the model repo, so the app never executes code
downloaded from Hugging Face. Model identity became per-descriptor along the way, which removed three
standing assumptions that there is exactly one model: `cache.py`'s single `MODEL_ID`,
`SidecarASRClient`'s hardcoded `ASRModelContract` (it was telling even the `fake` backend to expect
Parakeet), and `BenchMain.meta`'s Apple-or-Parakeet ternary, which would have labelled every ARK
benchmark run as Parakeet.

Not native Swift/MLX: mlx-swift 0.31.6 needs swift-tools **6.3** against our 5.9, the newest
5.9-compatible tag is 0.23.1, MLX Swift cannot build its Metal shaders under the SwiftPM CLI at all —
it requires Xcode, which this repo's shell-first build deliberately avoids — and no licensed Swift ARK
implementation exists to vendor (the one the model card links is absent from the repository, and that
repository carries no licence). Not GGUF or Rust either: llama.cpp's `mtmd` has no `arkasr` graph or
converter, and Candle's own Voxtral example forces CPU on non-CUDA builds.

**What would reopen this.** An ARK release that emits punctuation and case at 3B quality *and* lands
under ~350 ms p50 on 10 s of audio; or the consented real-speaker TechTerms corpus showing a jargon
win large enough to pay for the latency. On the current evidence the more interesting candidates are
elsewhere on that leaderboard: `ibm-granite/granite-speech-4.1-2b-nar` (4.95% WER at RTFx 2079, a
non-autoregressive CTC-plus-LLM editor, i.e. one forward pass rather than a decode loop) and
`Qwen/Qwen3-ASR-1.7B` (4.98%, streaming, with a companion forced aligner for the timestamps ARK
cannot give us).

### Streaming Parakeet has no operating point, and the reason generalises

Measured 2026-08-14, M4 Pro, FLEURS n=64, one process, batch and every streaming config warmed
before timing, audio decoded up front so no `ffmpeg` lands inside a measurement.

The earlier dead-end entry compared *total* streaming compute against one batch pass. That is the
wrong metric: streaming's entire claim is that the encoder runs while the user is still talking, so
what a user waits for is the **residual** — the last `add_audio()` call after the hotkey is released.
This sweep reports both, and it also sweeps `context_size`, which the earlier attempt left at the
default `(256, 256)` (a 20.48 s unfinalized tail, since the units are 80 ms encoded frames).

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

Two findings, and the second is the useful one.

**The mechanism works.** Residual falls from 117.8 ms to **46 ms** as the context shrinks, and every
streaming config runs at 4-21x real time, so the encoder comfortably keeps up during capture. The
*architecture* — overlap the encoder with capture, pay only the last chunk at release — is sound and
lands squarely in Apple SpeechTranscriber's measured 66 ms ASR territory.

**The checkpoint cannot pay for it.** Accuracy collapses from 4.4% to 55-85% U-WER. This is not a
harness artifact; the output degrades into coherent-but-wrong phonetics
("All nouns I world say for you always begin with a cap little letter of a scent with a sea"), which
is a model decoding out of distribution rather than crashing. `parakeet-tdt-0.6b-v3` is
**full-context trained** (non-causal ALiBi), and `transcribe_stream` swaps the encoder to
`rel_pos_local_attn` with the given window. Only `L256 R256` keeps accuracy, and it does so precisely
because 256 frames x 80 ms = 20.48 s is longer than the whole utterance, i.e. it is not really
streaming — and it is *slower* than batch anyway. So the two requirements are mutually exclusive on
this checkpoint, which closes the question rather than deferring it.

**The consequence.** Getting Apple's latency means a checkpoint **trained** for streaming, and the
residual numbers above are the payoff to expect (~46-64 ms). Candidates that are genuinely
streaming-trained *and* runnable on this Mac, in order of fit:

| candidate | size | lookahead | licence | Apple runtime | timestamps / confidence |
|---|---|---|---|---|---|
| `moonshine-ai/moonshine-streaming-medium` | 245M / ~289 MB ORT | 80 ms | MIT | official C++ core + ONNX Runtime 1.23.2 arm64 | word timestamps real; **confidence is a hardcoded 1.0** (see below) |
| `nvidia/nemotron-speech-streaming-en-0.6b` | ~700 MB q8_0 GGUF | 80-1120 ms | NVIDIA Open Model | NeMo-Speech.cpp, Apache-2, Metal | timestamps yes; **word confidence is a 1.0 placeholder** |
| `kyutai/stt-1b-en_fr-mlx` | ~1 GB BF16 | 500 ms delay | CC-BY-4.0 | MLX-native (`moshi-mlx`) | word timestamps; no confidence |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` | 4.42 GB int4 | 80-2400 ms | Apache-2 | ExecuTorch Metal | neither |

**Moonshine was built and probed 2026-08-14, and it is not ready.** Upstream commit
`06f74196`, native C++ core with a bundled ONNX Runtime 1.23.2 arm64 dylib, MIT, model release
`medium-streaming-en/quantized_26_07_30` (291 MiB core, 431 MiB total download, warm RSS 1.5 GB,
first session load 240 ms). Its latency profile is genuinely outstanding — smoke residuals of
**4.5, 4.5 and 37.2 ms** against our 117.8 ms, and ~750 ms total for a 10 s clip, so ~14x real time.
Word timestamps are real (19-20 aligned words per utterance) and volatile partials exist. Two things
stop it:

1. **Its confidence is a lie in the same way Nemotron's is.** The public header documents a 0..1
   per-word confidence, but `core/word-alignment.cpp:366-369` unconditionally assigns
   `tw.confidence = 1.0f; // default confidence`, and every observed word was 1.0. This invalidates
   the earlier claim in this document that Moonshine was the one candidate whose confidence could
   keep `RiskAuthorizer`'s replace path alive. It cannot.
2. **Sequential utterances in one process corrupt.** The third clip decodes truncated and garbled
   when it follows two others in the same process, and is correct when run alone. Disabling word
   timestamps, disabling speculative decoding, reusing the stream, and warming on the longest clip
   all failed to fix it. That is an upstream inter-utterance state or reset defect, and a persistent
   process transcribing one utterance after another is exactly what a dictation app is, so no
   corpus sweep was run.

The generalisable lesson, now seen twice: **a documented capability is not a capability.** Both
Moonshine and Nemotron advertise per-word confidence in their public API and both hardcode 1.0 in the
implementation. Any backend's evidence claims must be verified against its source or against a
falsification probe (constant confidence, uniformly spread timestamps), never against its header.
Nemotron remains the better-WER candidate with the same confidence defect; `kyutai/stt-1b-en_fr-mlx`
is the remaining untried option and is MLX-native, which suits this repo.

**Kyutai was built and measured 2026-08-14, and it loses on its own terms — which closes the
streaming question.** `kyutai/stt-1b-en_fr-mlx` is MLX-native, so it needed no new runtime here, and
its central risk was the documented 500 ms delay. That risk is answered definitively: the tail **can**
be flushed faster than real time. `moshi_mlx` stepping has no clock at all — `LmGen._step` counts an
integer `step_idx` (`moshi_mlx/models/generate.py:60-114`), upstream's own file script drives it with
a bare unpaced loop, and the only pacing anywhere in the tree is the microphone. Feeding zero-padding
drains the delay at **~17.6 ms per 80 ms block, i.e. 4.5x real time**, independently reproducing
Kyutai's own "500 ms becomes ~125 ms at 4x" claim, and words genuinely fall out of the pad steps at
the indices the 6.25-block delay predicts.

And it still loses: 7 flush blocks x 17.6 ms puts residual at **141 ms**, against Parakeet batch
inference at **117.8 ms**. Indicative accuracy on 3 rows was 9.59% against Parakeet's 4.416% U-WER.
Two operational notes for anyone revisiting it: the flush must be bounded at `ceil(500/80) = 7`
blocks, because padding past ~13 makes it hallucinate text out of pure silence, and its confidence is
discarded rather than absent — `sampling.py:147` computes a full log-softmax and `lm.py:465` throws it
away into `_`, so it is recoverable through the private `_step` plus one extra `text_linear` matmul.

**Synthesis across all four candidates.** Streaming does not pay for utterances this short, and the
reason is structural rather than a property of any one model. A whole-utterance decode costs 117.8 ms
*once*; a streaming model must drain its trained delay before it can finalise, and that drain
(141 ms for Kyutai at 4.5x) is the floor no amount of runtime work removes. The only candidate whose
residual genuinely beat batch was Moonshine at 4.5-37 ms, and it is blocked on a hardcoded confidence
and on corrupting sequential utterances in one process. So: **stop pursuing streaming for the current
utterance profile.** It becomes interesting again only if capture lengths grow substantially, if a
streaming checkpoint appears with both real confidence and clean sequential behaviour, or if we start
wanting live partial text on screen during capture as a product feature rather than as a latency
trick — which is a different justification and should be argued on its own merits.

### Runtime bake-off: is a non-Python runtime faster? Rust, no. C and CoreML, yes.

Measured 2026-08-13, M4 Pro, FLEURS n=64, every leg run **serially under an exclusive hardware
window** and scored with `voiceoour_bench.metrics`. Warm in every case: model resident, kernels
compiled, two discarded warm-up passes, model load reported separately and never inside a row.

**Framework question, isolated.** Whisper large-v3-turbo is the one non-trivial ASR architecture
MLX, Candle and whisper.cpp all implement, so it is the controlled comparison. Decoding was matched
leg-by-leg against Candle's actual behaviour — greedy, no beam, language forced to `en`,
`condition_on_previous_text` off, `suppress_blank` off, and `compression_ratio_threshold` disabled
because Candle sets that field to `NaN` and never computes it, making its fallback branch dead code.

| runtime | U-WER | ASR p50 |
|---|---:|---:|
| **MLX (Python)** | 4.274% | **435 ms** |
| whisper.cpp (C/Metal) | 3.989% | 495 ms |
| Candle (Rust/Metal) | 4.274% | **960 ms** |

Candle is **2.2x slower than Python/MLX on identical weights and identical decoding**. The GPU is
provably engaged: the same binary on `--cpu` at the same dtype takes 8145 ms against 999 ms on
Metal. A second tell that this is kernel quality rather than configuration — going f32 to f16 buys
Candle only ~10%, where a compute-bound GPU should give far more. Candle and MLX agreeing to three
decimal places on U-WER is the check that the A/B was fair.

Two further facts kill Rust as a route rather than merely losing on speed. Candle 0.11.0 **does not
compile its own Whisper example** as released: `candle-examples` requests symphonia 0.6 while its
`audio.rs` is written against the 0.5 module layout. And Rust has **no Parakeet TDT and no ARK
implementation at all** — `candle-transformers` audio is csm, dac, encodec, metavoice, mimi,
parler_tts, snac, voxtral, whisper; mistral.rs has no C ABI and no transducer; `parakeet-rs` is an
ONNX Runtime wrapper, not native. Choosing Rust means writing the model *and* being slower.

**Same-model, different-runtime.** whisper.cpp upstream now ships a native Parakeet TDT
(`libparakeet`, MIT, plain C ABI, Metal) running the same `parakeet-tdt-0.6b-v3` checkpoint we
ship, and FluidAudio ships it as CoreML for Swift. Both are directly comparable to production.

| runtime | U-WER | CER | p50 | p95 | Python? |
|---|---:|---:|---:|---:|---|
| MLX sidecar (today) | 4.416% | 1.966% | 119.9 ms | — | yes |
| parakeet.cpp (C/Metal) | 4.416% | 1.929% | **88.4 ms** | 123.1 ms | no |
| FluidAudio (CoreML/ANE) | **3.989%** | **1.892%** | **71.5 ms** | 86.3 ms | no |

**Ordering-controlled 2026-08-14.** The five legs above ran serially in one long window, so whichever
ran last met the hottest machine. Re-measured MLX and parakeet.cpp in ABBA order, three rounds, six
runs each: parakeet.cpp p50s spanned 87.6-89.5 ms (spread **1.9 ms**), MLX 142.3-146.2 ms (spread
**3.9 ms**). The effect is **7.5x the worst within-tool spread**, so it is not thermal drift.
That re-run also exposed a confound in the re-run itself, worth recording because it inflates any
in-process MLX comparison: the harness called `parakeet_mlx.audio.load_audio`, which **shells out to
`ffmpeg`** (28.6 ms p50 here), while production uses the `load_pcm16_mono_wav` fast path and
parakeet.cpp reads the WAV directly in 0.19 ms. Comparing inference only, MLX is 117.3 ms against
parakeet.cpp 88.0 ms — a 25.0% gap, which is what the 119.9/88.4 row already said. The table stands.

Both beat the incumbent, and both delete Python. `parakeet.cpp` reproduces our U-WER to three
decimals — it is the same model and the same greedy TDT decode — and it still exposes word
timestamps and real per-token posteriors, so `RiskAuthorizer` would keep working. FluidAudio is
fastest and scores best, on the Neural Engine rather than the GPU, which should also help battery.

The one caveat worth keeping: across 64 rows FluidAudio has **one more contiguous multi-word
dropout** than parakeet.cpp (2 runs vs 1). Its aggregate word operations are otherwise better
(34 substitutions / 14 deletions / 8 insertions against 39/15/8). The 4-word dropout on
`fleurs-en_us-test-000048` occurs in *both* runtimes and is therefore the model, not the runtime.
Silent deletion at high reported confidence is the failure mode dictation can least afford, so this
deserves a larger sample before FluidAudio is trusted as a default.

**The bigger lever is not the runtime.** From 500 real sessions on this machine, segmented by
whether refinement ran: with refinement skipped, release-to-inserted is 316 ms for `mlx` against
**184 ms for `apple`**, whose ASR stage is 66 ms — because SpeechAnalyzer transcribes *during*
capture rather than after the key is released. `parakeet-mlx` already exposes `StreamingParakeet`
and `transcribe_stream` and we do not use either. Streaming Parakeet during capture would attack
the whole post-stop ASR stage rather than the 30-40% a runtime swap wins, and it composes with
either runtime above. That, not the language the decoder is written in, is where the remaining
latency is.



## What would actually move the needle next

Ranked by expected value, not by ease:

0. **Evaluate a streaming-TRAINED checkpoint. The streaming mechanism is now measured and works; our
   checkpoint is what fails.** On 500 real sessions here, release-to-inserted with refinement skipped
   is 316 ms on `mlx` against 184 ms on `apple`, whose ASR stage is 66 ms, because SpeechTranscriber
   transcribes while the user is still speaking. The 9-config sweep above settles what that costs us:
   feeding Parakeet in chunks drops the residual from 117.8 ms to **46 ms** at 4-21x real time — the
   overlap idea is right and lands in Apple's territory — while U-WER goes from 4.4% to 55-85%,
   because `parakeet-tdt-0.6b-v3` is full-context trained and cannot decode inside a small local
   attention window. There is no operating point on this checkpoint, so the next move is a different
   checkpoint, not a different setting.
   **All four candidates were tried and the line is closed — see the synthesis above.** Moonshine has
   the only residual that beats batch (4.5-37 ms) and is blocked on a hardcoded `1.0f` confidence plus
   sequential-utterance corruption. Kyutai's flush provably works at 4.5x real time and still lands at
   141 ms against batch's 117.8 ms. Nemotron has the better WER and the same confidence defect. The
   structural reason is that a streaming model must drain its trained delay before finalising, and at
   these utterance lengths that drain costs more than decoding the whole utterance once.
   **Demote this item.** Revisit only if capture lengths grow, if a checkpoint appears with real
   confidence and clean sequential behaviour, or if live partial text becomes a product goal in its own
   right rather than a latency trick.
0b. **Or swap the ASR runtime, which is smaller but nearly free.** The bake-off above measured
   `parakeet.cpp` at 88.4 ms and FluidAudio at 71.5 ms against our 119.9 ms, both on our own model
   and both without Python. `parakeet.cpp` is the conservative pick: identical U-WER to three
   decimals, MIT, plain C ABI, and it still returns word timestamps and per-token posteriors, so
   `RiskAuthorizer` survives. Do not take FluidAudio as default until its extra multi-word dropout
   is characterised on a larger sample.
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
- ARK-ASR comparison: the harness was a scratch package outside this repository and is not committed,
  in line with the other raw artifacts here. To rebuild it, `uv` a Python 3.12 env with
  `mlx==0.32.0`, `transformers==4.57.6`, `librosa`, `jiwer` and `whisper-normalizer`; `snapshot_download`
  `leope/ark-asr-0.6B-mlx` and `leope/ark-asr-3B-mlx`; put each snapshot's bundled `src/` on
  `sys.path` and drive `ark_asr_mlx.api.ArkASR`. Iterate `benchmarks/data/<tier>/manifest.jsonl`,
  skipping rows over 30 s because ARK raises on them, and score with `voiceoour_bench.metrics`
  (`uwer`, `cer`, `fwer`, `case_f1`, `percentiles`) so the numbers stay comparable to the tables above.
  Two traps cost real time: warm up on a clip of representative length, because the first
  `librosa.load` pays a multi-second numba import that otherwise lands on row one and reads as 23 s of
  "preprocessing"; and warm up on a row under 30 s, or the warm-up itself throws.
- Foundation Models timing: build a standalone harness against the `FoundationModels` framework and
  replicate `RefinerPolicy.onDeviceSystemPrompt` + `RefinerPolicy.ompUserMessage` verbatim; use
  `SystemLanguageModel.tokenCount(for:)` for token counts rather than character estimates.
- **Run one model benchmark at a time.** Concurrent Metal work distorted results by 130 → 230 ms
  during this investigation. Every headline number here was re-run under an exclusive hardware window.
