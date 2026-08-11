# Developer setup

## Prerequisites

- macOS 14 or newer.
- Xcode or Command Line Tools with SwiftPM.
- `uv` for Python dependency management.
- Apple Silicon for the real Parakeet MLX proof.

## First success path

```sh
swift build
swift test
(cd asr && uv --no-config run pytest)
scripts/run_dev.sh --self-test
```

This repository standardises on `uv --no-config` for every Python command, and the scripts use it where they launch the sidecar. That is deliberate: a host-level `uv.toml` (`/etc/uv/uv.toml` or `~/.config/uv/uv.toml`) can otherwise change dependency resolution, so results would depend on whose machine ran them.

## Run the fake dev app

```sh
scripts/run_dev.sh
```

This is the fake development launch. It creates a synthetic WAV and uses the fake sidecar backend, so it does not require a model download, microphone permission, or the app bundle's microphone metadata.

`--debug` is an app launch argument, not a setting: `scripts/run_dev.sh --debug` and `scripts/restart_real.sh --debug` pass it through to reveal the machine-facing Diagnostics pane.

## Inspect the UI offscreen

```sh
make ui-snap                              # render every scene, check against fixtures/ui
make ui-update                            # rewrite the goldens after an intended change
make ui-list                              # print the scene catalog as JSON
scripts/ui_harness.sh --only console      # just one area
```

This is the preferred way to look at the UI. It renders SwiftUI views into a borderless window parked far offscreen, dumps the in-process accessibility tree, lints both, and diffs against the goldens in `fixtures/ui/`. No window appears on your display, the frontmost application does not change, and it needs neither Screen Recording nor Accessibility permission. Artifacts land in `.build/ui-harness/`: a PNG and an `.ax.txt` dump per scene, an `.ax.diff` when a dump moved, `manifest.jsonl`, and a `contact-sheet.png` tiling every scene. See [docs/ui-harness.md](ui-harness.md) for the CLI surface, the manifest schema, the lint rules, how to add a scene, and what an offscreen render cannot show you.

The harness exits from the first statement of `VoiceOourApp.init()`, so it starts none of the app's real machinery. A normal launch is unaffected: `UIHarnessRequest` is nil unless `--ui-harness` is present.

## Screenshot the console

```sh
scripts/console_shot.sh                        # sessions -> .build/console-sessions.png
scripts/console_shot.sh voice /tmp/voice.png   # any section, custom output path
```

Captures the console window for one section: `sessions` (default), `home`, `voice`, `glossary`, `refinement`, `system`, or `diagnostics`. Prefer `make ui-snap` above for everything except real glass; this script is the only way to see composited glass, on either render path, and the two paths fail in the harness for different reasons. Legacy behind-window `NSVisualEffectView` — `GlassSurfaces.swift`'s `FrostedGlassBackground` — rasterises as a flat opaque fill offscreen, because there is no desktop to sample. Modern SwiftUI `.glassEffect` does not rasterise at all: `cacheDisplay(in:to:)` leaves those pixels transparent, so an `os26` golden photographs the app's own paint with the material missing (design bible §5.2). It builds, launches the fake backend (no microphone, model download, or network), then opens the real `Window("VoiceOour", id: "main")` console scene via the development-only `--show-console --no-activate --console-section=<name>` flags, captures just that window with `screencapture`, and quits the app. A fresh window opens at 1164x820, but macOS may restore the last console frame (e.g. a near-fullscreen size), which is handy for reproducing the layouts users actually see. The controlling terminal needs macOS Screen Recording permission or the capture will be blank.

