# Developer setup

## Prerequisites

- macOS 14 or newer.
- Xcode Command Line Tools or Xcode with SwiftPM.
- [`uv`](https://docs.astral.sh/uv/) only for the Python benchmark package under `bench/`.
- `git-lfs` only when fetching benchmark datasets that are stored through LFS.

The application and sidecar are self-contained Swift/C/C++ products. Python never ships in the app bundle.

## First success path

```sh
xcode-select --install                 # only if Command Line Tools are absent
make build
make test
scripts/run_dev.sh --self-test
scripts/run_dev.sh
```

`scripts/run_dev.sh` builds and launches the debug executable with the deterministic `fake` backend unless `VOICEOUR_ASR_BACKEND` is already set. It needs no microphone grant, model, or network.

## Contributor checks

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

`CONTRIBUTING.md` distinguishes required, advisory, real-hardware, and release checks.

## Inspect the UI offscreen

```sh
make ui-snap                       # portable accessibility + PNG-digest scene check
make ui-flow                       # portable semantic journey journals
make ui-all                        # add native macOS 26 legs when supported
make ui-list
make ui-flow-list
scripts/ui_harness.sh --only console
```

Use `make ui-update` only after reading the generated `.ax.diff`. Use `make ui-flow-update` only after reading the generated `.flow.diff`. See [`ui-harness.md`](ui-harness.md) for the CLI, artifact tree, activation guarantees, and measured raster limitations.

## Screenshot the native console

The offscreen harness is preferred for deterministic review. To inspect WindowServer-composited material in a real window:

```sh
scripts/console_shot.sh general .build/console-general.png
scripts/console_shot.sh glossary .build/console-glossary.png
scripts/console_shot.sh history .build/console-history.png
scripts/console_shot.sh system .build/console-system.png
```

The script builds the fake app, launches `--show-console --no-activate --console-section=<tab>`, captures the window, and quits it. Current tab names are `general`, `glossary`, `history`, and `system`; an unrecognized value means "no override", so the launch opens on the stored last-used tab (or General). This path still places a real window onscreen and needs Screen Recording permission for the controlling terminal.

`--no-activate` suppresses `ConsoleWindowView`'s normal promotion from `.accessory` to `.regular`, but the show-console notification still activates the app to open the window. The flag reduces the focus disruption; it cannot eliminate it.

## Run the real Parakeet app

```sh
scripts/run_real.sh
```

This builds `.build/Voiceour.app`, launches the `parakeet` backend, and lets macOS attribute microphone and Accessibility grants to the bundle. A fresh installation immediately uses real local ASR. On first launch the app downloads the pinned 1.26 GB model and shows progress in the menu and System tab. After that cache exists, dictation works offline.

The model contract is:

- `ggml-org/parakeet-GGUF`
- revision `35156454d1a39de06863303dd209fd2bed6ee079`
- `ggml-parakeet-tdt-0.6b-v3-f16.bin`

The app is English-only. There is no locale setting.

When the bundle already exists and source has not changed, restart without rebuilding:

```sh
scripts/restart_real.sh
```

Use `scripts/run_real.sh` after source, bundled-resource, entitlement, or helper changes. `restart_real.sh` intentionally reuses the existing bundle.

## Run the real ASR proof

```sh
swift build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav
```

This validates the pinned cache/model against the fixture and prints transcript plus load/inference timing. It requires the model cache. The sibling-helper rule is the same in `.build/debug`, `.build/release`, and `Voiceour.app/Contents/MacOS`.

To prove the full acquisition path — download, digest verification, manifest write, load — point the cache at a scratch directory with `VOICEOUR_MODEL_CACHE` (one 1.26 GB download):

```sh
SCRATCH=$(mktemp -d) && VOICEOUR_MODEL_CACHE="$SCRATCH" \
  .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav; rm -rf "$SCRATCH"
```

`VOICEOUR_MODEL_CACHE` is the only cache override. Overriding `HOME` does not move the cache — `FileManager` resolves `.cachesDirectory` through the user's sandbox container path, not `$HOME` — so a `HOME`-scratch "fresh acquisition" silently reuses the real cache and passes without downloading anything. Measured here: 3.8 s wall against a warm cache versus 155 s for the real download.

## Bundling and verification

```sh
scripts/bundle.sh
scripts/verify_bundle.sh
```

The bundle contains `Voiceour` and the signed sibling `voiceour-asr` helper. Verification checks bundle shape, identifiers, entitlements, signatures, helper placement, and hardened-runtime expectations.

The sidecar downloads only:

`https://huggingface.co/ggml-org/parakeet-GGUF/resolve/35156454d1a39de06863303dd209fd2bed6ee079/ggml-parakeet-tdt-0.6b-v3-f16.bin`

Its environment is reduced to process basics, proxy/TLS routing names, and `VOICEOUR_*` controls.

## Local signing

```sh
scripts/setup_local_signing.sh
scripts/bundle.sh
scripts/verify_bundle.sh
```

`setup_local_signing.sh` creates or reuses a stable local certificate and writes local configuration outside the committed source. Stable signing keeps TCC identity stable across rebuilds. Do not commit local signing material.

## Release hardening and notarization

```sh
scripts/sign_notarize.sh
```

The release script builds with the configured Developer ID, enables hardened runtime, verifies signatures and entitlements, submits with `notarytool`, staples, and validates. The CI release job covers `swift build -c release`, `scripts/bundle.sh`, and `scripts/verify_bundle.sh`; notarization still requires release credentials and a clean-account manual pass.

Voiceour's entitlement file grants audio input only. The bundle has no provisioning profile and stores no credential. The measured data-protection-keychain limitation is documented in [`architecture.md`](architecture.md).

## Optional real-hardware checks

```sh
VOICEOUR_PARAKEET_INTEGRATION=1 swift test
VOICEOUR_CAPTURE_INTEGRATION=1 swift test
```

The Parakeet leg needs the full model cache and exercises process/model lifecycle cases that are too expensive for the ordinary fake-backed suite. The capture leg opens the physical microphone, is serialized, and verifies device pinning and signal liveness. Both skip when their environment flag is absent.

Manual permission and insertion checks live in [`permissions.md`](permissions.md).

## Benchmarks

From the repository root:

```sh
make bench-smoke
make bench-stt N=64
make bench-e2e N=64
make bench-techterms
make bench-gate BASELINE=benchmarks/results/<baseline>.json CANDIDATE=benchmarks/results/<candidate>.json
```

Direct invocations keep uv isolated from user configuration:

```sh
cd bench
uv --no-config sync
uv --no-config run pytest
uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend parakeet --n 64
uv --no-config run python -m voiceour_bench.run --tier fleurs --mode e2e --backend parakeet --n 64
uv --no-config run python -m voiceour_bench.run --tier techterms --mode stt --backend parakeet
```

The only accepted benchmark backends are `parakeet` and `fake`; the default is `parakeet`. See [`benchmarks.md`](benchmarks.md) before comparing reports, because row-id and model-provenance equality are mandatory.

## Script inventory

| script | purpose |
| --- | --- |
| `run_dev.sh` | Build and launch fake-first development; supports `--self-test`. |
| `run_real.sh` | Rebuild/bundle and launch real Parakeet. |
| `restart_real.sh` | Relaunch the existing bundle without a rebuild. |
| `bundle.sh` | Assemble `.build/Voiceour.app` and its helper. |
| `verify_bundle.sh` | Verify bundle contents, identity, entitlements, and signatures. |
| `setup_local_signing.sh` | Create stable local signing configuration. |
| `sign_notarize.sh` | Developer-ID signing and notarization workflow. |
| `ui_harness.sh` | Offscreen scenes, accessibility, lint, digests, and semantic flows. |
| `console_shot.sh` / `find_console_window.swift` | Onscreen native-console capture for composited material. |
| `vendor_parakeet.sh` | Vendor-integrity check or controlled vendor refresh. `--check` also rejects unexpected files and verifies the embedded Metal source is reproducible. |
| `make_fixture.sh` | Regenerate the small committed audio fixture. |
| `make_icon.sh` / `render_emoji_icon.swift` | Regenerate the committed app icon. |
| `archive/perf_probe.sh` | Historical live rendering probe; not wired into Make or CI. |
