---
description: Diagnose, reproduce, then fix reproducible open issues in parallel — one clean worktree per issue, repro test first.
---

# Fix Issues

Diagnose, reproduce, then fix reproducible open GitHub issues in parallel: one clean worktree per issue.

## Arguments

`$ARGUMENTS` optional: space/comma-separated issue numbers or URLs, or GitHub-search qualifiers (`is:open`, `label:bug`, `author:foo`, …) and/or a time window (`3d`, `2w`, `12h`).

No issues or flags → all issues open and created within the last 3 days.

## 1. Resolve issues

Parse `$ARGUMENTS`.

- Explicit numbers or URLs: use verbatim.
- Otherwise `github` `op: search_issues`. No args:

  ```
  github { op: "search_issues", query: "is:open", since: "3d", limit: 50 }
  ```

  User qualifiers verbatim in `query`; add `is:open` unless present. A time window (`3d`, `2w`, `12h`, ISO date) → `since`. `dateField` defaults `created`; set `"updated"` only for an explicit request about recently-touched issues. `repo` defaults to this checkout's `joswha/voiceour`.

Print the resolved set before fan-out so scope can be confirmed.

## 2. Parallel subagents

One `task` subagent per issue. Give each the number, title, a body summary, and the workflow below. Agents work isolated; use `hub` when two issues clearly touch the same file, and always for the real-app rule in step b.

Each subagent MUST:

### a. Read

1. Read `issue://<N>`; cross-repo `issue://<owner>/<repo>/<N>`. Body and comments arrive together, and the comments usually carry the repro. Append `?comments=0` only to skip them deliberately.
2. Run `gh search prs` for the issue number. A reasonable existing PR → review it per `.omp/commands/review-prs.md`, report `existing-pr`, and do NOT create a competing fix.
3. Check the standing product decisions before spending a worktree. An issue asking for an Intel or universal build, cloud ASR, telemetry, accounts, an update check, a "paste everywhere" switch, clipboard save-and-restore, persisted audio, or a keychain-backed secret is `not-a-bug`: cite the `AGENTS.md` rule and stop.

### b. Diagnose and reproduce

MUST reproduce in the current checkout on `main`, before any worktree.

1. Read the relevant sources; state a concrete 1–2 sentence failure hypothesis naming the type and the boundary.
2. Write a focused repro test in the target that owns the behavior:

   ```swift
   // Tests/VoiceCoreTests/ReproIssue<N>Tests.swift
   import Testing

   @testable import VoiceCore

   @Suite("repro/issue-<N>")
   struct ReproIssue<N>Tests {
       @Test func <theBehaviorTheIssueReports>() { … }
   }
   ```

   Greppable, deletable, one file. Prefer `VoiceCoreTests` — policy, cleanup, glossary, safety mapping, wire models, and persistence all live behind Foundation-only types and need no host.

3. Run only that suite, never the suite set:

   ```bash
   swift test -Xswiftc -warnings-as-errors -Xswiftc -DUI_HARNESS --filter ReproIssue<N>
   ```

   The filter regex matches the test ID, which carries the *type* name — `ReproIssue<N>Tests` — not the `@Suite` display string.

4. Confirm it fails for the reported reason. A test that fails for a different reason is not a repro.

Three exits:

- Reproduced → **c**.
- Not reproducible as a test, but the issue is a real-surface class — microphone capture, a TCC prompt, the Fn/Globe gesture, synthetic Cmd-V into a named app, real glass material, signing, notarization, model download — then the repro is the app itself. Build and launch the real bundle, exercise the path, and record what happened.

  <critical>
  A second app instance terminates at launch. NEVER run `make run` or `make stop` concurrently with another agent. `make run` stops every running Voiceour first, so a concurrent launch kills the peer's app rather than quietly losing to it. `make status` reports whether the app is already someone else's. Announce the turn on `hub`, take it, verify the intended PID and bundle, and release it. Two agents launching the real app produce one silent loser and two worthless results.
  </critical>

  Reproduced in the real app → **c**, with the manual procedure written down as the repro and status `repro-manual`; the fix still lands with whatever unit-level test its root cause admits.
