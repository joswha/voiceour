> Archived 2026-08-15. Historical defect record: the refinement, secondary-recognizer, and live-preview subsystems measured below were deleted on 2026-08-15; current performance guidance lives in [performance-roadmap.md](../performance-roadmap.md).

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

## State at the close of that historical phase

Before the later subsystem deletions, the fixes above had temporarily established these invariants:

- `OmpRpcRefiner` filtered terms through the shared cloud-eligibility policy before prompt construction.
- `TranscriptProcessingPipeline` compiled one capture-scoped `VocabularySnapshot` for the stop path.
- Every `VocabularyCompiler` selection pass checked the effective hard limit, including priority selection and deferred backfill.
- `SessionStageTimings` persisted the then-current end-to-end and backend timing fields.
- The retired system recognizer's finalized-audio duration supplied its capture time.
- Model-rewrite timeouts scaled with utterance length and had an absolute ceiling.

The 2026-08-15 overhaul then removed the model-rewrite path, its vocabulary authorization machinery, and the secondary recognizer. These bullets explain the measurements below; they are not current implementation requirements.

## Removed partial-preview measurement

The live partial-transcript preview was deleted on 2026-08-15. This measurement is retained only as the decision record.

Appending 2.5 seconds of digital silence changed 25 of 32 transcripts, with 0.493% normalized U-WER and 0.105% CER; sub-threshold noise changed 21 of 32, with 0.583% U-WER and 0.194% CER. Reusing a preview as the final transcript therefore spent more than the project's +0.35 percentage-point gate.

Each preview also re-decoded the whole growing buffer. Decode cost measured about 10.1 ms per second of audio: 32 ms at 1.5 s, 100 ms at 10 s, 267 ms at 30 s, and 932 ms at 92 s. At the former one-second cadence, cumulative work was 0.59 s for a 10 s utterance, 6.27 s for 37 s, 9.60 s for 46 s, and 39.95 s for 92 s. That quadratic cost bought display text that was neither inserted nor safe to adopt, so the entire feature was removed rather than rescheduled.
