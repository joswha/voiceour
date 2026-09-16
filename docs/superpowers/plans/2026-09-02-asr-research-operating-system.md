# ASR Research Operating System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a persistent hybrid repo/wiki control plane for Voiceour's S-tier and A-tier ASR research, then leave four parallel workstreams with exact next actions.

**Architecture:** The Voiceour repository owns executable evidence and experiment contracts; the Obsidian vault owns status, dependencies, decisions, and compact session handoff. Ten tracks are organized into four parallel workstreams, while exclusive GPU/ANE validation stays serialized under one integration owner.

**Tech Stack:** Obsidian Markdown, YAML frontmatter, JSON manifest tracking, git, Voiceour's Swift/Python benchmark harness, existing wiki-update and wiki-lint workflows.

---

## File map

### Voiceour repository

- Existing design: `docs/superpowers/specs/2026-09-02-asr-research-operating-system-design.md`
- Create: `research/next-program.md` — durable workstream contracts, metrics, artifact locations, and execution order.
- Modify: `research/INDEX.md` — link the next program and mark its control-plane relationship.

### Obsidian vault

Root: `/Users/vlad/Documents/ObsidianVault`

- Create: `_meta/taxonomy.md` — minimal controlled vocabulary and `voiceoour → voiceour` alias.
- Move/update: `entities/VoiceOour.md` → `entities/Voiceour.md`.
- Update: `synthesis/Research: Technical Term Comprehension in Voice Dictation.md`.
- Create: `projects/voiceour/voiceour.md`.
- Create: `projects/voiceour/concepts/asr-research-program.md`.
- Create ten track pages under `projects/voiceour/concepts/`.
- Create: `projects/voiceour/skills/autoresearch-operating-loop.md`.
- Update: `.manifest.json`, `index.md`, `log.md`, and `hot.md`.

---

### Task 1: Normalize the wiki identity and taxonomy

**Files:**
- Create: `/Users/vlad/Documents/ObsidianVault/_meta/taxonomy.md`
- Move: `/Users/vlad/Documents/ObsidianVault/entities/VoiceOour.md` → `/Users/vlad/Documents/ObsidianVault/entities/Voiceour.md`
- Modify: every existing `[[VoiceOour]]` link in `index.md`, `hot.md`, and the technical-term synthesis page.

- [ ] **Step 1: Create the controlled tag vocabulary**

Write canonical tags with a five-tag page limit:

```markdown
# Tag Taxonomy

## Domains
- `speech` — speech capture, recognition, synthesis, and audio evidence
- `ml` — model training, inference, calibration, and evaluation
- `macos` — Apple platform implementation and runtime behavior
- `performance` — latency, energy, memory, and storage
- `safety` — precision, abstention, false activation, and critical corruption
- `data` — corpora, labels, splits, provenance, and licences

## Types
- `research` — experiment programs, results, and synthesis
- `skill` — reusable operating procedures
- `project` — project overview or control-plane page

## Projects
- `voiceour` — Voiceour project-specific knowledge

## Aliases
- `voiceoour` → `voiceour`
```

- [ ] **Step 2: Rename the stale entity page**

Rename the file to `Voiceour.md`; update its title, heading, tag, source paths, timestamp, and summary. Replace stale Parakeet MLX/refiner claims with the current signed GGML sidecar, strict glossary repair, source-only v0.3.0 status, and research-only ensemble boundary.

- [ ] **Step 3: Rewrite every old wikilink**

Replace `[[VoiceOour]]` and `[[entities/VoiceOour]]` with `[[Voiceour]]`; verify no old filename or `voiceoour` tag remains outside the taxonomy alias.

- [ ] **Step 4: Validate identity normalization**

Run a vault grep for `VoiceOour|voiceoour`; expected result: only `_meta/taxonomy.md` contains the historical alias.

---

### Task 2: Create the project overview and research control plane

**Files:**
- Create: `/Users/vlad/Documents/ObsidianVault/projects/voiceour/voiceour.md`
- Create: `/Users/vlad/Documents/ObsidianVault/projects/voiceour/concepts/asr-research-program.md`
- Create: `/Users/vlad/Documents/ObsidianVault/projects/voiceour/skills/autoresearch-operating-loop.md`

