# Next ASR research program — repository contract

Date: 2026-09-02. Authoritative only on `main`; `research/asr-research-os` is merged
fast-forward and the branch copy is a draft until then. The
`.worktrees/asr-research-os` worktree is transient and never owns artifacts.
Frontier of record: commit `0ac7514`, measured in `research/final-report.md`.

This file is the durable, executable half of the S-tier/A-tier program that follows the
three-bets session. It fixes the interfaces that must not drift between sessions, agents,
or context compactions: the four workstreams, their artifact roots, the evidence-packet
schema, shared metric identifiers, global gates, exclusive-hardware ownership, run
budgets, and fresh-holdout rules.

It deliberately carries **no live status**. Track state, owners, current sprint, last
results, blockers, decision-ledger entries, and session handoff live only in the wiki
control plane named below.

## Authority boundary

| authority | owns | location |
|---|---|---|
| repository | code, patches, preregistrations, scripts, metric outputs, SHA-pinned manifests, committed verdicts, and this contract | `research/**`, `bench/**`, `Sources/**`, `Vendor/**` |
| wiki control plane | track state, owner, experiment budget consumed, current hypothesis, last result, blockers, decision ledger, session handoff | `projects/voiceour/concepts/asr-research-program.md` |
| wiki track pages | per-track goal, evidence summary, gates, dependencies, risks, and next action | `projects/voiceour/concepts/<track>.md` |

Vault root: `/Users/vlad/Documents/ObsidianVault`.

Rules:

- A wiki claim that names a result must cite a repository commit or an evidence path.
- A repository experiment that changes direction updates the control plane before the
  session ends; a session is incomplete if the next step is only reconstructable from
  chat history.
- On disagreement, repository evidence wins and the wiki is corrected immediately.
- The live status of this program is never mirrored into `research/**`. Reading this file
  plus the control plane must never produce two versions of the same fact.
- Global numeric bars, wave costs, and budget rules are defined only in this file; the
  control plane's gate and budget sections are summaries of it. Track-level bars live in
  the track's page and preregistration and must sit inside the global ones. A
  disagreement between the control plane and this file is a wiki defect to correct,
  never a new bar.

## Workstreams

Exactly four. The identifiers are stable and are used verbatim in artifact paths, packet
filenames, and the control plane. `.build/asr-research` exists only in the primary
checkout `/Users/vlad/Desktop/voiceoour`: the canonical harness and every artifact write
run from there, because `autoresearch.sh` resolves its pinned assist models and CoreML
tiers under `$PWD/.build/asr-research/` (`autoresearch.sh:51-75`) and the gitignored
jargon corpus and audio under `benchmarks/data/` (`autoresearch.sh:41-42`,
`.gitignore:17`), and dies when they are absent. No worktree owns artifacts.

| workstream | artifact root | shared contract |
|---|---|---|
| `data-foundation` | `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/data-foundation/` | immutable train / calibration / sealed-test splits; speaker- and session-disjoint; licence and provenance recorded per row |
| `precision-recall` | `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/precision-recall/` | dynamic active vocabulary, explicit abstention, hard-negative safety, no unconstrained rewriting |
| `single-model` | `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/single-model/` | one pinned resident artifact inside the existing storage and runtime envelope |
| `runtime-speed` | `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/runtime-speed/` | one final transcript, deterministic cancellation, no partial text publication |

Workstreams are the unit of parallel dispatch. Tracks are the unit of preregistration,
budget, and kill/keep verdicts.

## Track inventory

Ten tracks. Identifier, tier, workstream, and cross-track interface are fixed here.
Hypotheses, primary metrics, cheapest falsifiers, consumed budget, and status are declared
per track in the control plane and in that track's preregistration, never here.

