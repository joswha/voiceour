# Development rules

## Default context

Voiceour is a macOS menu-bar dictation app. The intended user flow is: focus a text input, tap Fn/Globe by itself, speak one utterance, stop once, transcribe locally through the Parakeet sidecar, apply deterministic literal composition, cleanup, and glossary repair, then paste or copy into the target focused when delivery begins.

[README.md](README.md) is the product and technical contract: behavior, architecture, data, model and network, safety, non-goals, development, and verification. This file holds the engineering invariants and workflows that keep that contract true. A change that alters behavior updates whichever of the two owns it, in the same commit.

The product/repository names are `Voiceour` and `voiceour`. Do not rename either without explicit instruction.

## Terminology

- **Voiceour** — the Swift executable target and macOS app.
- **VoiceCore** — Foundation-only domain models, policies, and contracts.
- **VoiceMac** — macOS adapters for capture, sidecar launch, targets, pasteboard, permissions, hotkeys, and system audio.
- **ASR sidecar** — the signed sibling `voiceour-asr` executable. It links vendored parakeet.cpp/ggml and speaks NDJSON protocol v1 over stdio.
- **Capture target** — app/window context snapshotted before recording; it names the record-start target label and decides nothing else.
- **Delivery target** — app/window/control context snapshotted immediately before persistence and insertion, then identity-checked again by the inserter.
- **Text stages** — the three deterministic stages after ASR, in order: `LiteralComposition` (always), `CleanupEngine` (filler removal, repeat collapse, sentence-case repair, glossary canonicalization), and `VocabularyRepairEngine` (phonetic repair toward glossary terms). The cleanup setting gates the last two together. Nothing else rewrites a transcript.
- **Vocabulary snapshot** — the bounded set of glossary terms compiled once per utterance, before ASR, by `VocabularyCompiler`. Every text stage and suggestion retrieval for that utterance reads it.
- **Suggestions** — `CandidateRetrieval` output after delivery: in-memory proposals that become vocabulary only through explicit user action.
- **Console** — the native `Window("Voiceour", id: "main")` containing Home, Glossary, History, and Settings tabs.
- **Recording island** — the borderless nonactivating panel that draws the procedural mercury body during a session.
- **Lifetime ledger** — `dictation-activity.json`: aggregate counts per local day and per destination app, read by Home. Never the retired `dictation-stats.json`, which is still swept off disk at launch.
- **Secure delivery** — concealed, host-only pasteboard copy; never Cmd-V, never a History row, never a ledger entry.
- **Syncour** — a separate sibling package at `../syncour`, not part of this repository. It imports DJI Mic recordings into an iCloud Drive library and transcribes them through this project's sidecar, consuming the `VoiceCore` and `VoiceMac` library products by path dependency. It is the one external consumer of those two products, so their public API is not private to this repository; its owner raises its own platform and toolchain requirements.

## Repository structure

| path | purpose |
| --- | --- |
| `Sources/VoiceCore/` | Foundation-only settings, state, text stages, glossary, ASR wire types, history and ledger models, failure presentation, and safety policy. `Resources/ordinary-words.txt` is the repair stage's ordinary-word list. |
| `Sources/VoiceMac/` | AVFoundation/AppKit/CoreGraphics/CoreAudio adapters: recording, fake audio, sidecar process client, targets, pasteboard insertion, permissions, hotkeys, muting, installed-app lookup, word-list import. |
| `Sources/Voiceour/` | SwiftUI menu, recording island, four-tab console, Home stats islands, persistence journals, and coordinator/pipeline orchestration. |
| `Sources/Voiceour/UIHarness/` | Compile-gated scene renderer, AX dump, PNG digest, lint, semantic flow runner, mercury benchmark, and NDJSON reports. |
| `Sources/ASRSidecarCore/` | Model cache and acquisition, WAV loading, Parakeet context/token mapping, optional CoreML encoder client, fake/real sidecar backends, and server. |
| `Sources/VoiceourASR/` | `voiceour-asr` executable entry point. |
| `Sources/ASRSidecarStub/` | Protocol/process test helper. |
| `Sources/VoiceourBench/` | `voiceour-bench`, the Swift production-path benchmark executable. |
| `Sources/ParakeetMixedQuantize/` | `parakeet-mixed-quantize`, a research quantization tool. It never ships in the app. |
| `Vendor/parakeet/` | Vendored parakeet.cpp and ggml, pin/patch ledger, and embedded Metal source. |
| `Tests/` | Swift Testing suites aligned to the target boundaries. |
| `fixtures/protocol/` | Canonical protocol-v1 JSON fixtures. |
| `fixtures/ui/` | Scene AX/PNG-digest goldens and semantic flow journals. |
| `bench/` | Non-shipping Python dataset, report, comparison, and metric tools. |
| `benchmarks/` | Prepared data and committed benchmark reports. |
| `research/` | Published research record: preregistrations, experiments, negative results. Evidence, never a product contract. |
| `scripts/` | Build, launch, bundle, signing, release, harness, fixture, and vendor workflows. |
| `docs/` | Specialist appendices — harness runbook, renderer derivation, benchmark and performance records. Superseded records live under `docs/archive/`; `docs/superpowers/` holds dated planning records. |

## Architecture boundaries

- Keep `VoiceCore` Foundation-only. Never import AppKit, SwiftUI, AVFoundation, Accessibility, CoreGraphics event posting, pasteboard, process-launch, or Keychain APIs there.
- Put macOS APIs and side effects in `VoiceMac` behind small contracts consumed by the app layer. `VoiceMac` never imports SwiftUI.
- Keep `Voiceour` focused on UI and orchestration. `DictationCoordinator` remains `@MainActor` for observable state; the stop pipeline is its extension in `TranscriptProcessingPipeline.swift`.
- `ASRSidecarCore` imports `VoiceCore` and `CParakeet`, never `VoiceMac`. Nothing imports `Voiceour`.
- Preserve dependency injection around recording, ASR, target tracking, insertion, permissions, hotkeys, muting, settings, and recent sessions. Fake development and tests depend on substitutable services.
- Production defaults to `parakeet`; `fake` is deterministic development infrastructure and a debug-only choice. Registered backends are exactly those two. Retired ids (`mlx`, `ark-0.6b`, `ark-3b`, `apple`) normalize to `parakeet`.
- The sidecar is the only child process. The pinned model acquisition is the only network path.

## Native UI contract

The console window follows macOS. The app's own visual language applies only to the menu popover, the recording island, and Home's stats islands.

### Console

- One `TabView` — Home, Glossary, History, Settings — with three grouped `Form`s and one Home page. Home is the one non-`Form` tab: it is a page of figures, not a list of settings. The window reopens on the last tab, except that owed first-run guidance opens Home.
- Native controls only: `TabView`, `Form(.grouped)`, `Section`, `Toggle`, `Picker`, `TextField`, `LabeledContent`, `Button`, searchable lists, context menus. No custom window or navigation chrome, control skins, or forced dark appearance; the window inherits appearance, accent, focus, control metrics, VoiceOver semantics, and accessibility settings.
- Destructive actions — Delete transcript, Remove term, Clear History, Clear Vocabulary — use native confirmation dialogs with a visible title and destructive role.
- App-owned styling inside the console stays narrow: monospaced text for code-like values, `ConsoleStateMark`, `ConsoleCaption`, `ConsoleRow`, and `MeterBar`. On a native plate `MeterBar` paints in system semantic colours — the same split `ConsoleStateMark` (system colours) and `StatusChip` (app palette) already make.
- The window ground is a system material behind unmodified native controls: `NSGlassEffectView(style: .regular)`. It paints no app-palette colour, it clears only `NSWindow.isOpaque` and `backgroundColor`, and Reduce Transparency replaces it with `windowBackgroundColor`. Content keeps its native section plates: text never sits directly on a sampled desktop. No shipping view uses SwiftUI `.glassEffect`.
- Settings orders preferences before readouts: Dictation, Audio, Model, then — under `--debug` only — Backend and Overlay, then Readiness, Capture, Privacy, and Danger. There is no General tab: a switch and the permission that decides whether it can take effect belong on one destination.
- Home's first-run card and the Settings readiness rows read the same `ConsoleReadiness` values and sentences and offer the same remediation buttons. Whether the card is owed is `DictationPolicy.owesFirstRunGuidance`: `Settings.hasCompletedFirstRun` is false and both durable records are empty. An absent key decodes to `false`, and the records are what stop an install that predates the flag from being handed onboarding. The flag is written by `completeFirstRun()` one line outside the branch that writes the two records, so a secure delivery retires the card exactly like a journaled one; a refused start, a cancel, and a failed decode never reach it.
- `ConsolePresentation` owns showing the console, and every path goes through it: the menu item, `--show-console`, `applicationShouldHandleReopen` (Dock click, `open -a`, reopening a running app), and the window's own `onAppear`. It promotes the process to `.regular` while the console is hosted, returns to `.accessory` when it closes, orders the window front, and deminiaturizes it. It does nothing when launch passed `--no-activate` or the policy is `.prohibited`.
- The console is neither miniaturizable nor restorable. A minimized window is clicked back from a Dock tile that exists only while the console is open, and AppKit restoration once carried that parked state into an `.accessory` launch that owned an unreachable window.

