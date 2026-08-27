# Changelog

Notable user-visible changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

There are no tagged releases yet, so `Unreleased` is the state of `main` and the starting point every later entry is written against.

Cutting a release moves the `Unreleased` bullets beneath a new version heading — `## <version>`, or `## [<version>] - <date>` — and leaves `Unreleased` empty above them. The version is `CFBundleShortVersionString` in `Resources/Info.plist`, the only place a version is written down, and the git tag is `v<version>`. That section is the release notes: `scripts/release.sh` extracts it verbatim and the published release carries it unedited, so it cannot be cut while the heading is missing or the section is empty. [AGENTS.md](AGENTS.md#release-procedure) holds the procedure.

## Unreleased

### Added

- **Word lists can carry heard-as forms.** Glossary import accepts a JSON array of `{"term": ..., "heard_as": [...]}` rows alongside the array-of-spellings and newline shapes it already took. A spelling alone repairs only what `derivedAliases` covers — `Swift UI` from `SwiftUI` — and nothing derives `Qbectal` from `kubectl`, so the surfaces a model actually produces now have a way in. Imported forms are filtered, deduplicated case-insensitively against each other and the spelling, and capped per term.

### Changed

- **Listening meter.** The recording island's eleven bars rest at 8 pt so an open microphone is a visible row, and they rise only after voice activity holds — two samples to start, seven to stop — instead of twitching on room noise.
- **Working mark.** While the island is processing, three dots hand emphasis right to left. The random-emoji comet is gone.
- **Unclean delivery.** Copy-only, a failed paste, and an error hold for a moment with a symbol and a word; a clean paste and a cancel still dismiss at once.

### Fixed

- **Rectangular halo around the recording island.** The island no longer stacks app-drawn black drop shadows on top of system glass. Those shadows cannot follow a capsule glass effect, so Core Animation was casting them from the rectangular layer bounds. Liquid Glass already supplies its own adaptive shadow.
- **Washed-out island on a light desktop.** On macOS 26 system glass, labels and glyphs use `.primary`/`.secondary` and meaning-bearing hues use a mid-tone `OnGlass` palette measured to stay readable on both light and dark glass. The pastel `Signal` and `Text` colours remain on the near-black grounds.

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
