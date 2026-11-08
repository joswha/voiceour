# Voiceour engineering map

Voiceour is local-only macOS dictation. [README.md](README.md) owns the product contract. This file maps the code to the contract that governs each part. [`.omp/RULES.md`](.omp/RULES.md) holds the invariants every change keeps: omp injects it into every session and subagent; other agents read it first.

RFC 2119 keywords apply here and in every contract doc; NEVER = MUST NOT, AVOID = SHOULD NOT.

## Contracts

Before editing, read the contract for what you are changing; update it in the same commit as the behavior.

| change touches | contract |
| --- | --- |
| Dictation lifecycle, hotkeys, capture, cancellation, delivery and insertion safety, clipboard, persistence, network, environment variables, permissions, signing, running the app | [docs/runtime.md](docs/runtime.md) |
| Term spotting, literal commands, cleanup, repair, language detection, glossary and its editors, word-list import | [docs/text-pipeline.md](docs/text-pipeline.md) |
| `voiceour-asr`, the NDJSON protocol, model cache and acquisition, Granite, `Vendor/` | [docs/asr.md](docs/asr.md) |
| Console window and tabs, History, menu, design tokens | [docs/console-ui.md](docs/console-ui.md) |
| Recording island, notch collar, mercury, Island garage | [docs/recording-island.md](docs/recording-island.md); derivations in [docs/mercury-renderer.md](docs/mercury-renderer.md) |
| UI harness, scenes, flows, goldens, `RenderOverrides` | [docs/ui-harness.md](docs/ui-harness.md) |
| Benchmarks, `bench/`, `voiceour-bench` | [docs/benchmarks.md](docs/benchmarks.md) |
| Version, release notes, publishing, notarization | [docs/release.md](docs/release.md) |

## Architecture boundaries

Platform: Swift tools 6.4, Swift 6 language mode, macOS 27, arm64 only. Names: `Voiceour` app/target; `voiceour` package/repository. NEVER rename without instruction.

| path / target | responsibility / boundary |
| --- | --- |
| `Sources/VoiceCore/` | Foundation-only models, settings, state, text stages, glossary, ASR wire types, history/ledger, failures, safety policy |
| `Sources/VoiceMac/` | macOS adapters: capture, fake audio, sidecar, focus, pasteboard, permissions, hotkeys, muting, installed apps, word-list import; NEVER SwiftUI |
| `Sources/Voiceour/` | SwiftUI and orchestration; `DictationCoordinator` stays `@MainActor`; stop path in `TranscriptProcessingPipeline.swift` |
| `Sources/ASRSidecarCore/` | Acquisition/cache (`ModelCache`), WAV, Granite context/transcript mapping, backends, server; imports `VoiceCore` + `CGranite`, NEVER `VoiceMac` |
| `Sources/VoiceourASR/` | Signed sibling `voiceour-asr`; vendored ggml + Granite port; NDJSON v1 |
| `Sources/VoiceourBench/` | `voiceour-bench`: production-path measurement |
| `Sources/ASRSidecarStub/` | `ASRSidecarStub` protocol helper; non-shipping |
| `Sources/Voiceour/UIHarness/` | Compile-gated scene/flow renderer, AX/PNG reports, lint, mercury benchmark |
| `Vendor/ggml/` | `CGgml`: ggml sources (upstream-relative), pin, ordered patches, embedded Metal; `NOTICE.md`, `LICENSE` |
| `Vendor/granite/` | `CGranite`: adapted transcribe.cpp Granite port on `CGgml`; frozen `include/granite.h`, `NOTICE.md` file map, `LICENSE` |
| `Tests/`, `fixtures/protocol/`, `fixtures/ui/` | Swift Testing suites; protocol-v1 fixtures; AX/digest/flow goldens |
| `bench/`, `benchmarks/` | Non-shipping Python tooling; prepared data and committed measurement reports |
| `scripts/`, `docs/`, `research/` | Workflows; subsystem contracts and evidence; dated experiments |

