---
description: Parallel PR triage — decide merge-worthiness, rebase in a worktree, fix blockers, hand the branches back for human merge.
---

# Review PRs

Parallel PR triage: decide merge-worthiness, prepare rebased worktrees, fix blockers, return them for human merge.

## Arguments

`$ARGUMENTS` optional:

- space/comma-separated PR numbers or URLs; or
- GitHub-search qualifiers (`is:open`, `author:foo`, `label:bug`, `draft:false`, …) and/or a time window (`3d`, `2w`, `12h`).

No PRs or flags → all open PRs opened in the last 3 days.

## 1. Resolve PRs

Parse `$ARGUMENTS`. Explicit numbers or URLs: use verbatim. Otherwise `github` `op: search_prs`; no-args default:

```
github { op: "search_prs", query: "is:open", since: "3d", limit: 50 }
```

Supplied qualifiers go verbatim into `query`; add `is:open` unless present. A time window (`3d`, `2w`, `12h`, ISO date) → `since`. `dateField` defaults `created`; set `"updated"` only when recently-touched PRs were explicitly requested. `repo` defaults to this checkout's `joswha/voiceour`.

Print the resolved set before fan-out so scope can be confirmed.

## 2. One parallel `task` subagent per PR

Assign each PR's number, head ref, author, and the workflow below. Agents work isolated. Use `hub` for exactly two reasons: a fix on PR A obviously conflicts with PR B, and the real-app serialization rule below.

### Required subagent workflow

#### Read and decide

1. Read `pr://<N>` (comments included by default; `?comments=0` skips) and `pr://<N>/diff` for the changed-file listing. Full unified diff: `pr://<N>/diff/all`; one file slice: `pr://<N>/diff/<i>`.
2. Check `git log origin/main` and `gh search prs` for an already-landed equivalent.
3. Decide:
   - `slop` — AI-generated noise, broken, off-spec, or net-negative. Drop with a 1–2 line justification; no checkout.
   - `out-of-scope` — the change is refused by a standing product decision, not by its quality. Drop with the citation. The recurring ones: a universal or Intel build (the vendored parakeet/ggml drop is arm64-only by design and asserts it at compile time); network text processing, telemetry, crash reporting, accounts, or an update check (local-first policy allows exactly one network path, the pinned model artifact); a "paste everywhere" switch (`InsertionSafetyPolicy` is the single class-to-disposition mapping and only `.normalText` may paste); clipboard save-and-restore (the previous clipboard is never read, saved, restored, or cleared); persisting audio; a keychain-backed feature (this bundle ships no provisioning profile and `SecItemAdd` returns `errSecMissingEntitlement`).
   - `superseded` — already fixed or merged in `main` or a newer PR. Drop with a pointer.
   - `worthy` — proceed.

Ambiguous → `worthy`. A human decides on a real branch.

#### Checkout

```
github { op: "pr_checkout", pr: "<N>" }
```

MUST use `github pr_checkout`, never raw `gh pr checkout`: it creates a dedicated worktree under `~/.omp/wt/<encoded-repo>/pr-<N>/` and wires the push remote for a later `pr_push`.

#### Build artifacts

Nothing to symlink, and one thing not to:

- The expensive download — the 1.26 GB `f16` or 669 MB `q8_0` model artifact — already lives at `~/Library/Caches/Voiceour/<variant>/`, outside any checkout, so every worktree shares it with no setup.
- NEVER symlink `.build` between checkouts. SwiftPM keys its build database to the scratch path, and one shared scratch directory also serializes the parallel builds this command exists to run. Each worktree pays one cold build, including the vendored parakeet/ggml compile.
- `VOICEOUR_MODEL_CACHE` names one directory its caller owns. Set it only to pin a variant deliberately; leaving it unset is what shares the cache.

#### Rebase

```bash
git fetch origin main
git rebase origin/main
```

Mechanical conflicts (formatting, adjacent edits, changelog bullets) → resolve and continue. Semantic conflicts → abort, note it in the report, commit nothing.

#### Review

Correctness, regressions, security, breaking-change impact, and test coverage for new paths. Beyond the general read, check what this repository actually guarantees:

