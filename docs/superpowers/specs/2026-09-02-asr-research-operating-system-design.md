# ASR Research Operating System Design

Date: 2026-09-02
Status: approved architecture

## Purpose

Voiceour's next research program covers the S-tier and A-tier speed, recall, and precision tracks without repeating the previous session's slow serial loop. The system must survive context compaction and agent-session boundaries while keeping every result tied to executable evidence.

## Canonical architecture

Use a hybrid control plane:

- The Voiceour repository is authoritative for code, commits, preregistrations, scripts, metric outputs, frozen manifests, and reproducible evidence.
- The Obsidian wiki is authoritative for program status, decisions, dependencies, cross-session handoff, and synthesized knowledge.
- A wiki claim that names a result must link to a repository commit or evidence path. A repository experiment that changes direction must update the wiki control plane before the session ends.

Large or generated artifacts remain outside git under `.build/asr-research/`; durable summaries and exact reproduction commands live under `research/`.

## Wiki layout

```text
projects/voiceour/
├── voiceour.md
├── concepts/
│   ├── asr-research-program.md
│   ├── acoustic-glossary-verifier.md
│   ├── streaming-pre-encoding.md
│   ├── technical-student-distillation.md
│   └── real-speaker-techterms-corpus.md
└── skills/
    └── autoresearch-operating-loop.md
```

The stale `entities/VoiceOour.md` and global technical-term synthesis page are updated and linked into this project rather than duplicated.

## Research control plane

`asr-research-program.md` is the only page needed to recover top-level state. It contains:

- verified frontier metrics and commit;
- four workstreams and their dependencies;
- each track's tier, status, owner, experiment budget, current hypothesis, last result, and next executable action;
- blockers and external prerequisites;
- decision ledger with keep, kill, supersede, and reopen conditions;
- a compact session handoff.

Track states are:

```text
backlog → screening → preregistered → running → kept | killed | blocked
```

A killed track can reopen only when its page records new evidence that invalidates the original kill mechanism.

## Workstream decomposition

### Data foundation

Combines the real-speaker TechTerms corpus and contrastive homophone generation. It supplies immutable train, calibration, and sealed-test splits to every model and precision track.

### Precision and recall

Combines the acoustic glossary verifier, learned glossary-conditioned decoder, and confidence calibration. Shared contract: dynamic active vocabulary, explicit abstention, hard-negative safety, and no unconstrained rewriting.

### Single-model frontier

Combines technical-student distillation, quantization-aware training, and modern single-model replacement screening. Shared product constraint: one pinned artifact within the existing storage and runtime envelope.

### Runtime speed

Combines non-emitting pre-encoding during capture and a stateful arbitrary-length ANE encoder. Shared contract: one final transcript, deterministic cancellation, and no partial text publication.

## Accelerated execution process

### Wave 0 — static screen

Run read-only code, literature, model, data, and artifact analysis in parallel. Produce one structured packet per workstream. No model downloads, production edits, or full benchmarks.

### Wave 1 — cheapest falsifiers

Run independent offline pilots in parallel where hardware permits. Examples: cached-provenance replay, 16-positive/16-negative model pilot, encoder-shape feasibility, corpus licence and speaker audit. A failed pilot stops the track.

### Wave 2 — frozen development gate

Only candidates that pass Wave 1 enter the canonical harness. Exclusive GPU/ANE work is serialized by the parent session. Maximum three full benchmark runs per candidate family.

### Wave 3 — fresh validation

A candidate receives one fresh holdout only after frozen recall, precision, general-U-WER, determinism, latency, and footprint gates pass. Holdout failure invalidates the candidate; the holdout becomes development data and cannot validate its repair.

### Wave 4 — promotion packet

Product promotion requires the relevant cross-SoC, cold-start, packaging, storage, and dual-consumer evidence. Research success alone does not imply shipping.

## Global measurements

### Speed

- steady-state ASR p50/p95;
- stop-to-delivery p50/p95;
- cold first-use and post-eviction latency;
- RTFx, compute energy, physical footprint, installed bytes.

### Recall

- macro exact term recall;
- real-speaker technical recall;
- general U-WER;
- candidate recall-at-K and changed-span recovery.

### Precision

- unsupported taught-surface activations per 1,000 opportunities;
- changed-span precision;
- critical syntax corruption;
- formatted-WER regression rows;
- calibration error and precision/coverage curves.

Every track declares its own primary metric and meaningful effect before execution. Shared hard guards remain zero critical corruption, deterministic paired output, and no unexplained general-regression breach.

## Session start protocol

1. Read `projects/voiceour/voiceour.md`.
2. Read `asr-research-program.md`.
3. Read only the active track pages.
4. Verify repository HEAD, branch, worktree cleanliness, and last evidence commit.
5. Execute the exact `next_action` recorded for the highest-priority unblocked track.

## Session end protocol

1. Record result, evidence path, commit, and disposition on the track page.
2. Update frontier, dependencies, decision ledger, and next action in the control plane.
3. Update wiki manifest, index, log, and hot cache.
4. Commit durable repository evidence.
5. Leave one exact shell command or tool action that resumes work.

A session is incomplete if another agent would need to reconstruct the next step from chat history.

## Failure handling

- Missing external data blocks only the dependent track.
- Concurrent agents never edit the same tracker page; one integration owner writes the control plane after each wave.
- Full-harness hardware contention invalidates timing and requires a clean rerun.
- Unsafe fresh-holdout output invalidates the candidate; thresholds and references do not move.
- Wiki and repo disagreement is resolved in favor of repository evidence, then the wiki is corrected immediately.

## Validation

The foundation is complete when:

- the Voiceour project and research program are represented in the wiki;
- every S-tier and A-tier track has a standardized page or control-plane record;
- manifest, index, log, and hot cache are current;
- session start from only the project overview, control plane, and active track page yields an unambiguous next action;
- the repo contains an implementation plan for the four accelerated workstreams.
