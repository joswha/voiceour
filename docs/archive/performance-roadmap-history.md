> Archived 2026-08-09. Historical research record; not current documentation. Superseded by [../performance-roadmap.md](../performance-roadmap.md).

# Performance roadmap history

The defect list and the numeric corrections from the 2026-08-01 performance
investigation. Every defect below has since been fixed; the entries are kept
because the reasoning explains why several current invariants exist, not because
any of them is outstanding. The live document is
[`docs/performance-roadmap.md`](../performance-roadmap.md).

## Correction to previously circulated numbers

An earlier pass computed refinement quality as `rawTranscript → final text`. That is wrong:
production runs `LiteralComposition.apply` then `CleanupEngine.clean` **before** the model, so the
refiner never sees the raw transcript. Replaying the coordinator's exact sequence over all 137 refined
sessions via `VoiceCore` gives the corrected, refiner-only figures:

| metric | wrong (raw→final) | **correct (cleaned→final)** |
|---|---:|---:|
| byte-identical no-ops | 20/137 (14.6%) | **40/137 (29.2%)** |
| aggregate word edits | 900 | **524** |
| emitted words that differ from model input | 14.70% | **8.56%** |
| over-generation ratio | 6.80x | **11.69x** |
| edit distance p25/p50/p75/p90 | 2/4/8/16 | **0/2/5/11** |

Deterministic cleanup independently performs 459 word edits — the free layer is already doing about
half the work previously credited to the model. The correction makes the over-generation case
*stronger*, and shows nearly a third of refine calls are pure waste.

## Defects found (not performance)

1. **Privacy-contract violation in `OmpRpcRefiner`.** `OmpRpcRefiner.swift:147` passes the glossary
   straight into `RefinerPolicy.ompUserMessage` with **no `cloudEligible` filter**, while
   `LLMRefiner.swift:64` correctly applies `RefinerPolicy.cloudEligible(glossary)` first.
   `docs/architecture.md:90` justifies this by classifying `OmpRpcRefiner` as a "local backend" so
   "project-private terminology never leaves the device" — but every suggested omp model
   (`RefinerProvider.swift`) is `anthropic/claude-haiku-4-5`, `openai-codex/gpt-5.5`, or
   `openai-codex/gpt-5.3-codex-spark`. **Local subprocess, remote model.** Terms the user explicitly
   marked non-cloud-eligible, and `projectID`-scoped terms, cross the network on that provider.
   Compounded by defect 2, the count is unbounded. This is a security finding, not a perf one, and it
   was the highest-priority item in this document.
2. **`VocabularyCompiler` is bypassed on the refine path.** `DictationCoordinator.swift:1217-1221`
   passes uncapped `Glossary.activeTerms`, contradicting `docs/architecture.md:88` ("that snapshot is
   the single active set consumed by refinement, biasing, and the risk authorizer").
3. **`VocabularyCompiler`'s 100-term cap is soft.** The priority pass (`Vocabulary.swift:202-206`)
   appends every `isPriority` term with no limit guard; a probe compiled **101 terms with `limit: 100`**.
4. <a name="telemetry-gap"></a>**No end-to-end span is persisted.** `SessionStageTimings` has
   `captureMs`/`asrMs`/`insertMs`/`startLatencyMs`, populated on 141/188/188/43 of 353 sessions, and
   nothing covering stop-release → insertion outcome. Recommend one monotonic
   `stopReleaseToInsertionOutcomeMs: Int?`. Without it, the 2608 ms composite above cannot be replaced
   by a real measurement.
5. **Apple-path capture timing is already implemented.** `AppleSpeechDictationEngine` computes the
   finalized audio duration and the coordinator persists it as `captureMs`; the 43 stored Apple
   sessions without that field predate its introduction on 2026-07-20.

**Addressed since this investigation (2026-08):** defects 1-4 are fixed. `OmpRpcRefiner.swift:147` now
applies `RefinerPolicy.cloudEligible` before building the prompt; the refine path compiles its snapshot
through `VocabularyCompiler.compile` in `DictationCoordinator`; the 100-term cap is hard — both passes in
`VocabularyCompiler.compile` guard on `selected.count < effectiveLimit`; and
`stopReleaseToInsertionOutcomeMs` plus `asrBackendId`/`asrLoadMs`/`asrInferenceMs` are persisted per
session (`RecentSessionStore.swift:57-60`). Refine timeouts are now length-scaled
(`RefinerPolicy.effectiveTimeoutMs`).
