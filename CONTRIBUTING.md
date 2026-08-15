# Contributing

Voiceour is fake-first. A contributor should be able to build, test, and smoke the app without downloading the Parakeet model, granting microphone permission, or configuring a network refiner.

## Local checks

Everything here is fake-backed and needs no model, microphone, TCC grant, or credential. The
required `ci` job runs:

```sh
make build
make format-check
make check-docs
make lint-python
make test
make ui-flow
make ui-coverage
(cd bench && uv --no-config run pytest)
scripts/run_dev.sh --self-test
make bench-smoke
```

`make lint-python` and the explicit pytest command operate only on `bench/`, which never ships.

Use `make test`, not a bare `swift test`: the offscreen UI harness suites are compiled out unless
`UI_HARNESS` is defined, which is what keeps them out of the shipping binary.

CI also rejects the introduction of a local control-plane directory, fixture set, or symbol. That
workflow-only assertion is recorded in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

The separate, non-blocking hosted UI job runs `make ui-snap` and `make ui-flow-frames`; treat both
as required visual review locally. `make ui-snap-os26` needs a macOS 26 host and remains local-only.
The env-gated integration tests are deliberately absent from CI because each needs a credential,
model download, or newer OS. The complete command and UI-target inventory is in
[`docs/developer-setup.md`](docs/developer-setup.md).

`make ui-film` is not a check. It re-records the recording-island GIF at the top of `README.md`
from the real SwiftUI overlay through the harness and rewrites `docs/media/dictation-island.gif`.
Run it only when the overlay's appearance actually changed, and review the result by eye. A reel
is media, so no gate diffs it. It needs `ffmpeg` on `PATH`. See `docs/ui-harness.md`.

## Test tiers

- Required PR gate: every command in the local-checks block above plus CI's no-control-plane assertion.
- Opt-in integration tests: set `VOICEOUR_OMP_INTEGRATION`, `VOICEOUR_FM_INTEGRATION`, `VOICEOUR_APPLE_SPEECH_INTEGRATION`, or `VOICEOUR_PARAKEET_INTEGRATION` to enable the corresponding real OMP RPC, Foundation Models (macOS 26+), Apple Speech/SpeechAnalyzer (macOS 26+), or Swift Parakeet sidecar tests in `swift test`. `VOICEOUR_OMP_MODEL` overrides the OMP model (default `anthropic/claude-haiku-4-5`), and `VOICEOUR_OMP_BIN` selects the OMP executable.
- App smoke: `scripts/run_dev.sh --self-test`.
- Advisory UI snapshot check: `make ui-snap`. Renders every scene offscreen and diffs it against `fixtures/ui/`. No window appears, the frontmost app does not change, and no TCC permission is needed. Read `.build/ui-harness/<scene>.ax.diff` before blessing anything with `make ui-update`, and commit the goldens with the change. See `docs/ui-harness.md`.
- UI flow gate: `make ui-flow`. Drives deterministic multi-step journeys through real views and the real `DictationCoordinator`, checks named semantics, and compares host-independent journals under `fixtures/ui/flows/`. A red flow cannot bless a golden or cover a ledger key. Use `make ui-flow-frames` when frame goldens are also relevant and `make ui-flow-update` only after reading `.build/ui-harness/flows/<flow>.flow.diff` and when the change is intended.
- UI coverage gate: `make ui-coverage`. Enforces `fixtures/ui/coverage-baseline.txt` in both directions: a newly uncovered key and a stale entry for a key now covered both fail. A filtered flow run cannot prove completeness; run the full gate before committing. When `make ui-flow-update` changes the baseline, a removed line is a gap closed; an added line is coverage dropped and needs justification in the pull request.
- Manual permission/insertion E2E: follow the fake and real checklists in [`docs/permissions.md`](docs/permissions.md).
- Real ASR proof: `swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav`.
- Release gate: bundled, signed, and notarized app on a clean macOS account, followed by the release insertion matrix in [`docs/permissions.md`](docs/permissions.md).

## Coding rules

- Keep `VoiceCore` pure Swift/Foundation; no AppKit or AVFoundation there.
- Keep stdout from the ASR sidecar protocol-only. Logs go to stderr.
- Change the Swift protocol models and the fixtures in `fixtures/protocol/` together.
- Preserve protected glossary terms exactly after deterministic cleanup and after refiner output.
- Do not read or restore the user's previous clipboard.
- Do not paste into terminal, code editor, secure, or unknown-risky targets.
- Do not turn on network refinement by default.
- Add both a `UISceneCatalog` scene and a `UICoverageRegistry` entry for every new UI surface. Add a `UIFlow` for every new interactive behaviour and claim its required coverage key.

## Subsystem rules

### ASR wire protocol

- The ASR wire protocol is v1.
- Change every wire field in one change across the Swift protocol models and the fixtures in `fixtures/protocol/`. A field present in only one is a broken change.

### Vocabulary trust boundaries

- Only cloud-eligible, non-tombstoned, non-project-scoped terms may reach the network refiner (`OmpRpcRefiner`) prompt; the on-device backend (`FoundationModelsRefiner`) keeps the full active set. Never widen what the network prompt sees.
- Ephemeral context candidates, project-scoped terms, cloud-ineligible imports, and tombstoned terms must never cross the cloud boundary.
- Only explicit user action (Sessions Fix/Teach, suggestion accept, Glossary Import, System "Clear learned vocabulary") may set a term's confirmed or `tombstonedAt` timestamps. Never set them from automatic or background paths.
- Keep the per-utterance active snapshot bounded (<= 100 terms) and compiled from the captured target's bundle id and active project.

### Audio and Parakeet invariants

- Never persist audio.
- Keep Parakeet work serialized on the ASR sidecar's dedicated decode queue.

## Dependency notes

The app uses a local active session-level `CGEventTap` (`.cgSessionEventTap`) for Fn/Globe capture instead of `KeyboardShortcuts` because the current CLI toolchain cannot compile KeyboardShortcuts 2.x. It toggles on a standalone Fn/Globe tap and, when Accessibility is granted, consumes the Globe "assigned action" key event so the macOS emoji popup is suppressed; it preserves Fn+other-key combinations and falls back to a passive monitor if Accessibility is unavailable. The same binder claims an unmodified Escape to discard a live session, gated by `HotkeyBinding.setCancelArmed(_:)` which the coordinator drives from `SessionState.isActive`. Escape is never touched while no session is running.
