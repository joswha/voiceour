# Architecture

Voiceour is a macOS menu-bar dictation app. It has one production speech path: microphone capture, a local Parakeet sidecar, deterministic cleanup, then a safety-checked delivery to the focused app. Downloading the pinned model is the only network access, and `voiceour-asr` is the only subprocess.

```mermaid
flowchart LR
    Hotkey[Fn / Globe tap] --> Coordinator[DictationCoordinator]
    Coordinator --> Recorder[MicrophoneRecorder]
    Recorder --> WAV[16 kHz mono WAV]
    WAV --> Client[SidecarASRClient]
    Client --> Sidecar[voiceour-asr]
    Sidecar --> Model[pinned parakeet.cpp GGUF]
    Coordinator --> Cleanup[CleanupEngine + glossary + repair]
    Cleanup --> Safety[Delivery-target safety check]
    Safety --> Clipboard[Clipboard]
    Safety --> Paste[Cmd-V when allowed]
```

## Targets and products

- `VoiceCore` — domain logic: settings, session state, ASR wire types, cleanup, glossary, vocabulary repair, history models, failures, safety policy. Foundation only; no AppKit, SwiftUI, or AVFoundation.
- `VoiceMac` — macOS adapters: capture, fake audio, sidecar process management, target tracking, pasteboard delivery, permissions, hotkeys. Imports `VoiceCore` and system frameworks, never SwiftUI.
- `Voiceour` — the app executable: SwiftUI menu, recording overlay, console window, and `DictationCoordinator`. Imports both libraries; nothing imports it.
- `ASRSidecarCore` — model acquisition, WAV loading, the Parakeet context, the optional CoreML encoder client, both backends, and the NDJSON server. Imports `VoiceCore` and `CParakeet`, never `VoiceMac`.
- `VoiceourASR` builds `voiceour-asr`. `ASRSidecarStub` serves process-contract tests. `VoiceourBench` builds `voiceour-bench`, which runs the production path over manifests.
- `CGgml` and `CParakeet` compile the vendored C/C++ under `Vendor/parakeet/`.

## Session flow

```text
idle -> checkingPermissions -> recording -> finalizingAudio -> transcribing -> cleaning
     -> readyToInsert -> pasteAttempted | copiedOnly | insertFailed -> idle
```

`error` and `cancelled` are the other two endings, both returning to `idle`.

Invariants:

- One tap starts one utterance. No wake word, no live transcript.
- One stop performs one final decode. A second tap, the overlay, and auto-stop all finalize exactly one WAV.
- Stale async work is ignored. Each phase takes a token from `AsyncGenerationGate`; a result whose token is no longer current is dropped, not applied to a newer session.
- Cleanup runs exactly once, after ASR.

Each utterance takes two target snapshots: the capture target before recording, which names the record-start "Will paste into X" label, and a fresh delivery target immediately before persistence and insertion. Vocabulary is compiled once per utterance from the glossary alone; a term is active everywhere, never scoped to an app or a project.

Starting and stopping capture blocks, so it runs off the main actor on a serial queue.

Which device records is decided per recording, in `CoreAudioInputDevice.preferredCaptureUID`. A microphone chosen in Settings — persisted as its durable CoreAudio UID plus the name that can still label it while unplugged — wins whenever it is connected. Without one, or when it is unplugged, the automatic policy applies: the system default input, except that a Bluetooth headset default is redirected to a working built-in microphone, because HFP/SCO negotiation replaces the first second of a headset capture with digital zeros. A selection that stops resolving falls back rather than failing the dictation.

`UserFacingDictationFailure` is the single mapping from mechanism to recovery: each failure gets a title, a plain cause, whether retrying can work, and where to fix it.

## Recording overlay renderer
The full derivation, research record, rejected alternatives and measured gates live in
[Procedural mercury renderer](mercury-renderer.md).

`RecordingOverlayController` owns one transparent nonactivating panel, one
`MercuryHitRegion`, and one random session seed. `MercuryRibbon` turns state and the
eleven input levels into `MercurySimulation.Drive`. `MercurySurfaceView` binds one
`CADisplayLink` to the display containing the panel; `MercuryEngine` advances the fixed
120 Hz simulation and writes the resulting `CGImage` directly to its layer. The same
field is published to AppKit mouse routing.

