# Development Rules

## Default Context

Voiceour is a macOS menu-bar dictation app. The intended user flow is: focus any text input, tap Fn/Globe by itself, speak one utterance, transcribe locally through the ASR sidecar, clean/refine text when configured, then paste or copy the final text into whichever target is focused when delivery begins.

The product/repo name appears as `Voiceour` / `voiceour`. Do not rename either without explicit instruction.

## Terminology

- **Voiceour**: the Swift executable target and macOS app.
- **VoiceCore**: pure Swift/Foundation domain logic and contracts.
- **VoiceMac**: macOS adapters for audio, pasteboard, permissions, hotkeys, process management, and optional refinement.
- **ASR sidecar**: the Swift `voiceour-asr` executable under `Sources/VoiceourASR/`, linking the vendored parakeet.cpp under `Vendor/parakeet/`, that speaks the transcription protocol over stdio.
- **Refiner**: the optional text refinement layer. It has exactly two destinations: `omp`, the locally installed Oh My Pi CLI, which brokers every network model and owns every credential involved; and Apple's on-device system model. It is not the ASR model and must remain opt-in.
- **Capture target**: the app/window context captured before recording starts for vocabulary, cleanup, and refinement decisions.
- **Delivery target**: the app/window/text destination focused immediately before insertion begins.

## Repository Structure

| Path | Purpose |
| --- | --- |
| `Sources/VoiceCore/` | Foundation-only models, session state, settings, cleanup, glossary, ASR wire types, and safety classification. |
| `Sources/VoiceMac/` | macOS-specific adapters: audio recording, fake audio, sidecar process client, target tracking, pasteboard insertion, permissions, Carbon hotkey binding, and the optional refiner backends. |
| `Sources/Voiceour/` | SwiftUI `MenuBarExtra`, settings UI, recording overlay, and `DictationCoordinator` orchestration. |
| `Sources/Voiceour/UIHarness/` | Offscreen UI harness: scene and flow catalogs, inert fixtures, deterministic runner, accessibility dump, UX lint, coverage ledger, and the `--ui-harness` CLI. |
| `Vendor/parakeet/` | Vendored parakeet.cpp and ggml sources, with the upstream pin and local patch ledger in `NOTICE.md`. |
| `Sources/ASRSidecarCore/` | Model cache, WAV reader, parakeet context wrapper, token mapping, fake backend, and NDJSON server. |
| `Sources/VoiceourASR/` | Swift executable target for the shipped `voiceour-asr` sidecar. |
| `Sources/ASRSidecarStub/` | Test-only executable for exercising sidecar transport failures; never shipped. |
| `fixtures/protocol/` | Golden NDJSON/JSON protocol fixtures decoded by Swift protocol tests. |
| `fixtures/text/` | Text cleanup fixtures. |
| `fixtures/ui/` | Committed UI goldens: one accessibility dump and one PNG digest per scene. |
| `Resources/` | App plist and entitlements. |
| `docs/` | Architecture, permissions, setup, and scoped product notes. |
| `scripts/` | Developer, smoke, fixture, bundle, signing, and real/fake run scripts. |

## Architecture Boundaries

- Keep `VoiceCore` pure Swift/Foundation. Do not import AppKit, SwiftUI, AVFoundation, Accessibility, CoreGraphics event posting, pasteboard APIs, process-launch APIs, or Keychain APIs there.
- Put macOS APIs and side effects in `VoiceMac` behind small protocols/types consumed by the app layer.
- Keep `Voiceour` focused on UI and orchestration. `DictationCoordinator` owns the live session flow and should stay `@MainActor` for observable UI state.
- Preserve dependency injection around recording, ASR, target tracking, insertion, permissions, hotkeys, refinement, settings, and recent-session storage. Tests and fake development rely on substitutable services.
- Keep fake-backend development intact. The fake ASR/audio path is the default smoke path and must not require microphone permission, model download, or network refiner configuration.

## Runtime Flow

The core session flow is:

```text
idle -> checkingPermissions -> recording -> finalizingAudio -> transcribing -> cleaning -> refining -> readyToInsert -> pasteAttempted/copiedOnly -> idle
```

Important invariants:

- Snapshot the capture target before recording starts and use it for utterance context. Snapshot the delivery target again immediately before insertion; insertion safety and recent-session destination metadata use that latest target.
- Keep the recording overlay on the focused target's display. A saved manual position is relative to the display, never an absolute pin to one monitor.
- Ignore stale async work with generation/cancellation checks. Do not let an old transcription/refinement result update current UI state.
- Remove temporary audio files on success, cancellation, and error paths when the coordinator still owns the file.
- Skip refinement unless it is enabled/configured and the target class allows it.
- Surface unsafe or unavailable paste paths as copy-only behavior, not silent failure.

## ASR Sidecar Protocol

The sidecar protocol is newline-delimited JSON over stdio.

- **stdout is protocol-only.** Never print logs, progress bars, tracebacks, warnings, or dependency output to stdout from the sidecar.
- Diagnostics, progress, and backend logs go to stderr.
- Every message carries `protocol_version: 1`.
- Startup emits `hello`.
- Accepted request types are `health`, `transcribe`, and `cancel`.
- Each `transcribe` request must produce exactly one terminal `result`, `error`, or `cancelled` response.
- The sidecar is a persistent process: the Swift client spawns it once, keeps stdio open, and multiplexes requests by `request_id`; the sidecar serializes decodes on one queue while keeping cancellation and health handling actionable during an in-flight request.
- `VOICEOUR_PRELOAD=1` acquires the pinned model in the background after `hello`, loads it, and runs one throwaway decode so the first dictation does not pay Metal pipeline materialisation.
- The wire no longer carries `bias_phrases`, `bias_snapshot_id`, `hypotheses`, or `decoder`; `ASRConfidenceMode` contains only `none` and `greedy_token_prob`.
- Wire-contract changes must update Swift protocol models and the shared fixtures in `fixtures/protocol/` together.

## Privacy and Insertion Safety

This app touches the user's active workspace. Treat insertion safety as product-critical.

- Never read, snapshot, restore, upload, or inspect the user's previous clipboard contents.
- Write only the final dictated text needed for copy/paste to `NSPasteboard.general`.
- Do not paste into terminal, code-editor, secure, or unknown-risky targets. These must degrade to copy-only.
- Re-check target identity before writing the pasteboard and again before synthetic paste.
- Use pasteboard write plus Cmd-V event posting for eligible insertion. Do not mutate text fields directly with Accessibility APIs.
- Secure keyboard entry is a target-safety signal, not just an AX role. `WorkspaceTargetTracker` samples `IsSecureEventInputEnabled()` and an active flag forces `.secure` (copy-only). Do not remove it because AX already covers the known password managers: it exists for the ones AX cannot see.
- Copy-only text carries `org.nspasteboard.ConcealedType` and pasted text carries `org.nspasteboard.TransientType` so clipboard-history managers can skip it. Always keep writing the plain `.string` type too.
- Strip exactly one trailing newline for terminal copy-only text so a copied command is not accidentally executed on paste.
- If event-post/Accessibility permission is missing or unstable, copy only and report the reason.
- Recent transcripts must remain local and clearable from the Sessions view. Do not persist audio history; temporary audio files should be removed when no longer needed.
- Dictation history is two files with different bounds: `recent-sessions.json` (newest 500 transcripts) and `dictation-stats.json` (`DictationStatsLedger`, uncapped aggregates). Both are written behind one FIFO and "durable" means both took the change. Never derive a lifetime statistic from the capped transcript corpus, and never estimate the time economy — a dictation without capture timing is excluded from it, not given an assumed speaking rate.
- The ledger stores no transcript text beyond one 320-character record preview. Clearing history resets it; deleting a single transcript keeps the lifetime counts and drops any quote sourced from that session.

## Local-First and Network Policy