- `VoiceCore` MUST NOT import AppKit, SwiftUI, AVFoundation, Accessibility, event posting, pasteboard, process-launch, or Keychain APIs. Put OS side effects behind `VoiceMac` contracts.
- Production targets MUST NOT import `Voiceour`; tests may.
- MUST preserve injection for recording, ASR, targets, insertion, permissions, hotkeys, muting, settings, recent sessions.
- `../syncour` consumes `VoiceCore` and `VoiceMac` by path dependency. Their public APIs are external contracts; Syncour's owner handles its platform/toolchain migration.
- Registered backends, picker order `fake`, `granite`: `granite` (default and only recognizer; [model contract](docs/asr.md#model-contract-and-vendor-rules)), `fake` (deterministic development). Retired `mlx`, `ark-0.6b`, `ark-3b`, `apple`, `parakeet` ids normalize to `granite` (`LaunchOptions.retiredBackendIDs`).
- `voiceour-asr` is the only child process. Pinned model acquisition is the only network path.

## Model pin

Model `vladers/granite-speech-5.0-470m-turboctc-GGUF`, revision `bd7db273aa69a26fc81e370c84597fa738fe2ad0`: the Q8_0 file of the maintainers' reproducible GGUF set of `ibm-granite/granite-speech-5.0-470m-turboctc` @ `1dd23f46f6d4e6eae2531982ba2e33220086dd97` (IBM, Apache-2.0), whose `conversion/build.sh` rebuilds every file byte for byte:

| file | SHA-256 | bytes |
| --- | --- | ---: |
| `granite-speech-5.0-470m-turboctc-Q8_0.gguf` | `fc34cbe71f979a6aeb8bea08bfac88d5c62c1736c0bc845827e37c90f28e336c` | 505,663,136 |

`GraniteModelContract` in `Sources/VoiceCore/ASRProtocol.swift` is the source; `make check-docs` checks this section, README.md and NOTICE against it. Re-pinning follows [docs/asr.md](docs/asr.md#model-contract-and-vendor-rules).

## Swift conventions

- SHOULD use concrete target-boundary types and small protocols.
- Observable state MUST stay main-actor isolated. Blocking capture, I/O, hashing, model work stay off-main; 25 Hz meter data stays off coordinator observation.
- MUST use structured ownership for files/processes/capture/persistence tails; identity-check teardown against newer owners.
- MUST reuse conventions, migrate callers, delete obsolete internal APIs. Avoid unnecessary allocation, copying, computation in hot paths.

## Developer commands

Use the smallest proving command. `make` lists the catalogue; release, harness, benchmark and vendor commands live in their contract docs.

| task | command |
| --- | --- |
| Build; Swift/C/C++ warnings are errors | `make build` |
| Swift tests, harness included | `make test` |
| Full local gate | `make check` |
| Format / check format | `make format` / `make format-check` |
| Model pins + documented commands | `make check-docs` |
| Python lint / tests | `make lint-python` / `make test-python` |
| Bundle / verify | `make bundle` / `make verify-bundle` |
| Stable local signer | `make signing` |
| Fake debug app / real bundle | `make dev` / `make run` |
| Stop / status / logs | `make stop` / `make status` / `make logs` |
| Generate local audio fixture | `make fixture` |
| Granite model fixture proof | `make build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav` |
| Scene gate / bless / inventory | `make ui-snap` / `make ui-update` / `make ui-list` |
| Flow gate / bless / inventory | `make ui-flow` / `make ui-flow-update` / `make ui-flow-list` |
| Offline fake benchmark | `make bench-smoke` |

- Real-model/microphone checks require task relevance and available prerequisites; microphone also requires explicit interruption consent.

## Git and collaboration

- MUST fetch before pushing and preserve remote commits. NEVER force-push, bypass protection, or publish unverified work. If direct push is blocked, report the exact blocker.
- Generated data/build artifacts stay uncommitted unless their artifact type is explicitly tracked.
- Intended AX/digest/flow goldens MUST accompany the behavior change requiring them.

## Documentation rules

- README.md owns the product contract: behavior, architecture, data, model/network, safety, development, verification. AGENTS.md is this map: boundaries, model pin, commands, git. `.omp/RULES.md` holds only invariants that bind every change. Each contract doc in the table above owns its subsystem's engineering rules. MUST update the owning contract in the same change.
- Keep AGENTS.md and `.omp/RULES.md` short: a subsystem rule belongs in its contract doc.
- Evidence docs — `docs/mercury-renderer.md` (derivations), `docs/benchmarks.md`, `docs/performance-roadmap.md` and `research/` (measurements) — link back to the contract they serve; NEVER redefine product policy or promote dated evidence into shipping claims.
- `CONTRIBUTING.md`: PR gates. `SECURITY.md`: reporting. `CHANGELOG.md`: user-visible changes/release notes.
- One owner per topic; link elsewhere. Declarative current-state prose, not deletion history. Archive useful superseded records under `docs/archive/` with date/notice; `docs/superpowers/` contains historical plans. NEVER add new plan/redirect documents.
- Every documented command MUST exist. `make check-docs` checks model pins and make/script references in roots, CONTRIBUTING, top-level docs. Preserve linked headings.
