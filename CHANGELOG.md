# Changelog

Notable user-visible changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Released versions are immutable; Unreleased is the state of main since the latest tag.

Cutting a release moves the `Unreleased` bullets beneath a new version heading — `## <version>`, or `## [<version>] - <date>` — and leaves `Unreleased` empty above them. The version is `CFBundleShortVersionString` in `Resources/Info.plist`, the only place a version is written down, and the git tag is `v<version>`. That section is the release notes: `scripts/release.sh` extracts it verbatim and the published release carries it unedited, so it cannot be cut while the heading is missing or the section is empty. [AGENTS.md](AGENTS.md#release-procedure) holds the procedure.

## Unreleased

## [0.3.0] - 2026-09-02

### Added

- **Glossary phonetic repair.** Terms taught in the Glossary now correct close phonetic mishearings as well as spelling and spacing variants. Matching remains deterministic and local, protects ordinary words and ambiguous surfaces, and applies exactly once before delivery.

## [0.2.1] - 2026-08-30

### Changed

- **Faster local transcription.** The native Parakeet path reuses encoder scheduler reservations, removes redundant Metal copies and transforms, avoids pathological pointwise-convolution dispatch, and merges prediction with the following joint step. On the frozen M4 Pro corpus, ASR p95 moved from about 282 ms to 206–209 ms and p50 from about 171 ms to 125–128 ms, with byte-identical transcripts on all 500 promotion rows.
- **Far lower runtime memory.** Verified model weights now warm from a read-only file-backed arena. Peak physical footprint moved from about 1.46 GB to 178 MB and RSS from about 1.39 GB to 113 MB. First load creates a second, model-sized local acceleration file, so total cache use is about 2.51 GB for Balanced or 1.34 GB for Compact.

### Fixed

- **Safe acceleration-cache creation.** Arena creation is locked, atomic and fsynced, validates the exact source pin and tensor layout, physically reserves its bytes before mapping, and falls back to ordinary model buffers on stale state, disk pressure or any cache failure instead of risking a sparse-file `SIGBUS`.

## [0.2.0] - 2026-08-29

### Added

- **Word lists can carry heard-as forms.** Glossary import accepts a JSON array of `{"term": ..., "heard_as": [...]}` rows alongside the array-of-spellings and newline shapes it already took. A spelling alone repairs only what `derivedAliases` covers — `Swift UI` from `SwiftUI` — and nothing derives `Qbectal` from `kubectl`, so the surfaces a model actually produces now have a way in. Imported forms are filtered, deduplicated case-insensitively against each other and the spelling, and capped per term.
- **Microphone selection.** Settings' Audio section offers the connected input devices by name, or Automatic. A chosen microphone is used whenever it is connected and applies from the next recording; while it is unplugged the row says NOT CONNECTED and Automatic takes over — the system default input, except that a Bluetooth headset default is redirected to a working built-in microphone, whose first second would otherwise be lost to Bluetooth negotiation.

### Changed

- **Mercury recording island.** The capsule, control discs, waveform, working dots and painted outcome words are replaced by one borderless procedural mercury body. Listening, speaking, processing and unclean outcomes are distinct organic poses; Finish and Cancel remain available as named VoiceOver actions on the stable status element.
- **Polished chrome material.** A full half-elliptic crown makes the whole body reflective instead of a flat lozenge with a bevel. Each session reflects one fixed generated RGB room through exact liquid-mercury Fresnel, with bounded source intensity and subtle neutral-mean room colour. A two-anchor response preserves real black and bright chrome bands while making plain-white collapse mathematically unreachable.
- **Display-synchronized mercury.** The recording body now presents on the actual display's vertical-sync clock — 120 fps on ProMotion and the native rate on lower-refresh screens, capped at 120 — instead of holding each CPU raster for 33 milliseconds. Process-built optical tables and a seam-safe octahedral room map keep the complete 120 Hz simulation-and-raster path below 8% of one M-series core without flattening the polished chrome.
- **One way to build and run.** `make` prints the target catalogue; `make run` builds and launches the real app, `make dev` runs the fake backend in the terminal, `make check` is the whole portable gate, and `make stop`, `make status`, `make logs` and `make signing` cover the rest of a development session. `scripts/run_real.sh`, `scripts/restart_real.sh` and `scripts/run_dev.sh` are gone. `make run` stops the running instance before it launches, which is a fix rather than a courtesy: the app terminates a second instance of itself, so launching a freshly built bundle over a live one made the *new* process quit and left the previous build running. It also re-bundles only when `Package.swift`, `scripts/bundle.sh`, `Sources/`, `Resources/` or `Vendor/` moved, so relaunching an unchanged bundle is the same command at about a quarter of a second, and it forwards `VOICEOUR_ASR_BACKEND`, `VOICEOUR_MODEL_VARIANT` and `VOICEOUR_SUPPORT_DIR` out of a root `.env` explicitly with `open --env`, instead of relying on whether a given macOS propagates the shell's environment through LaunchServices. `make check-docs` now also asserts that every command the live docs name is a real make target or an existing script.

### Fixed

- **Mechanical highlight sweep.** Generated rooms no longer rotate or change intensity under the body. All visible motion now comes from the autonomous and voice-driven surface modes, so highlights deform and travel with the organism.
- **Seed-dependent white-out.** The room distribution is bounded and benchmarked over 4,096 deterministic seeds. Its display response maps median and highlight anchors independently and has a strict 0.94 linear-light ceiling; sustained speech cannot saturate the island.

## [0.1.0] - 2026-08-26

First public release.

### Added

- **First-run guidance.** An install that has never completed a dictation opens the console on Home at launch, where a card states the whole gesture — tap Fn or Globe, speak, tap again — the speech model's live download or failure, and which permissions matter: microphone required, Accessibility optional and the difference between a paste and a clipboard copy. It retires itself at the first delivered dictation, including one into a secure field, and an install that has already dictated never sees it.
- **Tap-to-dictate.** One solitary Fn/Globe tap starts one utterance; a second tap, the overlay's finish control, Escape, or auto-stop ends it. Stop finalizes one WAV and performs one decode. Modified Fn combinations pass through untouched.
- **Local recognition.** A single `voiceour-asr` sidecar decodes on-device through vendored parakeet.cpp/ggml on Metal and Accelerate, using the pinned `ggml-org/parakeet-GGUF` weights. English only.
- **Two model footprints.** Settings offers Balanced (1.26 GB) and Compact (0.67 GB) conversions of the same checkpoint. The selection applies on the next launch, and only one artifact is ever resident.
- **Deterministic text cleanup.** Configured filler removal plus glossary canonicalization, one pass, applied exactly once after recognition. Nothing rewrites the transcript with a model.
- **Glossary.** A searchable term list, learned suggestions that only an explicit action accepts, word-list import, and ⌘T teaching from a History transcript. A term is active everywhere; ambiguous aliases are rejected rather than guessed.
- **Fail-closed delivery.** Ordinary text fields receive a clipboard write plus a synthetic Cmd-V. Terminals, code editors, secure fields, and targets that could not be inspected are copy-only, with no setting that widens it; secure delivery is concealed and records no history. Target identity is re-checked before the write and again before the keystroke, and the previous clipboard is never read, saved, or restored.
- **Recording overlay.** A live waveform with cancel and finish, following the focused target's display, with manual placement stored relative to a display.
- **Console window.** Four native tabs: Home's lifetime figures, top destination apps, streaks and activity grid; Glossary; History with search, an app filter, day grouping, one open transcript and click-to-copy; and Settings for the tap gesture, auto-stop, cleanup, system-audio muting, session sounds, model footprint, readiness, permissions, and diagnostics.
- **Bounded local persistence.** The newest 500 transcripts in one file, aggregate counts in a second, no audio ever retained, and an unreadable file quarantined as `<name>.corrupt-<ISO8601>` with the reset reported.
- **System audio muting.** Optional muting of the recorded device's output for the duration of a session, with durable ownership so a restore survives a launch.
- **Accessibility adaptations.** VoiceOver labels and actions throughout, plus Reduce Transparency, Reduce Motion, Increase Contrast, and Differentiate Without Color treatments.
- **No network surface beyond the model.** No account, telemetry, crash reporting, analytics, update check, credential store, or local control socket. Acquiring the pinned weights, digest-verified, is the only request the app makes.
- **Apple Silicon only.** Published binaries run on Apple Silicon (arm64); release pages and notes identify that requirement.
- **Repeatable measurement.** An offscreen UI harness with committed accessibility, raster-digest and semantic-flow goldens; a `voiceour-bench` production-path runner; and a non-shipping Python benchmark package with LibriSpeech, FLEURS, technical-term, and noise tiers.
- **Licence notices travel with the binary.** `Contents/Resources/THIRD-PARTY-LICENSES.txt` carries the vendored parakeet.cpp/ggml MIT text verbatim, read from `Vendor/parakeet/LICENSE` at bundle time rather than restated, with every further copyright holder in that tree swept out of the sources that compile, plus the CC BY 4.0 terms of the weights the app downloads. The signature seals it and `make verify-bundle` fails without it.
- **Corpus attribution.** `benchmarks/DATA-LICENSE.md` names the LibriSpeech and FLEURS creators, titles, licence, warranty disclaimer and prior modifications, and states exactly which committed reports and JSON keys hold CC BY 4.0 transcript text. Repository code stays MIT; that text is not covered by it.
- **Distribution linting.** `scripts/sign_notarize.sh` refuses to publish a stapled bundle that Apple's own `syspolicy_check distribution` rejects. `make verify-bundle` reports the same findings on a local build without failing it, because an ad-hoc identity and a missing notary ticket are expected there.
- **Stated project terms.** `LICENSE` names its copyright holder. The README says who maintains the project and which contributions are welcome, and answers why the build is Apple Silicon only, what the single network request discloses, and how to reset a stuck permission.