The geometry pipeline has one representation:

1. `MercurySimulation.Geometry` supplies 97 top and bottom contact-line samples.
2. `MercuryField` linearly evaluates their center/radius signed field for pixels and hit
   testing.
3. `MercuryCrown` lifts that field with
   `z = β√(2rφ̃ − φ̃²)`, `β = 0.78`, using a quarter-pixel smooth-positive `φ̃` only to
   regularize the analytic limb. The normal is the total derivative
   `(∂z/∂φ)∇φ + (∂z/∂r)∇r`; omitting the second term lets the outline wiggle while the
   reflection remains mechanically straight.

`MercuryEnvironment` builds three 96² octahedral linear-RGB tables with one analytic
border texel on every edge. Runtime reflection lookup is four taps with no trigonometry,
modulo or seam branch. Room of Ten uses 32 bounded, equal-area-stratified
spherical-Gaussian area sources (log-uniform sharpness 20–600) over 30% neutral bounce.
Per-source log intensity is bounded to ±0.55 and a seed-random
Rec.709-luminance-null opponent supplies at most 7% local chroma; source coefficients
are power-centered, so the sphere mean remains neutral. The room is fixed after
construction. Spectral Weather remains a debug-only alternate draw and is fixed too;
environment motion never competes with the organism.

`MercuryRasterizer` samples the static room in the exact mirror direction. Process-built
tables interpolate the exact unpolarized liquid-mercury conductor Fresnel, bounded
Naka–Rushton response and IEC sRGB transfer; dense oracle tests hold the optical error
below one 8-bit code value. `MercuryCalibration` meters linear `room × Fresnel` samples
pooled over listening and speaking and solves `MercuryDisplayResponse` from two anchors:
p50→0.32 and p98→0.87. Its compiled 0.94 linear-light ceiling is unreachable by finite
radiance; RGB gamut handling preserves mapped Rec.709 luminance while desaturating only
when a channel would leave that ceiling.

The permanent material and speed gate is `make ui-mercury-bench`: 4,096 generated-room
seeds, 64 production rasters, reflected-direction coverage, output bounds, 30 seconds of
surface motion, 1,200 production rasters and 1,200 complete engine-plus-layer
presentations representing ten seconds at 120 Hz. Raster p50/p99 must stay below
0.55/0.70 ms and 6.6% of one core; engine plus layer must stay below 0.65/0.85 ms and
8%. `make ui-mercury` is the non-gating visual bench for states, grounds, worlds,
motion, parameter sweeps and shipping/prototype comparisons.

Physics always advances in exact 1/120-second substeps. Presentation follows the panel's
screen, capped at 120 fps: one substep per ProMotion frame, two per 60 Hz frame, with a
fractional carry for other fixed rates. The view-bound display link stops while hidden or
off-display and is recreated when the panel changes screens. No per-frame value is
published through SwiftUI. Geometry-mode calibration warms during launch; the gate holds
it below 200 ms and first-room plus first-raster latency below 25 ms.

## ASR sidecar protocol

Newline-delimited JSON over the sidecar's stdin and stdout. Stdout carries protocol frames only; logs go to stderr. Every frame carries `protocol_version: 1`, and the client rejects any mismatch.

The sidecar emits `hello` on start and accepts `health`, `transcribe`, and `cancel`. Each request gets exactly one terminal response — `result`, `error`, or `cancelled` — matched by request id. `health` reports readiness, model and cache state, download progress, warmup, and the backend's last unresolved acquisition failure. That failure is a wire error code plus a diagnostic detail, optional in both directions, latched by the backend when a download, verification, disk-space or load attempt fails and cleared by the next successful load. The app takes it over any state it could infer for itself.

`SidecarASRClient` owns one persistent child and multiplexes request ids. The child's environment is an allowlist — `PATH`, `HOME`, `TMPDIR`, the proxy and TLS variables downloading needs, and `VOICEOUR_` names — so no other parent variable crosses the boundary. Registered backends are exactly `parakeet` (production) and `fake` (development, tests, benchmarks), and the recognizer is English-only.

## Model pin

One repository at one revision, holding two conversions of the same checkpoint:

- model: `ggml-org/parakeet-GGUF`
- revision: `35156454d1a39de06863303dd209fd2bed6ee079`
- `f16` — Balanced: `ggml-parakeet-tdt-0.6b-v3-f16.bin`, SHA-256 `833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f`, 1,255,897,319 bytes
- `q8_0` — Compact: `ggml-parakeet-tdt-0.6b-v3-q8_0.bin`, SHA-256 `4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e`, 668,757,119 bytes

`f16` is the default and the fallback for an unknown or stale persisted value. The two decode the same text to within what the committed corpus can resolve, so the choice is a footprint trade: `q8_0` saves 587 MB of download and approximately 1.17 GB of combined post-load cache, and loads faster. `f16` decoded faster when this default was chosen on macOS 26.5.2, and that ordering no longer reproduces on 26.6.2, so throughput is not currently a reason to prefer either artifact. [performance-roadmap.md](performance-roadmap.md) holds the measurements and the dated correction.

The selection travels one path. Settings persists it as `asr_model_variant`; the app resolves `VOICEOUR_MODEL_VARIANT` first and that setting second, so a harness or benchmark run can pin an artifact without editing the user's settings; the resolved variant is written into the sidecar's launch environment, which picks that variant's cache subdirectory, artifact manifest, and download URL; and every real decode request carries `expected_model.file`, the one field that can distinguish two artifacts of a single revision, so a sidecar still holding the previous selection fails the request instead of transcribing with the wrong weights. Switching therefore takes effect on the next launch, and `DictationCoordinator.activeModelVariant` stays the running sidecar's artifact so Settings can say so.

`ParakeetModelCache.cacheOK` accepts a cached artifact only when the manifest's id, revision, file, digest, and size all equal the selected variant's compiled pin, and the file on disk is exactly that size. Downloads verify the streaming digest. Once the wanted artifact is verified, the other variants' cache directories are removed: only one artifact is ever resident, and `f16` keeps the legacy directory name so an existing install is not orphaned into re-downloading 1.26 GB. To exercise a cold download, point `VOICEOUR_MODEL_CACHE` at an empty directory; that override names one directory for whichever variant is selected, so it neither gains a per-variant subdirectory nor prunes anything. Overriding `HOME` does not move the cache, so a scratch home silently reuses the real artifact and proves nothing.

After the selected artifact is verified, the sidecar derives a source-pin-named weight arena for warm loads. The arena has an exact tensor-layout manifest, is built under a cross-process lock with physically reserved bytes, fsynced temporary files and atomic renames, and is mapped read-only only after validation; stale, partial or unusable state falls back to ordinary model buffers. It is generated locally and is approximately the model’s size, so model plus arena use about 2.51 GB for Balanced or 1.34 GB for Compact. Switching variants removes the other variant’s cache directory, including its arena.

## Experimental CoreML encoder

An off-by-default execution path runs the FastConformer encoder on the Neural Engine through CoreML while the mel frontend, the TDT decode loop, and the pinned GGUF weights stay native. It is an execution-engine change, not a second recognizer: nothing extra is downloaded, no wire field changes, and with the variables unset the sidecar behaves exactly as the native build does.

`CoreMLEncoderSet` in `ASRSidecarCore` reads three optional environment variables, one per fixed-shape tier: `VOICEOUR_COREML_ENCODER_TINY` (audio up to 6 s), `VOICEOUR_COREML_ENCODER_SHORT` (up to 8 s), and `VOICEOUR_COREML_ENCODER` (up to 15 s). Each names one `.mlmodelc` or `.mlpackage`. `VOICEOUR_COREML_TINY_MAX_S`, `VOICEOUR_COREML_SHORT_MAX_S`, and `VOICEOUR_COREML_MAX_S` lower a tier's bound below the shape its model was compiled for and are rejected if they try to raise it. The shortest configured tier that covers the utterance takes it; audio longer than every configured tier, and every utterance when none is set, decodes natively.

`VOICEOUR_TAIL_BACKEND=cpu` additionally routes the TDT prediction/joint tail to the CPU/Accelerate backends with CPU-side decode buffers, so with a CoreML encoder configured the GPU stays idle for the whole decode; unset or `default` keeps the Metal tail, and any other value fails sidecar startup closed.