- Real ASR is local through the `parakeet` backend and its Swift/C sidecar. The current model is `ggml-org/parakeet-GGUF` at revision `35156454d1a39de06863303dd209fd2bed6ee079`, file `ggml-parakeet-tdt-0.6b-v3-f16.bin`. An opt-in `apple` backend (macOS 26+) uses the on-device SpeechAnalyzer/SpeechTranscriber instead of the sidecar; it is also fully local.
- Do not replace the model id or revision casually. `Vendor/parakeet/` and the model pin move together; treat model identity, cache manifest behavior, docs, and tests as one compatibility contract.
- The cache manifest records `model_id`, `revision`, `file`, `sha256`, and `size_bytes`. The digest is verified once at download; later launches check the pinned file's presence and size. No separate offline-mode environment flag or Hugging Face snapshot layout is involved.
- Network access is acceptable for first model download/cache setup or when the user explicitly enables/configures the optional refiner.
- Never enable network refinement by default.
- Network refinement leaves this machine only through the `omp` subprocess. Voiceour holds no provider credential: no API-key field, no credential environment variable, no keychain item, and no per-provider base URL. Do not add one back — OMP already reaches every provider on the user's behalf, and the entitlement reason a keychain cannot work here is recorded in `docs/architecture.md`.
- The Model field is a picker whose options come from `omp models --json`; never reintroduce a free-text model id. `OmpModelCatalog.load` is the single loader behind both the picker and the CHECK probe so the two can never describe different lists.
- That catalog query is the one `omp` call that runs with `shadowCredentials: false`, and it must stay that way. The single-space credential tombstones protect the transcript-bearing path, but OMP advertises a provider whenever its variable is *set*: shadowed, `omp models --json` returns 50 providers the refiner cannot reach, and `GITLAB_TOKEN=" "` makes it hang forever with nothing on stderr. Both measured; see `docs/architecture.md`.
- Protected glossary terms must survive deterministic cleanup and optional refiner output exactly.

## Swift Conventions

- Swift tools version is 5.9; deployment target is macOS 14.
- Prefer concrete, explicit types at target boundaries and protocol contracts.
- Keep UI-observable coordinator state on the main actor.
- Keep async cancellation explicit. Check cancellation around side effects and before committing UI-visible results.
- Keep side-effecting macOS behavior behind injectable adapters rather than embedding it in pure logic.
- Use Swift Testing for Swift test targets already configured in `Package.swift`.
- Do not add `sindresorhus/KeyboardShortcuts` back without verifying the command-line toolchain issue described in the repo docs is resolved. The current Carbon hotkey binder is intentionally small and replaceable.

## Vendored parakeet.cpp

- Vendor parakeet.cpp and ggml from `ggml-org/whisper.cpp` at commit `592feef04a1802b18cbeffd0fd0eb5d02570c2ec` (v1.9.2 lineage), preserving upstream-relative paths.
- Mark every local change to an upstream file with a `VOICEOUR PATCH` comment and list it in `Vendor/parakeet/NOTICE.md`.
- Preserve the existing patch for `ggml-org/whisper.cpp#3932`: the TDT decode loop chooses duration slots from raw pre-log-softmax logits rather than log-softmax output guarded by the `-1e10f` sentinel.
- `Vendor/parakeet/ggml/embed/ggml-metal-embed.metal` is generated. Regenerate it with `Vendor/parakeet/ggml/embed/regenerate.sh` after any re-vendor of the Metal sources.
- Do not enable `-mcpu=native`; the copyable app must remain compatible with older Apple Silicon Macs rather than target the build host's exact CPU.
- Keep backend selection through `VOICEOUR_ASR_BACKEND=fake|parakeet|apple`; `parakeet` is the real sidecar backend and `apple` is the opt-in in-process backend.

## Developer Commands

Use the smallest command that verifies the change.

| Purpose | Command |
| --- | --- |
| Swift build | `make build` |
| Swift tests | `make test` |
| UI scene gate (offscreen) | `make ui-snap` |
| Bless intended scene change | `make ui-update` |
| UI semantic flow gate (offscreen) | `make ui-flow` |
| UI flow frame gate | `make ui-flow-frames` |
| Bless intended flow change | `make ui-flow-update` |
| List UI flows | `make ui-flow-list` |
| UI coverage ledger | `make ui-coverage` |
| Full scene and flow-frame gate | `make ui-all` |
| Re-record the README GIF (media, not a gate) | `make ui-film` |
| Fake app self-test | `scripts/run_dev.sh --self-test` |
| Fake app launch | `scripts/run_dev.sh` |
| Real ASR launch | `scripts/run_real.sh` |
| Real ASR proof fixture | `swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav` |
| Bundle app | `scripts/bundle.sh` |
| Restart existing real bundle | `scripts/restart_real.sh` |
| Benchmark smoke (offline, fake) | `make bench-smoke` |
| Benchmark suite | `docs/benchmarks.md` (`make bench-stt`, `bench-refine`, `bench-e2e`) |

