---
description: Classify and label newly opened issues against the Voiceour taxonomy — primary, priority, functional scope, macOS version.
---

# Triage

Classify and label newly opened GitHub issues that are missing labels.

## Arguments

`$ARGUMENTS`: optional `--days <n>`, default `7`. Triage only open issues created inside that window.

## 0. Taxonomy prerequisite — one time

GitHub's default label set covers the primary axis only. The priority, functional, and macOS-version labels below MUST exist before the command can apply them. `--force` makes this file authoritative for the labels it defines and leaves GitHub's own defaults untouched:

```bash
while IFS='|' read -r name color desc; do
  [ -n "$name" ] && gh label create "$name" --color "$color" --description "$desc" --force
done <<'LABELS'
proposal|c2e0c6|Design or process proposal needing a maintainer decision
prio:p0|b60205|Critical blocker: data loss, security, or an unusable workflow
prio:p1|d93f0b|High impact: a common workflow is broken
prio:p2|fbca04|Medium impact: a workaround exists
prio:p3|fef2c0|Low impact: edge case or minor issue
asr|1d76db|Sidecar, wire protocol, model acquisition, decode
capture|0e8a16|Audio capture, input devices, WAV finalization, auto-stop
hotkey|5319e7|Fn/Globe gesture, event tap, key suppression
insertion|b60205|Pasteboard, paste vs copy-only, insertion safety classes
permissions|d4c5f9|Microphone, Accessibility trust, secure input, TCC
console|0052cc|The console window: Home, Glossary, History, Settings
overlay|006b75|The recording overlay and its placement
glossary|bfd4f2|Terms, aliases, Teach, canonicalization
history|c5def5|Session records, transcript detail, search and app filter
persistence|fbca04|Settings, history, and lifetime-ledger files
benchmarks|d0e0e3|bench/ tooling, datasets, reports, gates
packaging|5319e7|Bundle, signing, notarization, release artifacts
harness|e99695|Offscreen UI harness, scenes, flows, goldens
vendor|ededed|Vendored parakeet.cpp and ggml
os:macos14|c2e0c6|Reproduced on or specific to macOS 14
os:macos15|c2e0c6|Reproduced on or specific to macOS 15
os:macos26|c2e0c6|Reproduced on or specific to macOS 26, including Liquid Glass
LABELS
```

## 1. Fetch

Parse `$ARGUMENTS` for `--days` (default `7`).

```bash
DAYS=7                                  # or the value parsed from --days
CUTOFF="$(date -u -v-"${DAYS}"d +%Y-%m-%d)"   # -v is BSD date; this repository is macOS-only
gh issue list --state open --search "created:>=${CUTOFF}" \
  --json number,title,body,labels,comments,createdAt --limit 50
```

## 2. Candidates

Skip issues older than the cutoff. Of the rest, skip only when every applicable requirement already holds:

- Exactly one primary: `bug` | `enhancement` | `question` | `proposal` | `documentation` | `invalid` | `duplicate`.
- `bug` → exactly one `prio:*`.
- An applicable functional scope → at least one functional label.
- A macOS-version-bound report → the matching `os:*`.

## 3. Classification

Read the title, the body, and every comment; the comments usually carry the reproduction and the version. One primary, one priority for `bug` only, all applicable functional labels. `os:*` requires explicit evidence.

**Primary**
- `bug` — broken existing behavior: crash, hang, wrong transcript delivery, regression, "doesn't work".
- `enhancement` — a feature request or an improvement to existing behavior.
- `question` — how-to, clarification, usage.
- `proposal` — a design or process proposal needing a maintainer decision.
- `documentation` — missing, incorrect, or outdated docs.
- `invalid` — spam, off-topic, not actionable.
- `duplicate` — a clear duplicate; reference the original in a comment.

**Bug priority**
- `prio:p0` — dictation is unusable, text lands in the wrong place, a secure field's contents are exposed, audio is persisted, the app cannot launch.
- `prio:p1` — a common workflow is broken: the hotkey does not fire, the model will not load, insertion silently drops, the console will not open.
- `prio:p2` — medium impact with a workaround, including copy-only fallback where paste was expected.
- `prio:p3` — cosmetic or an edge case: a label, a rounding, an uncommon device.

**Functional** — all that apply
- `asr` — sidecar lifecycle, NDJSON protocol, model download or verification, decode quality and timing.
- `capture` — microphone capture, device selection or disconnect, WAV finalization, auto-stop, muting.
- `hotkey` — the Fn/Globe gesture, the event tap, Escape handling, key suppression.
- `insertion` — pasteboard writes, paste versus copy-only, safety classification of a target app, Cmd-V.
- `permissions` — microphone or Accessibility prompts, trust loss, secure input, degraded modes.
- `console` — the window and its four tabs, including Home's figures and Settings' controls.
- `overlay` — the recording overlay, its placement, its display.
- `glossary` — terms, aliases, Teach, canonicalization, import.
- `history` — session rows, the open transcript, search, the app filter, copy and teach gestures.
- `persistence` — settings, `recent-sessions.json`, the lifetime ledger, corruption and quarantine.
- `benchmarks` — `bench/` tooling, datasets, reports, gates.
- `packaging` — bundling, signing, notarization, Gatekeeper, release assets, first-launch trust.
- `harness` — the offscreen UI harness, scenes, flows, goldens, lint.
- `vendor` — vendored parakeet.cpp or ggml, the pin, the patch ledger.

**macOS version** — only when material to reproduction or root cause
- `os:macos14`, `os:macos15` — the painted pre-macOS-26 glass path and the deployment floor.
- `os:macos26` — native Liquid Glass, `NSGlassEffectView`, the native harness legs.

Do not label a hardware generation. The app is Apple Silicon only by design; an Intel or universal-build request is `wontfix`, not a platform label.

**Meta** — manual judgment only. Automated triage NEVER applies `good first issue` or `help wanted`.

`wontfix` belongs on a request refused by a standing product decision, applied with the citation in a comment. The recurring ones: an Intel or universal build (the vendored drop is arm64-only and asserts it at compile time); cloud ASR, telemetry, crash reporting, accounts, or an update check (exactly one network path exists, the pinned model artifact); a "paste everywhere" switch (`InsertionSafetyPolicy` is the single class-to-disposition mapping); clipboard save-and-restore; persisted audio; a keychain-backed feature (this bundle ships no provisioning profile).

## 4. Apply

Add the chosen labels; NEVER remove an existing one.

```bash
gh issue edit <number> --add-label "bug,prio:p1,insertion,permissions"
```

## 5. Summary

```
## Triage Summary

|#|Title|Added Labels|Skipped|
|---|---|---|---|
|42|Nothing pastes into Ghostty|bug, prio:p2, insertion||
|38|Offer a Small model variant|enhancement, asr||
|35|How do I teach a spelling?|question, glossary||
|30|Universal build for Intel Macs|wontfix|arm64-only by design|
|27|Already labeled|—|Complete|
```

Then: `Processed: X | Labeled: Y | Skipped: Z`

## Rules

- `os:*` only for behavior that is version-specific or was reproduced on exactly one macOS version.
- Named subsystem → the functional label, not a guess from the title alone. A "transcript is wrong" report is `asr` when the decode is wrong and `glossary` when canonicalization is.
- A `bug` always carries exactly one `prio:*`.
- `wontfix` always arrives with a comment citing the standing decision; a silent `wontfix` is worse than no label.
- A sparse body is classified from the comments; NEVER skip an issue before reading them.
- NEVER remove a maintainer's existing label, and NEVER close an issue from this command.