- [ ] **Step 1: Create the Voiceour project overview**

Use frontmatter:

```yaml
---
title: >-
  Voiceour
category: project
tags: [voiceour, speech, macos, research]
sources: [/Users/vlad/Desktop/voiceoour]
summary: >-
  Current Voiceour architecture, shipped versus research-only ASR paths, and links to the active S-tier/A-tier research program.
provenance:
  extracted: 0.85
  inferred: 0.12
  ambiguous: 0.03
created: 2026-09-02T00:00:00Z
updated: 2026-09-02T00:00:00Z
---
```

Body sections: product boundary, current verified model/runtime, shipped glossary repair, research-only teacher, key concepts, active program, durable repo evidence, and related global pages.

- [ ] **Step 2: Create the control plane**

`asr-research-program.md` must contain:

```yaml
frontier_commit: 0ac7514
frontier_recall: 0.852601
frontier_hits: 295/346
frontier_uwer_mix: 0.028068
frontier_uwer_general: 0.030725
frontier_uwer_jargon: 0.025410
frontier_false_terms: 0
```

Add four workstream tables, ten track rows, state definitions, dependency graph, global gates, experiment budgets, decision ledger, current sprint, and a `Session Handoff` section with `last_verified_commit`, `active_track`, `last_result`, `next_action`, and `resume_command`.

Initial current sprint:

1. Data foundation corpus feasibility and licence screen.
2. Acoustic verifier static seam analysis.
3. Streaming pre-encoding ownership/protocol analysis.
4. Student/model-frontier training and runtime inventory.

- [ ] **Step 3: Create the operating-loop skill page**

Specify the exact session start/end protocols from the design, plus:

- parent owns the control plane and exclusive hardware;
- subagents own disjoint read-only/static packets or isolated scratch outputs;
- no full harness before a pilot passes;
- maximum three full harness runs per candidate family;
- one fresh holdout only after frozen gates;
- exact evidence/commit/next command required at handoff.

- [ ] **Step 4: Test compaction recovery manually**

Read only the project overview, control plane, and operating-loop page. Expected: the current frontier, active sprint, ownership, gates, and next four actions are unambiguous without chat history.

---

### Task 3: Create S-tier track pages

**Files:**
- Create: `projects/voiceour/concepts/acoustic-glossary-verifier.md`
- Create: `projects/voiceour/concepts/streaming-pre-encoding.md`
- Create: `projects/voiceour/concepts/technical-student-distillation.md`
- Create: `projects/voiceour/concepts/real-speaker-techterms-corpus.md`

Each page uses tags `[voiceour, speech, research]` plus at most two of `ml`, `performance`, `safety`, or `data`.

Each page must include these exact sections:

```markdown
## Goal
## Current Evidence
## Hypothesis
## Cheapest Falsifier
## Development Gate
## Fresh Validation Gate
## Dependencies
## Risks
## Experiment Budget
## Decision Ledger
## Session Handoff
```

- [ ] **Step 1: Define the acoustic glossary verifier**

Record the proposed encoder-state/phoneme verification seam, `>295/346` recall target, zero unsupported terms, `<15 ms` p95 overhead, and hard negatives including IAM/I am, Redis/radios, runc/run, Swift/Suisse, and C++/CI.

Next action: map reusable encoder-state and word-timing APIs without code changes.

- [ ] **Step 2: Define streaming pre-encoding**

Record the non-emitting pre-encoder contract: no partial transcript, final TDT decode only at stop, identity-safe cancellation, and target stop-to-delivery p95 below 80 ms.

Next action: reconstruct capture→WAV→sidecar ownership and identify the smallest protocol seam.

- [ ] **Step 3: Define technical-student distillation**

Record one-artifact target, teacher disagreement mining, disjoint real-speaker training data, q8/QAT export, recall `>=295/346`, general U-WER `<=.030725 + .0035`, p95 `<=230 ms`, RTFx `>=100`, and installed cache `<=6.4 GB`.