`VOICEOUR_TAIL_QUANT=q8_0` requires the CPU tail and repacks its seven two-dimensional
f16 matmul weight records (the prediction LSTM's input/hidden matrices and the three
joint linears; the embedding stays f16) to q8_0 while loading. The artifact on disk is
untouched — every pin and digest check still holds — and the quantized image is cached
in a separate `.tail-q8` weight arena, so warm loads skip the conversion. A requested
repack that converts no record fails the load rather than silently measuring the f16
tail. Unset or `default` keeps the f16 tail; any other value, or `q8_0` without
`VOICEOUR_TAIL_BACKEND=cpu`, fails sidecar startup closed. Like the encoder path, this
changes tail numerics on a small number of rows and is a measured non-inferiority
trade: development evidence, including a 5,159-row held-out real-speech
non-inferiority and determinism evaluation, is recorded in
`research/bet3-quantization.md`.

Startup is fail-closed. Every configured path is resolved and validated while the backend is constructed, so a missing artifact, a path that is neither `.mlmodelc` nor `.mlpackage`, or an out-of-range bound fails the sidecar's start rather than quietly reverting to Metal. Loading is separately lazy: each tier's `MLModel` is built on the first utterance that routes to it, so a configured tier that never matches costs nothing at startup, and a load or prediction failure fails that request instead of being retried on another engine.

The path is not byte-identical to the native encoder. It is deterministic — the same audio through the same artifacts produces the same bytes across passes and across processes — but its encoder numerics differ from the Metal kernels on a small number of rows, so it is a measured non-inferiority trade, not a drop-in equivalence. Everything known about it is development evidence from one M4 Pro over synthetic corpora, recorded in `research/bet2-ane-encoder.md`. The compiled encoder artifacts are large and are not distributed with the app, which is why the path stays behind environment variables and why the app itself never sets them.

## Cleanup and glossary

Three deterministic stages run after ASR and nothing else does. `LiteralComposition` resolves the spoken spelling and literal commands. `CleanupEngine` performs configured filler removal plus glossary canonicalization, in one pass over the transcript. `VocabularyRepairEngine` then repairs close phonetic mishearings of glossary terms. The cleanup setting gates the second and third together; all three are pure functions of the transcript and the glossary snapshot compiled at the top of the stop path — the capture target names the label, never the vocabulary — and every way of adding a term passes through `VocabularySanitizer`, which rejects an ambiguous alias instead of guessing.

Repair only ever moves the transcript toward a term the user taught. It scores token windows of up to five words against the active canonicals at a phonetic threshold of 0.95, frozen because lowering it needs new safety evidence rather than a better result, and accepts a rewrite only on a span nothing else claimed: exact alias matches resolve first and longest, then the highest-scoring phonetic candidates take what is left. Two rules keep it from inventing corrections. A canonical that is itself an ordinary English word, or is at most two characters, is never a phonetic target and its occurrences are protected spans: `Rust` still lands wherever the glossary rule matches that word, but repair will not conjure it out of a span that merely sounds like it. And a candidate whose every token is an ordinary word is rejected outright — the guard that stops `I am` from becoming `IAM` — with single letters ordinary only for `a` and `i`. That word list is a baked resource, `Sources/VoiceCore/Resources/ordinary-words.txt`, which `scripts/bundle.sh` copies into the app as `Contents/Resources/voiceour_VoiceCore.bundle` and refuses to build without. The engine is rebuilt only when the active canonical set changes. The sidecar's own transcript is untouched by any of this: repair is a text stage in the app, and `voiceour-bench pipeline` applies it only when passed `--vocabulary`.

`WordListImporter` is the bulk path into that vocabulary. It reads a JSON array of spellings, a JSON array of `{"term": ..., "heard_as": [...]}` rows, or a newline-delimited list, and returns unprotected `manualImport` terms. The row shape carries the surfaces a model actually produces, which is what a spelling cannot: `derivedAliases` recovers `Swift UI` from `SwiftUI` for free, but nothing derives `Qbectal` from `kubectl`. Spellings and heard-as forms pass the same filters — `VocabularySanitizer.isSafe`, the length cap, case-insensitive de-duplication — and the coordinator validates the whole merged glossary for ambiguity before accepting any of it, so a colliding file is refused rather than partially applied.

## Insertion safety

