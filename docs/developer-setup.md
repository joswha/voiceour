# Developer setup

## Prerequisites

- macOS 14 or newer.
- Xcode or Command Line Tools with SwiftPM.
- `uv` for Python dependency management.
- Apple Silicon for the real Parakeet MLX proof.

## First success path

```sh
make build
make format-check
make lint-python
make test
(cd asr && uv --no-config run pytest)
(cd bench && uv --no-config run pytest)
scripts/run_dev.sh --self-test
make bench-smoke
make ui-flow
make ui-coverage
make ui-snap
make ui-flow-frames
```

This is the complete fake-backed verification inventory. The exact required-versus-advisory CI
classification lives in [`CONTRIBUTING.md`](../CONTRIBUTING.md). `make python-test` is the Makefile
wrapper for the ASR pytest command above; `make format` applies Swift formatting rather than
checking it.

This repository standardises on `uv --no-config` for every Python command, and the scripts use it
where they launch the sidecar. That is deliberate: a host-level `uv.toml` (`/etc/uv/uv.toml` or
`~/.config/uv/uv.toml`) can otherwise change dependency resolution, so results would depend on
whose machine ran them.

## Run the fake dev app

```sh
scripts/run_dev.sh
```

This is the fake development launch. It creates a synthetic WAV and uses the fake sidecar backend, so it does not require a model download, microphone permission, or the app bundle's microphone metadata.

`--debug` is an app launch argument, not a setting: `scripts/run_dev.sh --debug` and `scripts/restart_real.sh --debug` pass it through to reveal the machine-facing Diagnostics pane.

## Inspect the UI offscreen

```sh
make ui-snap                              # render portable scenes and check fixtures/ui
make ui-flow                              # check host-independent journey journals
make ui-coverage                          # enforce the UI coverage ledger
make ui-flow-frames                       # check journey rasters and AX dumps
make ui-all                               # ui-snap followed by ui-flow-frames
make ui-update                            # rewrite portable scene goldens
make ui-flow-update                       # rewrite intended flow journals and frames
make ui-list                              # print the scene catalog as JSON
make ui-flow-list                         # print the flow catalog
make ui-snap-os26                         # native macOS 26 scenes
make ui-update-os26                       # rewrite native macOS 26 scene goldens
make ui-flow-os26                         # native macOS 26 journeys
make ui-film                              # regenerate README media; not a gate
scripts/ui_harness.sh --only console      # run just one area
```

This is the preferred way to look at the UI. It renders SwiftUI views into a borderless window parked far offscreen, dumps the in-process accessibility tree, lints both, and diffs against the goldens in `fixtures/ui/`. No window appears on your display, the frontmost application does not change, and it needs neither Screen Recording nor Accessibility permission. Artifacts land in `.build/ui-harness/`: a PNG and an `.ax.txt` dump per scene, an `.ax.diff` when a dump moved, `manifest.jsonl`, and a `contact-sheet.png` tiling every scene. See [docs/ui-harness.md](ui-harness.md) for the CLI surface, the manifest schema, the lint rules, how to add a scene, and what an offscreen render cannot show you.

The harness exits from the first statement of `VoiceOourApp.init()`, so it starts none of the app's real machinery. A normal launch is unaffected: `UIHarnessRequest` is nil unless `--ui-harness` is present.

## Screenshot the console

```sh
scripts/console_shot.sh                        # sessions -> .build/console-sessions.png
scripts/console_shot.sh voice /tmp/voice.png   # any section, custom output path
```

Captures the console window for one section: `sessions` (default), `home`, `voice`, `glossary`, `refinement`, `system`, or `diagnostics`. Prefer `make ui-snap` above for everything except real glass; this script is the only way to see composited glass, on either render path, and the two paths fail in the harness for different reasons. Legacy behind-window `NSVisualEffectView`, implemented by `GlassSurfaces.swift`'s `FrostedGlassBackground`, rasterises as a flat opaque fill offscreen because there is no desktop to sample. Modern SwiftUI `.glassEffect` does not rasterise at all: `cacheDisplay(in:to:)` leaves those pixels transparent, so an `os26` golden photographs the app's own paint with the material missing (design bible §5.2). It builds, launches the fake backend (no microphone, model download, or network), then opens the real `Window("VoiceOour", id: "main")` console scene via the development-only `--show-console --no-activate --console-section=<name>` flags, captures just that window with `screencapture`, and quits the app. A fresh window opens at 1164x820, but macOS may restore the last console frame (e.g. a near-fullscreen size), which is handy for reproducing the layouts users actually see. The controlling terminal needs macOS Screen Recording permission or the capture will be blank.