Next action: inventory available v3 training/export checkpoints and Apple-compatible training/runtime paths.

- [ ] **Step 4: Define the real-speaker TechTerms corpus**

Record speaker/session-disjoint splits, positive terms, ordinary homophones, minimal pairs, critical syntax, multiple microphones/noise, licence/provenance, and immutable sealed-test policy.

Next action: screen existing public corpora and estimate the recording gap before collecting data.

---

### Task 4: Create A-tier track pages

**Files:**
- Create: `projects/voiceour/concepts/glossary-conditioned-decoding.md`
- Create: `projects/voiceour/concepts/confidence-calibration.md`
- Create: `projects/voiceour/concepts/contrastive-homophone-training.md`
- Create: `projects/voiceour/concepts/stateful-ane-encoder.md`
- Create: `projects/voiceour/concepts/layerwise-mixed-quantization.md`
- Create: `projects/voiceour/concepts/single-model-replacement-screen.md`

Use the same standardized track sections as Task 3.

- [ ] **Step 1: Define learned glossary-conditioned decoding**

Differentiate it explicitly from killed flat boosts: learned context adapter, dynamic bounded glossary, abstention, and hard-negative training. Cheapest falsifier: architecture/training/export feasibility packet.

- [ ] **Step 2: Define confidence calibration**

Record current ECE `.57–.62`, per-term/source calibration, conformal risk bounds, precision/coverage curves, and changed-span precision. Cheapest falsifier: calibration replay over cached token evidence.

- [ ] **Step 3: Define contrastive homophone training**

Record paired acoustic/text confusables and auxiliary verifier/student losses. Make it a dependency of the verifier and student tracks rather than an independent shipping component.

- [ ] **Step 4: Define stateful arbitrary-length ANE**

Record why naive chunking failed, required cache/state equivalence, one-artifact goal, arbitrary duration, incremental capture compatibility, and cross-SoC gate. Cheapest falsifier: static architecture/state inventory plus one exported-layer recurrence probe.

- [ ] **Step 5: Define layerwise mixed quantization**

Record global 6-bit pass/global 4-bit fail, per-layer sensitivity, QAT recovery, artifact and latency targets, and F32 provenance requirement. Cheapest falsifier: offline layer sensitivity ranking with no new full model.

- [ ] **Step 6: Define modern replacement screening**

Track Qwen3-ASR, Kyutai STT MLX, Canary, and Cohere Transcribe/CoreML. Reuse a fixed 16 residual/16 negative/16 general pilot; require at least two safe residual rescues before full evaluation.

---

### Task 5: Update the existing synthesis with verified Voiceour results

**Files:**
- Modify: `/Users/vlad/Documents/ObsidianVault/synthesis/Research: Technical Term Comprehension in Voice Dictation.md`

- [ ] **Step 1: Correct the stale current-state section**

Replace Parakeet MLX/optional-refiner claims with the signed GGML sidecar, shipped strict repair, final research teacher metrics, safety invalidations, and the explicit non-productization decision.

- [ ] **Step 2: Add completed evidence**

Summarize the killed flat bias, forced score, k-best, broad phonetic lowering, unsafe keyterm bias, and multi-model product rejection. Link `[[asr-research-program]]` and the active S/A track pages.

- [ ] **Step 3: Preserve prior external research**

Keep the cited literature and mark July proposals superseded, validated, or still open rather than deleting them.

---

### Task 6: Update wiki tracking and backlinks

**Files:**
- Modify: `/Users/vlad/Documents/ObsidianVault/.manifest.json`
- Modify: `/Users/vlad/Documents/ObsidianVault/index.md`
- Modify: `/Users/vlad/Documents/ObsidianVault/log.md`
- Modify: `/Users/vlad/Documents/ObsidianVault/hot.md`

- [ ] **Step 1: Add the project manifest entry**

Add `projects.voiceour` with:

```json
{
  "source_cwd": "/Users/vlad/Desktop/voiceoour",
  "last_synced": "2026-09-02T00:00:00Z",
  "last_commit_synced": "cd1e93f",
  "pages_in_vault": [
    "projects/voiceour/voiceour.md",
    "projects/voiceour/concepts/asr-research-program.md",
    "projects/voiceour/skills/autoresearch-operating-loop.md"
  ]
}
```

Extend `pages_in_vault` with all ten track pages and the updated entity/synthesis pages.

- [ ] **Step 2: Update the index**

Add the Voiceour project, control plane, skill, and ten tracks under their categories with one-line summaries. Remove the stale `VoiceOour` entry.

- [ ] **Step 3: Append the operation log**

Append one parseable `WIKI_UPDATE` entry naming project, pages created/updated, source commit, and source cwd, plus one `TAG_NORMALIZE` entry for `voiceoour → voiceour`.

- [ ] **Step 4: Refresh hot cache**

Keep only the latest three operations in Recent Activity. Set Voiceour ASR research as an active thread, record the four-workstream sprint, and state the single-model/acoustic-verifier takeaway.

- [ ] **Step 5: Add backlinks**

Ensure the project overview links every project page, the global synthesis links the control plane, and the control plane links the global evidence concepts.

---

### Task 7: Create the repository-side next-program contract

**Files:**
- Create: `research/next-program.md`
- Modify: `research/INDEX.md`

- [ ] **Step 1: Write the durable workstream contract**

Mirror only stable interfaces from the wiki: four workstreams, artifact naming, shared metrics, ownership, maximum run budgets, exclusive-hardware boundary, and repo evidence paths. Do not duplicate live status or session handoff.

Use artifact roots:

```text
.build/asr-research/next/data-foundation/
.build/asr-research/next/precision-recall/
.build/asr-research/next/single-model/
.build/asr-research/next/runtime-speed/
```

- [ ] **Step 2: Define shared packet schemas**

Each workstream packet must return: verified facts, hypotheses, cheapest falsifier, required artifacts, acceptance bars, safety risks, dependencies, and exact next action.

- [ ] **Step 3: Link from the research index**

Add `research/next-program.md` as the authoritative contract for the next phase and point live status to the wiki control plane.

- [ ] **Step 4: Verify documentation**

Run `make check-docs` and `git diff --check`; expected output: both exit 0.

- [ ] **Step 5: Commit**

```bash
git add research/next-program.md research/INDEX.md
git commit -m "Plan next ASR research program"
```

---

### Task 8: Validate the wiki and leave the first executable handoff

**Files:** all vault pages and tracking files from Tasks 1–6.

- [ ] **Step 1: Run wiki health validation**

Invoke the `wiki-lint` workflow. Expected: no broken wikilinks, duplicate Voiceour identity, missing summaries, malformed frontmatter, or pages above the tag limit.

- [ ] **Step 2: Verify manifest/index agreement**

Every `projects.voiceour.pages_in_vault` path must exist and every new page must appear in `index.md`.

- [ ] **Step 3: Verify exact recovery path**

A cold agent reads only:

1. `projects/voiceour/voiceour.md`
2. `projects/voiceour/concepts/asr-research-program.md`
3. the active track page

It must identify the same frontier commit, active workstream, blockers, gates, and next action.

- [ ] **Step 4: Set the first Wave 0 handoff**

Control plane values:

```yaml
active_workstreams:
  - data-foundation
  - precision-recall
  - single-model
  - runtime-speed
next_action: Dispatch four read-only/static packets in one parallel wave; no full harness.
resume_command: git -C /Users/vlad/Desktop/voiceoour status --short --branch
```

- [ ] **Step 5: Record completion**

Update wiki log/hot/manifest timestamps and leave repository HEAD plus wiki page paths in the final response.

---

## Self-review

- Spec coverage: hybrid authority, control plane, all ten S/A tracks, four workstreams, compaction recovery, parallelization, evidence tracking, manifest/index/log/hot updates, and validation each map to a task.
- Placeholder scan: no deferred or unspecified steps.
- Type consistency: workstream names, track states, frontier fields, evidence packet schema, artifact roots, and wiki paths are identical across tasks.
