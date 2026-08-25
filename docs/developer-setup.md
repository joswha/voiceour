# Developer setup

## Prerequisites

- macOS 14 or newer.
- A Swift 6 toolchain: Xcode 16 or newer, or just its Command Line Tools. `swift format` ships inside it, so `make format` installs nothing.
- [`uv`](https://docs.astral.sh/uv/) for the Python benchmark package under `bench/`.

## Run it

```sh
scripts/run_dev.sh --self-test
scripts/run_dev.sh
```

This builds and launches the debug app on the fake backend: synthetic audio, no microphone permission, no model download.

## Run the real app

```sh
scripts/run_real.sh
```

This builds `.build/Voiceour.app` and launches the real backend, so macOS attributes permission grants to the bundle. The first launch downloads the selected artifact of the pinned model — `ggml-org/parakeet-GGUF`, revision `35156454d1a39de06863303dd209fd2bed6ee079`, file `ggml-parakeet-tdt-0.6b-v3-f16.bin` unless Settings or the environment asks for Compact — and shows progress in the menu. Dictation works offline once that cache exists.

Nothing built here is notarized. `scripts/bundle.sh` signs with the ad-hoc `-` identity unless `VOICEOUR_CODESIGN_IDENTITY` is set or a local `voiceour-dev` keychain exists, and it says so on stderr. Two consequences follow. TCC keys grants to a code identity, and an ad-hoc identity can change on rebuild, so Microphone and Accessibility may be asked for again; `scripts/setup_local_signing.sh` installs a stable self-signed `voiceour-dev` certificate that `bundle.sh` then picks up on its own, which is worth doing before any repeated permission testing. And a bundle built and launched in place carries no quarantine flag, so it opens normally — but the same `.app` copied off this machine does, and Gatekeeper will refuse an unnotarized copy until it is opened explicitly from Finder's context menu or allowed under Privacy & Security. `scripts/sign_notarize.sh` is the separate Developer ID path.

Relaunch an existing bundle without rebuilding:

```sh
scripts/restart_real.sh
```

Check the cached model against the committed fixture:

```sh
swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav
```

## Checks

`make build` compiles with warnings as errors and `make test` runs the fake-backed suite; `make format-check`, `make check-docs` and `make lint-python` are the other portable gates, and `make ui-flow` is the one a UI change always needs. [AGENTS.md](../AGENTS.md#developer-commands) holds the complete command matrix, and [CONTRIBUTING.md](../CONTRIBUTING.md) the order to run them in before a PR.

Bless golden changes with `make ui-update` or `make ui-flow-update` only after reading the generated `.ax.diff` or `.flow.diff`. See [`ui-harness.md`](ui-harness.md).

Two suites skip without their flag: `VOICEOUR_PARAKEET_INTEGRATION=1 swift test` needs the model cache; `VOICEOUR_CAPTURE_INTEGRATION=1 swift test` opens the microphone. Manual permission and insertion checks live in [`permissions.md`](permissions.md). Benchmark tiers and commands live in [`benchmarks.md`](benchmarks.md).

Three environment seams pin one run instead of persisting a choice. `VOICEOUR_MODEL_VARIANT=f16|q8_0` picks the speech-model artifact, outranks the Settings selection for that launch, and degrades to `f16` on an unrecognized value; the app writes the resolved value into the sidecar's launch environment, so the helper never acts on a stale inherited one. `VOICEOUR_MODEL_CACHE` points the model cache at one explicit directory — how a cold download is exercised — and that directory is neither per-variant nor pruned. `VOICEOUR_ASR_BACKEND` selects a registered backend.

`scripts/console_shot.sh <tab> <output.png>` captures a real onscreen console window and needs Screen Recording permission.

## Ship it

- `make bundle` assembles `.build/Voiceour.app` and its signed `voiceour-asr` sibling.
- `make verify-bundle` checks bundle shape, identifiers, entitlements, and signatures.
- `scripts/setup_local_signing.sh` creates a stable local certificate so permission grants survive rebuilds. Do not commit its output.
- `scripts/sign_notarize.sh` signs with the Developer ID, submits to `notarytool`, staples, and validates.

## Scripts

| script | purpose |
| --- | --- |
| `run_dev.sh` | Build and launch the fake app. |
| `run_real.sh` | Rebuild and launch the real backend. |
| `restart_real.sh` | Relaunch the existing bundle. |
| `bundle.sh` | Assemble the app bundle and its helper. |
| `verify_bundle.sh` | Verify bundle contents, identity, and signatures. |
| `setup_local_signing.sh` | Create local signing configuration. |
| `sign_notarize.sh` | Developer-ID signing and notarization. |
| `ui_harness.sh` | Run offscreen scenes and flows. |
| `console_shot.sh` | Capture the onscreen console window. |
| `check_docs.sh` | Check docs against the model contract. |
| `vendor_parakeet.sh` | Check vendored sources or refresh them. |
| `make_fixture.sh` | Regenerate the committed audio fixture. |
| `make_icon.sh` | Regenerate the committed app icon. |