Do not use real-ASR or GUI/manual flows as routine verification unless the change affects them. Prefer fake-first checks for fast, deterministic coverage.

## Fast Iteration Runtime

- For Swift app behavior or bundled-resource changes, do not stop at source edits or tests. Rebuild and restart the running menu-bar app before yielding so the user never tests a stale binary.
- For UI changes, verify offscreen with `make ui-snap` first. Relaunching the app takes over the user's screen, so reserve it for changes that genuinely need the live app: menu-bar item behavior, hotkeys, real insertion, permission prompts, or either glass material — the offscreen capture shows neither the legacy behind-window tint nor modern `.glassEffect`.
- Prefer the fake path for fast iteration when real ASR is not required: `scripts/run_dev.sh --self-test` for smoke verification and `scripts/run_dev.sh` for an interactive fake launch.
- If `.build/Voiceour.app` or a real-ASR instance is running, rebuild the bundle with `scripts/bundle.sh`, quit existing `Voiceour` processes, then reopen with the correct launch path (`scripts/restart_real.sh` for PARAKEET/real-bundle testing, `scripts/run_dev.sh` for fake development).
- When a user reports stale UI or behavior, confirm the active `Voiceour` process path/arguments after relaunch before declaring the fix visible.

## Offscreen UI Harness

`Voiceour --ui-harness` renders SwiftUI views into a borderless window parked at -30000,-30000, dumps the in-process accessibility tree, lints both, and diffs against the scene goldens in `fixtures/ui/`. Its flow layer drives real views and the real `DictationCoordinator` through deterministic multi-step journeys, checks named semantics, and reconciles journals and optional captured frames under `fixtures/ui/flows/`. It needs no Screen Recording or Accessibility permission, never orders a window onscreen, and leaves the frontmost application unchanged. It is the default way to inspect this app's UI and interactive UI behaviour. Full reference: `docs/ui-harness.md`.

Each invariant below was measured. Breaking one silently puts a window on the user's display or bakes machine-specific bytes into a golden.

- Keep the harness activation policy `.prohibited`. `.accessory` self-activated in 20 of 30 measured runs.
- Keep the window `[.borderless]` and keep `constrainFrameRect(_:to:)` overridden to return the rect unchanged. AppKit otherwise drags an offscreen window back onto a display.
- Leave the harness window unordered. Reaching for `orderFront`, `orderFrontRegardless`, `makeKey`, or `NSApp.activate` on this path defeats the whole design.
- Keep every scene settle and flow wait to a fixed run-loop pump count, never a wall-clock deadline. Adaptive pumping goes nondeterministic against `.repeatForever` animation, and elapsed time makes flow verdicts host-dependent.
- Rasterise through `NSHostingView` plus `cacheDisplay` into a hand-built `.deviceRGB` `NSBitmapImageRep`. `ImageRenderer` stubs every `NSViewRepresentable` and `ProgressView` with an opaque `#FFCC00` placeholder, and `bitmapImageRepForCachingDisplay` embeds the developer's display ICC profile.
- Keep the `ConsoleView` activation guard. Hosting the real `ConsoleView` otherwise promotes the app to `.regular` and activates it.
- Keep every `RenderOverrides` field `nil` in production and every production read shaped as `override ?? <real value>`. The seams pin the clock, permission snapshot, storage paths, and overlay comet so goldens do not encode one machine.
- Keep production seams value-only, never behavioural. `DictationCoordinator` takes a `DictationRuntime` for `now`, `makeUUID`, and `sleep` and falls back with `runtimeOverride ?? .live`; `GeneralPasteboard.writeOverride` and `clearOverride` stay nil in shipping builds. Never add `#if UI_HARNESS` control flow to a shipping method.
- Keep flow selectors exact and reject ambiguity. A substring that silently retargets is the regression a flow exists to catch.
- Hold every asynchronous flow boundary behind a named gate that the script releases. Intermediate coordinator states are otherwise races rather than checkpoints.
- Declare new scenes in `UISceneCatalog` only. Every new UI surface needs a `UICoverageRegistry` entry; a static surface needs both entries, and every new interactive behaviour needs a `UIFlow` that claims its required key.
- Treat `fixtures/ui/coverage-baseline.txt` as a shrink-only ratchet: an uncovered required key absent from the file and a covered key still present both fail. A red flow blesses nothing and covers nothing.
- Keep lint rules quiet on correct UI. The first rule set produced 173 findings of which 172 were false, and a rule that cries wolf trains every later agent to ignore the harness.