### History

- History keeps exactly one transcript open, on a grouped `Section` of its own inside its day, directly under the row that selected it; each day renders as one to three plates and names itself once. Every closed row recedes while a transcript is open (0.45 opacity, 0.8 under Increase Contrast) so the page has one subject. A closed row is the heading — stamp, outcome mark, word count, destination app as its own icon and name, two-line preview — and the open row drops the preview because the transcript well directly under it holds the whole text.
- The detail has no action buttons: the transcript is the control. A plain single click copies the whole delivered transcript (plain string, never transient) and confirms with a transient COPIED TO CLIPBOARD mark plus a VoiceOver announcement; selecting words — or right-clicking one for the text view's own `Fix / Teach “word”` item — then ⌘T teaches a correction; the one footer line under the text names what ⌘T will teach, or the instruction, or the copy confirmation. `HistoryInputMonitor` delivers the three inputs the grouped form swallows (margin click and Escape close the transcript, ⌘T teaches), and the transcript element carries named accessibility actions for copy and teach.
- Record-level commands — Copy Transcript, Fix / Teach a Word, Show Only *App*, Delete — live in the row's context menu. The open record leads with the transcript. Differing Raw text and a `Details` row holding the `Target` row (app name, plus the safety chip when the class was not ordinary text), Timings, and the least-sure word are two sibling native `DisclosureGroup`s with independent bindings, both shut on every newly opened transcript, because a reader who opened a transcript came for the words. `Details` is omitted entirely when the record has no target, no stage timings and no least-sure word. Each label carries the accessibility identifier and an explicit default accessibility action, since the triangle SwiftUI publishes answers an accessibility press with success and does not change its own state.
- The search row also carries the app filter: a `Menu`-wrapped inline `Picker` offered only when some row has a delivery target, with facets built from the rows themselves (count desc, then display label, then bundle id) and each app named by its newest row. Filter and query are ANDed, one `N of M sessions match` caption serves both, and a filter whose last row disappeared falls away rather than showing an empty list. The facet menu re-sorts on the resolved label so its order matches what it displays; `RecentSessionQuery.appFacets` keeps its pure order for its pure consumers.
- Every console app label resolves through `AppIdentity`: the installed app's own Finder display name, else the name persisted with the row, else the pure `AppDisplayName.label(bundleId:name:)` humanization — so no surface shows a reverse-DNS string and none shows a name the app has since changed. The bundle id stays the internal key. `AppIdentity` also carries the installed app's icon, which Home's Top-apps rows show bare at badge size (the monogram is the not-installed fallback) and History's heading rows show at `Control.inlineIcon` beside the name; the open transcript's `Target` row and the engaged filter chip take the friendly name without an icon. `InstalledAppCatalog` in VoiceMac is the only bundle-id-to-app LaunchServices lookup, main-actor and process-lifetime cached, and `RenderOverrides.installedApps` pins it so goldens never encode which apps the rendering Mac has. The menu's live *Will paste into* label uses `AppDisplayName` directly.

### Visual vocabulary

One graphite ground and a small semantic signal family, defined in `DesignTokens.swift`.

| role | value |
| --- | --- |
| `Ink.void` | sRGB (0.02, 0.03, 0.05), opaque |
| `Text.high` | sRGB (0.89, 0.91, 0.95) |
| `Text.mid` | sRGB (0.64, 0.71, 0.80) |
| `Text.low` | sRGB (0.51, 0.56, 0.64) |
| cyan | active, live, focus |
| mint | successful outcome |
| amber | degraded or waiting |
| crimson | failure or destructive action |
| `Alien.bloom` + heat ladder | Home only: dictation volume and the page's one accent |

- One signal colour dominates a view. `Alien` appears only on Home, as fill, glyph tint, and glow, never as text colour. Its four heat steps are quartiles of the window's busiest day, and Differentiate Without Color replaces the hue ladder with a size ladder at one hue.
- `OnGlass` (`cyan`, `mint`, `amber`, `crimson`) is the same four roles for text on system glass only: mid-tones measured to clear 4.5:1 against both white and black. It does not apply on painted or opaque grounds.
- Text roles: `micro` 10 pt, `caption` 12 pt, `label` 13 pt; figures use `tileValue` 20, `metric` 32, and `heroMetric` 64 pt. Spacing: `hair` 2, `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 24. Control heights are 24, 28, 32, and 40 pt, with 20 pt compact status marks as the one declared exception.
- Home's stats islands are app-drawn on purpose: element glass cannot sample the window's own glass ground, so they paint `Ink.pane` + `glassTint` + a specular rim + an `Alien` neon rim rather than stacking a second material. They stay fixed-dark in both system appearances and declare their own `surfaceGround` so contrast lint resolves text against what is actually painted.

### Menu popover

A `MenuBarExtra` in `.window` style, 280 pt wide, with three whitespace-separated blocks: Status (state chip, mute state when relevant, Fn keycap, one headline), Report (failure, last transcript, or delivery outcome; absent when there is nothing to report), and Actions (one primary dictation action followed by one grouped command list). Model download or warmup progress must remain visible while either is active; the popover re-polls health while an acquisition moves.

### Recording island

- The panel is a clear, borderless, nonactivating 260×80 pt window that never becomes key or main; only one procedural mercury body is visible inside the centred 180×34 pt envelope. Placement is computed on the envelope: 44 pt below the display's visible top edge, centred, with a 16 pt screen margin. The transparent remainder is window bleed, not another surface.
- The island follows the display of the focused app's frontmost window, falling back to the pointer's display. A dragged position is saved and replayed by translating it from the visible frame it was dropped on into the destination display's visible frame; it is never an absolute pin to one monitor.
- There is no capsule, glass material, app shadow, control disc, waveform, working mark, painted word, symbol, authored highlight, rim or tint. A CPU rasterizer draws a generated polished-mercury material into one `CGImage`. `MercuryField` is the sole pixel, drag hit-test, and cursor silhouette. A fixed-aspect half-elliptic crown supplies the exact two-axis normal; one static seed-drawn room supplies bounded area-source reflections; exact liquid-mercury Fresnel and a two-anchor response with an unreachable 0.94 linear-light ceiling supply the chrome. The room never moves independently of the surface. Room of Ten is the shipping world; Spectral Weather is a `--debug` comparison.
- `MercurySurfaceView` uses `NSView.displayLink(target:selector:)` bound to the panel's current screen, capped at 120 fps. Physics stays fixed at 120 Hz: one substep per 120 Hz frame, two per 60 Hz frame, fractional carry at other rates. The link stops while hidden or off-display and is rebuilt on a screen change. Never put the frame clock back through `TimelineView`, a timer, or published SwiftUI state.
- Listening, speaking, processing and three unclean outcomes are distinct size and shape poses. Unclean outcomes (`gathered`, `lurch`, `collapse`) hold for 1.2 s, click-through, with no glyph, word or hue carrying the state. A clean paste and a cancel dismiss at once. Idle draws and publishes nothing.
- Active states expose one fixed-frame accessibility element labelled `Dictation status`; Finish and Cancel survive as named actions on it, and the controller posts an announcement for each active state and unclean outcome.
- Reduce Motion removes autonomous noise but keeps voice and pose motion because those carry information. Reduce Transparency needs no island branch: the body is opaque and its room static. Increase Contrast re-solves the same bounded anchors and never clips against the ceiling.
- `make ui-mercury-bench` is the permanent quality and speed gate. [mercury-renderer.md](docs/mercury-renderer.md#renderer-contract) holds the derivation, rejected alternatives, and the [hard-gate table](docs/mercury-renderer.md#measured-gates); a change to the field, mode law, crown, room, optics, response, cadence, or gate updates that document in the same commit.

### Motion and accessibility

- Respect Reduce Motion at every animation boundary and use the shared quick (0.14 s), standard (0.18 s), and deliberate (0.22 s) timings. The menu animates report and state changes so resizing does not jump under the pointer. Native console controls keep system motion and focus behaviour. Resting settings do not animate, and a static state stays understandable with all motion disabled.
- Every interactive element carries a stable, human label. State is never colour-only: chips and marks carry words, and Differentiate Without Color adds symbols. Explanatory captions are siblings, not folded into a control's accessibility label. Where a gesture is the only way to reach a behaviour, the same element publishes a named accessibility action, and a completed gesture posts an announcement.

## Runtime flow

The session state machine is:

```text
idle -> checkingPermissions -> recording -> finalizingAudio -> transcribing -> cleaning
     -> readyToInsert -> pasteAttempted | copiedOnly | insertFailed -> idle