| track | tier | workstream | cross-track interface |
|---|---|---|---|
| `real-speaker-techterms-corpus` | S | `data-foundation` | produces the immutable train / calibration / sealed-test splits consumed by every precision and model track |
| `contrastive-homophone-training` | A | `data-foundation` | produces paired acoustic/text confusables as auxiliary-loss input to the verifier and student tracks; never ships alone |
| `acoustic-glossary-verifier` | S | `precision-recall` | consumes `data-foundation` splits and calibration thresholds; verifies against encoder state and word timings; abstains instead of rewriting |
| `glossary-conditioned-decoding` | A | `precision-recall` | learned context adapter over a dynamic bounded glossary; explicitly outside the killed flat-boost family |
| `confidence-calibration` | A | `precision-recall` | consumes cached token evidence; supplies abstention thresholds and precision/coverage curves to the other `precision-recall` tracks |
| `technical-student-distillation` | S | `single-model` | consumes `data-foundation` splits plus teacher disagreement from the `0ac7514` ensemble; emits one resident artifact |
| `layerwise-mixed-quantization` | A | `single-model` | per-layer precision assignment over the student or the pinned artifact; inherits the F32-provenance requirement |
| `single-model-replacement-screen` | A | `single-model` | screens external candidates; either feeds `single-model` or closes |
| `streaming-pre-encoding` | S | `runtime-speed` | pre-encodes during capture behind the existing sidecar protocol; non-emitting, final decode only at stop |
| `stateful-ane-encoder` | A | `runtime-speed` | stateful arbitrary-length encoder for the same pinned weights; one artifact; cross-SoC evidence required |

Track states, defined once in the control plane, are
`backlog → screening → preregistered → running → kept | killed | blocked`. A killed track
reopens only when its page records new evidence that invalidates the original kill
mechanism.

## Evidence packet schema

Every workstream returns one packet per wave. All eight fields are required, and each
field carries one `### <track>` subsection per track the packet covers, so the integration
owner never infers attribution. A packet missing a field, or a field missing a track that
packet covers, is rejected and the wave is not closed.

| field | required content | rejection rule |
|---|---|---|
| `verified_facts` | claims with file paths, line ranges, commits, or measured numbers | unsourced assertion, or inference not labelled as inference |
| `hypotheses` | falsifiable statements with a declared meaningful effect | restatement of the goal, or an unmeasurable claim |
| `cheapest_falsifier` | the smallest experiment that can kill the hypothesis, with its exact command or tool action | anything requiring the full harness at Wave 0 or Wave 1 |
| `required_artifacts` | absolute paths under the workstream artifact root, plus the SHA-pinned inputs they consume | paths outside the workstream root, or unpinned inputs |
| `acceptance_bars` | primary metric, guard set, and the numeric bar for each, drawn from the global gates | bars weaker than the global gates, or bars invented after a measurement |
| `safety_risks` | named hard negatives and the failure they would produce | "no risk", or precision risk stated without a negative example |
| `dependencies` | upstream tracks, external data, and hardware exclusivity needs | omission of an exclusive-hardware need |
| `next_action` | one exact command or tool action, runnable without chat history | a plan, a list of options, or a step needing reconstruction |

Skeleton:

```markdown
# <workstream> packet — wave <N>

## verified_facts
### <track>
## hypotheses
### <track>
## cheapest_falsifier
### <track>
## required_artifacts
### <track>
## acceptance_bars
### <track>
## safety_risks
### <track>
## dependencies
### <track>
## next_action
### <track>
```

Packets are returned to the integration owner, who transcribes them into the wiki. The
mapping is fixed so the two schemas cannot drift:

| packet field | wiki track section |
|---|---|
| `verified_facts` | `## Current Evidence` |
| `hypotheses` | `## Hypothesis` |
| `cheapest_falsifier` | `## Cheapest Falsifier` |
| `acceptance_bars` | `## Development Gate` and `## Fresh Validation Gate` |
| `safety_risks` | `## Risks` |
| `dependencies` | `## Dependencies` |
| `required_artifacts` | `## Decision Ledger` evidence paths |
| `next_action` | `## Session Handoff` |

A packet's own text is not committed. It becomes repository content only when it carries
commands, manifests, or numbers needed to reproduce a result; that durable summary is one
file per track, `research/next-<track>.md`, using the track identifiers above.

## Artifact roots and naming

Generated and large artifacts stay out of git, in the primary checkout only:

```text
/Users/vlad/Desktop/voiceoour/.build/asr-research/next/<workstream>/<track>/<wave>/
    prereg.md       # hypothesis, endpoints, bars, stop rule — written before measuring
    verdict.md      # disposition, derived tables, and the evidence they rest on
    run<n>/         # one directory per run; waves 1–4 only
        manifest.json   # pinned inputs and environment; required keys below
        metrics.txt     # harness runs: instrument output, verbatim
        metrics.jsonl   # non-harness measurements: one record per metric
        rows.jsonl      # per-row records
        command.txt     # the single command that reproduced the run, verbatim
/Users/vlad/Desktop/voiceoour/.build/asr-research/next/<workstream>/holdout-v<N>/
                    # sealed, workstream-level
```

