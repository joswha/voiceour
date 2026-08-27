# Developer setup

The Makefile is the interface. `make` prints the target catalogue.

## Prerequisites

- macOS 14 or newer.
- A Swift 6 toolchain: Xcode 16 or newer, or just its Command Line Tools. `swift format` ships inside it, so `make format` installs nothing.
- An Apple Silicon Mac (arm64). Intel Macs are not supported: the vendored parakeet.cpp/ggml drop intentionally omits the x86 architecture sources, and `ggml-metal-embed.c` rejects x86_64 at compile time. This is deliberate, not merely untested.
- [`uv`](https://docs.astral.sh/uv/) for the Python benchmark package under `bench/`.

## Run it

```sh
make self-test
make dev
```

`make self-test` is the deterministic launch-path check. `make dev` builds and launches the debug app on the fake backend: synthetic audio, no microphone permission, no model download.

## Run the real app

```sh
make run
```

This builds `.build/Voiceour.app` and launches the real backend, so macOS attributes permission grants to the bundle. The first launch downloads the selected artifact of the pinned model — `ggml-org/parakeet-GGUF`, revision `35156454d1a39de06863303dd209fd2bed6ee079`, file `ggml-parakeet-tdt-0.6b-v3-f16.bin` unless Settings or the environment asks for Compact — and shows progress in the menu. Dictation works offline once that cache exists.

Nothing built here is notarized. `scripts/bundle.sh` signs with the ad-hoc `-` identity unless `VOICEOUR_CODESIGN_IDENTITY` is set or a local `voiceour-dev` keychain exists, and it says so on stderr. Two consequences follow. TCC keys grants to a code identity, and an ad-hoc identity can change on rebuild, so Microphone and Accessibility may be asked for again; `make signing` installs a stable self-signed `voiceour-dev` certificate that `bundle.sh` then picks up on its own, which is worth doing before any repeated permission testing. And a bundle built and launched in place carries no quarantine flag, so it opens normally — but the same `.app` copied off this machine does, and Gatekeeper will refuse an unnotarized copy until it is opened explicitly from Finder's context menu or allowed under Privacy & Security. That is why only the Developer ID path under [Ship it](#ship-it) produces a bundle fit to hand to anyone else.

`make run` re-bundles only when `Package.swift`, `scripts/bundle.sh`, `Sources/`, `Resources/` or `Vendor/` moved, so relaunching an unchanged bundle is the same command and costs about a quarter of a second. It stops the running instance before launching, because the app terminates a second instance of itself and the freshly built one would otherwise be the process that quits.

```sh
make status
make stop
make logs
```

`make status` reports the process (a pid, or not running), whether the bundle is current or stale, and which identity signed it. `make stop` quits every running Voiceour, bundled or debug, and is silent when none is running. `make logs` streams the unified log filtered to subsystem `com.voiceour.app`; `hotkey` is the only category the app logs today, and the stop-path signposts need xctrace instead.

Launch flags go through `ARGS`: `make run ARGS="--debug --show-console"`, and the same form works for `make dev`. A `.env` at the repo root is sourced by `make run` and `make dev`. `make run` then forwards `VOICEOUR_ASR_BACKEND`, `VOICEOUR_MODEL_VARIANT` and `VOICEOUR_SUPPORT_DIR` explicitly with `open --env`, so what the app reads never depends on whether a given macOS propagates the shell's environment through LaunchServices. macOS 26 does; that is not a documented contract, and `open --env` is why it does not have to be one.

Check the cached model against the committed fixture:

```sh
make build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav
```

## Checks

`make check` is the whole portable gate in one command. It runs `build`, `format-check`, `check-docs`, `lint-python`, `test`, `ui-flow`, `test-python`, `self-test` and `bench-smoke` in that order.

The individual targets remain when a change only needs one of them: `make build` compiles with warnings as errors, `make test` runs the fake-backed Swift suite (harness suites included), `make format-check`, `make check-docs` and `make lint-python` are the other portable checks, `make test-python` is the bench package's pytest suite, `make self-test` is the launch-path check, `make bench-smoke` is the offline fake-backend smoke, and `make ui-flow` is the one a UI change always needs. [AGENTS.md](../AGENTS.md#developer-commands) holds the complete command matrix, and [CONTRIBUTING.md](../CONTRIBUTING.md) the order to run them in before a PR.

Bless golden changes with `make ui-update` or `make ui-flow-update` only after reading the generated `.ax.diff` or `.flow.diff`. See [`ui-harness.md`](ui-harness.md).

Two suites skip without their flag: `VOICEOUR_PARAKEET_INTEGRATION=1 swift test` needs the model cache; `VOICEOUR_CAPTURE_INTEGRATION=1 swift test` opens the microphone. Manual permission and insertion checks live in [`permissions.md`](permissions.md). Benchmark tiers and commands live in [`benchmarks.md`](benchmarks.md).

Three environment seams pin one run instead of persisting a choice. `VOICEOUR_MODEL_VARIANT=f16|q8_0` picks the speech-model artifact, outranks the Settings selection for that launch, and degrades to `f16` on an unrecognized value; the app writes the resolved value into the sidecar's launch environment, so the helper never acts on a stale inherited one. `VOICEOUR_MODEL_CACHE` points the model cache at one explicit directory — how a cold download is exercised — and that directory is neither per-variant nor pruned. `VOICEOUR_ASR_BACKEND` selects a registered backend.

`scripts/console_shot.sh <tab> <output.png>` captures a real onscreen console window and needs Screen Recording permission.

## Ship it

Bundle checks:

- `make bundle` assembles `.build/Voiceour.app` and its signed `voiceour-asr` sibling.
- `make verify-bundle` checks bundle shape, identifiers, entitlements, and signatures.
- `make signing` creates a stable local certificate so permission grants survive rebuilds. Do not commit its output.

Releases come in two kinds and `scripts/release.sh` runs both. `make release` is a source release: preflight, the local gate, the version's changelog section extracted to `.build/Voiceour-<version>-release-notes.md`, then the `git tag`, `git push` and `gh release create --notes-file` commands printed for you to run. It signs nothing and reads no Apple credentials, so it works on any checkout. GitHub attaches the source archives itself.

`scripts/release.sh --binary` is the same procedure plus the distributable app. It needs a Developer ID, and it adds `.build/Voiceour-<version>.zip`, `.build/Voiceour-<version>.zip.sha256` and `.build/Voiceour-release-manifest.txt` — the archive is named from `CFBundleShortVersionString` in `Resources/Info.plist`, and the sidecar is relative, so `shasum -a 256 -c Voiceour-<version>.zip.sha256` works from inside `.build`. The printed `gh release create` line attaches both files. There is deliberately no `make` target for this one.

Either mode takes `--dry-run`, in any argument order, which runs every check for that mode and stops before writing the notes file, signing anything, or printing the publish commands. Each failed check prints its own `release.sh: FAIL:` line and the script exits 1; expect the run to be slow, because the checks end in `make build`, `make format-check`, `make check-docs` and `make test`. Neither mode bumps the version, tags, pushes, or publishes.

The binary path alone needs credentials: `DEVELOPER_ID_APPLICATION` plus either `NOTARY_KEYCHAIN_PROFILE`, created once with `xcrun notarytool store-credentials`, or `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_SPECIFIC_PASSWORD`. Prefer the keychain profile: a password on a command line is visible in the process table. `scripts/sign_notarize.sh --check-env` reports what it found and exits without submitting anything; `make notarize` runs that signing, notarizing, stapling and archiving on its own, outside a release.

[AGENTS.md](../AGENTS.md#release-procedure) holds the release rules and the ordered steps, including the changelog section the preflight requires; this section is only the commands.

## Commands

| command | purpose |
| --- | --- |
| `make` | Print the target catalogue. |
| `make build` | Debug build, warnings as errors. |
| `make run` | Incremental real-app bundle, replace the running instance, launch. |
| `make dev` | Debug app on the fake backend, in this terminal. |
| `make self-test` | Launch-path check on the fake backend. |
| `make stop` | Quit every running Voiceour. |
| `make status` | Process, bundle currency, signing identity. |
| `make logs` | Unified log for `com.voiceour.app`. |
| `make signing` | Stable local `voiceour-dev` identity, once per machine. |
| `make check` | Whole portable gate, in order. |
| `make test` | Swift suites, harness suites included. |
| `make format` | Rewrite Sources and Tests in place. |
| `make format-check` | Fail on formatting drift. |
| `make check-docs` | Model pin, and every command the docs name, must be real. |
| `make lint-python` | ruff over the bench package. |
| `make test-python` | Bench package pytest suite. |
| `make bundle` | Assemble and sign `.build/Voiceour.app`. |
| `make verify-bundle` | Bundle layout, plist, entitlements, signature. |
| `make notarize` | Sign, notarize, staple, validate, archive. |
| `make release` | Source-release preflight; prints the publish commands. |
| `make fixture` | Regenerate the committed audio fixture. |
| `make clean` | Delete `.build`. |
| `make ui-snap` | Portable scene digests and AX dumps. |
| `make ui-snap-os26` | Native Liquid Glass scenes (macOS 26 host). |
| `make ui-update` | Bless intended portable scene changes. |
| `make ui-update-os26` | Bless intended native scene changes. |
| `make ui-list` | List the scene catalogue. |
| `make ui-flow` | Portable semantic flow journals. |
| `make ui-flow-os26` | Native semantic flow journals (macOS 26 host). |
| `make ui-flow-update` | Bless intended portable flow journals. |
| `make ui-flow-list` | List the flow catalogue. |
| `make ui-all` | Every UI gate this host can run. |
| `make bench-smoke` | Offline fake-backend smoke run. |
| `make bench-stt` | LibriSpeech transcription accuracy (`N=`, `BACKEND=`). |
| `make bench-e2e` | FLEURS end-to-end report (`N=`, `BACKEND=`). |
| `make bench-techterms` | Technical-term smoke run. |
| `make bench-gate` | U-WER regression gate (`BASELINE=`, `CANDIDATE=`). |
| `scripts/ui_harness.sh` | Extra harness flags (`--only`, `--help`) beyond the make targets. |
| `scripts/release.sh --binary` | Binary release: the source procedure plus the notarized archive. |
| `scripts/release.sh --dry-run` | Release preflight only. |
| `scripts/console_shot.sh` | Capture the onscreen console window. |
| `scripts/sign_notarize.sh --check-env` | Validate the Apple notarization environment. |
| `scripts/vendor_parakeet.sh --check` | Vendored source integrity. |
| `scripts/vendor_parakeet.sh <upstream>` | Refresh vendored parakeet.cpp/ggml from an upstream checkout. |
| `scripts/make_icon.sh` | Regenerate the committed app icon. |
