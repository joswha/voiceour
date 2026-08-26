---
description: One behavior-preserving cleanup iteration over the Swift sources — discover one target, complete the cutover, verify against the goldens.
---

# Cleanup

Autonomous cleanup-loop iteration: discover ONE target → complete execution → verify → report. Stateless: derive everything from the current tree; assume prior runs left it consistent.

<critical>
- Behavior-preserving ONLY: menu, console, overlay, hotkey gesture, insertion disposition, wire protocol, persisted file shapes, rendered output NEVER change.
- Goldens are the oracle, not the obstacle. `fixtures/ui/**` and `fixtures/protocol/**` MUST come out byte-identical. A cleanup run that blesses a golden is a failed cleanup run.
- Every iteration MUST yield a named concrete quality win: duplicate implementation gone, responsibility extracted, dead cluster removed, guard clutter deleted. Deletion favored: net-negative LOC expected and the candidate tie-breaker; a justified net-neutral split or boundary fix is acceptable only with a real win. Report LOC delta either way.
- NEVER touch vendored code: `Vendor/parakeet/**` is pinned upstream with its own integrity gate.
- Complete the cutover this run: migrate every callsite, delete the original. NEVER half-migrate, NEVER leave a `typealias` or forwarding wrapper behind.
- No target above bar → output exactly `CLEAN: no target above threshold` and stop.
</critical>

## Scope

Swift only. Target priority: `Sources/VoiceCore`, `Sources/Voiceour`, `Sources/VoiceMac`, `Sources/ASRSidecarCore`. `Sources/VoiceourASR`, `Sources/ASRSidecarStub`, `Sources/VoiceourBench`, and `Tests/**` MAY change only where callsite migration requires it.

NEVER touch: `Vendor/**`, `fixtures/**`, `benchmarks/**`, `bench/**` (own lint), `Resources/*.plist`, `Resources/*.entitlements`, `scripts/archive/**`, `docs/archive/**`, `Package.resolved`.

Voiceour is an application, not a library: it has no external API consumers, so `public` marks a target boundary rather than a published contract and an unreferenced `public` symbol is deletable. The named exceptions are entry points and seams that no reference search can see:

- `Package.swift` products and their `main` entry points.
- `RenderOverrides` fields — production-compiled because real views read them; a field with no reader anywhere is dead, a field read by a harness scene is not.
- `#if UI_HARNESS` code, which `swift build` alone never compiles. Search it explicitly.
- Symbols reached only from `Resources/Info.plist`, a `scripts/*.sh` invocation, or an environment key (`VOICEOUR_*`).

## 1. Discover

No scanner script exists. Derive candidates with the tools, never by opening files hoping.

One size ranking — a god-object shortlist, never a verdict on its own:

```bash
wc -l $(git ls-files 'Sources/**/*.swift') | sort -rn | head -20
```

Then three searches, through the `grep` tool rather than a shell:

- `pattern: 'try\?'`, `path: Sources` — error suppression. At a persistence or wire boundary this is a bug class, not clutter: `AGENTS.md` says write failures are not suppressed.
- `pattern: 'import (AppKit|SwiftUI|AVFoundation|Accessibility)'`, `path: Sources/VoiceCore` — a hard boundary violation. MUST be empty.
- `pattern: 'import (AppKit|SwiftUI|AVFoundation)'`, `path: Sources/Voiceour` — inverted: the files that do NOT match hold Foundation-only logic sitting in the app layer, where only a view can test it. Those belong in `VoiceCore`.

Then `lsp symbols` per shortlisted file and `lsp references` per candidate symbol. Output is EVIDENCE, not verdict: read every entry before acting.

Candidate classes:

**Dead weight** — highest value
- Declarations with zero non-test references. `lsp references` MUST come back empty, and the `#if UI_HARNESS` sources MUST be searched separately because a plain build never compiles them.
- A symbol referenced only by a test that mirrors it: delete both.
- Unpassed initializer parameters, injected ports with one production and one fake conformer where the fake is unused, unreachable `switch` arms.
- Settings keys, `SessionCue` cases, `UserFacingDictationFailure` cases, or `RenderOverrides` fields nothing produces.
- Runtime checks duplicating what the type system already guarantees.

**Duplication**
- A helper reimplemented in two targets because `VoiceCore` was not the obvious home.
- Copies differing only by a literal or a flag.
- The three JSON stores — settings, recent sessions, lifetime ledger — share one quarantine-on-corrupt and ordered-write-tail shape. Divergence between them is a defect; a fourth hand-rolled copy is the smell.
- Parallel `switch` chains dispatching on one discriminant (`SessionState`, `InsertionDisposition`, `ASRErrorCode`) in several files.
- Inline reimplementation of `AppDisplayName.label`, `AppSupportPaths`, `InsertionSafetyPolicy`, or a Core Audio property getter.

**God objects**
- A file dwarfs its siblings AND mixes responsibilities: observable state + file IO + rendering + parsing. Size alone is no smell — a large coherent view file stays.
- Coordinator or view methods spanning domains that already have a home in another target.

