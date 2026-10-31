# Voz (Desert Ant Labs) — external recogniser evaluation

Evaluated 2026-09-04 at tip `aafb589b`. Sources: <https://huggingface.co/desert-ant-labs/voz>
at pinned tag `v0.1.0` (`8e7ab8ca342c6bb00f9347a25e53fe44543b2a40`), the SDK at
<https://github.com/Desert-Ant-Labs/desert-ant-core> at `v3.1.0`, and the licence at
<https://license.desertant.com/1.0>.

> **Verdict: do not adopt; do copy two of its techniques.** Do not add `desert-ant-core` as a
> package dependency and do not vendor Voz's artifacts into the sidecar. Voz is the same
> NVIDIA Parakeet TDT 0.6B v3 checkpoint this app already pins, exported to a 6-bit
> palettized Core ML graph — the artifact class bet 2 already built, measured,
> real-speech-validated and committed behind `VOICEOUR_COREML_ENCODER`.
>
> Measured here rather than argued: **Voz's encoder is 17.8% faster than our own palettized
> standard tier on this M4 Pro** (25.07 vs 30.50 ms p50, ratio 0.822 across three runs) while
> doing strictly more work and returning 3.2× fewer bytes. That is a real finding and it does
> not change the verdict — it is 5.4 ms on a 107 ms pipeline, and the two mechanisms that
> plausibly explain it (fp16 IO across the Core ML boundary, and fusing the joint's 1024→640
> projection into the encoder graph) are ours to apply to our own artifact for free. Adoption
> would still cost a macOS 14 fallback, a second vendor patch for the 640-channel output, a
> weaker download-integrity contract, and CC BY 4.0 traded for a source-available licence with
> an audit clause — to buy 5% of one stage. **Take the techniques, not the dependency.**

## What Voz actually is

Same weights, different container. `THIRD_PARTY_NOTICES.md` at `v0.1.0` states Voz derives
from NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0), converted NeMo/PyTorch → compiled Core ML with
6-bit palettization and a restructured encoder/frontend/decoder, and that "weight values are
otherwise unchanged". Voiceour pins the same checkpoint through `ggml-org/parakeet-GGUF`
revision `35156454d1a39de06863303dd209fd2bed6ee079`.

Read off the shipped artifacts rather than the marketing page:

| property | value | source |
|---|---|---|
| encoder signature | `func main<ios18>(key_bias fp16[1,188,1,1], mel fp16[1,128,1,1500], pad_mask fp16[1,1,1,188]) -> enc_proj fp16[1,640,1,188]` | `encoder.mlmodelc/model.mil` |
| weight compression | `constexpr_lut_to_dense` over `uint6` indices, group 64 — 6-bit palettization | `encoder.mlmodelc/model.mil` |
| decoder signature | `func main<ios18>(c_in[16,1280,1,1], embed[16,640,1,1], enc_step[16,640,1,8], h_in[16,1280,1,1]) -> logits[16,8198,1,8], h_out, c_out` | `decoder.mlmodelc/model.mil` |
| window | fixed 15.0 s / 240,000 samples → 1500 mel frames → 188 encoder frames | `meta.json` |
| deployment target | `iOS18` (Core ML specification version 9) | `meta.json`, MIL `<ios18>` |
| encoder weights | 460,717,376 B, SHA-256 `afdc12527e014af6a92f8ca9f62884cd31e5e4ad9835e8bf54f5cf7605259179` | HF tree API at `v0.1.0` |
| repository total | ~488 MB across 18 files (encoder 460.7 MB, decoder 15.8 MB, embedding 10.5 MB, mel 0.83 MB) | HF tree API at `v0.1.0` |

Two structural facts matter more than the size. First, the encoder graph has the joint's
encoder-side linear (640×1024) **fused into it**: its output is `enc_proj` at 640 channels,
not raw encoder states at 1024. Second, the decode step is lane-batched sixteen ways, which
is a throughput design for long files — a dictation utterance fills exactly one lane.

## Measured on this Mac, 2026-09-04

Voz's encoder was benchmarked head-to-head against our own palettized standard tier, because
the objective was a speed question and the vendor's figures are single-machine and
cross-hardware. Desert Ant's licence §4 expressly permits benchmarking to decide adoption.