- Not reproduced at all → stop. Delete the test. Report `unreproduced` with the hypothesis, the evidence of non-failure, and the exact unblockers: macOS version, Apple Silicon generation, model variant, input device, target app bundle id, Accessibility trust state, or the author's own repro snippet.

Out of scope or not a bug — user configuration, intended behavior, duplicate, or a standing product decision — → stop and report `not-a-bug` with an explanation postable to the issue.

### c. Worktree

Only after a confirmed repro.

```bash
MAIN="$(git rev-parse --show-toplevel)"
ENC="$(printf '%s' "$MAIN" | sed 's|[/\\:]|-|g')"
WT="$HOME/.omp/wt/${ENC}/fix-issue-<N>"

git -C "$MAIN" fetch origin main
git -C "$MAIN" worktree add -B "fix/issue-<N>" "$WT" origin/main
```

Branch `fix/issue-<N>`, or `fix/issue-<N>-<slug>` when one issue takes several. The path follows the `pr_checkout` convention.

### d. Build artifacts

Nothing to link, and one thing not to:

- The model artifact already lives at `~/Library/Caches/Voiceour/<variant>/`, outside any checkout, so every worktree shares the 1.26 GB download with no setup. Leave `VOICEOUR_MODEL_CACHE` unset — it names one directory its caller owns, and setting it opts out of the shared cache.
- NEVER symlink `.build` between checkouts. SwiftPM keys its build database to the scratch path, and a shared scratch directory serializes the parallel builds this command exists to run. Each worktree pays one cold build, vendored parakeet/ggml included.

### e. Fix

1. **Move**, never copy, the failing test from the main checkout into the same path in the worktree, and remove it from main. The original checkout ends clean.
2. Confirm it still fails on the worktree branch.
3. Fix the source, following `AGENTS.md`: root cause, not symptom; no stub, mock, or `TODO: implement` in product code; no downstream guard where the type is wrong upstream; no suppressed write failure.
4. Re-run the repro until it passes.
5. Real contract changed → add or adjust the adjacent unit tests; run only those files.
6. Touched `Sources/Voiceour` → `make ui-all`, and read the `.ax.diff` or `.flow.diff` before blessing anything. A golden moves only when the fix genuinely changes what the app renders.
7. Touched the wire protocol, the model pin, or a documented contract → update `fixtures/protocol/**` and the docs in the same change, then `make check-docs`.
8. `make build`, then `make format` over the edited files and `make format-check`.

### f. Commit

One commit, in this repository's voice: an imperative sentence subject, optionally area-prefixed (`Console: …`), never a conventional-commit prefix. `git log` is the reference.

```bash
git add -A
git commit -m "Reject a latched recording before the decode

<short body naming the root cause and the fix>

Fixes #<N>."
```

Do NOT push. The human pushes and opens the PR.

### g. Report

```
Issue #<N>  <title>
Status:    fixed | repro-manual | unreproduced | not-a-bug | existing-pr (#<M>)
Repro:     <test path in the worktree, or the manual procedure>
Worktree:  ~/.omp/wt/.../fix-issue-<N>            (if created)
Branch:    fix/issue-<N>                          (if created)
Gate:      build ✓  <suite> ✓  ui-all ✓/n-a  check-docs ✓/n-a  format-check ✓
Commits:   <shas + one-liners>                    (if any)
Notes:     <root cause in one sentence, or exactly what information is missing>
```

## 3. Aggregate

After all subagents:

```
| # | Title | Status | Branch / Notes |
|---|-------|--------|----------------|
```

Then the worktree paths grouped by status, `fixed` first, for a batch `cd` and push.

## Rules

MUST: reproduce in the current checkout on `main` before creating a worktree; one parallel subagent per issue; check for an existing PR first and divert a reasonable one to `review-prs`; serialize every real-app launch through `hub`; commit with a `Fixes #<N>.` trailer in the repository's own subject style.

MUST NOT: symlink `.build` across checkouts; push, open PRs, or comment on issues; ship a stub, a product-code mock, or a placeholder; expand past the reported bug into adjacent code smells; bless a UI golden without reading its diff.

Failed repro → delete the temporary test in the main checkout before yielding. The original checkout is left clean either way.
