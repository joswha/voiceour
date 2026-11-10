# Voiceour engineering map

Voiceour is local-only macOS dictation. [README.md](README.md) owns the product contract; this file maps the code to the contract that governs each part. [`.omp/RULES.md`](.omp/RULES.md) holds the invariants every change keeps: omp injects it into every session and subagent; other agents read it first. RFC 2119 keywords apply here and in every contract doc; NEVER = MUST NOT, AVOID = SHOULD NOT.

## Contracts

Before editing, read the contract for what you are changing; update it in the same commit as the behavior.

- [docs/runtime.md](docs/runtime.md): dictation lifecycle, hotkeys, capture, cancellation, delivery and insertion safety, clipboard, persistence, network, environment variables, permissions, signing, running the app.
- [docs/text-pipeline.md](docs/text-pipeline.md): term spotting, literal commands, cleanup, repair, language detection, glossary and its editors, word-list import.
- [docs/asr.md](docs/asr.md): `voiceour-asr`, the NDJSON protocol, the model pin, model cache and acquisition, Granite, `Vendor/`.
- [docs/console-ui.md](docs/console-ui.md): console window and tabs, History, menu, design tokens.
- [docs/memory.md](docs/memory.md): memory folder, entry schema, derived pages, write planner, when dictations fold in, agent access.
- [docs/recording-island.md](docs/recording-island.md): recording island, notch collar, mercury, Island garage; derivations in [docs/mercury-renderer.md](docs/mercury-renderer.md).
- [docs/ui-harness.md](docs/ui-harness.md): UI harness, scenes, flows, goldens, `RenderOverrides`.
- [docs/benchmarks.md](docs/benchmarks.md): benchmarks, `bench/`, `voiceour-bench`.
- [docs/release.md](docs/release.md): version, release notes, publishing, notarization.

## Architecture boundaries

Swift tools 6.4, Swift 6 language mode, macOS 27, arm64 only. `Voiceour` names the app and target, `voiceour` the package and repository; NEVER rename either without instruction.

- `VoiceCore` holds Foundation-only models, settings, state, text stages, glossary, ASR wire types, history/ledger, failures and safety policy. It MUST NOT import AppKit, SwiftUI, AVFoundation, Accessibility, event posting, pasteboard, process-launch, or Keychain APIs; put OS side effects behind `VoiceMac` contracts.
- `VoiceMac` holds the macOS adapters; NEVER SwiftUI. `Voiceour` holds SwiftUI and orchestration: `DictationCoordinator` stays `@MainActor`; the stop path is `TranscriptProcessingPipeline.swift`.
- `ASRSidecarCore` imports `VoiceCore` and `CGranite`, NEVER `VoiceMac`. `voiceour-asr` (`VoiceourASR`) is the only long-lived child process; the only other children are the self-relaunch and, while agent session binding is on, the signature-verified `tern` CLI of the Tern app being pasted into ([runtime.md › Agent session binding](docs/runtime.md#agent-session-binding)).
- Production targets MUST NOT import `Voiceour`; tests may.
- MUST preserve injection for recording, ASR, targets, insertion, permissions, hotkeys, muting, settings, recent sessions, agent session resolution and reading.
- `../syncour` consumes `VoiceCore` and `VoiceMac` by path dependency. Their public APIs are external contracts; Syncour's owner handles its platform/toolchain migration.
- Backends: `granite` (default and only recognizer), `fake` (deterministic development).

## Swift conventions

- SHOULD use concrete target-boundary types and small protocols.
- Observable state MUST stay main-actor isolated. Blocking capture, I/O, hashing, model work stay off-main; 25 Hz meter data stays off coordinator observation.
- MUST use structured ownership for files/processes/capture/persistence tails; identity-check teardown against newer owners.

## Developer commands

`make` lists every target; release, harness, benchmark and vendor commands live in their contract docs.

- Gates: `make build` (Swift/C/C++ warnings are errors), `make test` (harness included), `make format-check`, `make check-docs`, `make ui-snap`, `make ui-flow`, `make lint-python` / `make test-python` for `bench/`. `make check` runs the full local gate.
- `make dev` runs the fake-backend debug app in the terminal. `make run` stops the running app, then rebuilds and launches the real bundle.
- Granite model fixture proof: `make build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav`. Run real-model checks only when the task needs them and the model is downloaded.

## Git and documentation

- Generated data/build artifacts stay uncommitted unless their artifact type is explicitly tracked.
- Intended AX/digest/flow goldens MUST accompany the behavior change requiring them.
- Keep AGENTS.md and `.omp/RULES.md` short: a subsystem rule belongs in its contract doc. The rules for editing docs and `.omp/rules/` load with the first such edit (`.omp/rules/read-docs-rules.md`).