Apple M4 Pro, macOS 26.6.2 (25G83), Swift 6.3.3. Both artifacts are specification-version 9
(`func main<ios18>`), both loaded `MLComputeUnitsCPUAndNeuralEngine`, both driven through
`outputBackings`, both a fixed 15 s window. Identical deterministic mel content fed to both.
Three runs, each 4 interleaved ABBA blocks × 30 timed predictions, after one warm-up:
720 timed predictions per model per occupancy case. Harness and artifacts:
`.build/asr-research/voz-eval/` (untracked). Voz's three LFS digests were verified against
the values the Hub publishes for `v0.1.0` before any measurement.

| | ours (palettize6 standard) | Voz `v0.1.0` |
|---|---:|---:|
| warm prediction p50, full 15 s window | 30.50 / 30.53 / 30.52 ms | **25.07 / 25.08 / 25.09 ms** |
| warm prediction p50, ~6 s speech in the window | 30.50 / 30.50 / 30.44 ms | **25.06 / 25.08 / 25.06 ms** |
| ratio Voz/ours, three runs | — | **0.8220 / 0.8216 / 0.8220** |
| warm load | 73.5–94.1 ms | 73.4–77.2 ms |
| cold load (ANE specialization) | 17,486 ms | 16,174 ms |
| bytes returned per window | 770,048 (fp32 1024×188) | **240,640** (fp16 640×188) |

Sanity-checked rather than assumed: both graphs return finite, non-degenerate activations
(ours min −0.0570 max 0.0693 sd 0.0112 over 192,512 values; Voz min −0.7749 max 1.1826
sd 0.0989 over 120,320 — the wider range is the joint projection Voz has already applied).
Neither short-circuits: the ~6 s case costs exactly the same as the full window on both,
which independently reproduces bet 2's constant-cost finding on a second artifact family.

**Voz's encoder is 17.8% faster than ours while doing strictly more work** — its 25.07 ms
includes the joint's 1024→640 encoder projection that our tail performs separately
afterwards. It also hands back 3.2× fewer bytes. This corrects the earlier reading of the
vendor's published figures; at the encoder stage the advantage is real and reproducible.

Three candidate causes, in the order they should be tested:

1. **Compiler generation.** Ours was built with coremlc 3520.5.1, Voz with 3600.25.2. This is
   a live confound and the cheapest to eliminate: re-export our encoder unchanged on the
   current toolchain and re-measure.
2. **fp16 IO.** Our graph's final op is an explicit `cast` of a [1,1024,188] tensor from fp16
   to fp32, and we then copy 770 KB across the boundary per window. Voz emits fp16 and copies
   235 KB.
3. **Fused joint projection.** Narrowing 1024→640 inside the graph shrinks the cast and the
   copy, and removes per-token projection work from the tail that this benchmark does not
   even capture.

What it is worth end to end: 5.4 ms on a dictation pipeline whose hybrid p50 is 107 ms — about
5%, one window per utterance. Real, worth having, and not remotely large enough to carry the
blockers below. Every one of those blockers stands unchanged, and causes 2 and 3 are
techniques we can apply to our own artifact without anyone's licence.

## Why it still cannot be adopted, in order of hardness