These launch flags are development-only and guarded like `--self-test`: `--show-console` posts a notification the menu-bar label observes to `openWindow(id: "main")`, so it drives the same production scene the "Open Console…" menu item does (nothing about the shipping flow changes). `--no-activate` suppresses the console's usual promotion to `.regular` (the Dock icon and Cmd-Tab entry that appear and disappear around a capture) plus the second `NSApp.activate` in `ConsoleView.onAppear`; it does **not** make the capture invisible, because the window has to be onscreen to be screenshotted and the show-console notification handler still activates the app. Expect a brief focus blip, just a smaller one. Use `make ui-snap` when you want no disruption at all. A normal user launch passes neither flag and behaves exactly as before. `scripts/find_console_window.swift` resolves the window id via `CGWindowListCopyWindowInfo`, which needs no Screen Recording permission.

## Run the real Parakeet app

```sh
scripts/run_real.sh
```

`scripts/run_real.sh` is the recommended interactive test path for real ASR. It launches the `.app` bundle with `NSMicrophoneUsageDescription` metadata and passes `--repo-root`, `--asr-dir`, and `--asr-backend mlx` through `open --args`. The macOS microphone prompt may appear when you first start a real recording, not merely when the app launches; Parakeet may cold-load on first use, and the model and inference remain local.

While recording, VoiceOour shows a compact movable graphite island with cancel/check controls. Drag the island body to reposition it. Escape discards the session and is claimed only while the island is on screen. Recording shows the live waveform, initially flat until levels arrive; processing shows an uppercase state label and comet, and there is no transcript preview. In real mode, silence should keep the waveform bars low, and speaking should raise and move them. If a transcript for a normal text target only lands on the clipboard, grant the macOS Accessibility permission VoiceOour requests for synthetic paste and Fn/Globe capture, then retry. Copy-only remains expected for terminal, code-editor, secure, unknown-risky, and target-change cases.

After granting Accessibility/event-post permission, restart the existing test bundle without rebuilding it:

```sh
scripts/restart_real.sh
```

Use this for repeated local tests. `scripts/restart_real.sh` enforces one running `.build/VoiceOour.app` instance for this repo before reopening the bundle. Before the first permission-sensitive build, run `scripts/setup_local_signing.sh` once. It creates a dedicated password-free `voiceoour-dev` keychain and identity; `scripts/bundle.sh` then unlocks and selects that identity without touching unrelated signing keychains. Grant Accessibility once to the resulting app. Its designated requirement remains stable across later rebuilds, so macOS keeps the grant. An explicit `VOICEOOUR_CODESIGN_IDENTITY` remains available for other identities; without either identity, the bundle is ad-hoc signed and requires a new grant after the code changes.

## Configure the network refiner

Refinement is opt-in and disabled by default. To use the default Gemini flash-lite refiner locally, open the Refinement pane, choose the Gemini provider (the default), paste an API key or launch with `GEMINI_API_KEY`, keep or choose a suggested Gemini model such as `gemini-2.5-flash-lite`, and enable refinement. VoiceOour stores the pane's API key in the macOS Keychain through `KeychainRefinerAPIKeyStore`.

```sh
export GEMINI_API_KEY="..."
scripts/run_real.sh
```

VoiceOour derives the base URL for Gemini, OpenAI, and OpenRouter providers and appends `/chat/completions` when sending refinement requests; only the Custom provider asks for an OpenAI-compatible base URL. Network refinement runs only when refinement is enabled and configured, and it is skipped for terminal, code-editor, and secure targets.

Gemini direct (`gemini-2.5-flash-lite`) is the shipped default: one provider, the already-working `GEMINI_API_KEY`, currently faster at equal accuracy. The **OpenRouter** provider with `meta-llama/llama-3.3-70b-instruct` (routed to Groq) is a latency-comparable alternative — both sit around 0.8–1s p50 with occasional spikes and trade places run to run (see `docs/archive/refinement-exploration.md`) — and is the one-tap fallback for when Gemini degrades. Set `OPENROUTER_API_KEY` in `.env` (or the environment); `scripts/run_real.sh` and `scripts/restart_real.sh` source `.env` so the bundled app inherits it. Keychain keys are stored per provider and take precedence; Custom keys are further scoped to the normalized endpoint. Without a Keychain key, the selected provider variable (`GEMINI_API_KEY`, `OPENAI_API_KEY`, or `OPENROUTER_API_KEY`) is checked first, followed by the provider-independent `VOICEOOUR_REFINER_API_KEY`; Custom uses only `VOICEOOUR_REFINER_API_KEY` for environment lookup.

