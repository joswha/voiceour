# Development rules

## Default context

Voiceour is a macOS menu-bar dictation app. The intended user flow is: focus a text input, tap Fn/Globe by itself, speak one utterance, stop once, transcribe locally through the Parakeet sidecar, apply deterministic cleanup and glossary canonicalization, then paste or copy into the target focused when delivery begins.

The product/repository names are `Voiceour` and `voiceour`. Do not rename either without explicit instruction.

## Terminology

- **Voiceour** — the Swift executable target and macOS app.
- **VoiceCore** — Foundation-only domain models, policies, and contracts.
- **VoiceMac** — macOS adapters for capture, sidecar launch, targets, pasteboard, permissions, hotkeys, and system audio.
- **ASR sidecar** — the signed sibling `voiceour-asr` executable. It links vendored parakeet.cpp/ggml and speaks NDJSON v1 over stdio.
- **Capture target** — app/window context snapshotted before recording; it names the record-start target label.
- **Delivery target** — app/window/control context snapshotted immediately before persistence and insertion, then identity-checked again by the inserter.
- **Cleanup** — deterministic filler removal and glossary canonicalization. It is the only text-processing stage after ASR.
- **Console** — the native `Window("Voiceour", id: "main")` containing Home, Glossary, History, and Settings tabs.
- **Lifetime ledger** — `dictation-activity.json`: aggregate counts per local day and per destination app, read by Home. Never the retired `dictation-stats.json`, which is still swept off disk at launch.
- **Secure delivery** — concealed pasteboard copy, never Cmd-V and never a History row.
- **Syncour** — a separate sibling package at `../syncour`, not part of this repository. It imports DJI Mic recordings into an iCloud Drive library and transcribes them through this project's sidecar, consuming the `VoiceCore` and `VoiceMac` library products by path dependency. It is the one external consumer of those two products, so their public API is not private to this repository.

## Repository structure

| path | purpose |
| --- | --- |
| `Sources/VoiceCore/` | Foundation-only settings, state, cleanup, glossary, ASR wire types, history models, failure presentation, and safety policy. |
| `Sources/VoiceMac/` | AVFoundation/AppKit/CoreGraphics adapters: recording, fake audio, sidecar process client, targets, pasteboard insertion, permissions, hotkeys, and muting. |
| `Sources/Voiceour/` | SwiftUI menu, overlay, four-tab console, Home stats islands, persistence journal, and coordinator/pipeline orchestration. |
| `Sources/Voiceour/UIHarness/` | Compile-gated scene renderer, AX dump, PNG digest, lint, semantic flow runner, and NDJSON reports. |
| `Sources/ASRSidecarCore/` | Model cache, WAV loading, Parakeet context/token mapping, fake/real sidecar backends, and server. |
| `Sources/VoiceourASR/` | `voiceour-asr` executable entry point. |
| `Sources/ASRSidecarStub/` | Protocol/process test helper. |
| `Sources/VoiceourBench/` | Swift production-path benchmark executable. |
| `Vendor/parakeet/` | Vendored parakeet.cpp and ggml, pin/patch ledger, and embedded Metal source. |
| `Tests/` | Swift Testing suites aligned to the target boundaries. |
| `fixtures/protocol/` | Canonical protocol-v1 JSON fixtures. |
| `fixtures/ui/` | Scene AX/PNG-digest goldens and semantic flow journals. |
| `bench/` | Non-shipping Python dataset, report, comparison, and metric tools. |
| `benchmarks/` | Prepared data and committed benchmark reports. |
| `scripts/` | Build, launch, bundle, signing, harness, fixture, and vendor workflows. |
| `docs/` | Current architecture, permissions, UI, benchmark, and performance contracts; superseded records live under `docs/archive/`. |

## Architecture boundaries