```

`error` and `cancelled` are terminal outcomes before return to idle.

Required invariants:

- One solitary Fn/Globe tap toggles recording on release. Shift, Control, Option, Command, Caps Lock, or any other key during the hold disarms it. Toggle while recording stops; toggle during `checkingPermissions` cancels; toggle while finalizing, transcribing, cleaning, or delivering is ignored.
- With Accessibility trust, the event tap consumes the Globe assigned-action event (keycode 179) and the Fn release that toggles, and consumes an unmodified Escape — keyDown, repeats, keyUp — only during an active session. Without trust, use passive monitors, which never suppress, and degrade insertion to copy-only. A 2 s watchdog promotes to the tap once trust appears; the Accessibility prompt is shown at most once per process, never mid-session.
- Recreate `HotkeyEventRouter` whenever the tap is torn down or rebuilt. Passive routing ignores Globe keycode 179.
- Escape and the island's Cancel discard the session while checking permission, recording, finalizing, and transcribing. Once the pasteboard write has happened, cancellation reports copy-only, not failure.
- Start order for the real backend: refuse with `model_not_installed` while the model is not ready, before any microphone prompt; then request Microphone only if it is undetermined. The fake backend skips both.
- Stop always finalizes one WAV and performs one final decode. There is no in-progress ASR request path and no maximum recording length; a 6 s no-signal deadline after start stops and reports no audio.
- Ignore stale asynchronous work through `AsyncGenerationGate` tokens and cancellation checks. An old recording, decode, or suggestion task cannot update a newer session.
- Capture writes 16 kHz mono 16-bit WAV to `$TMPDIR/voiceour/`. Capture startup failure removes its WAV. Once finalization begins, the processing pipeline owns discard; cancellation must not race a second owner. The launch scavenger removes stale recordings older than one hour.
- Capture latches runtime errors, active-device disconnects, conversion errors, and WAV write failures. Finalization drains the converter and closes the WAV, then rejects any latched, zero-frame, or all-zero recording before ASR; liveness scans every channel, including interleaved Int16 and Int32 sources.
- `AVCaptureSession` start and stop run on the dedicated serial `com.voiceour.capture-session` queue, never the main actor. Capture telemetry analysis runs off the main actor.
- Capture device choice is per recording in `CoreAudioInputDevice.preferredCaptureUID`: a connected Settings selection wins; otherwise the system default, except a Bluetooth/BLE default is redirected to the built-in microphone while the lid is open. A selection that stops resolving falls back rather than failing.
- The no-speech gate runs before ASR: a non-synthetic capture whose `snrDB` is below `DictationPolicy.minimumCaptureSNRDB` (6 dB) ends as `cancelled`. Absent telemetry and synthetic capture proceed.
- Compile the vocabulary snapshot once, after finalization and before ASR. Apply the text stages exactly once after ASR, then snapshot the delivery target before persistence.
- A secure delivery target skips the journal and ledger entirely and receives concealed copy-only delivery.
- Surface capture, permission, acquisition, and every wire failure through `UserFacingDictationFailure`: a title, a plain cause, whether retrying can work, and where to fix it. Never show raw codes as the primary sentence. The stop pipeline unwraps `SidecarASRClientError.protocolError` to keep the wire code and detail; local timeouts map to `timeout`; launch, missing-greeting, process-exit and pipe-write failures map to `backend_unavailable`; incompatible greetings and unexpected response kinds map to `incompatible_protocol`. The public client error enum stays stable for library consumers.
- Muting is restored by recorded device UID, started (not awaited) the moment capture ends so the 120 ms fade never delays ASR. The start cue plays before the mute; the end cue waits for the restore. Durable mute ownership survives launch and later sessions when the recorded device cannot resolve. Clear it only after a real restore attempt; refuse a new mute rather than overwrite pending ownership. Disk-loaded and interrupted fades restore partial volumes, while a completed live mute keeps the conservative check for user-adjusted volume. Muting applies only to the Parakeet backend.
- A second bundled instance terminates at launch. Quit discards in-flight work and restores audio before exit.

## Text pipeline

- **Order and gating.** `LiteralComposition.apply` always runs. `CleanupEngine.clean` and `VocabularyRepairEngine.repair` run only when `Settings.cleanupEnabled`. All three are pure functions of the transcript and the utterance's vocabulary snapshot. An empty result ends the session as `cancelled`. History stores the raw ASR text and the final text; the least-confident word comes from the raw transcript's words.
- **Literal composition** recognizes `spell`, `spell that`, `letter by letter` / `letter-by-letter`, `literal`, `snake case`, `camel case`, `capital`/`uppercase`, and the standalone symbol words `dash`, `dash dash`, `dot`, and `underscore`. Commands match whole words case-insensitively; a command's word run continues across single spaces and ends at the next punctuation. It returns the input unchanged when nothing matched. The symbol words apply anywhere, so prose that uses them as words is rewritten too.
- **Cleanup** normalizes whitespace; removes the fixed fillers `um`, `uh`, `uhm`, `erm`, `mmm`, `hmm`; collapses an immediately repeated phrase of up to four words; restores sentence case only where a deletion moved an all-lower-case token to a sentence start and the original sentence was capitalized; then applies `Glossary.canonicalize`. Tokens with a leading `-`, a `/`, `~`, `_`, a digit, or an internal capital, and glossary surfaces, are never fillers or recased. Multi-word glossary surfaces that the deletion passes would damage are sheltered from them, decided by running the passes rather than restating their rules.
- **Canonicalization** is deterministic and one-pass over the original text: gather every term's matches (canonical, user aliases, derived aliases), resolve overlap longest-first then leftmost, and apply accepted replacements right-to-left. Escape canonical text with `NSRegularExpression.escapedTemplate` before replacement. `Glossary.derivedAliases` spaces out compound spellings (`SwiftUI` → `swift ui`, `swift u i`); single-letter aliases and aliases of all-digit canonicals never generalize.
- **Vocabulary repair** scores token windows of up to five words against eligible canonicals at `RepairVocabulary.frozenPhoneticThreshold` (0.95). The threshold is frozen: lowering it needs new safety evidence, not a better benchmark. Exact alias matches resolve first and longest, then the highest-scoring phonetic candidates take unclaimed spans. A canonical that is an ordinary English word or at most two characters is never a target, and its occurrences are protected spans. A multi-word phonetic candidate whose every token is ordinary is rejected; single letters are ordinary only for `a` and `i`. The engine is cached and rebuilt only when the ordered active canonicals change. `voiceour-bench pipeline` applies repair only with `--vocabulary`; the sidecar's own transcript is never repaired.
- **The ordinary-word list** is `Sources/VoiceCore/Resources/ordinary-words.txt`, generated by `scripts/generate_ordinary_words.py` from the frozen research repair vocabulary. `RepairVocabulary.bundledOrdinaryWords` resolves it from the packaged `voiceour_VoiceCore.bundle` or `Bundle.module`; a missing or unreadable list is a precondition failure. `scripts/bundle.sh` refuses to bundle without the resource bundle, and `scripts/verify_bundle.sh` asserts the list is non-empty.
- **Vocabulary snapshot.** `VocabularyCompiler.compile` keeps at most 100 terms: priority terms (explicit corrections and protected terms, which include the bundled defaults) first, then the rest in trust, recency, and index order under per-source quotas with backfill. Vocabulary is never scoped to an app or a project.
- **Suggestions** run after delivery on a detached utility task over the final text and commit only if their generation is still current. They are suggestion-only: never edit delivered text or the target. They are cleared at the next recording. Retrieval currently also runs for secure-target dictations; nothing persists unless the user accepts one.

## ASR sidecar protocol

The sidecar protocol is newline-delimited JSON over stdin/stdout.

- Protocol version is 1 on every frame. Reject any mismatched response, not only `hello`; a mismatch is connection-fatal.
- Stdout is protocol-only; logs go to stderr. Keep stderr continuously drainable.
- Startup emits `hello` with sidecar version, backend id and status, and capabilities.
- Accepted requests are `health`, `transcribe`, and `cancel`. Health and cancel are handled on the reader thread so they stay readable while a decode runs.
- Every decode request gets exactly one terminal `result`, `error`, or `cancelled`, carrying its request id.
- `health` reports `ready`, `model_loaded`, `cache_ok`, plus optional download fraction, warming state, and last unresolved acquisition failure. That failure is a wire `ASRErrorCode` plus a diagnostic detail, never a parallel taxonomy, and optional in both directions: a sidecar that omits it and one that sends it both decode.
- `transcribe` carries the request id, WAV metadata, `expected_model` (`model_id`, `revision`, `file`), and a timeout. The WAV header is authoritative and must be 16 kHz mono 16-bit PCM. The deadline is enforced by the client (30 s for a dictation); on timeout it sends `cancel`, waits 500 ms, then kills the child.
- The request path never downloads. A cold cache answers `model_not_installed` immediately while the preload thread acquires.
- Preserve request ids end-to-end so concurrent client bookkeeping cannot cross responses. Well-formed responses for a retired id are ignorable stale work, not framing errors.
- Keep one persistent sidecar per client. Timeout, malformed frame, EOF, or crash fails pending work and permits a clean later spawn. An inference failure exits the sidecar after its terminal frame so the next request gets a fresh process.
- The client's line reader passes exact `Data` frames to decoding and never repairs malformed UTF-8. It validates UTF-8 scalars and rejects literal NUL before Foundation can auto-detect UTF-16/32; a legitimately encoded replacement character is preserved. Invalid JSON, invalid known-frame schemas, unknown response types and incompatible versions fail every pending call and terminate that process; its identity guard discards any buffered valid tail or stale callback. An invalid greeting is `incompatibleHello`; EOF before a greeting is `noHello`.
- Server decode work stays serialized. The server owns its preload thread, sets shutdown before EOF exit, and performs bounded joins. Never add an unbounded Darwin `waitUntilExit()` after bounded shutdown.
- A successful model load clears an earlier load-failure latch, and the acquisition-failure latch with it. The sidecar is the authority on why acquisition failed; the app reports what the sidecar states and infers only where it states nothing.
- Model context construction is serialized under the load lock; concurrent contexts can destroy ggml's shared Metal device. An idle model context is released after 30 minutes and rebuilt on the next request.

Change protocol models, client/server encoding, and `fixtures/protocol/` together. A field or request type present on only one side is a broken change.

## Model contract and vendor rules

The repository pin is model `ggml-org/parakeet-GGUF` at revision `35156454d1a39de06863303dd209fd2bed6ee079`. That one revision holds two interchangeable conversions of the same checkpoint:

| variant | file | SHA-256 | size |
| --- | --- | --- | --- |
| `f16` — Balanced | `ggml-parakeet-tdt-0.6b-v3-f16.bin` | `833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f` | 1,255,897,319 bytes |
| `q8_0` — Compact | `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | `4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e` | 668,757,119 bytes |