### Oh My Pi refiner (optional)

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
cold_load_ms=193738 warm_inference_ms=4360 rss_kb=1743880192
```

This proof is non-interactive; it does not record the manual GUI insertion matrix.

## Bundle

```sh
scripts/bundle.sh
open .build/VoiceOour.app
```

`scripts/bundle.sh` prefers the dedicated local `voiceoour-dev` identity installed by `scripts/setup_local_signing.sh`, uses `VOICEOOUR_CODESIGN_IDENTITY` when explicitly set, and otherwise warns before falling back to ad-hoc signing. Stable identity signing keeps Accessibility permission across rebuilds. For repeated permission-sensitive restarts without rebuilding, use `scripts/restart_real.sh`.

## Release hardening

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

## Manual fake E2E

1. Launch with `scripts/run_dev.sh`.
2. Focus a normal text target on one display.
3. Tap Fn/Globe to start recording. Once Accessibility is granted, VoiceOour consumes the standalone tap and suppresses the macOS emoji popup; without it, the passive fallback may let the popup also appear.
4. Expect the compact movable graphite island on the focused target's display. Drag the island body to reposition it. Recording shows the live waveform, initially flat until levels arrive; processing shows an uppercase state label and comet, and there is no transcript preview.
5. Focus a normal text target on another display. The island should move to that display while preserving its relative placement.
6. Tap Fn/Globe again or use the check control to stop. The island should remain open during finalization, then the fake transcript should be copied and Cmd-V attempted in the target focused when insertion begins.
7. If the transcript only lands on the clipboard for a normal text target, grant the macOS event-post/Accessibility synthetic-paste permission VoiceOour requests and retry.
8. Deny synthetic paste permission or use a terminal/code/secure/unknown-risky delivery target. Expected: copy-only. Target identity is bundle id, pid and safety class, re-checked immediately before the pasteboard write and again before Cmd-V, so a focus change after the delivery snapshot — including to a secure field inside the same app — degrades to copy-only rather than pasting into an unverified target.

## Test tiers

- PR gate: `swift test` and `cd asr && uv --no-config run pytest`.
- App smoke: `scripts/run_dev.sh --self-test`.
- UI gate: `make ui-snap` (offscreen, no window, no focus change; see `docs/ui-harness.md`).
- Interactive fake app: `scripts/run_dev.sh`.
- Interactive real Parakeet app: `scripts/run_real.sh` on a logged-in desktop; the macOS microphone prompt may appear when real recording first starts, and Parakeet may cold-load on first use.
- Real ASR proof: generated fixture plus `phase0_asr_proof.py`.
- Release: signed/notarized app on a clean macOS account with the manual insertion matrix.
- Benchmarks: `make bench-smoke` (offline, fake backend) and the accuracy/speed tiers in `docs/benchmarks.md`.

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
|`console_shot.sh`, `find_console_window.swift`|screenshot tooling|Onscreen console window capture. Superseded by `ui_harness.sh` except for real glass — behind-window `NSVisualEffectView` and modern `.glassEffect` alike, neither of which the offscreen path can rasterise.|
|`archive/perf_probe.sh`, `archive/perf_probe_helper.swift`|archived|Measuring render performance. Archived, not wired into `make` or CI: it needs a running bundled app plus an Accessibility grant, and it mutates focus and cursor state while sampling. Run it directly from `scripts/archive/` if you need a render baseline.|
|`make_icon.sh`, `render_emoji_icon.swift`|asset regeneration|One-off generators that produced the committed `Resources/AppIcon.icns`.|

