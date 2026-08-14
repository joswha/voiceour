> Archived 2026-08-14. Historical defect record; superseded by the current [performance roadmap](../performance-roadmap.md) and source tree.

# Performance roadmap history

This preserves the defect list and numeric corrections from the 2026-08-01 performance investigation. The defects have since been fixed. They remain here because the reasoning explains current privacy, vocabulary, and telemetry invariants; they are not outstanding work.

## Correction to previously circulated numbers

An earlier pass computed refinement quality as `rawTranscript → final text`. That was wrong: production applies `LiteralComposition` and deterministic cleanup before the model, so the refiner never sees the raw transcript. Replaying the coordinator's exact sequence over all 137 refined sessions through `VoiceCore` gave the corrected, refiner-only figures:

| Metric | Wrong (raw→final) | **Correct (cleaned→final)** |
|---|---:|---:|
| Byte-identical no-ops | 20/137 (14.6%) | **40/137 (29.2%)** |
| Aggregate word edits | 900 | **524** |
| Emitted words that differ from model input | 14.70% | **8.56%** |
| Over-generation ratio | 6.80x | **11.69x** |
| Edit distance p25/p50/p75/p90 | 2/4/8/16 | **0/2/5/11** |

Deterministic cleanup independently performed 459 word edits—about half the work previously credited to the model. The correction strengthened the over-generation finding and showed that nearly a third of refinement calls were pure no-ops.

## Defects found outside performance

1. **Remote-provider privacy filtering was missing on the OMP path.** At the time, the full glossary was passed into the OMP prompt even though OMP-selected models were remote. Project-scoped and explicitly non-cloud-eligible terms could therefore cross the network. Calling OMP a local subprocess did not make its selected model local. This was a privacy finding, not a latency optimization.
2. **The refinement path bypassed the compiled vocabulary snapshot.** It passed the uncapped active glossary instead of the one capture-scoped set intended for biasing, cleanup, authorization, and refinement.
3. **The 100-term vocabulary cap was soft.** The priority pass appended without checking the limit; a probe compiled **101 terms with `limit: 100`**.
4. **No end-to-end post-stop span was persisted.** Stage fields covered capture, ASR, insertion, and start latency, but nothing measured stop release through insertion outcome. Arithmetic sums of independent medians could not replace that span.
5. **Apple capture timing was not actually missing.** The Apple path already computed finalized audio duration and the coordinator persisted it as capture time. Historical Apple sessions without the field predated its introduction on 2026-07-20.

## Current invariants created by those fixes

The code now enforces the conclusions above:

- [`OmpRpcRefiner`](../../Sources/VoiceMac/OmpRpcRefiner.swift) filters terms through the shared cloud-eligibility policy before prompt construction.
- [`TranscriptProcessingPipeline`](../../Sources/Voiceour/TranscriptProcessingPipeline.swift) compiles one capture-scoped `VocabularySnapshot` and uses it throughout the stop path.
- Every selection pass in [`VocabularyCompiler`](../../Sources/VoiceCore/Vocabulary.swift) checks the effective hard limit, including priority selection and deferred backfill.
- [`SessionStageTimings`](../../Sources/VoiceCore/RecentSessionStore.swift) persists `stopReleaseToInsertionOutcomeMs`, `asrBackendId`, `asrLoadMs`, and `asrInferenceMs`.
- Apple finalized-audio duration remains the source of persisted capture time.
- Refinement timeouts are length-scaled with an absolute ceiling rather than one fixed budget.