1. **It is macOS 15 only — but so is our own ANE ladder.** `Package.swift` targets macOS 14.
   Voz's `.mlmodelc` files are specification version 9, and the vendor's open issue
   [#85](https://github.com/Desert-Ant-Labs/desert-ant-core/issues/85) says it plainly: "We
   ship a precompiled .mlmodelc at spec version 9, so macOS 14 and iOS 17 refuse to load it."
   Read honestly, this is not a Voz defect: our own `parakeet_encoder_6bit.mlmodelc` is
   `func main<ios18>` too, and the ladder is default-off and fail-closed precisely so a
   macOS 14 user simply never routes through it. The blocker is therefore shared, and it
   argues against Voz only in that Voz cannot be the *fallback* — our GGUF/Metal path can and
   does run on macOS 14, which is what the shipping default needs.

2. **The encoder is not the pipeline.** The 5.4 ms above is one stage. Voz's remaining speed
   story is its sixteen-lane batched decode, which is a throughput design for long files; a
   dictation utterance fills exactly one lane and collects none of it. Voz's own card gives
   50–62x real time for "single short utterances, where every clip pays for a full 15 s
   window" on an M3 Ultra — 161–200 ms for a 10 s dictation. Our committed hybrid measures
   p50 107 ms / p95 179 ms on this M4 Pro, p50 97.5 / p95 165 with the pool dial. Adopting
   Voz wholesale trades a measured 107 ms pipeline for an unmeasured one, to win 5% of a
   stage. Voz's single 15 s tier also forfeits the 6/8/15 s ladder that answers the 29.3%
   padding waste bet 2 measured.

3. **It cannot be more accurate, because the weights are identical.** Voz reports 7.40%
   average WER over six Open ASR Leaderboard sets against Whisper large-v3-turbo's 7.00% —
   a statement about Parakeet TDT 0.6B v3, not about Voz. Its one deviation from the
   checkpoint is 6-bit palettization, which run 68 measured here at +0.0002 U-WER. The
   honest expectation is accuracy-neutral-to-marginally-worse against our f16 artifact.
   Voz's leaderboard figures and our U-WER figures are not comparable in either direction:
   different corpora subsets, different normalizers, different metric.

4. **The one advertised capability we lack, we already have.** Word-level timestamps come
   out of `TokenMapping.transcript(from:)`, which groups TDT tokens into words carrying
   start, end and per-word confidence, and they are already on the wire as
   `ASRSegment.words`. `TranscriptProcessingPipeline` consumes them for History's
   least-sure word. Voz trims word ends against the audio where we do not; for text pasted
   into a focused control that is worth nothing.

5. **It is not a drop-in for the seam we built.** `CoreMLEncoder` feeds `mel` as float32
   `[1, 128, capacity]` plus an int32 `mel_length`, and reads back 1024-channel encoder
   states which the native ggml tail then projects itself. Voz wants fp16 rank-4 `mel` with
   separate `key_bias` and `pad_mask` tensors, and hands back the already-projected 640
   channels. Routing Voz's encoder into our tail needs a second vendor patch that suppresses
   parakeet.cpp's own joint encoder projection — new numerics to validate, on a graph whose
   internals are a third party's to change.

6. **It weakens the model-pin contract.** `ParakeetModelCache` requires the full manifest
   (id, revision, file, sha256, size) to match and verifies the digest before use.
   Desert Ant's `ModelStore` maps only the LFS `oid` into a comparable SHA-256; plain
   git-tracked files get a size check and a locally computed hash recorded after the fact.
   `encoder.mlmodelc/model.mil` — 821 KB, the entire graph program — is in that second
   class. We would be relaxing a verified-before-use contract to a size check on the code
   that runs.

7. **Licence and governance move the wrong way.** Today the weights are CC BY 4.0 from
   NVIDIA. The Desert Ant Source-Available Licence 1.0 adds: a 100k monthly-active-device
   cap per model per platform (§3), a covenant against using outputs or logs to train a
   competing on-device model (§6), mandatory "Powered by Desert Ant Labs" attribution in a
   discoverable place (§9), a right to audit and to demand written certification of
   compliance (§11), and Netherlands law with exclusive Amsterdam jurisdiction (§15). The
   free tier is generous and the terms are not unreasonable — they are simply a strictly
   worse trade than the CC BY 4.0 weights we already ship, for a conversion we have already
   performed ourselves.

8. **Telemetry is absent today and is contractually protected from being removed
   tomorrow.** Voz drives Core ML directly and never touches `InferenceSession`, so the
   shared usage turnstile that POSTs to `https://platform.desertant.ai/api/v1/ingest` is not
   wired into it — there is no telemetry in Voz as shipped. But §6 forbids disabling or
   tampering with that telemetry, and one upstream refactor routing Voz through the tracked
   session path would silently add a network call to a dictation app whose architecture
   states that downloading the pinned model is its only network access. That risk is
   structural, not hypothetical, and we would be forbidden from patching it out.

9. **As an SDK it is a second in-process recogniser.** `desert-ant-core` is
   swift-tools-version 6.2 (we are 5.9) and resolves 46 products across 60 targets with
   mlx-swift-lm, swift-transformers, swift-xet, JavaScriptKit and swift-numerics in the
   graph. `docs/performance-roadmap.md` already lists "a second recognizer: a parallel
   permission, model, and runtime surface" as a non-candidate, and
   `docs/archive/apple-recognizer-ab.md` records the same decision being taken once already
   against `apple/SpeechTranscriber`.

10. **It is nine days old and unreviewed.** Voz landed in `desert-ant-core` on 2026-08-26
    (commit `3096348a`). The Hugging Face repo has one tag, and `main` has already moved
    past it (`78e93e14` vs the pinned `8e7ab8ca`). Reported downloads are 0 and the SDK
    repository has 13 stars. Four targeted searches found no independent benchmark, review
    or discussion of Voz anywhere. Every number above is the vendor's own, on hardware we do
    not have, and none of it is cross-SoC — which is precisely the bar our own promotion
    packet refuses to waive for our own artifacts.

## The integration path, spelled out

"Can we actually plug it in" deserves a concrete answer rather than an assertion, so here is
the whole path. There are two routes and they are not equally bad.

### Route A — the SDK, as a package dependency

Rejected before any code. `desert-ant-core` is swift-tools-version 6.2 against our 5.9, and
resolves 46 products across 60 targets. It would put a second recogniser in the *app* process
beside `voiceour-asr`, which contradicts `docs/architecture.md`'s "`voiceour-asr` is the only
subprocess" framing in spirit and the "second recognizer" non-candidate in
`docs/performance-roadmap.md` in letter. Its downloader would also become a second model
acquisition path with weaker verification than `ParakeetModelCache`. Nothing recommends it.

### Route B — the artifacts only, into the seam we already have

Technically real, and worth writing down because it is what "plug it in" actually means. The
encoder is the only piece worth taking; Voz's mel duplicates work parakeet.cpp already does,
and its sixteen-lane decoder is a long-file design a dictation utterance cannot use. Every
item below is required:

1. **`Sources/ASRSidecarCore/CoreMLEncoder.swift` — rewrite the IO contract.** Today it
   allocates `mel` as `.float32` `[1, 128, melFrameCapacity]` plus an `int32` `mel_length`,
   and reads back 1024-channel `encoder`/`encoder_length`. Voz wants rank-4 fp16 `mel`
   `[1,128,1,1500]` plus separate `key_bias` `[1,188,1,1]` and `pad_mask` `[1,1,1,188]`
   tensors, and returns fp16 `enc_proj` `[1,640,1,188]`. That is a different feature
   provider, a different mask convention (a −40000 bias vector instead of a scalar length),
   a different element type, and a different output rank and width. `CoreMLEncoder.melBins`
   survives; `encoderChannels = 1_024` does not.
2. **A new vendor patch beside 0016.** Patch 0016 injects external *encoder states* into
   parakeet.cpp. Voz hands back states that have already been through the joint's 1024→640
   projection, so the tail must be taught to skip its own. That is new numerics on the
   decode path, and it must clear the identity and NI gates like anything else.
3. **A mel-contract audit.** Bet 2's root cause was reflect-vs-zero centred STFT padding, not
   precision. Voz's frontend centre-pads with zeros and uses a geometric preemphasis tail on
   the right, with `n_fft` 512 and `preemph` 0.97; those constants have to be reconciled
   against parakeet.cpp's featurizer before the first transcript is believed, and 1500 mel
   frames against our 1501.
4. **A second pinned model family.** `ASRModelContract` and `ASRModelVariant` describe one
   repository, one revision, and per-variant file/digest/size; `ParakeetModelManifest` and
   `cacheOK` verify exactly that shape. Voz is a different repo at a different revision with
   18 files, four of which (`model.mil` among them) the Hub publishes no SHA-256 for — so we
   would have to pin digests we computed ourselves and re-verify them on every fetch to keep
   the contract we have today.
5. **Docs and gates.** `scripts/check_docs.sh` requires the model id, revision, and every
   variant's filename and digest to appear in `README.md`, `NOTICE`, `AGENTS.md`,
   `docs/architecture.md` and `docs/developer-setup.md`. A second family means all five, plus
   `NOTICE` gaining Desert Ant attribution and the licence's §9 credit landing on a
   user-visible surface.
6. **A network-policy amendment.** `docs/architecture.md` states downloading the pinned model
   is the only network access. A second host and repository is a rulebook change, not a code
   change, and belongs to the maintainer.

None of that is impossible. All of it is in service of 5.4 ms per window at the encoder,
which items 1–3 of the takeaway list below can chase against our own artifact without items
4, 5 or 6 existing at all. That asymmetry is the whole argument.

## What the evaluation is worth keeping

Voz is not adoptable and is genuinely useful to have measured.

**External corroboration of a one-Mac finding.** An independent team converting the same
checkpoint for the same hardware arrived at 6-bit palettization and a ~460 MB encoder. Run 68
killed 4-bit on non-inferiority and named 6-bit grouped as the operating point; run 69 sized
the single-tier fallback at 459 MB. Two independent derivations landing within 2 MB of each
other is the closest thing to cross-team replication this lane has, and it should be noted in
`research/bet2-promotion-packet.md` as supporting — never substituting for — the cross-SoC
rule, which is about silicon variance and not about conversion choices.

**Three takeable experiments, all inside our own pinned weights and our existing patch-0016
seam, with a measured 5.4 ms/window prize to divide between them.** Run them in this order,
because the first is the cheapest and can eliminate the confound in the other two:

- *Re-export the standard tier unchanged on the current toolchain.* Ours was compiled with
  coremlc 3520.5.1, Voz with 3600.25.2. If a plain re-export closes most of the 5.4 ms, the
  other two experiments are chasing a compiler upgrade and can be dropped. Identity must be
  re-pinned either way; the promotion packet's determinism rule applies unchanged.
- *Use fp16 IO across the Core ML boundary.* Our graph's last op casts [1,1024,188] from fp16
  to fp32, and `CoreMLEncoder` then allocates `mel` as float32 and copies 770,048 B back per
  window. Voz declares `io_precision` fp16 and copies 240,640 B. The weights are already
  palettized, so this raises no accuracy question they do not already raise — but it does
  change numerics, so it goes through the same NI gate as everything else.
- *Fuse the joint's encoder projection into the tier graph.* Voz emits 640-channel `enc_proj`
  where we emit 1024-channel states, and still finishes 17.8% sooner. This moves a 640×1024
  matmul per frame onto the ANE, shrinks the boundary copy 3.2×, and removes per-token
  projection work from the CPU tail that the encoder benchmark does not even capture — the
  same memory-bound tail cost the q8 repack already showed pays. It needs a companion vendor
  patch so parakeet.cpp does not project a second time.

All three are ordinary candidates for the existing runtime-speed workstream, gated by the same
harness, preregistration and identity rules as everything else in `research/next-program.md`.
None requires anyone's licence.

**The hosting blocker is self-servable.** Bet 2's promotion is blocked partly on hosting the
tier artifacts. Voz demonstrates the exact pattern working in public: `.mlmodelc` directories
on Hugging Face under an immutable tag, with per-file LFS SHA-256 exposed by the tree API —
and `ParakeetModelCache` already implements digest-verified acquisition against that shape for
GGUF. Publishing our own tiers is a maintainer decision and a network-policy amendment, not an
unsolved engineering problem.

## Alternatives surveyed, for completeness

| option | why not |
|---|---|
| FluidAudio (`FluidInference/FluidAudio`) | Apache-2.0 code, CC BY 4.0 model, no telemetry — the cleanest licence of the set. But it hardcodes the `main` revision for every download and performs no SHA-256 verification, which is a direct conflict with `ASRModelContract`; it is swift-tools 6.0 with a binary xcframework dependency; and it is the same fixed 15 s window over the same weights. Published M4 Pro figures (FLEURS 209.8x RTFx, LibriSpeech 2.5% WER) do not beat our committed hybrid. |
| Argmax ParakeetKit Pro | Gated, licence-keyed, with an SDK heartbeat. Incompatible with the network policy on its face. |
| WhisperKit | MIT, but ships no Parakeet path; Whisper variants only. |
| `senstella/parakeet-mlx` | Apache-2.0 Python on MLX GPU. No Swift surface, and GPU rather than ANE is the rail we are trying to leave. |
| Apple `SpeechAnalyzer` (macOS 26) | Would raise the floor to macOS 26 and reintroduce a second recogniser. The predecessor was A/B'd and deleted; see `docs/archive/apple-recognizer-ab.md`. |

Nothing in that table is better than the artifact family already in this tree.

## Resolution

1. Voz is recorded as a non-candidate in `docs/performance-roadmap.md`. No dependency is
   added, no artifact is vendored, no contract changes.
2. The measured encoder A/B — Voz 0.822× our standard tier, same machine, 720 timed
   predictions per side — is the substantive result, and it opens three ordered experiments
   in the runtime-speed workstream: toolchain re-export first (it may explain everything),
   then fp16 Core ML IO, then the fused joint projection. Prize is 5.4 ms/window measured,
   plus uncaptured tail savings from the narrower encoder states.
3. The 6-bit / ~460 MB convergence is noted in the promotion packet as external
   corroboration, with the cross-SoC rule left untouched.
4. `.build/asr-research/voz-eval/` holds the harness, the verified artifacts and the raw
   numbers. It is untracked, like every other measurement root under `.build/`.

## Revisit conditions

All three must hold, and none is near:

- Voiceour's deployment floor has moved to macOS 15 or later for reasons of its own.
- Desert Ant has published cross-SoC evidence, or a third party has, at a quality that
  would pass the sealed acceptance rule in `research/bet2-promotion-packet.md`.
- Some capability appears that is not reachable from the pinned checkpoint we already
  hold — a different or better recogniser, not a different container for the same one.

A fourth condition would also justify revisiting on its own: if Desert Ant re-exported at a
lower deployment target and relicensed the export CC BY 4.0, the artifact would become an
ordinary candidate rather than a governance question. Nothing suggests they intend to.