**Boundary rot** — the Swift analogue of import rot; there are no relative imports to smell
- `VoiceCore` reaching for a macOS framework. This is a hard AGENTS.md violation, not a preference.
- Pure policy living in `Sources/Voiceour` where only a view can test it.
- A macOS side effect in `Voiceour` that belongs behind a small `VoiceMac` contract.
- Names no longer describing contents after an earlier rename.

## 2. Select

Score `(quality win × confidence) / blast radius`. Pick exactly ONE cluster, roughly ≤12 touched files. Tie-break: deletion > dedup > split > move; equal → larger LOC reduction.

Worth-doing bar — name the win in one sentence: an entire duplicate implementation or ≥100 duplicated/dead lines removed; one oversized multi-responsibility file split on an existing seam; a dead case cluster or `try?` hotspot eliminated; logic moved across a target boundary so the tree reads as designed.

## 3. Execute

**Dead weight / suppressed errors**
- Delete the declaration and the tests that only mirror it. Deletion requires `lsp references` empty AND a `#if UI_HARNESS` search AND no `scripts/`, plist, or `VOICEOUR_*` reference. Any one fails → retain.
- Narrow once at the IO boundary; internal code receives the narrowed type. Then delete downstream `?.` on non-optionals, `?? fallback` on non-optionals, and `as` casts papering over flow.
- A value genuinely sometimes absent → fix the TYPE upstream; NEVER add a downstream guard.
- `try?` at a persistence or wire boundary → propagate. Swallowing a settings, history, or ledger write is a product bug: those failures are surfaced, and a quarantine path exists precisely so nothing limps.
- Precise catches only. Narrow file-absence handling stays.

**Dedup**
- Two copies → one declaration in the lowest target that can hold it. Foundation-only → `VoiceCore`. macOS-touching → `VoiceMac`, behind the same small contract shape its siblings use.
- Literal/flag variants → one function with a parameter that has a name at the callsite. NEVER a boolean positional.
- Keep the hardened copy — the one with the timeout, the cap, the identity re-check — never a fresh copy that lacks it.

**God objects**
- Split on existing seams into domain-named files inside the same target.
- Extraction is MOVEMENT: code verbatim except access level and imports. Rewriting while moving hides regressions.
- Update every reference. A split that introduces a protocol, a base class, an event bus, or a DI seam where a direct call existed is a failed split. The existing ports exist for substitutability in tests; a new one needs the same justification.

**Boundary moves**
- `git mv` the file, then fix `import` lines and access levels. Swift has no per-file import graph to rewrite, so the compiler is the whole check: `make build` catches every stale reference.
- Moving into `VoiceCore` MUST drop the macOS import. If it cannot, the move is wrong.

**Perf** — opportunistic; only code already touched
- Hoist loop invariants, precompile regexes, drop intermediate arrays and strings on the audio, decode, and render paths.
- NEVER trade cold-path clarity for micro-perf; NEVER add a cache.

## 4. Prohibitions

- NEVER add a dependency. `Package.swift` and `Package.resolved` stay untouched.
- NEVER add a setting, a feature flag, a `RenderOverrides` seam, a wrapper layer, a one-conformer abstraction, or future-proofing.
- NEVER change the ASR wire protocol, `fixtures/protocol/**`, the model pin, or anything `scripts/check_docs.sh` asserts.
- NEVER add `-mcpu=native` or any build setting; the bundle must run beyond this host.
- NEVER reformat or restyle outside the touched cluster; NEVER run `make format` over the whole tree in a cleanup commit.
- NEVER sweep comments or docs drive-by. Comment only new non-obvious code, and delete a comment only when it names something that no longer exists.
- NEVER add tests for moved-but-unchanged code. Keep the passing tests, relocating them with their subject.

## 5. Verify

In order; each is a hard gate.

1. `make build` — clean under warnings-as-errors.
2. `swift test -Xswiftc -warnings-as-errors -Xswiftc -DUI_HARNESS --filter <TouchedSuite>` while iterating, then `make test` once before reporting. One target per run keeps that affordable.
3. `make format` over the touched files only, then `make format-check`.
4. Touched `Sources/Voiceour` → `make ui-all`, and `git status --porcelain fixtures/ui` MUST be empty. A moved digest or journal means rendering changed.
5. Touched wire types → `make test` covers `ProtocolFixtureParityTests`, and `git status --porcelain fixtures/protocol` MUST be empty.
6. Touched a documented contract → `make check-docs`.
7. Touched `Vendor/**` by accident → revert it, then `scripts/vendor_parakeet.sh --check`.

## 6. Commit

One commit, in this repository's voice: an imperative sentence subject, optionally area-prefixed (`Console: …`, `Bench: …`), never a conventional-commit prefix — `git log` is the reference. Body names the win and the verification. NEVER push.

## 7. Report

- Target: the choice and its smell class.
- Actions: deleted / merged / split / moved; the named quality win; LOC delta.
- Verification: exact commands and results, including the two `git status` golden checks.
- Risk: what a reviewer should look at.

<critical>
One target per run; complete migration; originals deleted; `make build` and `make test` clean; `fixtures/**` byte-identical. Named quality win; identical behavior; no new abstractions, settings, or shims. Deletion-leaning: justify a net-positive delta. Nothing above bar → `CLEAN: no target above threshold`.
</critical>