`<wave>` is `wave0` … `wave4`. `<n>` is the run ordinal inside a wave, starting at 1.
Wave 0 is exactly one static screen per track, so it writes its screen output and the
per-run files at the wave level with `<n>` = 1; waves 1–4 write per-run files under
`run<n>/` so a second pilot or harness run never overwrites the first.

- `manifest.json` carries every input `autoresearch.sh` verifies by digest, whether or not
  the harness prints it. The printed `ASI key=value` set (`autoresearch.sh:432-444`) is a
  subset of the readonly pin constants (`autoresearch.sh:51-86`). Required pin keys:
  `general_corpus_sha256`, `jargon_corpus_sha256`, `jargon_terms_sha256`,
  `repair_vocabulary_sha256`, `coreml_encoder`, `coreml_encoder_digest`, `coreml_max_s`,
  `coreml_encoder_short`, `coreml_short_digest`, `coreml_short_max_s`,
  `coreml_encoder_tiny`, `coreml_tiny_digest`, `coreml_tiny_max_s`,
  `assist_model_sha256`, `assist_model_2_sha256`, `assist_model_3_sha256`,
  `assist_model_4_sha256`, `assist_model_5_sha256`, `model_sha256`, `model_bytes`,
  `sidecar_sha256`, `bench_sha256`. Required environment keys (`autoresearch.sh:445-454`):
  `hw_model`, `hw_chip`, `hw_cpu_threads`, `hw_perf_cores`, `hw_eff_cores`,
  `hw_memory_bytes`, `os_version`, `os_build`, `kernel`, `swift_version`. An input a
  measurement does not use records the harness's own absent value (`native`, `none`,
  `0`); no key is omitted.
- Harness runs copy the instrument's output into `metrics.txt` verbatim: the `METRIC` and
  `ASI` lines `autoresearch.sh` writes to `.build/autoresearch/metrics.txt`, followed by
  the `ASI` identity block it prints on stdout (`autoresearch.sh:395-455`). Never
  reformat, summarize, or re-encode it, and never restate a harness run's numbers in
  `metrics.jsonl`.
- Non-harness measurements — static screens, pilots, cached replays — write
  `metrics.jsonl` with exactly one record per metric:
  `{"run": "<track>/<wave>/<n>", "metric": "<identifier>", "value": <number>}`.
- Per-row records go in `rows.jsonl`, never in `metrics.jsonl`.
- `command.txt` is the single command that reproduced the run, copied verbatim.
- No track writes into another track's directory. Concurrent agents that share a root
  still own disjoint `<track>/` subtrees.
- Prior-session artifacts remain under
  `/Users/vlad/Desktop/voiceoour/.build/asr-research/three-bets/` and are read-only
  exploratory evidence, never reused as a verdict.

## Shared metrics

Canonical identifiers keep their existing definitions and are never renamed or shadowed.
Emitted by the current harness — `bash autoresearch.sh` → `research/harness.md`,
`bench/autoresearch/score_v5.py:223-235`, exactly 13 `METRIC` lines
(`autoresearch.sh:86,422-424`):

| identifier | definition | role |
|---|---|---|
| `jargon_term_recall` / `recall_hits` | exact case-sensitive canonical rate and hit count over 346 positives | recall primary |
| `uwer_mix` / `uwer_general` / `uwer_jargon` | pooled and per-corpus final-text U-WER | accuracy guards |
| `jargon_false_terms` | negative rows adding a taught surface absent from the reference | hard guard |
| `asr_inference_p95_ms` / `asr_inference_p50_ms` | steady-state decode latency | latency guards |
| `rtfx` | timed general audio seconds per ASR inference second | throughput guard |
| `load_ms` | model load time | cold-start input |
| `peak_phys_footprint_mb` / `peak_rss_mb` | peak `proc_pid_rusage` physical footprint and resident size | footprint guards |
| `error_rows` | failed rows across all passes | hard guard |

Prior-instrument identifiers, which `bash autoresearch.sh` does not emit. A packet that
needs one names the tool that produces it and the run it came from:

| identifier | definition | defined in |
|---|---|---|
| `fwer_negative` | case-preserving guard over the 110 ordinary-prose negatives; U-WER folds case, so re-casing damage is invisible to the primary | `research/CONTEXT.md:79-81`; produced by `bench/autoresearch/replay_repair.py:725` and the retired `bench/autoresearch/score.py:405` |
| `energy_j` | candidate compute-rail joules (CPU+GPU+ANE), median over the candidate blocks | `bench/autoresearch/score.py:301`, `research/bet2-ane-encoder.md:156-159` |
| `energy_dram_j` | median DRAM-rail joules over the same candidate blocks, a secondary rail beside `energy_j` | `bench/autoresearch/score.py:302-303` |
| `energy_ratio` | median candidate compute joules over median reference compute joules across the 8-block ABBA flight, under the wall-time contamination gate | `bench/autoresearch/score.py:300`, `research/bet2-ane-encoder.md:209-212` |

New program identifiers are declared here once and reused verbatim:

| identifier | definition | owner |
|---|---|---|
| `stop_to_delivery_p95_ms` | stop gesture to delivered final text | `runtime-speed` |
| `cold_first_use_ms` / `post_eviction_ms` | first-use and post-eviction latency | `runtime-speed`, `single-model` |
| `installed_bytes` | acquired and derived bytes resident on disk | `single-model` |
| `unsupported_activations_per_1k` | taught-surface activations unsupported by audio, per 1,000 opportunities | `precision-recall` |
| `changed_span_precision` | fraction of changed spans that are correct | `precision-recall` |
| `critical_syntax_corruption` | corrupted code, identifier, or number spans | program-wide hard guard |
| `ece` | expected calibration error over token or word confidence | `confidence-calibration` |
| `real_speaker_recall` | exact canonical recall on real-speaker technical rows | promotion evidence |
| `safe_residual_rescues` | residual misses rescued with zero unsafe fires in the track's screening pilot | `single-model-replacement-screen` |

An identifier absent from these tables is track-local: a track declares it in its
preregistration before reporting it, and never reuses a canonical name with a different
definition. Every track declares its primary metric and meaningful effect before
execution; secondary metrics are reported, never promoted to primary after a measurement.

## Global gates

Frozen reference bars, from the `0ac7514` frontier in `research/final-report.md` and the
harness guards in `research/harness.md`. These are floors and ceilings for candidate
comparison; they do not move because a candidate misses them. The `.0035` U-WER
non-inferiority margin is the repository's own, from
`bench/autoresearch/frozen_gate.py:9-10,43`, `bench/src/voiceour_bench/paired_gate.py:30`,
and `docs/benchmarks.md:65,78`.

| gate | bar | reference |
|---|---|---|
| recall | `jargon_term_recall` ≥ .852601 (295/346) for any recall-track candidate | frontier |
| general regression | `uwer_general` ≤ .030725 + .0035 | frontier plus non-inferiority margin |
| pooled accuracy | `uwer_mix` ≤ .037509 | harness guard |
| taught-surface safety | `jargon_false_terms` = 0 and `unsupported_activations_per_1k` = 0 | hard |
| critical corruption | `critical_syntax_corruption` = 0 | hard |
| determinism | paired transcript hashes identical across passes; `error_rows` = 0 | hard |
| latency | `asr_inference_p95_ms` ≤ 230 | product bar |
| throughput | `rtfx` ≥ 100 | product bar |
| process footprint | `peak_phys_footprint_mb` ≤ 2500 | harness guard |
| installed size | `installed_bytes` ≤ 6.4 GB, one resident artifact | product cache budget |

Hard guards are never traded. A candidate that breaches a hard guard is invalidated, not
re-tuned against the same evidence. Track-level bars and pilot designs are not global:
each track declares its own in its wiki page and its preregistration, inside these gates.

Standing hard negatives every precision candidate must survive, drawn from measured
failures: `IAM` from "I am"/"I'm", `Redis` from "radios"/"radius", `runc` from
"run"/"runs", `Credit Swift` for "Credit Suisse", `CALayer` from "color"/"colour", and
`C++` for spoken "CI" or "secret". Quantization candidates additionally inherit the
measured global-palettization result: 6-bit grouped-32 passes, global 4-bit fails on
`uwer_mix` (`research/bet2-ane-encoder.md`), and official-q8 provenance must derive from
original F32.

## Wave order and run budget