- Keep `VoiceCore` Foundation-only. Never import AppKit, SwiftUI, AVFoundation, Accessibility, CoreGraphics event posting, pasteboard, process-launch, or Keychain APIs there.
- Put macOS APIs and side effects in `VoiceMac` behind small contracts consumed by the app layer.
- Keep `Voiceour` focused on UI and orchestration. `DictationCoordinator` remains `@MainActor` for observable state.
- Preserve dependency injection around recording, ASR, target tracking, insertion, permissions, hotkeys, muting, settings, and recent sessions. Fake development and tests depend on substitutable services.
- Production defaults to `parakeet`; `fake` is deterministic development infrastructure and a debug-only choice.
- The sidecar is the only child process. The pinned model acquisition is the only network path.
- The console is native macOS: one `TabView`, four grouped Forms and one Home page, standard controls, and native confirmation dialogs. Do not create custom window/navigation chrome. Home is the one non-`Form` tab: it is a page of figures, not a list of settings.
- History keeps exactly one transcript open, on a grouped `Section` of its own inside its day, directly under the row that selected it; each day renders as one to three plates and names itself once. Every closed row recedes while a transcript is open (0.45 opacity, 0.8 under Increase Contrast) so the page has one subject. A closed row is the heading — stamp, outcome mark, word count, destination app as its own icon and name, two-line preview — and the open row drops the preview because the transcript well directly under it holds the whole text. The detail has no action buttons: the transcript is the control. A plain single click copies the whole transcript (plain string, never transient) and confirms with a transient COPIED TO CLIPBOARD mark plus a VoiceOver announcement; selecting words — or right-clicking one for the text view's own `Fix / Teach “word”` item — then ⌘T teaches a correction; the one footer line under the text names what ⌘T will teach, or the instruction, or the copy confirmation. `HistoryInputMonitor` delivers the three inputs the grouped form swallows (margin click and Escape close the transcript, ⌘T teaches), and the transcript element carries named accessibility actions for copy and teach. Keep the record-level commands — copy, teach, delete, `Show Only <App>` — in the row's own context menu; the `Target` row (app name, plus the safety chip when the class was not ordinary text), Timings and the least-sure word are buttonless evidence rows behind a second fold. The open record leads with the transcript: differing Raw text and a `Details` row holding those three measurements are two sibling native `DisclosureGroup`s with independent bindings, both shut on every newly opened transcript, because a reader who opened a transcript came for the words — and at dictation length the monospaced raw block alone is several times the height of every other evidence row. `Details` is omitted entirely when the record has no target, no stage timings and no least-sure word. Each label carries the accessibility identifier and an explicit default accessibility action, since the triangle SwiftUI publishes answers an accessibility press with success and does not change its own state.
- The search row also carries the app filter: a `Menu`-wrapped inline `Picker` offered only when some row has a delivery target, with facets built from the rows themselves (count desc, then display label, then bundle id) and each app named by its newest row. Filter and query are ANDed, one `N of M sessions match` caption serves both, and a filter whose last row disappeared falls away rather than showing an empty list. Every displayed app label resolves through `AppIdentity`: the installed app's own Finder display name, else the name persisted with the row, else the pure `AppDisplayName.label(bundleId:name:)` humanization — so no surface shows a reverse-DNS string and none shows a name the app has since changed. The bundle id stays the internal key. `AppIdentity` also carries the installed app's icon, which Home's Top-apps rows show bare at badge size (the monogram is the not-installed fallback) and History's heading rows show at `Control.inlineIcon` beside the name; the open transcript's `Target` row and the engaged filter chip take the friendly name without an icon. `InstalledAppCatalog` in VoiceMac is the only LaunchServices lookup, main-actor and process-lifetime cached, and `RenderOverrides.installedApps` pins it so goldens never encode which apps the rendering Mac has. The facet menu re-sorts on the resolved label so its order matches what it displays; `RecentSessionQuery.appFacets` keeps its pure order for its pure consumers.
- The console window's ground is a *system* material behind unmodified native controls: `NSGlassEffectView(style: .regular)` on macOS 26, behind-window `NSVisualEffectView(material: .underWindowBackground)` below it. It paints no app-palette colour, it clears only `NSWindow.isOpaque` and `backgroundColor`, and Reduce Transparency replaces it with `windowBackgroundColor`. Content keeps its native section plates: text never sits directly on a sampled desktop.
- Bespoke glass styling — the app's own tint, rim and shadow vocabulary — is limited to the menu popover and Home's stats islands. The recording overlay is not glass: it is one borderless CPU-rasterized mercury body, with no capsule, shadow, tint, rim, glyph or word. `MercuryField` is the sole pixel/hit-test silhouette; a fixed-aspect half-elliptic crown supplies the exact two-axis normal; one static seed-drawn RGB room supplies bounded area-source reflections; exact liquid-mercury Fresnel and a two-anchor response with an unreachable 0.94 linear-light ceiling supply the chrome. Generated rooms never move independently of the surface. Home islands are app-drawn on purpose: element glass cannot sample the window's own glass ground, so they paint `Ink.pane` + `glassTint` + a specular rim + an `Alien` neon rim rather than stacking a second material. They stay fixed-dark in both system appearances and declare their own `surfaceGround` so contrast lint resolves text against what is actually painted.

## Runtime flow

The session state machine is:

```text
idle -> checkingPermissions -> recording -> finalizingAudio -> transcribing -> cleaning
     -> readyToInsert -> pasteAttempted | copiedOnly | insertFailed -> idle
```

`error` and `cancelled` are terminal outcomes before return to idle.

Required invariants:

- One solitary Fn/Globe tap toggles recording on release. Modified Fn combinations are not dictation gestures.
- With Accessibility trust, consume the Globe assigned-action event and an unmodified Escape during an active session. Without trust, use the passive monitor and degrade insertion to copy-only.
- Recreate `HotkeyEventRouter` whenever the tap is torn down or rebuilt. Passive routing ignores Globe keycode 179.
- Keep the overlay on the focused target's display. Store manual placement relative to a display, never as an absolute pin to one monitor.
- Drive the mercury surface with `NSView.displayLink(target:selector:)` bound to the panel's current screen, capped at 120 fps. Physics remains fixed at 120 Hz: one substep per 120 Hz frame, two per 60 Hz frame, fractional carry at other rates. Never put the frame clock back through `TimelineView`, a timer, or published SwiftUI state.
- Stop always finalizes one WAV and performs one final decode. There is no in-progress ASR request path.
- Ignore stale asynchronous work through generation/cancellation checks. An old recording or decode cannot update a newer session.
- Capture startup failure removes its WAV. Once finalization begins, the processing pipeline owns discard; cancellation must not race a second owner.
- Capture latches runtime errors and active-device disconnects. Reject a latched or zero-successfully-written-frame recording before ASR.
- Run blocking `AVCaptureSession.startRunning()`/`stopRunning()` on their dedicated serial queue, not the main actor.
- Run capture telemetry analysis off the main actor.
- Apply `CleanupEngine` exactly once after ASR, then snapshot the delivery target before persistence.
- A secure delivery target skips the journal entirely and receives concealed copy-only delivery.
- Surface capture, permission, acquisition, and every wire failure through `UserFacingDictationFailure`; never show raw codes as the primary sentence.
- Model progress must remain visible in the menu while download or warmup is active.
- A second app instance terminates at launch.

## ASR sidecar protocol

The sidecar protocol is newline-delimited JSON over stdin/stdout.

- Protocol version is 1 on every frame. Reject any mismatched response, not only `hello`.
- Stdout is protocol-only; logs go to stderr. Keep stderr continuously drainable.
- Startup emits `hello` with sidecar/backend status and capabilities.
- Accepted requests are `health`, `transcribe`, and `cancel`.
- Every decode request gets exactly one terminal `result`, `error`, or `cancelled`.
- `health` reports ready/model/cache state plus optional download fraction, warming state, and last unresolved acquisition failure. That failure is a wire `ASRErrorCode` plus a diagnostic detail, never a parallel taxonomy, and optional in both directions: a sidecar that omits it and one that sends it both decode.
- `transcribe` carries request id, WAV metadata, expected model identity, and timeout.
- Preserve request ids end-to-end so concurrent client bookkeeping cannot cross responses.
- Keep one persistent sidecar per client. Timeout, malformed frame, EOF, or crash must fail pending work and permit a clean later spawn.
- Server decode work stays serialized. Cancellation remains readable while decode runs.
- The server owns its preload thread, sets shutdown before EOF exit, and performs a bounded join. Never add an unbounded Darwin `waitUntilExit()` after bounded shutdown.
- A successful model load clears an earlier load-failure latch, and the acquisition-failure latch with it. The sidecar is the authority on why acquisition failed; the app reports what the sidecar states and infers only where it states nothing.
- Model context construction/freeing is serialized; concurrent contexts can destroy ggml's shared Metal device.

Change protocol models, client/server encoding, and `fixtures/protocol/` together. A field or request type present on only one side is a broken change.

## Model contract and vendor rules

The repository pin is model `ggml-org/parakeet-GGUF` at revision `35156454d1a39de06863303dd209fd2bed6ee079`. That one revision holds two interchangeable conversions of the same checkpoint:

| variant | file | SHA-256 | size |
| --- | --- | --- | --- |
| `f16` — Balanced | `ggml-parakeet-tdt-0.6b-v3-f16.bin` | `833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f` | 1,255,897,319 bytes |
| `q8_0` — Compact | `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | `4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e` | 668,757,119 bytes |

`f16` is the default, the compiled fallback for an unknown or stale persisted value, and the faster of the two at decode on the committed corpus. The selection is a footprint trade and never a quality claim: `q8_0` saves 587 MB of disk and resident memory, and the two agree on transcripts to within the accuracy the committed corpus can resolve. Never present either artifact as more accurate.

Rules:

- Treat model id, revision, every variant's filename, digest and size, descriptor metadata, cache manifest, docs, fixtures, and tests as one compatibility contract.
- `cacheOK` requires the full manifest to equal the selected variant's pin and the file's on-disk size to equal that variant's pinned size. Download completion verifies digest; load failure may force rehash.
- Switching variants is restart-to-apply, like the debug backend picker. `DictationCoordinator.activeModelVariant` is the artifact the running sidecar was launched with and `settings.asrModelVariant` is what the next launch will use; keep both so Settings can say a selection needs a restart instead of misreporting what is loaded.
- Exactly one artifact is resident. Each variant owns its own cache subdirectory, and the others are deleted once the wanted one is acquired and verified — never at selection time, so a failed switch still has weights to load, and never under `VOICEOUR_MODEL_CACHE`, whose single directory belongs to its caller. `f16` keeps the cache directory name it has always had so an existing install is not orphaned into re-downloading 1.26 GB.
- `expected_model` pins `file` alongside id and revision. Every artifact of the pinned revision shares those two, so `file` is the only field that catches a sidecar still holding the previous selection's weights.
- Vendor parakeet.cpp/ggml from `ggml-org/whisper.cpp` commit `592feef04a1802b18cbeffd0fd0eb5d02570c2ec` (v1.9.2 lineage), preserving upstream-relative paths.
- Mark each local change to an upstream file with `VOICEOUR PATCH` and list it in `Vendor/parakeet/NOTICE.md`.
- `scripts/vendor_parakeet.sh --check` must reject unexpected files and verify embedded Metal regeneration is byte-reproducible.
- Never add `-mcpu=native`; the app bundle must run beyond the build host.
- The vendored parakeet.cpp/ggml drop is arm64-only by design, and `Vendor/parakeet/ggml/embed/ggml-metal-embed.c` enforces that at compile time. The app is Apple Silicon only; do not attempt a universal build. Making it universal would require re-vendoring upstream `ggml/src/ggml-cpu/arch/x86/{quants.c,repack.cpp}`, amending `Vendor/parakeet/NOTICE.md` and `scripts/vendor_parakeet.sh --check`'s expected-file set, and restructuring `Package.swift` into per-architecture targets because SwiftPM has no architecture build condition; that is not a supported build today.

## Privacy and insertion safety

This app touches the user's microphone, active workspace, clipboard, and keyboard. Treat safety as product-critical.

- Snapshot capture context before recording and delivery context immediately before journal/insertion.
- `InsertionSafetyPolicy` is the single class-to-disposition mapping. Only `.normalText` may paste.
- Terminal, code-editor, secure, and unknown-risky classes are copy-only. There is no “paste everywhere” switch.
- Strip exactly one trailing newline for terminal and unknown-risky copies.
- Classify Ghostty (`com.mitchellh.ghostty`) as terminal and Zed (`dev.zed.Zed`) as code editor.
- Re-check bundle id, pid, safety class, and secure-input flag before writing the pasteboard and again before Cmd-V.
- An AX inspection failure is unknown-risky. `kAXErrorNoValue` is the narrow “no focused element” answer; secure input and known risky bundles still outrank it.
- Never read, save, restore, or later clear the user's previous clipboard. Write only the transcript.
- Secure output carries the concealed marker, remains copy-only, and creates no `recent-sessions.json` row.
- Ordinary paste attempts carry the transient marker. Other copy-only output remains plain string.
- Never persist audio. Remove temporary files after success, cancellation, error, and stale-file scavenging.
- History is one local file, newest 500. Settings, history, and lifetime-ledger load failures quarantine the unreadable file as `<name>.corrupt-<ISO8601>` and report the reset.
- Settings saves, history snapshots, and ledger snapshots share the one ordered persistence tail. Do not suppress write failures.
- The lifetime ledger is folded at exactly the site the transcript is journaled, so the two durable records cannot disagree: a secure target reaches neither, every delivery disposition reaches both. It keeps aggregate counts per local day and per destination-app bundle id, prunes day buckets past 400 days while preserving totals, active-day count and the longest streak, and removes its file when emptied. App buckets are never capped or pruned: the map is bounded by the apps the reader dictates into, and each keeps sessions, words, seconds, the last non-nil display name seen, and its latest day key. First launch without a ledger seeds it once from the transcripts still on disk; rows with no measured `captureMs` contribute words with zero seconds rather than an invented speaking rate. An existing ledger with no app buckets is seeded once more, app buckets only (`totalSessions > 0 && apps.isEmpty`), because the totals already counted those sessions. The Settings tab's Clear History erases both.
- Durable mute ownership survives launch when the recorded device UID cannot currently resolve; clear it only after a real restore attempt can be made.

## Glossary rules

- Glossary canonicalization is deterministic and one-pass over the original text.
- Gather all alias matches, resolve overlap longest-first then leftmost, and apply accepted replacements right-to-left.
- Escape canonical text with `NSRegularExpression.escapedTemplate` before replacement.
- Reject an alias that case-insensitively equals another term's canonical or alias. Enforce this in Teach, add, accept, and import.
- A word list imports as one of three shapes: a JSON array of spellings, a JSON array of `{"term": ..., "heard_as": [...]}` rows, or a newline-delimited list of spellings. The row shape exists because a spelling alone cannot repair a term the model mishears rather than merely respaces — `derivedAliases` recovers `Swift UI` from `SwiftUI`, but nothing derives `Qbectal` from `kubectl`. `heard_as` is the field name the Glossary editors show. Imported surfaces are filtered rather than cleaned, deduplicated case-insensitively against each other and the canonical, and capped by `WordListLimits.maxAliasesPerTerm`; a row carrying one unusable form still contributes its usable ones.
- Only explicit user action may confirm, tombstone, import, or clear learned vocabulary. Automatic/background paths never teach.
- Keep each utterance's active vocabulary snapshot bounded. A term is active everywhere: vocabulary is never scoped to an app or a project, and both editors offer exactly Term and Heard as.
- History's ⌘T teach opens the term the selected surface already belongs to — its spelling and every user-authored form — and commits with that term's id, so a prior teaching is visible and full-set semantics apply. An unowned surface opens a blank spelling and commits additively. Teach offers no empty well for a further form: the surface it was aimed at already is the form, so only a set with nothing in it draws one. The Glossary's own two editors always draw it, because authoring a term is what that tab is for.
- Ephemeral candidate retrieval remains in memory and never becomes persisted authority without explicit acceptance.

## Local-first and network policy

- Real ASR is local through `parakeet`; the fake backend is non-production.
- The only acceptable network access is acquisition of one of the compiled model URLs — the variant's artifact on the same host, in the same repository, at the same revision, verified against its compiled digest. Do not add network text processing, telemetry, crash reporting, accounts, update checks, or arbitrary URLs.
- The sidecar launch environment is an allowlist: `PATH`, `HOME`, `TMPDIR`, proxy/TLS names needed by acquisition, and `VOICEOUR_*`. Never inherit the full parent environment. `VOICEOUR_MODEL_VARIANT` names the artifact — `f16` or `q8_0` — and is written last and unconditionally for a model-backed sidecar, so an inherited shell value cannot outrank the user's selection; in the app process it does outrank the persisted setting, which is what lets the harness and the benchmark pin an artifact without editing the user's settings.
- Voiceour stores no credential and has no credential UI, environment contract, base URL, or keychain item.

The absence of a secret store is measured. This bundle cannot use the macOS data-protection keychain: it ships no provisioning profile, and `Resources/Voiceour.entitlements` is audio-input only. `SecItemAdd` returned `errSecMissingEntitlement` (-34018); adding `keychain-access-groups` to an ad-hoc signature caused AMFI to kill it as “adhoc signed but contains restricted entitlements.” Do not introduce a feature that quietly depends on that keychain.

## Swift conventions

- Swift tools version is 5.9; deployment target is macOS 14.
- Prefer concrete, explicit target-boundary types and small protocols.
- Keep observable UI state main-actor isolated. Move blocking capture, file I/O, hashing, and model work off the main actor.
- Use structured ownership for files, processes, capture sessions, and persistence tails. Identity-check teardown where a stale owner can race a newer resource.
- Prefer existing patterns and delete obsolete callers/types in the same change. Do not leave compatibility shims for internal APIs.
- Avoid avoidable allocations/copies in compiled hot paths.

## Developer commands

Use the smallest command that proves the change.

| task | command |
| --- | --- |
| Print the target catalogue | `make` |
| Build with warnings as errors | `make build` |
| Swift tests including harness suites | `make test` |
| Whole portable gate | `make check` |
| Format sources/tests | `make format` |
| Check formatting | `make format-check` |
| Check model-doc consistency | `make check-docs` |
| Lint Python benchmark package | `make lint-python` |
| Bundle app | `make bundle` |
| Verify bundle | `make verify-bundle` |
| Stable local signing identity | `make signing` |
| Cut a source release | `make release` |
| Cut a binary release | `scripts/release.sh --binary` |
| Release preflight only | `scripts/release.sh --dry-run` |
| Sign, notarize, staple, validate | `make notarize` |
| Check the Apple notarization environment | `scripts/sign_notarize.sh --check-env` |
| Fake app self-test | `make self-test` |
| Fake app launch | `make dev` |
| Real app build/launch | `make run` |
| Stop every running Voiceour | `make stop` |
| Process, bundle, and signature | `make status` |
| Stream Voiceour logs | `make logs` |
| Real model proof | `make build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav` |
| Portable scene gate | `make ui-snap` |
| Native scene gate | `make ui-snap-os26` |
| Bless intended portable scene change | `make ui-update` |
| Bless intended native scene change | `make ui-update-os26` |
| List scenes | `make ui-list` |
| Portable semantic flow gate | `make ui-flow` |
| Native semantic flow gate | `make ui-flow-os26` |
| Bless intended portable flow journal | `make ui-flow-update` |
| List flows | `make ui-flow-list` |
| Complete local UI gate | `make ui-all` |
| Render isolated mercury material sheets | `make ui-mercury` |
| Benchmark mercury across 4,096 rooms | `make ui-mercury-bench` |
| Offline benchmark smoke | `make bench-smoke` |
| LibriSpeech benchmark | `make bench-stt N=64` |
| FLEURS end-to-end report | `make bench-e2e N=64` |
| Technical-term smoke | `make bench-techterms` |
| U-WER comparison gate | `make bench-gate BASELINE=... CANDIDATE=...` |
| Python benchmark tests | `make test-python` |
| Vendor integrity | `scripts/vendor_parakeet.sh --check` |
| Regenerate the committed audio fixture | `make fixture` |
| Delete `.build` | `make clean` |

Benchmark commands must retain `uv --no-config`. Do not run real model or microphone checks unless the task needs them and prerequisites are present.

## Fast iteration runtime

- Source edits are not a runtime proof. Rebuild and relaunch the surface the user will exercise when app behavior or bundled resources changed; the process still running is the previous binary until `make run` or `make dev` replaces it.
- Use the fake path for deterministic coordinator/menu/window behavior.
- Use the real bundle for microphone, model acquisition, hotkey, insertion, entitlement, signature, helper-placement, or material behavior.
- `make run` re-bundles only when `Package.swift`, `scripts/bundle.sh`, `Sources/`, `Resources/` or `Vendor/` moved, and it stops the running instance before launching. The app terminates a second instance of itself, so a launch over a live instance makes the newly built process quit and leaves the old one running. An agent that launches without stopping first verifies the previous build.
- Verify the intended PID/bundle with `make status` rather than assuming another launch won.
- A root `.env` is sourced by `make run` and `make dev`; `make run` forwards `VOICEOUR_ASR_BACKEND`, `VOICEOUR_MODEL_VARIANT` and `VOICEOUR_SUPPORT_DIR` explicitly with `open --env`. macOS 26 does propagate the shell's environment through a LaunchServices launch, but that is not a documented contract, so a name the app reads is forwarded rather than assumed. Add the forward when the app learns to read another one.
- Launch flags go through `ARGS`: `make run ARGS="--debug --show-console"`, `make dev ARGS=...`.

## Offscreen UI harness

`Voiceour --ui-harness` is compiled only with `-DUI_HARNESS`. It renders real SwiftUI into a borderless offscreen window, captures via `NSHostingView.cacheDisplay`, dumps in-process AX, lints, compares scene digests/dumps, and runs semantic journeys that write `.flow.txt` journals.

Current scene inventory covers Home, Glossary, History, Settings, menu, overlay, accessibility adaptations, and representative macOS 26 menu branches. Flows cover the four tabs — History through its in-place detail and its two search journeys — plus the core delivered/copy-only/cancel/error journeys; History's click-to-copy and ⌘T gestures have no flow because neither can be delivered to a window that never becomes key, and its app filter has none because an `NSMenu` popup cannot be shown by a window that never orders front, so the `console.sessions.selection`, `console.sessions.teach`, `console.sessions.deselected` and `console.sessions.filtered` scenes lock what those states say and the gestures themselves are verified in the real app. Use `make ui-list` and `make ui-flow-list` as authoritative inventories.

Load-bearing measured invariants:

- Set `.prohibited` before any hosted view. It activated in 0/24 runs versus 20/30 under `.accessory`; key refusal alone was insufficient.
- Ignore the false return from `setActivationPolicy(.prohibited)`; the policy is still applied.
- Create `NSApplication.shared` and call `finishLaunching()` before CoreGraphics window APIs.
- Park at (-30,000, -30,000). Override `constrainFrameRect` without `super`; a probe at (-12,000, -12,000) was moved visibly to (320, 480) for 2.4 seconds.
- The window cannot become key/main and may never order front. Swallow normal ordering and `orderFrontRegardless`; allow only order-out for close. Unordered capture was byte-identical.
- `ConsoleWindowView.managesActivationPolicy` must observe `.prohibited`; reassert it before/after hosting so appearance/disappearance cannot change policy.
- Enhanced accessibility is mandatory: measured 1 AX node before enabling and 23 after.
- Pump fixed counts: 150 one-millisecond iterations before and after interaction, 30 at teardown. Never adapt to “stable”; a 200 ms animated probe produced 6/6 unique hashes.
- Each pump includes a run-loop slice and posted-event drain; sleep or run-loop alone did not deliver queued AppKit events.
- Capture into an owned interleaved RGBA8 `.deviceRGB` bitmap. The system caching bitmap embedded a 3,149-byte monitor profile plus cICP data.
- Keep alpha; disabling it reintroduced subpixel font smoothing, the largest measured raster drift.
- Never replace capture with `ImageRenderer`; it painted AppKit-backed controls/representables as `#FFCC00` placeholders.
- The harness cannot show the console/menu glass paths: behind-window `NSVisualEffectView` becomes a flat opaque fill without desktop content, while SwiftUI `.glassEffect` is absent/transparent under `cacheDisplay`. Use an onscreen material check for glass itself. The recording overlay is a plain `CGImage` and is fully captured offscreen.
- `cacheDisplay` also omits blur/shadow filters. Do not weaken offscreen/activation guarantees to recover them.