`InsertionSafetyPolicy` is fail-closed: only a target classified as normal text may receive a synthetic Cmd-V; terminal, code-editor, secure, and unknown targets are clipboard-only. The inserter re-checks target identity before the pasteboard write and again before the keystroke, so a focus race only degrades to copy-only. [permissions.md](permissions.md) owns the target-safety matrix.

## Persistence

Transcripts live in one file, `recent-sessions.json`, newest first, capped at the newest 500. Lifetime totals need a second file, `dictation-activity.json`, because at that cap each new dictation evicts an older one: `DictationStatsLedger` holds aggregates only — sessions, words, seconds, active days, streaks, one bucket per local day and per destination app — and no transcript text or session ids. Settings, transcript, and ledger writes share one detached FIFO tail, keeping write order intact and file I/O off the main actor. A delivered dictation folds both records in one main-actor turn, from the journaled row itself, and only then enqueues the two writes: neither record is ever observable without the other, which matters because Home reads them together and the first-run card retires on either one. An unreadable file is quarantined as `<name>.corrupt-<ISO8601>`, and the reader sees that filename. No audio is retained.

## Console window

`Window("Voiceour", id: "main")` hosts `ConsoleWindowView`, a `TabView` with four tabs.

- Home — lifetime figures, top destination apps, streaks, an activity grid, and the first-run card described below.
- Glossary — learned suggestions, a searchable term list with one term open in its own plate, word-list import.
- History — search, an app filter, day-grouped transcripts, and one open transcript.
- Settings — tap gesture, auto-stop, cleanup, muting, session sounds, the speech-model footprint choice, the debug-only backend picker, then backend and model readiness, permissions, diagnostics, and clear actions.

Preferences lead that last tab and readouts follow it. There is no General tab: a switch and the permission that decides whether the switch can take effect were on two different destinations.

An install that has never completed a dictation opens this window at launch, on Home, and Home carries a first-run card above its figures. A menu-bar app's whole first-run surface is otherwise one status glyph, which cannot state the tap gesture, cannot show that a 1.26 GB model download is running, and cannot say which permissions matter — microphone required and prompted at the first dictation, Accessibility optional and worth the paste rather than a clipboard copy. The card reports those three states through `ConsoleReadiness`, the same values and the same sentences the Settings tab's readiness rows use, and offers the same remediation buttons. It retires at the first dictation that produced a transcript and reached delivery, which is also when the figures beneath it start saying something.

Whether the card is owed is `DictationPolicy.owesFirstRunGuidance`: `Settings.hasCompletedFirstRun` is the app's own record, written once from the stop pipeline, and both durable records — the transcript journal and the lifetime ledger — must additionally be empty. Reading the records is what stops an install that predates the flag from being handed onboarding: an absent key decodes to `false`, because a key that was never written is no evidence a dictation happened, and an install that has dictated has at least one record to prove it did. The flag is set one line outside the branch that writes those records, so a secure delivery target — which reaches neither — retires the card exactly like a journalled one. A refused start, a cancel, and a failed decode never reach that line.

`ConsolePresentation` owns showing that window, and every path goes through it: the menu bar item, the `--show-console` launch notification, `applicationShouldHandleReopen` (a Dock-icon click, `open -a`, a second launch of the bundle), and the window's own `onAppear`. It promotes the process to `.regular` while the console is hosted, drops back to `.accessory` when it closes, and orders the window front and deminiaturizes it on every show.

It also takes two states away from that window, because a menu-bar app cannot recover from either. The window is not miniaturizable: a minimized window is clicked back from a Dock tile, and this app's tile exists only while the console is open, so minimizing and then closing — or changing displays, or quitting — could leave the window parked with nothing left to click. And it is not restorable: AppKit's window restoration carried that parked state across a quit into an `.accessory` launch, which began owning a window that had no surface, no accessibility attributes, and no way to be shown. Frame persistence is unaffected: that is `setFrameAutosaveName`, whose `NSWindow Frame main` entry is written and read independently, so the console still opens where it was left.

[design-bible.md](design-bible.md) owns the visual language.

## No credentials

Voiceour stores no secret: no account, no credential field, no keychain item. `Resources/Voiceour.entitlements` requests audio input only and `scripts/bundle.sh` embeds no provisioning profile, so the data-protection keychain is unavailable to this bundle.