Scene goldens are the accessibility dump plus a PNG digest, never the images: committing the renders is 7.6 MB and rewrites half-megabyte binaries on every update. Flow goldens add a host-independent semantic journal and optional named-frame dump/digest pairs. Read `.build/ui-harness/<scene>.ax.diff` before `make ui-update` and `.build/ui-harness/flows/<flow>.flow.diff` before `make ui-flow-update`, then commit the corresponding files under `fixtures/ui/`.

`docs/media/` is the one place rendered images are committed, and it is not a golden set. `make ui-film` records the harness's `dictation-island` reel frame by frame and assembles `docs/media/dictation-island.gif`; the two console/menu stills beside it were exported from ordinary scene renders. Film reels are deliberately outside the scene, flow, lint and coverage gates — the reel's subject is a wall-clock-driven animation, which is exactly what a reproducible golden may never contain. Declare a reel in `UIFilmCatalog` only, never in `UISceneCatalog`, and never let a `make` gate depend on one.

The harness cannot show glass, and for two separate measured reasons. Legacy behind-window glass: an offscreen window has no desktop to sample, so `FrostedGlassBackground` rasterises as a flat opaque tint. Modern system glass: `cacheDisplay` does not rasterise SwiftUI `.glassEffect` at all — the material is absent rather than flattened, and its area captures fully transparent (`overlay.island.recording.os26.png` is 0.0% opaque and 59.3% fully transparent, `console.voice.os26.png` 37.6% fully transparent, against 100% opaque for the painted `console.home.populated.png`). An `os26` scene therefore gates the native `#available(macOS 26, *)` branch's own painted content, geometry, control boundaries and accessibility tree, never the material. Use `scripts/console_shot.sh` when the composited glass itself is the subject.

## macOS Permissions and Signing

- Microphone permission applies to real recording, not fake development.
- Event-post/Accessibility permission controls whether eligible targets receive synthetic Cmd-V. Missing permission should degrade to copy-only.
- Ad-hoc signing can invalidate macOS TCC grants across rebuilds. Stable signing identity preserves permission grants more reliably.
- Permission code belongs in `VoiceMac` adapters; user-facing state belongs in `Voiceour` UI/coordinator.
- Keep the shipped app entitlements narrow. `Resources/Voiceour.entitlements` is currently audio-input-only, and the bundle is intentionally not sandboxed; change that only with matching README/setup/release documentation.
- This bundle cannot use the data protection keychain at all, which is why the app stores no credential of its own; the measurement is recorded in `docs/architecture.md` under "Why Voiceour holds no credentials". Read it before adding any secret storage here.

## Git and Collaboration

- Default branch: `main`.
- Commit changes by default: once a change builds and its tests pass, stage the related files and commit with a clear, scoped message. Do not wait to be asked.
- Do not push. Leave commits local unless the user asks for a push, a PR, or a fork.
- Never commit secrets. `.env` is gitignored and must stay untracked; do not `git add` it or other credential files.
- Do not create GitHub issues, pull requests, comments, releases, or tags unless explicitly asked.
- Treat unexpected local changes as user work: prefer staging the specific files you changed over `git add -A` when unrelated modifications are present, and avoid overwriting them.
- Prefer updating existing docs/tests over creating parallel conventions.

## Documentation Rules

- Keep docs declarative and repo-specific. Do not copy Oh My Pi/Bun/TypeScript/catalog rules into this Swift app and its Python benchmark harness.
- If behavior changes, update the closest existing doc: `README.md` for user-visible behavior, `docs/architecture.md` for design contracts, `docs/developer-setup.md` for setup/run instructions, `docs/ui-harness.md` for the offscreen UI harness, and `CONTRIBUTING.md` for contributor rules.
- Keep `bench/` command examples aligned with `uv --no-config`; a host-level uv config must not be able to change benchmark results.