`RenderOverrides` is production-compiled because real views read it. The invariant is about its defaults: every field's declared default is nil or false, and with all of them at that default the app behaves exactly as it would if the type did not exist. How a set seam is read follows what it substitutes — `override ?? realValue` for a value, `if let` for a wholesale replacement such as `installedApps` or the `textRoleRecorder` probe, a plain boolean branch for `forceLegacyGlass`, which selects the painted pre-macOS-26 path every macOS 14/15 host takes anyway. Seams may pin time, locale/calendar/time zone, permissions, paths, accessibility adaptations, selection — including History's opening selection, which `historyStartsDeselected` suppresses so the closed-list state can be rendered — History's opening app filter (`historyInitialAppFilter`, because an `NSMenu` popup cannot be driven offscreen), History's open teach editor and the surface it was aimed at (`historyTeachSurface`, one seam read where ⌘T's own word is read, because the keystroke cannot reach a window that never becomes key), the microphone catalog (`availableMicrophones`, so goldens never encode which input devices the rendering Mac has), portable glass, and text-role instrumentation. A seam substitutes an input or selects a path production already reaches on some real machine or state; it may never fabricate an outcome the app cannot reach on its own, and no branch may exist solely to make a golden pass.

Read `.ax.diff` or `.flow.diff` before update mode. Error-severity lint findings and red flows cannot be blessed. Filtered runs accelerate iteration but do not prove the full catalog.

## macOS permissions and signing

- Microphone permission applies to real capture, not fake development.
- Accessibility trust enables active key suppression and synthetic Cmd-V. Missing trust degrades to passive hotkey observation and copy-only delivery.
- Accessibility inspection detects secure roles; it never mutates text.
- Input Monitoring is not requested.
- Use stable local signing for repeated TCC testing. Ad-hoc identity can change after rebuild.
- Release verification must include the signed sibling helper, hardened runtime, entitlements, and clean-account permission behavior.

## Release procedure

A release is a tag, the notes that describe it, and whatever assets that tag carries. There are two kinds and the only difference is the assets.

- **Source release.** The default, the normal case, and the kind this project cuts first: preflight, a `v<version>` tag, and a GitHub release whose notes are that version's `CHANGELOG.md` section. GitHub generates the source `.zip` and `.tar.gz` itself. Nothing is signed, no Apple identity exists in the flow, and no Apple environment variable is read — a source release cannot fail for want of a Developer ID because it never asks for one. It is worth cutting on its own: it gives the project a citable version, a permanent anchor for that changelog section, source archives that are not a moving branch, and a `releases/latest` that resolves instead of 404ing.
- **Binary release.** Opt-in and later. Everything the source release does, plus the signed, notarized and stapled app archive and its checksum attached as release assets. It needs a paid Developer ID, so it happens once there is one and not before.

Releasing at all is optional, and a binary is not what makes a release real. Building from source is a first-class supported path — the one `README.md` documents and the one every contributor uses — and a binary release exists only to spare a user the toolchain.

Rules for both kinds:

- `Resources/Info.plist` is the single source of truth for the version. `CFBundleShortVersionString` is the semver a human reads; `CFBundleVersion` increases monotonically and never repeats a value. No version literal is restated in a script, the Makefile, a workflow, or a document — tooling extracts it from the plist, the same discipline `scripts/check_docs.sh` applies to the model pin.
- The version, the `CHANGELOG.md` heading, and the git tag agree. The tag is `v<version>`. A version is released exactly once: a re-cut takes a new version rather than moving a tag.
- That version's `CHANGELOG.md` section *is* the release notes. `scripts/release.sh` extracts it verbatim — from the `## <version>` heading, which may also be written `## [<version>] - <date>`, up to the next `## ` — into `.build/Voiceour-<version>-release-notes.md`, and the printed `gh release create` line passes that file with `--notes-file`. Nothing composes release notes by hand, so a tag cannot disagree with the changelog.
- Preflight refuses to release from a dirty tree, from a branch other than `main`, from a `main` that is behind — or cannot be compared with — the local `origin/main` ref, on a `CFBundleShortVersionString` that is not `N.N.N`, on a version whose `## <version>` heading is missing or whose section is empty, or on a version whose `v<version>` tag already exists. It then runs `make build`, `make format-check`, `make check-docs`, and `make test`. A release points at a commit and that commit must be green, so the gate runs in both modes — nothing being signed is not a reason to skip verification.
- Preflight accumulates: every failed check prints its own `release.sh: FAIL: <reason>` line on stderr before the script exits 1, so one run names everything that needs fixing. A usage error exits 64; a binary release with incomplete Apple credentials exits 2.
- `scripts/release.sh` never bumps the version, tags, pushes, or publishes. It prints the exact `git tag`, `git push`, and `gh release create` commands for the mode it ran, and the maintainer runs them.
- `make release` is the source release. The binary release is `scripts/release.sh --binary` and has no `make` target on purpose: the default path must be the one that needs no credentials. `--dry-run` composes with either mode in any argument order, runs every check for that mode, and stops before writing the notes file and printing the publish commands — in source mode it is therefore the whole procedure minus its output, and it works with no Apple environment present at all.

Rules for the binary release only:

- An un-notarized binary is never published. The choice is a source release or a properly notarized one; a bare zip of an ad-hoc `.app` is not a third option. A copy of an ad-hoc or un-notarized `.app` arrives on another Mac carrying a quarantine flag and Gatekeeper refuses to open it, so that download is worse than no download: it looks like a broken app instead of an absent one. `docs/developer-setup.md` carries the hands-on version of this; keep the two consistent.
- A published binary is Apple Silicon only, and its release page and release notes must say so. Apply the same disclosure rule as the un-notarized-binary rule above.
- The published artifact is Developer ID signed with the hardened runtime, notarized, and stapled, and it is a zip produced by `ditto -c -k --keepParent`, never a DMG. `notarytool` accepts the zip directly, and a menu-bar app has no drag-to-Applications ritual that would repay a disk image's layout.
- **The notarization ticket is stapled into the app before the distributed archive is created.** The app is archived twice on purpose: once as a submission envelope, because `notarytool` cannot take a `.app` directory, and again after `stapler staple` has written the returned ticket into the app on disk. The stapled ticket is what lets Gatekeeper verify a first launch offline; an archive zipped before stapling contains an unstapled app and loses the ticket silently, because the build machine's own online lookup still succeeds and hides the defect. Do not collapse the two `ditto` calls into one — the single-archive form is exactly the bug this ordering fixes. The submission envelope is deleted afterwards so it can never be mistaken for the artifact.
- The archive is named from the extracted version and carries a `.sha256` sidecar beside it, which is the checksum of the stapled archive and never of the submission envelope.
- Required environment is `DEVELOPER_ID_APPLICATION` plus either `NOTARY_KEYCHAIN_PROFILE` or the `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` triple. Prefer the profile: an app-specific password passed on a command line is visible in the process table. Create it once with `xcrun notarytool store-credentials`. Nothing outside the binary path reads any of these, and their absence is not a failure anywhere else.
- Verification runs inside the flow, not afterwards as a favour. `scripts/verify_bundle.sh` asserts the `voiceour-asr` sibling is present and signed, `CFBundleIdentifier` is `com.voiceour.app`, `LSUIElement` is true, `NSMicrophoneUsageDescription` is non-empty, the `audio-input` entitlement is present, and `app-sandbox` and `input-monitoring` are absent. Never weaken those assertions to make a build pass. Hardened runtime, the stapled ticket, and `spctl --assess` are checked alongside them, and release verification also includes the clean-account permission behavior required above.
- A binary release is local and manual, never CI, and no release workflow should be added for it. Notarization needs Apple credentials, a public repository's secrets are a risk surface, and fork pull requests widen it — the same measured no-credential-store posture the network policy above describes. `.github/workflows/ci.yml`'s `release` job builds, bundles, and verifies, and uploads nothing: it is a packaging smoke test, not a release pipeline, and must not be mistaken for one.
- `make notarize` runs `scripts/sign_notarize.sh`: Developer ID signing with hardened runtime, submission, stapling, validation, then the archive, its checksum, and `.build/Voiceour-release-manifest.txt`. `scripts/sign_notarize.sh --check-env` validates the Apple environment and exits without building or submitting anything, so the credential rule lives in exactly one place.

The steps, in order, all maintainer-run. The Git rules below still hold: an agent does not tag, push, or publish.

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Move the `CHANGELOG.md` bullets under `Unreleased` beneath a new `## <version>` heading, leaving `Unreleased` empty above it. Preflight requires that heading and refuses an empty section, because that section is the release notes.
3. Commit those two files together, so the version and the notes that describe it are one revision.
4. Run `scripts/release.sh --dry-run` and fix everything it names.
5. Run `make release`. It re-runs every check, writes the notes file, and prints the publish commands.
6. Run the printed `git tag -a v<version>` and the two `git push` lines.
7. Run the printed `gh release create`. GitHub attaches the source `.zip` and `.tar.gz` itself, and the release is complete here.

A binary release replaces steps 4–7 with `scripts/release.sh --binary --dry-run` and then `scripts/release.sh --binary`, which signs, notarizes, staples, archives, and checksums before printing the same publish commands with the archive and its `.sha256` appended as assets. Nothing else about the procedure changes.

## Git and collaboration

- Default branch is `main`.
- Commit completed, verified related changes by default with a clear scoped message; never push unless asked.
- Do not discard or rewrite unrelated user changes.
- Keep generated benchmark data/build artifacts out of commits unless the repository explicitly tracks that artifact type.
- Commit intended UI AX/digest/journal goldens with the behavior change that requires them.

## Documentation rules

- Keep live docs declarative and repository-specific. Describe the app as it is, not the sequence of deletions that produced it.
- Put superseded but useful measurements under `docs/archive/` with an explicit archive notice and date.
- Update `README.md` for user-visible behavior, `docs/architecture.md` for design contracts, `docs/developer-setup.md` for commands, `docs/permissions.md` for TCC/insertion, `docs/ui-harness.md` for harness behavior, `docs/benchmarks.md` for measurement contracts, and `CONTRIBUTING.md` for gates.
- Every command example must exist in the current Makefile/scripts or executable CLI.
