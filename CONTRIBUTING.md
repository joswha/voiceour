# Contributing

Production Voiceour defaults to real local Parakeet. Development remains fake-first: a contributor must be able to build, test, run semantic UI flows, and smoke the app without downloading the model or granting TCC permissions.

## Required local checks

Run the same portable checks as CI:

```sh
make build
make format-check
make check-docs
make lint-python
make test
make ui-flow
(cd bench && uv --no-config run pytest)
scripts/run_dev.sh --self-test
make bench-smoke
```

CI also asserts that no local control socket/client has appeared. A release job separately runs:

```sh
swift build -c release
scripts/bundle.sh
scripts/verify_bundle.sh
```

The hosted `ui-snapshots` job is advisory until raster/AX portability has been demonstrated across runners. Run `make ui-snap` locally for UI work and inspect the artifacts.

## Check tiers

- **Required PR gate:** the portable block above plus CI's no-control-plane assertion.
- **Scene review:** `make ui-snap`; read `.build/ui-harness/<scene>.ax.diff` and the contact sheet before `make ui-update`.
- **Semantic UI gate:** `make ui-flow`; read `.build/ui-harness/flows/<flow>.flow.diff` before `make ui-flow-update`.
- **Native macOS 26 UI:** `make ui-snap-os26` and `make ui-flow-os26` on a supported host. These verify app-owned drawing and semantics, not system material.
- **Real ASR:** `VOICEOUR_PARAKEET_INTEGRATION=1 swift test` and `swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav` with the model cache present.
- **Physical microphone:** `VOICEOUR_CAPTURE_INTEGRATION=1 swift test`; serialized because it opens the real input device.
- **Manual insertion:** follow [`docs/permissions.md`](docs/permissions.md).
- **Release:** test the signed/notarized bundle on a clean macOS account, including one eligible paste target, one risky copy-only target, and a secure target that creates no History row.

Use `make ui-all` for the complete local scene/flow gate; it includes the native legs when the host is macOS 26 or newer.

## Coding rules

- Keep `VoiceCore` Foundation-only. AppKit, SwiftUI, AVFoundation, Accessibility, CoreGraphics event posting, pasteboard, process launch, and Keychain APIs belong outside it.
- Put macOS side effects in `VoiceMac` behind narrow contracts consumed by the app layer.
- Keep `Voiceour` focused on UI and orchestration. `DictationCoordinator` remains `@MainActor` for observable state.
- Keep stdout from `voiceour-asr` protocol-only; logs go to stderr.
- Change Swift wire types, sidecar parsing/encoding, client validation, and `fixtures/protocol/` together.
- Remove temporary audio on success, cancellation, and error. Never persist session audio.
- Never read, save, or restore the user's previous clipboard.
- Only verified normal text may receive Cmd-V. Terminal, code-editor, secure, and unknown-risky targets are copy-only.
- Secure delivery is concealed copy-only and never journaled.
- Keep glossary canonicalization one-pass and deterministic. Reject ambiguous aliases at every explicit vocabulary entry point.
- Preserve the fake audio/ASR path for deterministic development; do not make it the production default.
- The pinned model download is the only network path and `voiceour-asr` is the only child process.

## ASR protocol rules

- Protocol version is 1 on every frame, not only `hello`.
- Accepted request types are `health`, `transcribe`, and `cancel`.
- Every decode request receives exactly one terminal `result`, `error`, or `cancelled`.
- Stdout is NDJSON only. Stderr must remain drainable under flood.
- The client owns one persistent child and must recover from timeout, exit, malformed frames, and a later successful model load.
- Model construction is serialized. Do not concurrently create/free Parakeet contexts around the shared Metal device.
- Darwin shutdown must stay bounded; never follow a bounded wait with unbounded `waitUntilExit()`.

## Model and vendor rules

The production pin is `ggml-org/parakeet-GGUF` revision `35156454d1a39de06863303dd209fd2bed6ee079`, file `ggml-parakeet-tdt-0.6b-v3-f16.bin`.

- Move model id, revision, file, digest, size, docs, fixtures, and tests as one compatibility change.
- Keep the cache manifest equal to the compiled pin and the on-disk size equal to the pinned size.
- Vendor parakeet.cpp/ggml only through the controlled vendor workflow. Mark local upstream-file edits with `VOICEOUR PATCH` and record them in `Vendor/parakeet/NOTICE.md`.
- Run `scripts/vendor_parakeet.sh --check`; unexpected files and a non-reproducible embedded Metal source are failures.
- Do not add `-mcpu=native`; a copyable app cannot inherit the build host's CPU baseline.

## Vocabulary rules

- Automatic cleanup may preserve/canonicalize known terms but must never silently learn one.
- Only explicit user actions — Fix/Teach, add, suggestion accept, import, or clear — may alter confirmed/tombstoned vocabulary.
- Aliases are case-insensitively unambiguous across every canonical and alias. Reject a collision instead of relying on storage order.
- Resolve matches against the original string, longest first and then leftmost, and apply accepted replacements right-to-left.
- Escape canonicals as regex replacement templates.
- Keep the per-utterance vocabulary snapshot bounded and selected from the captured target. Ephemeral candidates remain in memory.

## Persistence rules

- History is only `recent-sessions.json`, newest 500, serialized through the journal FIFO.
- Settings writes use the same persistence tail so file I/O stays ordered and off the main actor.
- Unreadable settings/history are quarantined as `<name>.corrupt-<ISO8601>` before defaults are used; report the reset.
- Do not suppress a save failure. Surface it through the coordinator.
- Destructive UI actions complete only after their exact snapshot is durable.

## UI rules

- The console is a native four-tab `TabView` of grouped Forms. Start with native controls and confirmation dialogs; do not add custom window/navigation chrome.
- The bespoke visual system is limited to the menu popover and recording overlay.
- Every new visible static state needs an appropriate `UISceneCatalog` scene; every new interaction journey needs a semantic `UIFlow`.
- `RenderOverrides` may provide values only at existing production boundaries. Every normal read remains `override ?? realValue`, with false/nil production defaults.
- The offscreen harness never verifies system material. Use a live or onscreen screenshot check when glass itself changed.

## Dependency notes

Voiceour uses an active `.cgSessionEventTap` for Fn/Globe and Escape. It toggles on a solitary tap, preserves modified combinations, consumes the Globe assigned-action event when trusted, and falls back to a passive monitor without Accessibility. The router is recreated whenever the tap is rebuilt.

The Swift Testing package is pinned by revision. Do not update dependencies, the vendored runtime, or the model pin as incidental cleanup.

## Pull requests

Keep changes narrow and declarative:

1. Explain the observable contract and why it changes.
2. Name the smallest verification that proves it.
3. Include intended UI golden/journal changes only after reading their diffs.
4. Include benchmark provenance and complete row-id equality for performance/accuracy claims.
5. Update the closest current document; put superseded design history under `docs/archive/` rather than leaving it in live guidance.
