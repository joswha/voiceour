# Developer setup

## Prerequisites

- macOS 14 or newer.
- Xcode Command Line Tools or Xcode with SwiftPM.
- [`uv`](https://docs.astral.sh/uv/) for the Python benchmark package under `bench/`.
- `git-lfs` for benchmark datasets stored through LFS.

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

This builds `.build/Voiceour.app` and launches the real backend, so macOS attributes permission grants to the bundle. The first launch downloads the pinned model — `ggml-org/parakeet-GGUF`, revision `35156454d1a39de06863303dd209fd2bed6ee079`, file `ggml-parakeet-tdt-0.6b-v3-f16.bin` — and shows progress in the menu. Dictation works offline once that cache exists.

Relaunch an existing bundle without rebuilding:

```sh
scripts/restart_real.sh
```

Check the cached model against the committed fixture:

```sh
swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav
```

## Checks

| command | purpose |
| --- | --- |
| `make build` | Compile with warnings as errors. |
| `make test` | Run the fake-backed suite. |
| `make format` | Format `Sources` and `Tests`. |
| `make format-check` | Fail on unformatted Swift. |
| `make check-docs` | Fail when docs drift from the model contract. |
| `make lint-python` | Lint the `bench/` package. |
| `make ui-snap` | Check offscreen scenes against their goldens. |
| `make ui-flow` | Check journeys against flow goldens. |
| `make ui-all` | Add the native macOS 26 legs when supported. |

Bless golden changes with `make ui-update` or `make ui-flow-update` only after reading the generated `.ax.diff` or `.flow.diff`. See [`ui-harness.md`](ui-harness.md).

Two suites skip without their flag: `VOICEOUR_PARAKEET_INTEGRATION=1 swift test` needs the model cache; `VOICEOUR_CAPTURE_INTEGRATION=1 swift test` opens the microphone. Manual permission and insertion checks live in [`permissions.md`](permissions.md). Benchmark tiers and commands live in [`benchmarks.md`](benchmarks.md).

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
