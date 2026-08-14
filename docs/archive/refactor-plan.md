> Archived 2026-08-14. Historical planning record; superseded by the current [architecture](../architecture.md) and source tree.

# Open-source readiness refactor plan

This was an unexecuted proposal, not a description of current work. The repository evolved independently: some recommendations landed, some became irrelevant after deletion, and some proposed files were never created. This version preserves the measurements, verified reasoning, and sequencing rules without presenting the old path inventory as current.

## Historical baseline

The plan began from this measured clean-tree snapshot. Nothing in the table has been re-measured, and the numbers must not be used as current build or test expectations.

| Signal | Snapshot value |
|---|---:|
| Swift build | green, 0 warnings |
| Swift tests | 406 tests / 38 suites in 10.2 s |
| Swift source | 36,663 lines across 88 files |
| Swift tests | 12,050 lines across 33 files |
| Rust TUI | 8,634 lines |
| Python ASR / benchmark | 3,203 / about 2,000 lines |
| Tracked files | 463, including 96 vendored local-agent skill files |
| Git history | 112 commits; no secret found in any blob; `.env` had never been tracked |
| CI/tooling | no workflow and no Swift/Python formatter or linter configuration |

The zero-warning build justified adopting warnings as errors before structural work. The broader rule was more important than the exact count: every behavior-preserving pass needed a named parity baseline, and any intentional test-count change needed to identify the removed or added contract.

## Findings that shaped the plan

Fifteen subsystem audits produced 83 findings. Six load-bearing claims were then challenged by three independent refuters each. The corrections mattered more than the raw finding count:

| Historical claim | Verified result and durable lesson |
|---|---|
| A same-process focus race could paste into a secure field. | Confirmed. PID and bundle identity were insufficient across an asynchronous permission wait; safety-relevant focus state had to be checked again immediately before clipboard write and paste. |
| Failed Accessibility inspection was classified as normal text. | Partially confirmed. A completely untrusted fresh install still degraded to copy-only, but trusted-yet-failed inspection could reach the fail-open classification. Unknown inspection must remain risky. |
| A post failure was reported as total failure after the clipboard had been written. | Mechanically confirmed but impact downgraded. The branch was reachable only on event construction failure, not an ordinary unstable-permission path. Outcome naming still had to tell the truth about data already copied. |
| The opt-in control socket changed permissions before rejecting a symlink. | Confirmed, then eliminated with the unused control plane. Deleting the unneeded surface was safer than repairing it. |
| The stop path built multiple vocabulary snapshots. | Partially confirmed and worse than first reported: up to three compilations were possible. The purported one-snapshot test did not enable decoder bias and could not observe bias phrases. Tests must exercise the condition named by the test. |
| The offscreen UI harness was linked into the release executable. | Confirmed for linkage and refuted for execution. It was dormant unless explicitly selected, so the issue was binary size and attack surface rather than runtime behavior. |

A separate audit found that the security policy denied persistent transcript history while the product intentionally kept a capped local recent-session journal. For a privacy-positioned app, correcting a false retention statement ranked above structural cleanup. The durable rule is that security documentation must be read against actual persistence code, not product intent.

## Decisions that remain useful

### Build the safety net before movement

The plan proposed shared test doubles, characterization tests around code about to move, contract-level assertions rather than implementation pinning, CI on a runner without models or permissions, and isolated formatter adoption. The details moved on; the rationale did not:

- A test named for a gated branch must enable and observe that branch.
- Wire and security assertions stay strict even when mechanism-level assertions are relaxed.
- Characterization tests should protect the exact logic being moved, not chase a coverage percentage.
- Formatting belongs in an isolated change, never mixed into a semantic refactor.
- CI must distinguish reproducible gates from suites that require a model, microphone, Accessibility grant, newer OS, or external CLI.

### Subtract before splitting