These launch flags are development-only and guarded like `--self-test`: `--show-console` posts a notification the menu-bar label observes to `openWindow(id: "main")`, so it drives the same production scene the "Open Console…" menu item does (nothing about the shipping flow changes). `--no-activate` suppresses the console's usual promotion to `.regular` (the Dock icon and Cmd-Tab entry that appear and disappear around a capture) plus the second `NSApp.activate` in `ConsoleView.onAppear`; it does **not** make the capture invisible, because the window has to be onscreen to be screenshotted and the show-console notification handler still activates the app. Expect a brief focus blip, just a smaller one. Use `make ui-snap` when you want no disruption at all. A normal user launch passes neither flag and behaves exactly as before. `scripts/find_console_window.swift` resolves the window id via `CGWindowListCopyWindowInfo`, which needs no Screen Recording permission.

## Run the real Parakeet app

```sh
scripts/run_real.sh
```

`scripts/run_real.sh` is the recommended interactive test path for real ASR. It launches the `.app` bundle with `NSMicrophoneUsageDescription` metadata and passes `--repo-root`, `--asr-dir`, and `--asr-backend mlx` through `open --args`. The macOS microphone prompt may appear when you first start a real recording, not merely when the app launches; Parakeet may cold-load on first use, and the model and inference remain local.

The default is `mlx-community/parakeet-tdt-0.6b-v3`, pinned to revision
`ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`; Apple Silicon is required. The first launch downloads
and caches the model. Once its cache manifest exists the sidecar sets `HF_HUB_OFFLINE=1`, stays
alive for the app run, and preloads at launch so later dictations pay inference rather than model
startup.

While recording, VoiceOour shows a compact movable graphite island with cancel/check controls. Drag the island body to reposition it. Escape discards the session and is claimed only while the island is on screen. Recording shows a static `WARMING` label until the microphone delivers real audio and the live waveform from then on; processing shows an uppercase state label and comet, and there is no transcript preview. In real mode, silence should keep the waveform bars low, and speaking should raise and move them. With a Bluetooth headset as the default input, capture is deliberately redirected to the built-in microphone, so the waveform should replace `WARMING` promptly rather than a second later and the first words of the utterance should survive; `docs/architecture.md`, *Microphone capture*, records why the headset microphone is skipped. Both real backends name the microphone they opened on stderr: `MicrophoneRecorder` (the `mlx` path) logs `VoiceOour: capture device=<name>`, adding `(redirected from system default)` when the policy moved it, and `--asr-backend apple` reports the same device in its `session init breakdown` line. Permission fallback and insertion-safety outcomes are covered by [`docs/permissions.md`](permissions.md).

After granting Accessibility/event-post permission, restart the existing test bundle without rebuilding it:

```sh
scripts/restart_real.sh
```

Use this for repeated local tests. `scripts/restart_real.sh` enforces one running `.build/VoiceOour.app` instance for this repo before reopening the bundle. Before the first permission-sensitive build, run `scripts/setup_local_signing.sh` once. It creates a dedicated password-free `voiceoour-dev` keychain and identity; `scripts/bundle.sh` then unlocks and selects that identity without touching unrelated signing keychains. Grant Accessibility once to the resulting app. Its designated requirement remains stable across later rebuilds, so macOS keeps the grant. An explicit `VOICEOOUR_CODESIGN_IDENTITY` remains available for other identities; without either identity, the bundle is ad-hoc signed and requires a new grant after the code changes.

## Configure the refiner

Refinement is opt-in and disabled by default, and the Refinement pane offers exactly two providers: **Oh My Pi**, which hands the request to the locally installed `omp` CLI, and **Apple On-Device**. Neither takes a credential from VoiceOour, so there is no key to paste and no credential variable to export. Enable the refiner, pick a model, and dictate.

```sh
scripts/run_real.sh
```

The Model field is a picker over `omp models --json`, not a free-text id: it starts on the provider default (`anthropic/claude-haiku-4-5`), **REFRESH** reloads the catalog after you connect an account, and the filter field narrows a long list. Network refinement runs only when refinement is enabled and configured, and it is skipped for terminal, code-editor, and secure targets.

