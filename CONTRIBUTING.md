# Contributing

VoiceOour is fake-first. A contributor should be able to build, test, and smoke the app without downloading the Parakeet model, granting microphone permission, or configuring a network refiner.

## Local checks

Everything here is fake-backed and needs no model, microphone, TCC grant, or credential.

```sh
swift build                              # CI-enforced, warnings as errors
make test                                # CI-enforced; swift test with the UI harness compiled in
(cd asr && uv --no-config run pytest)     # CI-enforced
(cd bench && uv --no-config run pytest)   # CI-enforced
scripts/run_dev.sh --self-test            # CI-enforced
make bench-smoke                          # CI-enforced
make ui-snap                              # non-blocking CI job; treat as required locally
make ui-flow                              # CI-enforced semantic journey gate; no frame reconciliation
make ui-coverage                          # CI-enforced coverage-ratchet gate
make ui-flow-update                       # only when an intended flow or baseline change must be written
```

Use `make test`, not a bare `swift test`: the offscreen UI harness suites are compiled out unless
`UI_HARNESS` is defined, which is what keeps them out of the shipping binary.

`make ui-snap-os26` needs a macOS 26 host, so it is local-only. The env-gated integration tests are
deliberately absent from CI — see the table in `README.md` for what each one needs.

The `Makefile` wraps the common commands: `make build`, `make test`, `make python-test`,
`make bench-smoke`, `make ui-snap`, `make ui-flow`, `make ui-flow-update`, `make ui-coverage`,
`make ui-all`, `make format`, `make format-check`, and `make lint-python`.

`make ui-film` is not a check. It re-records the recording-island GIF at the top of `README.md`
from the real SwiftUI overlay through the harness and rewrites `docs/media/dictation-island.gif`.
Run it only when the overlay's appearance actually changed, and review the result by eye — a reel
is media, so no gate diffs it. It needs `ffmpeg` on `PATH`. See `docs/ui-harness.md`.

## Test tiers

- PR gate: Swift unit tests and Python sidecar tests, fake-backed and TCC-free.
- Opt-in integration tests: set `VOICEOOUR_OMP_INTEGRATION`, `VOICEOOUR_FM_INTEGRATION`, `VOICEOOUR_APPLE_SPEECH_INTEGRATION`, or `VOICEOOUR_MLX_INTEGRATION` to enable the corresponding real OMP RPC, Foundation Models (macOS 26+), Apple Speech/SpeechAnalyzer (macOS 26+), or MLX sidecar tests in `swift test`. `VOICEOOUR_OMP_MODEL` overrides the OMP model (default `anthropic/claude-haiku-4-5`), and `VOICEOOUR_OMP_BIN` selects the OMP executable.
- App smoke: `scripts/run_dev.sh --self-test`.
- UI gate: `make ui-snap`. Renders every scene offscreen and diffs it against `fixtures/ui/`. No window appears, the frontmost app does not change, and no TCC permission is needed. Read `.build/ui-harness/<scene>.ax.diff` before blessing anything with `make ui-update`, and commit the goldens with the change. See `docs/ui-harness.md`.
- UI flow gate: `make ui-flow`. Drives deterministic multi-step journeys through real views and the real `DictationCoordinator`, checks named semantics, and compares host-independent journals under `fixtures/ui/flows/`. A red flow cannot bless a golden or cover a ledger key. Use `make ui-flow-frames` when frame goldens are also relevant and `make ui-flow-update` only after reading `.build/ui-harness/flows/<flow>.flow.diff` and when the change is intended.
- UI coverage gate: `make ui-coverage`. Enforces `fixtures/ui/coverage-baseline.txt` in both directions: a newly uncovered key and a stale entry for a key now covered both fail. A filtered flow run cannot prove completeness; run the full gate before committing. When `make ui-flow-update` changes the baseline, a removed line is a gap closed; an added line is coverage dropped and needs justification in the pull request.
- Manual fake E2E: `scripts/run_dev.sh`, focus a text app, tap standalone Fn/Globe to start and tap it again to stop; Accessibility lets the event tap suppress the macOS emoji popup, while the passive fallback may show it.
- Real ASR proof: `scripts/make_fixture.sh`, then `cd asr && uv --no-config run python ../scripts/phase0_asr_proof.py ../fixtures/audio/hello_16k_mono.wav`.
- Release gate: bundled, signed, and notarized app with permissions granted on a clean macOS account.

## Coding rules

- Keep `VoiceCore` pure Swift/Foundation; no AppKit or AVFoundation there.
- Keep stdout from the Python sidecar protocol-only. Logs go to stderr.
- Add protocol fixture coverage on both Swift and Python sides for wire changes.
- Preserve protected glossary terms exactly after deterministic cleanup and after refiner output.
- Do not read or restore the user's previous clipboard.
- Do not paste into terminal, code editor, secure, or unknown-risky targets.
- Do not turn on network refinement by default.
- Add both a `UISceneCatalog` scene and a `UICoverageRegistry` entry for every new UI surface. Add a `UIFlow` for every new interactive behaviour and claim its required coverage key.

## Subsystem rules

### ASR wire protocol

- The ASR wire protocol is v1. New evidence fields (`ASRWord` and segment words, transcript `confidence`/`confidenceMode`, ranked `ASRHypothesis` with pre-bias `rawScore`, `ASRDecoderInfo`, request `biasPhrases`/`biasSnapshotId`, error `biasListTooLarge`) are additive and optional, so adding one never bumps the version.
- Mirror every new wire field in a single change across the Swift `ASRProtocol`, the Python sidecar protocol, and every `fixtures/protocol/*.json`. A field present on one side but missing on another is a broken change.

### Vocabulary trust boundaries

- Only cloud-eligible, non-tombstoned, non-project-scoped terms may reach the network refiner (`OmpRpcRefiner`) prompt; the on-device backend (`FoundationModelsRefiner`) keeps the full active set. Never widen what the network prompt sees.
- Ephemeral context candidates, project-scoped terms, cloud-ineligible imports, and tombstoned terms must never cross the cloud boundary.
- Only explicit user action (Sessions Fix/Teach, suggestion accept, Glossary Import, System "Clear learned vocabulary") may set a term's confirmed or `tombstonedAt` timestamps. Never set them from automatic or background paths.
- Keep the per-utterance active snapshot bounded (<= 100 terms) and compiled from the captured target's bundle id and active project.

### Default-off automation

- Automatic term correction (`Settings.automaticTermCorrectionEnabled`) and decoder bias (`Settings.decoderBiasEnabled`) ship default-off and stay off until measured on a consented real-speaker corpus; TTS smoke numbers do not qualify.
- Before enabling either, clear the gates on real-speaker data: U-WER regression <= +0.35 pp and no false-activation/false-replacement regression. Keyword spotting is deferred under the same rule.

### Audio and MLX invariants

- Never persist audio.
- Keep MLX/Metal work serialized on its dedicated thread; do not move Parakeet inference off it.

## Dependency notes

The app uses a local active session-level `CGEventTap` (`.cgSessionEventTap`) for Fn/Globe capture instead of `KeyboardShortcuts` because the current CLI toolchain cannot compile KeyboardShortcuts 2.x. It toggles on a standalone Fn/Globe tap and, when Accessibility is granted, consumes the Globe "assigned action" key event so the macOS emoji popup is suppressed; it preserves Fn+other-key combinations and falls back to a passive monitor if Accessibility is unavailable. The same binder claims an unmodified Escape to discard a live session, gated by `HotkeyBinding.setCancelArmed(_:)` which the coordinator drives from `SessionState.isActive` — Escape is never touched while no session is running.
