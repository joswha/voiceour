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

Nothing built here is notarized. `scripts/bundle.sh` signs with the ad-hoc `-` identity unless `VOICEOUR_CODESIGN_IDENTITY` is set or a local `voiceour-dev` keychain exists, and it says so on stderr. Two consequences follow. TCC keys grants to a code identity, and an ad-hoc identity can change on rebuild, so Microphone and Accessibility may be asked for again; `scripts/setup_local_signing.sh` installs a stable self-signed `voiceour-dev` certificate that `bundle.sh` then picks up on its own, which is worth doing before any repeated permission testing. And a bundle built and launched in place carries no quarantine flag, so it opens normally — but the same `.app` copied off this machine does, and Gatekeeper will refuse an unnotarized copy until it is opened explicitly from Finder's context menu or allowed under Privacy & Security. That is why only the Developer ID path under [Ship it](#ship-it) produces a bundle fit to hand to anyone else.

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

Bundle checks:

- `make bundle` assembles `.build/Voiceour.app` and its signed `voiceour-asr` sibling.
- `make verify-bundle` checks bundle shape, identifiers, entitlements, and signatures.
- `scripts/setup_local_signing.sh` creates a stable local certificate so permission grants survive rebuilds. Do not commit its output.

Releases come in two kinds and `scripts/release.sh` runs both. `make release` is a source release: preflight, the local gate, the version's changelog section extracted to `.build/Voiceour-<version>-release-notes.md`, then the `git tag`, `git push` and `gh release create --notes-file` commands printed for you to run. It signs nothing and reads no Apple credentials, so it works on any checkout. GitHub attaches the source archives itself.

`scripts/release.sh --binary` is the same procedure plus the distributable app. It needs a Developer ID, and it adds `.build/Voiceour-<version>.zip`, `.build/Voiceour-<version>.zip.sha256` and `.build/Voiceour-release-manifest.txt` — the archive is named from `CFBundleShortVersionString` in `Resources/Info.plist`, and the sidecar is relative, so `shasum -a 256 -c Voiceour-<version>.zip.sha256` works from inside `.build`. The printed `gh release create` line attaches both files. There is deliberately no `make` target for this one.

Either mode takes `--dry-run`, in any argument order, which runs every check for that mode and stops before writing the notes file, signing anything, or printing the publish commands. Each failed check prints its own `release.sh: FAIL:` line and the script exits 1; expect the run to be slow, because the checks end in `make build`, `make format-check`, `make check-docs` and `make test`. Neither mode bumps the version, tags, pushes, or publishes.

The binary path alone needs credentials: `DEVELOPER_ID_APPLICATION` plus either `NOTARY_KEYCHAIN_PROFILE`, created once with `xcrun notarytool store-credentials`, or `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_SPECIFIC_PASSWORD`. Prefer the keychain profile: a password on a command line is visible in the process table. `scripts/sign_notarize.sh --check-env` reports what it found and exits without submitting anything; `make notarize` runs that signing, notarizing, stapling and archiving on its own, outside a release.

[AGENTS.md](../AGENTS.md#release-procedure) holds the release rules and the ordered steps, including the changelog section the preflight requires; this section is only the commands.

## Scripts

| script | purpose |
| --- | --- |
| `run_dev.sh` | Build and launch the fake app. |
| `run_real.sh` | Rebuild and launch the real backend. |
| `restart_real.sh` | Relaunch the existing bundle. |
| `bundle.sh` | Assemble the app bundle and its helper. |
| `verify_bundle.sh` | Verify bundle contents, identity, and signatures. |
| `setup_local_signing.sh` | Create local signing configuration. |
| `sign_notarize.sh` | Developer-ID signing, notarization, and stapling. |
| `release.sh` | Preflight and publish commands for one release; `--binary` adds the notarized archive. |
| `ui_harness.sh` | Run offscreen scenes and flows. |
| `console_shot.sh` | Capture the onscreen console window. |
| `check_docs.sh` | Check docs against the model contract. |
| `vendor_parakeet.sh` | Check vendored sources or refresh them. |
| `make_fixture.sh` | Regenerate the committed audio fixture. |
| `make_icon.sh` | Regenerate the committed app icon. |
