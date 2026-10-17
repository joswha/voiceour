# Moonshot sprint — design

Date: 2026-10-17. Owner decision: "Proceed" on the physics-first moonshot plan.

## Mandate

Targets come from physical limits; every claim comes from a measurement. The owner lifted six
product rules for this research program:

1. Transcribe only after stop, from one finalized WAV — audio may stream to the engine during
   recording.
2. No live transcript — optional preview text is allowed.
3. Parakeet v3 as the only recognizer and one resident artifact — our own small and large models
   are allowed.
4. Never persist audio — opt-in, encrypted, local personal-learning data is allowed.
5. Vocabulary never scoped to an app or project — local context may drive per-utterance
   vocabulary.
6. Tap to stop — end-of-utterance detection may commit.

Kept without exception: everything runs on the Mac (latency budget and privacy). The shipping app
keeps its current behavior, and `AGENTS.md` keeps describing it, until a replacement passes its
measurement gates; each invariant is rewritten in the change that ships its replacement.

## North-star targets

| metric | today | physics floor | target |
|---|---:|---:|---:|
| key release → text, p50 | 184 ms | ~1 ms compute + one 8.3 ms frame | ≤ 8 ms |
| key release → text, p90 | 804 ms | same | ≤ 8 ms |
| end of speech → text | waits for the tap | ~100–150 ms end-of-speech detection | before the tap |
| technical terms missed (synthetic, glossary taught) | 100 / 346 | expert who sees the screen | 0 on-screen misses; ≤ 10 overall |
| install → first dictation | 1.26 GB download + ~11 s | app launch | < 1 s, no download |
| compute used while speaking | ~1% | 100% | all of it |

Today's latency figures are timing-only aggregates of 500 local dictations; term figures are the
frozen synthetic jargon corpus (one voice).

## 72-hour sprint squads

| squad | deliverable | acceptance |
|---|---|---|
| 1a streaming spike | existing streaming runtime + NVIDIA cache-aware checkpoint on this Mac | release-to-text p50/p95 and real-time factor per chunk config; accuracy vs v3 on all three corpora |
| 1b native streaming | incremental cache-aware streaming in the vendored engine (benchmark seam, patch 0025) | streaming tokens equal the engine's masked full-utterance mode; release-to-text via `voiceour-bench` |
| 2 big model + context | >1B open speech model on the M4 Pro with context prompts | real-time factor, memory; term recall, false terms and general U-WER with and without context |
| 3 context engine | local index of repos, CLI tools, packages and on-screen text with spoken forms | build time, query p95, counts; unit tests |
| 4 prize audit | share of term misses whose correct term already exists locally | defined ratios over benchmark misses, taught glossary and aggregate real usage |
| 5a data machine | licensed multi-voice synthetic technical speech, verified | ≥ 1,000 utterances from ≥ 200 voices, throughput, verification rate, no benchmark leakage |
| 5b recorder | consented real-speech capture tool and prompt pack | simulated full session yields a valid bundle |

## Rules of evidence

- Product latency, real-time factor and memory are measured only on Apple Silicon; official
  timing runs are serialized by the orchestrator on AC power.
- The devbox GPU's PCIe link corrupts host↔device copies: its outputs are verified or replicated,
  and no training runs there until the link is repaired (`research/devbox/README.md`).
- Every model and dataset records revision, SHA-256 and licence; gated repositories stay blocked;
  non-commercial assets never enter training data.
- User data is read locally for aggregate statistics only; no transcript text or private
  identifier leaves the machine or enters a report.

## Layout

Code: `bench/moonshot/<squad>/`. Mac artifacts: `.build/moonshot/<squad>/`. Devbox artifacts:
`/srv/devbox/research/voiceour/runs/moonshot-<squad>/`. Curated results:
`benchmarks/results/`. Live scoreboard: `docs/moonshot.md`.