A `settings.json` written by an older build that named `gemini`, `openAI`, `openRouter`, or `custom` loads as `omp` with `refiner_model` cleared and `refiner_enabled` forced back to `false`. Re-enable refinement after choosing an OMP model; the app will not silently point a live refiner at a different network destination.

### Oh My Pi refiner (the default provider)

Oh My Pi is the subscription-backed refiner provider. When OMP refinement is enabled and configured, VoiceOour starts one persistent `omp --mode rpc` child lazily from recording-stop warm-up (or the first direct refine) and reuses it for subsequent refines. The app needs no API key.

In Refinement → Oh My Pi, connected providers are grouped first; ChatGPT, Claude, Gemini, and Kimi remain visible with **CONNECT** or **RECONNECT** actions when no active account exists. **ADD** starts another login for an already-connected provider, while **BROWSE** opens OMP's complete current provider catalog. VoiceOour opens OMP's interactive login in a temporary Terminal window, waits for the command to finish, and selects a matching model from the provider-scoped `omp models <provider> --json` catalog. **REFRESH** runs `omp usage --json --redact` in the same credential-shadowed environment and retains only aggregate provider/account counts. OMP alone stores and refreshes the credentials; VoiceOour does not read the credential database, token values, or returned account identities.

The default model is `anthropic/claude-haiku-4-5` (fastest measured on the production dictation prompt, ~1.4–1.7s median warm refine); `openai-codex/gpt-5.5` is ~1.9s median. The child runs with a hermetic profile under `~/Library/Application Support/VoiceOour/omp-rpc/` so refine requests carry no OMP memory or MCP tool context.

```sh
bun install -g @oh-my-pi/pi-coding-agent
# or
brew install can1357/tap/omp
```

If the desired `omp` binary is not on the app's launch path, set `VOICEOOUR_OMP_BIN` in the launch environment to its absolute path. The manual fallback remains `omp auth-broker login <provider>`.

### Apple On-Device refiner (macOS 26+)

The "Apple On-Device" provider runs Apple's system language model through the FoundationModels framework: no network, no API key, no model download managed by VoiceOour, measured p50 ~1.6–2.0 s per refine on M4 Pro with the production glossary (see `docs/performance-roadmap.md`). It requires Apple Intelligence to be enabled in System Settings (the OS downloads the model itself). If Apple Intelligence is off or the Mac is unsupported, the Refinement pane's status check reports why, and refinement falls back to deterministic cleanup. Outputs that look like assistant chatter (preambles, answered questions) are rejected by the shared faithfulness guards and also fall back deterministically.

## Run the real ASR proof

```sh
scripts/make_fixture.sh
cd asr && uv --no-config run python ../scripts/phase0_asr_proof.py ../fixtures/audio/hello_16k_mono.wav
```

Example proof output:

```text
transcript=Hello world testing NVIDIA Parakeet NN Spaceport.
cold_load_ms=193738 warm_inference_ms=4360 rss_bytes=1743880192
```

This proof is non-interactive; it does not record the manual GUI insertion matrix.

## Bundle

```sh
scripts/bundle.sh
open .build/VoiceOour.app
```

The bundle uses `Resources/Info.plist` with `LSUIElement=true` and a microphone usage string, plus
`Resources/VoiceOour.entitlements` with audio input only; it is deliberately not sandboxed.
`scripts/verify_bundle.sh` checks the plist values, signature validity, and shipped entitlements.

`scripts/bundle.sh` prefers the dedicated local `voiceoour-dev` identity installed by `scripts/setup_local_signing.sh`, uses `VOICEOOUR_CODESIGN_IDENTITY` when explicitly set, and otherwise warns before falling back to ad-hoc signing. Stable identity signing keeps Accessibility permission across rebuilds. For repeated permission-sensitive restarts without rebuilding, use `scripts/restart_real.sh`.

## Release hardening

`scripts/sign_notarize.sh` builds with the configured Developer ID identity, signs with hardened
runtime, verifies signature and entitlements, submits to `notarytool`, staples and validates,
assesses Gatekeeper, writes `.build/VoiceOour-release-manifest.txt`, and prints a SHA-256.

Non-credentialed local bundle verification:

```sh
scripts/bundle.sh
scripts/verify_bundle.sh
scripts/run_dev.sh --self-test
```

Credentialed release preferably stores the notary credentials in the login keychain. Run once; `notarytool` prompts for the Apple ID, team ID, and app-specific password:

```sh
xcrun notarytool store-credentials "VoiceOour-notary"
```

Then release with the keychain profile:

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export NOTARY_KEYCHAIN_PROFILE="VoiceOour-notary"
scripts/sign_notarize.sh
```

Direct credentials remain supported for existing release environments, but expose the app-specific password in the process table while `notarytool` runs:

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export APPLE_ID="..."
export APPLE_TEAM_ID="..."
export APPLE_APP_SPECIFIC_PASSWORD="..."
scripts/sign_notarize.sh
```

Signing is the only v0 task intentionally gated on credentials.

## Manual insertion and permission checks

Follow the fake and real E2E checklists in
[`docs/permissions.md`](permissions.md). That guide owns the Fn/Globe flow, permission fallbacks,
target-safety policy, focus-race checks, and release insertion matrix.

## Optional integration and benchmark checks

Real integrations are opt-in:

```sh
VOICEOOUR_MLX_INTEGRATION=1 swift test
VOICEOOUR_OMP_INTEGRATION=1 swift test
VOICEOOUR_FM_INTEGRATION=1 swift test
VOICEOOUR_APPLE_SPEECH_INTEGRATION=1 swift test
```

They require, respectively, the MLX model download, an OMP login, macOS 26 with Apple Intelligence,
or macOS 26 with SpeechAnalyzer. They skip when their environment variable is absent.

The benchmark Make targets are:

```sh
make bench-smoke
make bench-stt BACKEND=mlx N=64
make bench-refine
make bench-e2e BACKEND=mlx N=64
make bench-techterms
```

`make bench-smoke` is offline and fake-backed. The real tiers need their documented models and
datasets; see [`docs/benchmarks.md`](benchmarks.md).

## Script inventory

|Script|Status|Notes|
|---|---|---|
|`run_dev.sh`|supported|Fake dev launch + `--self-test` smoke; wrapped by `make dev`.|
|`run_real.sh`|supported|Real Parakeet bundle launch.|
|`restart_real.sh`|supported|Relaunch existing real bundle without rebuild.|
|`bundle.sh`|supported|Build + sign `.build/VoiceOour.app`; wrapped by `make bundle`. When an explicitly selected `VOICEOOUR_CODESIGN_IDENTITY` lives outside the default keychain search list, set `VOICEOOUR_CODESIGN_KEYCHAIN` to that keychain path; `bundle.sh` passes it to `codesign --keychain`.|
|`verify_bundle.sh`|supported|Non-credentialed bundle assertions; wrapped by `make verify-bundle`; also run by `sign_notarize.sh` after the hardened-runtime re-sign.|
|`sign_notarize.sh`|release-only|Credentialed Developer ID sign + notarize + staple.|
|`setup_local_signing.sh`|supported|One-time password-free `voiceoour-dev` keychain identity so `bundle.sh` rebuilds keep the Accessibility/TCC grant.|
|`make_fixture.sh`|supported|Generates the WAV proof fixture; wrapped by `make fixture`.|
|`phase0_asr_proof.py`|supported (model proof)|Loads the pinned model directly (not through the sidecar protocol; the sidecar path is covered by Swift/Python process tests) and prints transcript/latency/RSS.|
|`ui_harness.sh`|supported|Offscreen UI render/dump/lint/diff; wrapped by `make ui-snap`, `make ui-update`, `make ui-list`. Never opens a window, never steals focus.|
|`make_readme_gif.sh`|supported|Records the README's recording-island GIF from the harness film mode; wrapped by `make ui-film`. Needs `ffmpeg` and `ffprobe` on `PATH`. Media, not a gate: nothing diffs its output.|
|`console_shot.sh`, `find_console_window.swift`|screenshot tooling|Onscreen console window capture. Superseded by `ui_harness.sh` except for real glass. The offscreen path cannot rasterise either behind-window `NSVisualEffectView` or modern `.glassEffect`.|
|`archive/perf_probe.sh`, `archive/perf_probe_helper.swift`|archived|Measuring render performance. Archived, not wired into `make` or CI: it needs a running bundled app plus an Accessibility grant, and it mutates focus and cursor state while sampling. Run it directly from `scripts/archive/` if you need a render baseline.|
|`make_icon.sh`, `render_emoji_icon.swift`|asset regeneration|One-off generators that produced the committed `Resources/AppIcon.icns`.|