The control-plane/TUI had one consumer and no product path. Removing it deleted a second language, toolchain, protocol, socket surface, and fixture family. The important decision was not its old manifest: prove the consumer graph, delete the unused subsystem, and only then refactor what remains.

The same principle applied to local-agent files that were tooling rather than product and to measurement-only code inside a production module. Public symbols and user-data paths were the traps: move shared storage helpers before deleting their former owner, and treat removal from a published library as a migration rather than “dead code.”

### Separate behavior changes from mechanical moves

Safety corrections, persisted-enum changes, wire strictness, target-class additions, public API removal, and package-graph changes were not refactors. Each required its own review and migration story.

For module splits, the rule was: **move code; do not edit it in the same pass**. Renames, logic corrections, and access-level changes belonged in later changes. This made parity review possible and kept rollback boundaries honest.

### Prefer a few domain primitives over blanket abstraction

The audit found repeated generation/cancellation gates, duplicated NDJSON child-process lifecycle code, insertion policy spread across several layers, session query logic embedded in a view, and duplicated interactive chart behavior. Those were candidates because repeated state machines or policy decisions had already emerged.

The plan explicitly rejected registries or protocols for every switch. Stable stage order and coherent view primitives did not become better merely by becoming dynamic. Extension abstractions should reduce the real contributor edit surface, preserve persisted identifiers, and keep platform dependencies out of the core module.

### Treat public packaging as an API decision

The package exposed libraries whose public declarations had not been curated as a compatibility surface. Before a first public tag, the project needed to choose between versioning those APIs and treating them as app internals. The same reasoning applies to bundle identity and renames: package names, Application Support paths, defaults keys, and bundle identifiers carry user data, so a rename without migration orphans settings and history.

Attribution should be generated from lockfiles and include downloaded model provenance. Contributor setup should name CI-safe versus permission/model-dependent workflows. A security contact must be real. First-launch network behavior must include package-manager side effects, not only explicit app requests.

## What happened to the old proposal

Several recommendations are now repository history rather than open actions:

- CI, Swift formatting configuration, and Python lint configuration landed.
- The Rust TUI and control plane were removed.
- The recording overlay, glass components, UI harness, and property primitives were split into focused files.
- The two exploration notes moved to [`docs/archive/refinement-exploration.md`](refinement-exploration.md) and [`docs/archive/keyword-comprehension-exploration.md`](keyword-comprehension-exploration.md).
- The render probe moved to `scripts/archive/perf_probe.sh`. It is not wired into `make` or CI, but it is documented in [`docs/developer-setup.md`](../developer-setup.md) and can be run directly from `scripts/archive/` when a bundled app and Accessibility grant are available.

The proposal's never-created documentation and deleted implementation inventory have intentionally been removed from this record. Current contributor instructions belong in active documentation, not here.

## Sequencing rationale

The useful dependency order was:

1. Correct false security claims immediately.
2. Establish parity tests and reproducible CI.
3. Delete independently proven dead subsystems.
4. Land safety behavior changes in small, reviewable changes.
5. Split surviving modules without logic edits.
6. Extract only primitives demonstrated by repeated policy or lifecycle code.
7. Curate packaging and public API after the source shape stabilizes.

This avoided refactoring thousands of lines just before deletion and avoided extracting a flawed safety policy only to rewrite it. A phase number was never the deliverable; each slice had to be independently useful and verifiable.

## Deliberately rejected

- **Rewrite the profile-free UI image encoder.** It delegated encoding to the system bitmap representation specifically to keep golden images free of the developer display profile. The unusual shape recorded a measured reproducibility reason.
- **Collapse Apple batch and streaming speech clients.** Their semantic split was real; only shared analyzer setup was a candidate for extraction.
- **Add a registry for everything.** Existing coherent control families and deterministic pipeline order did not need dynamic dispatch.
- **Chase a coverage percentage.** Shared test support and characterization of moved policy were higher-value than a target number.
