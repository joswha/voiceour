# Changelog

Notable user-visible changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

There are no tagged releases yet, so `Unreleased` is the state of `main` and the starting point every later entry is written against.

Cutting a release moves the `Unreleased` bullets beneath a new version heading — `## <version>`, or `## [<version>] - <date>` — and leaves `Unreleased` empty above them. The version is `CFBundleShortVersionString` in `Resources/Info.plist`, the only place a version is written down, and the git tag is `v<version>`. That section is the release notes: `scripts/release.sh` extracts it verbatim and the published release carries it unedited, so it cannot be cut while the heading is missing or the section is empty. [AGENTS.md](AGENTS.md#release-procedure) holds the procedure.

## Unreleased

### Added

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