`f16` is the default and the compiled fallback for an unknown or stale persisted value. The selection is a footprint trade and never a quality claim: `q8_0` has a 587 MB smaller artifact, and the two agree on transcripts to within the accuracy the committed corpus can resolve. Never present either artifact as more accurate or make an unqualified speed claim: `f16` decoded faster when it was chosen on macOS 26.5.2, that ordering did not reproduce on 26.6.2, and a default change is gated on cross-SoC replication and the paired real-speaker gate in [benchmarks.md](docs/benchmarks.md#paired-fixed-corpus-promotion-gate). The dated record is in [performance-roadmap.md](docs/performance-roadmap.md).

Rules:

- Treat model id, revision, every variant's filename, digest and size, descriptor metadata, cache manifest, README.md, this file, NOTICE, fixtures, and tests as one compatibility contract. `make check-docs` reads the pin from `Sources/VoiceCore/ASRProtocol.swift` and requires README.md and AGENTS.md to name every artifact file and digest.
- The cache lives at `~/Library/Caches/Voiceour/<variant directory>/` with the artifact and `manifest.json` (`model_id`, `revision`, `file`, `sha256`, `size_bytes`). `f16` keeps its legacy directory name `parakeet-tdt-0.6b-v3-ggml` so an existing install is not orphaned into re-downloading 1.26 GB; `q8_0` uses `parakeet-tdt-0.6b-v3-ggml-q8_0`.
- `cacheOK` requires the full manifest to equal the selected variant's pin and the file's on-disk size to equal that variant's pinned size; it does not hash. Download completion verifies the streaming digest. A load failure re-hashes the file; a mismatch removes the artifact, manifest, and base arena and re-acquires once per process.
- Acquisition requires the remaining bytes plus 256 MiB free before fetching, uses an ephemeral session with three resumable attempts, and runs only on the preload thread.
- The selection travels one path. Settings persists `asr_model_variant`; the app resolves `VOICEOUR_MODEL_VARIANT` first and that setting second (an invalid environment value resolves to `f16`); the resolved variant is written last and unconditionally into a model-backed sidecar's launch environment; every real decode carries `expected_model.file`. Every artifact of the pinned revision shares id and revision, so `file` is the only field that catches a sidecar still holding the previous selection's weights.
- Switching variants is restart-to-apply, like the debug backend picker. `DictationCoordinator.activeModelVariant` is the artifact the running sidecar was launched with and `settings.asrModelVariant` is what the next launch will use; keep both so Settings can say *Restart to apply* instead of misreporting what is loaded. Restart drops the `VOICEOUR_ASR_BACKEND` and `VOICEOUR_MODEL_VARIANT` overrides so the saved choice wins.
- Exactly one artifact is resident. Other variants' cache directories are deleted after the selected variant loads successfully — never at selection time, so a failed switch still has weights, and never under `VOICEOUR_MODEL_CACHE`, whose single directory belongs to its caller. Overriding `HOME` does not move the cache, so a scratch home silently reuses the real artifact and proves nothing about a cold download.
- After the artifact is verified, the sidecar derives a weight arena named `weights-<sha256>-<size>.arena` with an exact tensor-layout manifest. It is built under a cross-process `flock`, with physically reserved bytes, fsynced temporary files and atomic renames; a warm load maps it read-only only after the manifest matches. A stale or partial arena is removed and rebuilt; ordinary model buffers are used only when arena creation fails. Model plus arena is about twice the artifact.
- Vendor parakeet.cpp/ggml from `ggml-org/whisper.cpp` commit `592feef04a1802b18cbeffd0fd0eb5d02570c2ec` (v1.9.2 lineage), preserving upstream-relative paths.
- Mark each local change to an upstream file with `VOICEOUR PATCH` and list it in `Vendor/parakeet/NOTICE.md`.
- `scripts/vendor_parakeet.sh --check` must reject unexpected files and verify embedded Metal regeneration is byte-reproducible; given an upstream checkout it also proves every manifest file equals the pin plus patches.
- Fix vendored warnings at the source with a recorded patch; never suppress them. `make build` treats Swift, C, and C++ warnings as errors.
- Never add `-mcpu=native`; the app bundle must run beyond the build host.
- The vendored parakeet.cpp/ggml drop is arm64-only by design, and `Vendor/parakeet/ggml/embed/ggml-metal-embed.c` enforces that at compile time. The app is Apple Silicon only; do not attempt a universal build. Making it universal would require re-vendoring upstream `ggml/src/ggml-cpu/arch/x86/{quants.c,repack.cpp}`, amending `Vendor/parakeet/NOTICE.md` and `scripts/vendor_parakeet.sh --check`'s expected-file set, and restructuring `Package.swift` into per-architecture targets because SwiftPM has no architecture build condition; that is not a supported build today.

## Environment seams

Environment variables pin one run; they never persist a choice. The app itself never sets the experimental sidecar variables.

| variable | read by | effect |
| --- | --- | --- |
| `VOICEOUR_ASR_BACKEND` | app, sidecar | Backend id. App precedence: `--asr-backend`, then this, then the persisted setting (`fake` only with `--debug`), then `parakeet`. The standalone sidecar defaults to `fake`. |
| `VOICEOUR_MODEL_VARIANT` | app, sidecar | `f16` or `q8_0`; outranks Settings for that launch. |
| `VOICEOUR_MODEL_CACHE` | sidecar | One explicit cache directory, neither per-variant nor pruned. Point it at an empty directory to exercise a cold download. |
| `VOICEOUR_SUPPORT_DIR` | app | Replaces `~/Library/Application Support/Voiceour/` verbatim. |
| `VOICEOUR_PRELOAD` | sidecar | `1` starts the preload thread; the app always sets it. |
| `VOICEOUR_IDLE_UNLOAD_MS` | sidecar | Idle model release delay; default 1,800,000; zero or negative disables. |
| `VOICEOUR_ASR_LOG` | sidecar | ggml log threshold: `debug`, `warn`, `error`, `none`; default info. |
| `VOICEOUR_FAKE_DELAY_MS` | fake backend | Delays fake transcription for cancellation tests. |
| `VOICEOUR_COREML_ENCODER_TINY`, `VOICEOUR_COREML_ENCODER_SHORT`, `VOICEOUR_COREML_ENCODER` | sidecar | Experimental CoreML encoder tiers for audio up to 6, 8, and 15 s. |
| `VOICEOUR_COREML_TINY_MAX_S`, `VOICEOUR_COREML_SHORT_MAX_S`, `VOICEOUR_COREML_MAX_S` | sidecar | Lower a tier's bound; raising it is rejected. |
| `VOICEOUR_COREML_WARM` | sidecar | `tiers` primes every configured tier whenever a context is created. |
| `VOICEOUR_TAIL_BACKEND` | sidecar | `cpu` routes the TDT prediction/joint tail to CPU/Accelerate. |
| `VOICEOUR_TAIL_QUANT` | sidecar | `q8_0` repacks the CPU tail's seven 2-D f16 matmul weights; requires the CPU tail. |
| `VOICEOUR_CPU_POOL` | sidecar | `persistent` attaches one ggml CPU threadpool sized to the decode thread count. |
| `VOICEOUR_ASSIST_MODEL`, `VOICEOUR_ASSIST_MODEL_2` … `_5`, `VOICEOUR_ASSIST_MAX_S`, `VOICEOUR_ASSIST_MODEL_3_MAX_S` … `_5_MAX_S` | sidecar | Research-only second-opinion GGUF models and their duration caps. A configured assist that fails is fatal. |
| `VOICEOUR_PARAKEET_INTEGRATION`, `VOICEOUR_CAPTURE_INTEGRATION` | tests | `1` enables the real-model and real-microphone suites. |
| `VOICEOUR_CODESIGN_IDENTITY`, `VOICEOUR_CODESIGN_KEYCHAIN` | `scripts/bundle.sh` | Signing identity and keychain; see [macOS permissions and signing](#macos-permissions-and-signing). |
| `VOICEOUR_REPO_ROOT` | UI harness, `scripts/console_shot.sh` | Repository root for fixtures and captures. |

Rules for the experimental sidecar seams:

- Every value other than unset or `default` that a seam does not recognize fails sidecar startup closed, and every configured CoreML path is resolved and validated while the backend is constructed: a missing artifact, a path that is neither `.mlmodelc` nor `.mlpackage`, or an out-of-range bound fails the start rather than reverting to Metal. CoreML tiers load lazily on the first utterance routed to them, and a load or prediction failure fails that request instead of retrying on another engine. The shortest configured tier covering the utterance takes it; longer audio decodes natively.
- `VOICEOUR_TAIL_QUANT=q8_0` leaves the artifact on disk untouched — every pin and digest check still holds — and caches the quantized image in a separate `.tail-q8` arena. A requested repack that converts no record fails the load rather than silently measuring the f16 tail.
- `VOICEOUR_COREML_WARM=tiers` primes on its own thread with throwaway clients, holding no decode state and no lock; a tier that fails to prime logs and stays lazy. Cold ANE specialization costs roughly twenty seconds per tier and its system cache is purgeable.
- These paths are deterministic but not byte-identical to the native Metal path; each is a measured non-inferiority trade, not a drop-in equivalence. Their evidence is development-only — `research/bet2-ane-encoder.md` and `research/bet3-quantization.md` — and the compiled encoder artifacts are not distributed with the app. Nothing here is a shipping configuration.
- `voiceour-bench external-encoder --engine coreai` compares a static 15 s Core AI encoder with one configured CoreML tier through the same native mel front end and four-thread ggml TDT tail. Its artifact contract is `mel` float32 `[1,128,1501]`, `mel_length` int32 `[1]`, `encoder` float32 `[1,1024,188]`, and `encoder_length` int32 `[1]`; `ParakeetContext.nativeMel` copies frame-major mel values for the asynchronous adapter, and external-state decoding keeps its own mel recomputation. The app, sidecar backend, launch environment, and settings never select it; [benchmarks.md](docs/benchmarks.md#core-ai-encoder-experiment) owns its conversion, measurement caveats, and provenance.

## Privacy and insertion safety

This app touches the user's microphone, active workspace, clipboard, and keyboard. Treat safety as product-critical. [README.md](README.md#safety-and-permissions) states the user-facing matrix.

- Snapshot capture context before recording and delivery context immediately before journal/insertion.
- `InsertionSafetyPolicy` is the single class-to-disposition mapping. Only `.normalText` may paste. It has no parameter to loosen that.
- Terminal, code-editor, secure, and unknown-risky classes are copy-only. There is no “paste everywhere” switch.
- Strip exactly one trailing newline for terminal and unknown-risky copies.
- `SafetyClassifier` precedence: active secure input, then a secure AX role or subrole, then no bundle id (unknown-risky), then known secure, terminal, and code-editor bundles (including Ghostty `com.mitchellh.ghostty`, Zed `dev.zed.Zed`, and every `com.jetbrains.` prefix), then an unavailable inspection (unknown-risky), else normal text.
- An AX inspection failure is unknown-risky. `kAXErrorNoValue` is the narrow “no focused element” answer and is classified by bundle; a readable element with nil role and subrole is normal text, because secure input already leads the precedence.
- Re-check full target identity — bundle id, app name, pid, safety class, and secure-input flag — before writing the pasteboard and again before Cmd-V.
- Never read, save, or restore the user's previous clipboard. Write only the transcript.
- Secure output carries the concealed marker, uses host-only pasteboard preparation, remains copy-only, and creates no `recent-sessions.json` row and no ledger entry.
- Ordinary paste attempts carry the transient marker, and only a posted Cmd-V schedules the transient clear: after 1.5 s, clear the transcript only if the pasteboard change count is unchanged. Copy-only output is plain string and is never cleared.
- Publish transcript text and privacy markers as one `NSPasteboardItem`. `GeneralPasteboard.copy` returns a change count only when the whole item landed; `nil` becomes `pasteboard_write_failed`. A failed write MUST NOT post Cmd-V, schedule a clear, confirm copying, or announce clipboard delivery.
- Never persist audio. Remove temporary files after success, cancellation, error, and stale-file scavenging.
- Accessibility inspection reads the focused control; it never mutates text. Delivery is never an Accessibility text write.

## Persistence

- Settings (`settings.json`, including the glossary), History (`recent-sessions.json`), and the lifetime ledger (`dictation-activity.json`) live in the support directory with owner-only permissions and atomic writes. Their saves share one detached FIFO persistence tail, keeping write order intact and file I/O off the main actor. Do not suppress write failures; a History snapshot failure surfaces as “Dictation history could not be saved.” without preventing delivery or later saves.
- History is one local file, newest first, capped at 500. Settings, history, and ledger load failures quarantine the unreadable file as `<name>.corrupt-<ISO8601>` and report the reset with that file name.
- Fold the ledger exactly where the transcript is journaled, in one main-actor turn and from that same row, then enqueue both snapshots on the ordered persistence tail. A secure target reaches neither; every other delivery disposition reaches both. Writes are atomic per file, not a cross-file transaction; persistence failures must remain visible. Home and the first-run decision read both records.
- The ledger keeps aggregate counts per local day and per destination-app bundle id — no transcript text and no session ids. It prunes day buckets more than 400 days before the recorded day while preserving totals, active-day count and the longest streak, and removes its file when emptied. App buckets are never capped or pruned: the map is bounded by the apps the reader dictates into, and each keeps sessions, words, seconds, the last non-nil display name seen, and its latest day key.
- First launch without a ledger seeds it once from the transcripts still on disk; rows with no measured `captureMs` contribute words with zero seconds rather than an invented speaking rate. An existing ledger with no app buckets is seeded once more, app buckets only (`totalSessions > 0 && apps.isEmpty`), because the totals already counted those sessions.
- Settings' Clear History erases History and the ledger. Clear Vocabulary removes every user-learned term and restores surviving bundled terms to their shipped surfaces.
- Diagnostics (Copy Diagnostics) carry build, backend, model, health, permission, microphone, saved-session count, and storage-path facts. Never add transcript text to them.

## Glossary rules

- Reject an alias that case-insensitively equals another term's canonical or alias, checked over generalizable aliases. Enforce it in Teach, Glossary add and save, suggestion accept, and import; an ambiguous proposal is refused whole, and an import validates the whole merged glossary before assigning any of it.
- A word list imports as one of three shapes: a JSON array of spellings, a JSON array of `{"term": ..., "heard_as": [...]}` rows, or a newline-delimited list of spellings. The row shape exists because a spelling alone cannot repair a term the model mishears rather than merely respaces — `derivedAliases` recovers `Swift UI` from `SwiftUI`, but nothing derives `Qbectal` from `kubectl`. `heard_as` is the field name the Glossary editors show. Imported surfaces are filtered rather than cleaned (`VocabularySanitizer.isSafe`, the length cap), deduplicated case-insensitively against each other and the canonical, and capped by `WordListLimits` (500 terms, 64 characters, 8 aliases per term); a row carrying one unusable form still contributes its usable ones. Imported terms are unprotected `manualImport` terms.
- Only explicit user action may confirm, reject, import, remove, or clear learned vocabulary. Automatic/background paths never teach. Suggestions stay in memory and never become persisted authority without acceptance.
- Keep each utterance's vocabulary snapshot bounded. A term is active everywhere: vocabulary is never scoped to an app or a project, and both editors offer exactly two inputs, Term and Heard as, plus a read-only *Also matched* readout of derived forms.
- History's ⌘T teach opens the term the selected surface already belongs to — its spelling and every user-authored form — and commits with that term's id, so a prior teaching is visible and full-set semantics apply. An unowned surface opens a blank spelling and commits additively. Teach offers no empty well for a further form: the surface it was aimed at already is the form, so only a set with nothing in it draws one. The Glossary's own two editors always draw it, because authoring a term is what that tab is for.

## Local-first and network policy

- Real ASR is local through `parakeet`; the fake backend is non-production.
- The only acceptable network access is acquisition of one of the compiled model URLs — the variant's artifact on the same host, in the same repository, at the same revision, verified against its compiled digest. Do not add network text processing, telemetry, crash reporting, accounts, update checks, or arbitrary URLs.
- The sidecar launch environment is an allowlist: `PATH`, `HOME`, `TMPDIR`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` (and their lowercase forms), `SSL_CERT_FILE`, and `VOICEOUR_*`. Never inherit the full parent environment. The client always writes `VOICEOUR_ASR_BACKEND` and `VOICEOUR_PRELOAD=1`, and writes `VOICEOUR_MODEL_VARIANT` last for a model-backed sidecar so an inherited shell value cannot outrank the user's selection; in the app process the variable does outrank the persisted setting, which is what lets the harness and the benchmark pin an artifact without editing the user's settings.
- Voiceour stores no credential and has no credential UI, environment contract, base URL, or keychain item.

The absence of a secret store is measured. This bundle cannot use the macOS data-protection keychain: it ships no provisioning profile, and `Resources/Voiceour.entitlements` is audio-input only. `SecItemAdd` returned `errSecMissingEntitlement` (-34018); adding `keychain-access-groups` to an ad-hoc signature caused AMFI to kill it as “adhoc signed but contains restricted entitlements.” Do not introduce a feature that quietly depends on that keychain.

## Swift conventions

- Swift tools version is 6.4; every target uses Swift 6 language mode and the deployment target is macOS 27.
- Prefer concrete, explicit target-boundary types and small protocols.
- Keep observable UI state main-actor isolated. Move blocking capture, file I/O, hashing, and model work off the main actor. Keep high-rate values such as the 25 Hz input meter off the coordinator's observed state.
- Use structured ownership for files, processes, capture sessions, and persistence tails. Identity-check teardown where a stale owner can race a newer resource.
- Prefer existing patterns and delete obsolete callers/types in the same change. Do not leave compatibility shims for internal APIs.
- Avoid avoidable allocations/copies in compiled hot paths.

## Developer commands

Use the smallest command that proves the change.

| task | command |
| --- | --- |
| Print the target catalogue | `make` |
| Debug build; Swift, C and C++ warnings are errors | `make build` |
| Swift tests including harness suites | `make test` |
| Whole local gate | `make check` |
| Format sources/tests | `make format` |
| Check formatting | `make format-check` |
| Model pin and doc command consistency | `make check-docs` |
| Lint Python benchmark package | `make lint-python` |
| Bundle app | `make bundle` |
| Verify bundle | `make verify-bundle` |
| Stable local signing identity | `make signing` |
| Cut a source release | `make release` |
| Cut a binary release | `scripts/release.sh --binary` |
| Release preflight only | `scripts/release.sh --dry-run` |
| Sign, notarize, staple, validate | `make notarize` |
| Check the Apple notarization environment | `scripts/sign_notarize.sh --check-env` |
| In-process cleanup and classification self-test | `make self-test` |
| Debug app on the fake backend, in this terminal | `make dev` |
| Real app build/launch | `make run` |
| Stop every running Voiceour | `make stop` |
| Process, bundle, and signature | `make status` |
| Stream Voiceour logs | `make logs` |
| Generate the local audio fixture | `make fixture` |
| Real model proof | `make build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav` |
| Scene gate | `make ui-snap` |
| Bless intended scene change | `make ui-update` |
| List scenes | `make ui-list` |
| Semantic flow gate | `make ui-flow` |
| Bless intended flow journal | `make ui-flow-update` |
| List flows | `make ui-flow-list` |
| Complete local UI gate | `make ui-all` |
| Extra harness flags (`--only`, `--help`) | `scripts/ui_harness.sh` |
| Render isolated mercury material sheets | `make ui-mercury` |
| Benchmark mercury across 4,096 rooms | `make ui-mercury-bench` |
| Capture the onscreen console (disruptive; Screen Recording) | `scripts/console_shot.sh` |
| Offline benchmark smoke | `make bench-smoke` |
| LibriSpeech benchmark | `make bench-stt N=64` |
| FLEURS end-to-end report | `make bench-e2e N=64` |
| Technical-term smoke | `make bench-techterms` |
| U-WER comparison gate | `make bench-gate BASELINE=... CANDIDATE=...` |
| Python benchmark tests | `make test-python` |
| Vendor integrity | `scripts/vendor_parakeet.sh --check` |
| Refresh vendored sources from an upstream checkout | `scripts/vendor_parakeet.sh <upstream>` |
| Regenerate the repair ordinary-word list | `scripts/generate_ordinary_words.py` |
| Regenerate the committed app icon | `scripts/make_icon.sh` |
| Delete `.build` | `make clean` |

`make check` runs `build`, `format-check`, `check-docs`, `lint-python`, `test`, `ui-flow`, `ui-mercury-bench`, `test-python`, `self-test`, `bench-smoke`, in that order. `make self-test` runs the debug app with `--self-test`, which checks cleanup output and target classification without constructing a backend. `make bench-stt` and `make bench-e2e` default to `N=200` and `BACKEND=parakeet`. Benchmark commands must retain `uv --no-config`. Do not run real model or microphone checks unless the task needs them and prerequisites are present. [benchmarks.md](docs/benchmarks.md) holds tiers, metrics, and promotion gates; [ui-harness.md](docs/ui-harness.md) holds harness commands and artifacts.

## Fast iteration runtime

- Source edits are not a runtime proof. Rebuild and relaunch the surface the user will exercise when app behavior or bundled resources changed.
- Default to nondisruptive verification: offscreen harnesses and synthetic or recorded fixtures. Do not activate windows, post keys into live apps, play speaker audio, or open the microphone without agreement to that specific interruption; a request to test end-to-end is not that agreement.
- Use the fake path for deterministic coordinator/menu/window behavior.
- Use the real bundle for microphone, model acquisition, hotkey, insertion, entitlement, signature, helper-placement, or material behavior.
- `make run` re-bundles only when `Package.swift`, `scripts/bundle.sh`, or anything under `Sources/`, `Resources/` or `Vendor/` moved, then stops the running instance and launches. The app terminates a second instance of itself, so a launch over a live instance makes the newly built process quit and leaves the old one running. An agent that launches without stopping first verifies the previous build. `.env` and signing changes do not trigger a re-bundle; run `make bundle`.
- `make dev` runs the unbundled debug binary and stops nothing; it uses the fake backend unless `VOICEOUR_ASR_BACKEND` is set.
- `make stop` and `make status` match the `Voiceour` process name only. The sidecar exits on stdin EOF after its bounded shutdown; check for a lingering `voiceour-asr` when a stale helper matters.
- Verify the intended PID/bundle with `make status` rather than assuming another launch won.
- A root `.env` is sourced, with every key exported, by `make run` and `make dev`, and `scripts/bundle.sh` reads its signing pins. `make run` forwards `VOICEOUR_ASR_BACKEND`, `VOICEOUR_MODEL_VARIANT` and `VOICEOUR_SUPPORT_DIR` explicitly with `open --env`. macOS 26 was observed propagating the shell's environment through a LaunchServices launch, but that is not a documented contract, so a name the app reads is forwarded rather than assumed. Add the forward when the app learns to read another one.
- Launch flags go through `ARGS`: `make run ARGS="--debug --show-console"`, `make dev ARGS=...`. The app reads `--debug`, `--show-console`, `--console-section=<home|glossary|history|settings>`, `--no-activate`, `--asr-backend <id>`, `--self-test`, and, only in `-DUI_HARNESS` builds, `--ui-harness`.
- `make logs` streams subsystem `com.voiceour.app`: categories `hotkey` and `audio`. The stop-path signposts (`stop-path`) need Instruments or `xctrace`.

## Offscreen UI harness

`Voiceour --ui-harness` is compiled only with `-DUI_HARNESS`, which the Makefile and `scripts/ui_harness.sh` pass on the command line. It renders real SwiftUI into a borderless offscreen window, captures via `NSHostingView.cacheDisplay`, dumps in-process AX, lints, compares scene digests/dumps, and runs semantic journeys that write `.flow.txt` journals. [ui-harness.md](docs/ui-harness.md) is its operational reference: commands, artifacts, goldens, scene and flow rules.

Current scene inventory covers Home, Glossary, History, Settings, menu, overlay, and accessibility adaptations through the shipping macOS 27 path. Flows cover the four tabs — History through its in-place detail and its two search journeys — plus the core delivered/copy-only/cancel/error journeys; History's click-to-copy and ⌘T gestures have no flow because neither can be delivered to a window that never becomes key, and its app filter has none because an `NSMenu` popup cannot be shown by a window that never orders front, so the `console.sessions.selection`, `console.sessions.teach`, `console.sessions.deselected` and `console.sessions.filtered` scenes lock what those states say and the gestures themselves are verified in the real app. Use `make ui-list` and `make ui-flow-list` as authoritative inventories.

Load-bearing measured invariants:

- Set `.prohibited` before any hosted view. It activated in 0/24 runs versus 20/30 under `.accessory`; key refusal alone was insufficient.
- Ignore the false return from `setActivationPolicy(.prohibited)`; the policy is still applied.
- Create `NSApplication.shared` and call `finishLaunching()` before CoreGraphics window APIs.
- Park at (-30,000, -30,000). Override `constrainFrameRect` without `super`; a probe at (-12,000, -12,000) was moved visibly to (320, 480) for 2.4 seconds.
- The window cannot become key/main and may never order front. Swallow normal ordering and `orderFrontRegardless`; allow only order-out for close. Unordered capture was byte-identical.
- `ConsolePresentation` and the app delegate's first-run guard must observe `.prohibited`; the harness reasserts it before and after hosting so appearance/disappearance cannot change policy.
- Enhanced accessibility is mandatory: measured 1 AX node before enabling and 23 after.
- Pump fixed counts: 150 one-millisecond iterations before and after interaction, 30 at teardown. Never adapt to “stable”; a 200 ms animated probe produced 6/6 unique hashes.
- Each pump includes a run-loop slice and posted-event drain; sleep or run-loop alone did not deliver queued AppKit events.
- Capture into an owned interleaved RGBA8 `.deviceRGB` bitmap. The system caching bitmap embedded a 3,149-byte monitor profile plus cICP data.
- Keep alpha; disabling it reintroduced subpixel font smoothing, the largest measured raster drift.
- Never replace capture with `ImageRenderer`; it painted AppKit-backed controls/representables as `#FFCC00` placeholders.
- The harness cannot show composited console/menu glass: `NSGlassEffectView` under `cacheDisplay` has no sampled desktop. Use an onscreen material check for glass itself. The recording island is a plain `CGImage`, pinned by seed and exact substep, and is fully captured offscreen without starting a display link.
- `cacheDisplay` also omits blur/shadow filters. Do not weaken offscreen/activation guarantees to recover them.

`RenderOverrides` is production-compiled because real views read it. The invariant is about its defaults: every field's declared default is nil or false, and with all of them at that default the app behaves exactly as it would if the type did not exist. How a set seam is read follows what it substitutes — `override ?? realValue` for a value, `if let` for a wholesale replacement such as `installedApps` or the `textRoleRecorder` probe. Seams may pin time, locale/calendar/time zone, permissions, paths, accessibility adaptations, selection — including History's opening selection, which `historyStartsDeselected` suppresses so the closed-list state can be rendered — History's opening app filter (`historyInitialAppFilter`, because an `NSMenu` popup cannot be driven offscreen), History's open teach editor and the surface it was aimed at (`historyTeachSurface`, one seam read where ⌘T's own word is read, because the keystroke cannot reach a window that never becomes key), the microphone catalog (`availableMicrophones`, so goldens never encode which input devices the rendering Mac has), the mercury seed, step, and world, and text-role instrumentation. A seam substitutes an input or selects a path production already reaches on some real machine or state; it may never fabricate an outcome the app cannot reach on its own, and no branch may exist solely to make a golden pass.

The authoritative field inventory and seam-specific rationale live in [`RenderOverrides.swift`](Sources/Voiceour/RenderOverrides.swift).

Read `.ax.diff` or `.flow.diff` before update mode. Error-severity lint findings and red flows cannot be blessed. Filtered runs accelerate iteration but do not prove the full catalog. CI requires semantic flows; its hosted scene snapshots are advisory, so never re-bless from CI raster drift.

## macOS permissions and signing

- Microphone permission applies to real capture, not fake development. It is requested at the first real recording.
- Accessibility trust enables active key suppression and synthetic Cmd-V; the synthetic-paste gate is `CGPreflightPostEventAccess()` or `AXIsProcessTrusted()`, requested at most once per process. Missing trust degrades to passive hotkey observation and copy-only delivery.
- Input Monitoring is not requested, and the entitlement set must never include it.
- Use stable local signing for repeated TCC testing. Ad-hoc identity can change after rebuild.
- `scripts/bundle.sh` picks its identity in this order: `VOICEOUR_CODESIGN_IDENTITY` and `VOICEOUR_CODESIGN_KEYCHAIN` from the environment; the same names from `.env`; the `voiceour-dev` identity in `~/Library/Keychains/voiceour-dev.keychain-db` that `make signing` creates; else ad-hoc `-`, with a stderr warning. An explicit identity bypasses the local pins, so release signing never inherits a development keychain. `VOICEOUR_CODESIGN_IDENTITY=- make bundle` is the documented ad-hoc fallback. Changing identity can require fresh Microphone and Accessibility grants.
- If `make signing` cannot unlock an existing development keychain, it refuses to replace it. Unlock it as its owner; never delete or reset a keychain for a build. Do not commit its output.
- Development bundles do not enable the hardened runtime; `scripts/sign_notarize.sh` enables and verifies it on both the app and `voiceour-asr`.
- Release verification must include the signed sibling helper, hardened runtime, entitlements, and clean-account permission behavior, using the manual qualification and release matrix in [README.md](README.md#verification).

## Release procedure

A release is a tag, the notes that describe it, and whatever assets that tag carries. There are two kinds and the only difference is the assets.

- **Source release.** The default, the normal case, and the kind this project cuts first: preflight, a `v<version>` tag, and a GitHub release whose notes are that version's `CHANGELOG.md` section. GitHub generates the source `.zip` and `.tar.gz` itself. Nothing is signed, no Apple identity exists in the flow, and no Apple environment variable is read — a source release cannot fail for want of a Developer ID because it never asks for one. It is worth cutting on its own: it gives the project a citable version, a permanent anchor for that changelog section, source archives that are not a moving branch, and a `releases/latest` that resolves instead of 404ing.
- **Binary release.** Opt-in and later. Everything the source release does, plus the signed, notarized and stapled app archive and its checksum attached as release assets. It needs a paid Developer ID, so it happens once there is one and not before.

Releasing at all is optional, and a binary is not what makes a release real. Building from source is a first-class supported path — the one `README.md` documents and the one every contributor uses — and a binary release exists only to spare a user the toolchain.

Rules for both kinds:

- `Resources/Info.plist` is the single source of truth for the version. `CFBundleShortVersionString` is the semver a human reads; `CFBundleVersion` increases monotonically and never repeats a value. No version literal is restated in a script, the Makefile, a workflow, or a document — tooling extracts it from the plist, the same discipline `scripts/check_docs.sh` applies to the model pin.
- The version, the `CHANGELOG.md` heading, and the git tag agree. The tag is `v<version>`. A version is released exactly once: a re-cut takes a new version rather than moving a tag.
- That version's `CHANGELOG.md` section *is* the release notes. `scripts/release.sh` extracts it verbatim — from the `## <version>` heading, which may also be written `## [<version>]` or `## [<version>] - <date>`, up to the next `## ` — into `.build/Voiceour-<version>-release-notes.md`, and the printed `gh release create` line passes that file with `--notes-file`. Nothing composes release notes by hand, so a tag cannot disagree with the changelog.
- Preflight refuses to release outside a git checkout, from a dirty tree, from a branch other than `main`, from a `main` that is behind — or cannot be compared with — the local `origin/main` ref (nothing is fetched), on a `CFBundleShortVersionString` that is not `N.N.N`, on a version whose `## <version>` heading is missing or whose section is empty, or on a version whose `v<version>` tag already exists. In binary mode it also requires `scripts/sign_notarize.sh --check-env` to pass. It then runs `make build`, `make format-check`, `make check-docs`, and `make test`. A release points at a commit and that commit must be green, so the gate runs in both modes — nothing being signed is not a reason to skip verification.
- Preflight accumulates: every failed check prints its own `release.sh: FAIL: <reason>` line on stderr before the script exits 1, so one run names everything that needs fixing. A usage error exits 64. Incomplete Apple credentials in binary mode are one of those preflight failures; `scripts/sign_notarize.sh` run on its own exits 2 for them and 64 for a usage error.
- `scripts/release.sh` never bumps the version, tags, pushes, or publishes. It prints the exact `git tag`, `git push`, and `gh release create` commands for the mode it ran, and the maintainer runs them.
- `make release` is the source release. The binary release is `scripts/release.sh --binary` and has no `make` target on purpose: the default path must be the one that needs no credentials. `--dry-run` composes with either mode in any argument order, runs every check for that mode, and stops before writing the notes file, signing anything, and printing the publish commands — in source mode it is therefore the whole procedure minus its output, and it works with no Apple environment present at all.

Rules for the binary release only:

- An un-notarized binary is never published. The choice is a source release or a properly notarized one; a bare zip of an ad-hoc `.app` is not a third option. A copy of an ad-hoc or un-notarized `.app` arrives on another Mac carrying a quarantine flag and Gatekeeper refuses to open it, so that download is worse than no download: it looks like a broken app instead of an absent one.
- A published binary is Apple Silicon only, and its release page and release notes must say so.
- The published artifact is Developer ID signed with the hardened runtime, notarized, and stapled, and it is a zip produced by `ditto -c -k --keepParent`, never a DMG. `notarytool` accepts the zip directly, and a menu-bar app has no drag-to-Applications ritual that would repay a disk image's layout.
- **The notarization ticket is stapled into the app before the distributed archive is created.** The app is archived twice on purpose: once as a submission envelope, because `notarytool` cannot take a `.app` directory, and again after `stapler staple` has written the returned ticket into the app on disk. The stapled ticket is what lets Gatekeeper verify a first launch offline; an archive zipped before stapling contains an unstapled app and loses the ticket silently, because the build machine's own online lookup still succeeds and hides the defect. Do not collapse the two `ditto` calls into one — the single-archive form is exactly the bug this ordering fixes. The submission envelope is deleted afterwards so it can never be mistaken for the artifact.
- The archive is `.build/Voiceour-<version>.zip`, named from the extracted version, with a `.sha256` sidecar beside it that is the checksum of the stapled archive and never of the submission envelope; the sidecar uses a relative path, so `shasum -a 256 -c` works from inside `.build`. `.build/Voiceour-release-manifest.txt` records the build.
- Required environment is `DEVELOPER_ID_APPLICATION` plus either `NOTARY_KEYCHAIN_PROFILE` or the `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` triple. Prefer the profile: an app-specific password passed on a command line is visible in the process table. Create it once with `xcrun notarytool store-credentials`. Nothing outside the binary path reads any of these, and their absence is not a failure anywhere else.
- Verification runs inside the flow, not afterwards as a favour. `scripts/verify_bundle.sh` asserts the signed `voiceour-asr` sibling, arm64-only app and helper, packaged resources (including the non-empty ordinary-word list and third-party licenses), `CFBundleIdentifier = com.voiceour.app`, `LSUIElement = true`, a non-empty `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion = 27.0`, and `vtool` `minos 27.x` / `sdk 27.x` on both binaries. The `audio-input` entitlement is present; `app-sandbox` and `input-monitoring` are absent. Never weaken those assertions to make a build pass. Notarization additionally verifies hardened runtime on both the app and helper, the stapled ticket, and `spctl --assess`; release verification includes clean-account permission behavior.
- A binary release is local and manual, never CI, and no release workflow should be added for it. Notarization needs Apple credentials, a public repository's secrets are a risk surface, and fork pull requests widen it — the same measured no-credential-store posture the network policy above describes. `.github/workflows/ci.yml`'s `release` job builds, bundles, and verifies, and uploads nothing: it is a packaging smoke test, not a release pipeline, and must not be mistaken for one.
- `make notarize` runs `scripts/sign_notarize.sh`: Developer ID signing with hardened runtime, submission, stapling, validation, then the archive, its checksum, and the manifest. `scripts/sign_notarize.sh --check-env` validates the Apple environment and exits without building or submitting anything, so the credential rule lives in exactly one place.

Release publication is maintainer-run by default. An agent MAY run the printed tag, push, and publication commands only after explicit user authorization in the current conversation.

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

- README.md and AGENTS.md are the only authoritative documents. README.md owns user-visible behavior and the product/technical contract — product behavior, architecture, runtime and data, model and network, safety and permissions, non-goals, development, and verification. AGENTS.md owns engineering invariants, boundaries, protocol and vendor rules, UI and harness rules, commands, and the release procedure.
- Specialist documents hold derivations, measurements, and runbooks only: `docs/ui-harness.md` (harness operation), `docs/mercury-renderer.md` (renderer derivation and gates), `docs/benchmarks.md` (benchmark tooling and dated measurement records), `docs/performance-roadmap.md` and `docs/rust-evaluation.md` (dated measurement records), and `research/` (experiments). They link back to the root sections they serve and never restate or redefine the product contract. A dated measurement is never a shipping promise.
- `CONTRIBUTING.md` owns PR gates, `SECURITY.md` vulnerability reporting, and `CHANGELOG.md` user-visible changes and release notes.
- Describe each topic in exactly one place and link to it elsewhere. Keep live docs declarative and repository-specific: describe the app as it is, not the sequence of deletions that produced it.
- Put superseded but useful records under `docs/archive/` with an explicit archive notice and date. Do not add new plan or redirect documents.
- Every command example must exist in the current Makefile/scripts or executable CLI; `make check-docs` enforces `make` targets and script paths in README.md, AGENTS.md, CONTRIBUTING.md, and top-level `docs/*.md`.