| wave | scope | allowed cost |
|---|---|---|
| 0 — static screen | read-only code, literature, model, data, and artifact analysis, in parallel | no downloads, no production edits, no benchmark |
| 1 — cheapest falsifier | independent offline pilots, parallel where hardware permits | cached replays, pilots, static probes; a failed pilot stops the track |
| 2 — frozen development gate | canonical harness on candidates that passed Wave 1 | ≤ 3 full harness runs per candidate family |
| 3 — fresh validation | one sealed holdout per candidate | one opening, preregistered endpoints |
| 4 — promotion packet | cross-SoC, cold-start, packaging, storage, and dual-consumer evidence | template: `research/bet2-promotion-packet.md` |

Budget rules:

- A **candidate family** is one mechanism plus one artifact set plus one configuration
  lineage. Threshold and parameter re-tunes inside a family spend the family's budget.
- The three runs are: frozen candidate against its reference pair, one corrective
  iteration after a diagnosed defect, and one confirmation. A fourth run requires a new
  preregistration under a new family identifier with a recorded reason.
- Only invocations of the canonical harness spend budget. Wave 0 and Wave 1 work does not.
- A run whose timing was contended is void: it spends no budget and must be rerun clean.
- No candidate reaches the harness before its Wave 1 falsifier passes.

## Exclusive hardware ownership

- One integration owner, the parent session, serializes every GPU/ANE and full-harness
  measurement. Subagents never invoke the harness.
- Stop the app first (`make stop`); the canonical harness refuses competing Voiceour or
  ASR processes and kills nothing itself.
- Timing-, energy-, and determinism-bearing measurements require an exclusive machine.
  Accuracy-only replays over cached artifacts may run concurrently only if they touch no
  GPU/ANE and write to their own track subtree.
- Concurrent contention invalidates a measurement: the numbers are discarded and the run
  is repeated clean, not annotated.
- The integration owner is the only writer of the control plane, writing at wave close and
  on any direction change.

## Fresh-holdout rules

- A holdout is generated, preregistered, and sealed before any candidate sees it, under
  `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/<workstream>/holdout-v<N>/`.
- A candidate earns a holdout only after its frozen recall, precision, general-U-WER,
  determinism, latency, and footprint gates pass.
- One opening per holdout, at the preregistered endpoints. Holdout failure invalidates the
  candidate; thresholds and references do not move to accommodate it.
- Once opened, a holdout is development data forever and can never validate a repair
  derived from it. The next validation needs a new sealed set.
- The `real-speaker-techterms-corpus` sealed split is the program-level holdout and is
  immutable. `real_speaker_recall` is the only recall figure cited as promotion evidence;
  synthetic `jargon_term_recall` is reported as development-gate evidence only.

## Repository evidence paths

| path | role |
|---|---|
| `research/next-program.md` | this contract; durable interfaces for the next program |
| `research/final-report.md` | frontier of record and the three-bets verdicts |
| `research/harness.md` | canonical instrument, metric definitions, and guards |
| `research/CONTEXT.md` | cold-start product/model facts; honor its stale-risk marks |
| `research/bet1-contextual-decoding.md` | vocabulary-binding evidence chain and killed mechanisms |
| `research/bet2-ane-encoder.md` | CoreML/ANE evidence chain, palettization frontier |
| `research/bet3-quantization.md` | quantization and margin-stability evidence chain |
| `research/bet2-promotion-packet.md` | promotion-evidence template |
| `research/next-<track>.md` | created when a track produces committed durable evidence |
| `/Users/vlad/Desktop/voiceoour/.build/asr-research/next/**` | gitignored artifacts for this program; primary checkout only |
| `/Users/vlad/Desktop/voiceoour/.build/asr-research/three-bets/**` | gitignored prior-session artifacts, read-only |

Canonical commands, all run from `/Users/vlad/Desktop/voiceoour`: `bash autoresearch.sh`
(measurement), `make stop` (release the machine), `swift build -c release --product
voiceour-asr` (sidecar), `make check` (full repository gate, run centrally and never
inside a research task).

## Out of scope for this file

The live state of this program — track state, owners, consumed budget, current sprint,
last results, blockers, decision-ledger entries, and session handoff — is wiki-only. If
this program's live state appears anywhere in `research/**`, delete it there and read
`projects/voiceour/concepts/asr-research-program.md` instead. Committed prior-session
records, including the three-bets ledger in `research/INDEX.md` and the verdicts in
`research/final-report.md`, are history and stay.