- `Sources/VoiceCore` imports Foundation only. AppKit, SwiftUI, AVFoundation, Accessibility, CoreGraphics event posting, pasteboard, process launch, and Keychain APIs there are a hard violation.
- Insertion safety: the class-to-disposition mapping unchanged; bundle id, pid, safety class, and secure-input flag re-checked before the pasteboard write and again before Cmd-V; a secure target still reaching neither the journal nor the ledger.
- Wire protocol: models, client encoding, server decoding, and `fixtures/protocol/**` changed together. A field or request type present on only one side is a broken change.
- Model contract: id, revision, every variant's filename, digest and size, descriptor metadata, cache manifest, docs, fixtures, and tests move as one unit. `make check-docs` is the gate.
- Persistence: no suppressed write failure, load failures still quarantining as `<name>.corrupt-<ISO8601>`, the ledger folded at exactly the site the transcript is journaled.
- Concurrency: observable state main-actor isolated; blocking capture, file IO, hashing, and model work off the main actor; stale generations still rejected.
- `RenderOverrides`: every new field defaults to nil or false, and the seam substitutes an input or selects a path production already reaches. A branch that exists only to make a golden pass is a blocker.
- UI changes carry their goldens. `fixtures/ui/**` changed → read the `.ax.diff` or `.flow.diff` and confirm the change is the one the PR describes. Error-severity lint findings and red flows cannot be blessed.
- Vendored files: each local change marked `VOICEOUR PATCH` and listed in `Vendor/parakeet/NOTICE.md`; `scripts/vendor_parakeet.sh --check` clean; no `-mcpu=native`.

#### Verify

```bash
make build
swift test -Xswiftc -warnings-as-errors -Xswiftc -DUI_HARNESS --filter <TouchedSuite>
make ui-all            # only when the diff touches Sources/Voiceour
make check-docs        # only when the diff touches the model pin or a documented contract
```

Run targeted suites, never the full suite from a subagent. `make format` over the union of edited files, then `make format-check`.

Some classes cannot be verified in a worktree at all: microphone capture, TCC prompts, the Fn/Globe hotkey, synthetic Cmd-V, real glass materials, signing, and notarization. Those need the real bundle from `scripts/run_real.sh`.

<critical>
A second app instance terminates at launch. NEVER run `scripts/run_real.sh` or `scripts/restart_real.sh` concurrently with another agent. Announce it on `hub`, take the turn, verify the intended PID and bundle, and release it. Two agents launching the real app produce one silent loser and two worthless results.
</critical>

#### Fix

Merge blockers only: build or test failure, an obvious PR-introduced bug, or an edge case the PR's own goal requires. NEVER taste-rewrite, refactor unrelated code, or expand scope. Read the existing patterns first and follow `AGENTS.md`; add or update tests for a behavior change.

#### Commit

One commit per logical fix atop the rebased PR branch, in this repository's voice — imperative sentence subject, optionally area-prefixed, never a conventional-commit prefix.

```bash
git add -A
git commit -m "Reject a latched recording before the decode

Addresses review feedback on #<N>."
```

NEVER amend the author's commits, push, merge, or force-push their history.

#### Report

```
PR #<N>  <title>
Decision: worthy | slop | out-of-scope | superseded
Worktree: ~/.omp/wt/.../pr-<N>          (or: not checked out)
Rebase:   clean | conflicts (resolved | aborted: <reason>)
Gate:     build ✓  <suite> ✓  ui-all ✓/n-a  check-docs ✓/n-a
Fixes:    <commit shas + one-liners>    (or: none needed)
Unverified: <real-app classes this PR touches that a worktree cannot prove>
Blockers: <anything the human must decide>
```

## 3. Aggregate

After all agents finish:

```
| PR | Title | Decision | Rebase | Gate | Fixes | Blockers |
|----|-------|----------|--------|------|-------|----------|
```

Then the worktree paths grouped by decision, for `cd` and merge.

## Rules

- MUST use parallel subagents, one per PR; NEVER a serial loop.
- `slop`, `out-of-scope`, `superseded` → no checkout; record the decision only.
- Fixes limited to merge blockers inside that PR's diff.
- Real-app verification is serialized through `hub`; a second instance terminates.
- MUST NOT push or merge. The human reviews and merges.
