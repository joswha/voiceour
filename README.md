# VoiceOour

VoiceOour is a minimalist macOS menu-bar dictation app. Tap Fn/Globe by itself, speak one utterance, transcribe locally with NVIDIA Parakeet through a Python sidecar, clean protected technical terms, then paste or copy the result into whichever app is focused when insertion begins. With Accessibility permission, an active event tap captures and consumes the standalone Fn/Globe tap before macOS can show its emoji/dictation popup; without it, a passive monitor still toggles recording but macOS may also react.

v0 is local-first:

- ASR defaults to the fake backend for development and tests.
- Real ASR uses `parakeet-mlx` with `mlx-community/parakeet-tdt-0.6b-v3` pinned at `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`. The sidecar is a persistent process: the model loads once per app run (preloading starts at launch), so dictation latency is inference-only after warm-up.
- Deterministic cleanup and the protected glossary run locally.
- The provider-based network refiner is opt-in, disabled by default, defaults to Gemini, and uses the network only after it is enabled and configured.
- Recent transcripts are stored locally for the dedicated Sessions view, can be cleared there, and audio history is not persisted.
- Terminal, code editor, secure, and unknown-risky targets degrade to copy-only.

## Requirements

- macOS 14 or newer. Apple Silicon is required for the real MLX backend; the fake backend runs anywhere.
- Command Line Tools: `xcode-select --install`. Full Xcode is not required.
- Swift 5.9 or newer (`Package.swift` declares `swift-tools-version: 5.9`). Check with `swift --version`.
- `uv` for the Python sidecar, from the official installer: `curl -LsSf https://astral.sh/uv/install.sh | sh`.
- Optional: Developer ID certificate and notary credentials, for release signing only.

## Quick start

```sh
swift build
make test          # swift test with the offscreen UI harness compiled in
(cd asr && uv --no-config run pytest)
scripts/run_dev.sh --self-test
make bench-smoke   # offline benchmark smoke: fake backend end-to-end
```

Nothing above downloads a model, opens the microphone, or reaches the network.

## Source map

`Sources/VoiceOour/VoiceOourApp.swift` is the entry point; it builds a
`DictationCoordinator`, which owns one utterance end to end — permissions,
recording, transcription, cleanup, optional refinement, insertion, history.
Everything the coordinator needs is injected, which is why the fake path needs no
hardware.

Below it, `Sources/VoiceCore` is pure Swift and Foundation: models, session state,
settings, deterministic cleanup, the glossary, wire types, and target-safety
classification. `Sources/VoiceMac` holds every macOS adapter — audio, pasteboard,
permissions, hotkey, Keychain, process management, and the optional refiner
backends. `asr/` is the Python sidecar that speaks the transcription protocol over
stdio.

Reading order for a first change: the coordinator, then the port protocols in
`Sources/VoiceCore/CorePorts.swift`, then whichever adapter you are touching.

## Test suites

| Command | Covers | Needs | CI |
|---|---|---|---|
| `swift build` | compiles the package, warnings as errors in CI | nothing | enforced |
| `make test` | Swift unit tests, fake-backed, including the UI harness suites | nothing | enforced |
| `cd asr && uv --no-config run pytest` | sidecar protocol, cache manifest, process behaviour | nothing | enforced |
| `cd bench && uv --no-config run pytest` | benchmark scoring and reporting logic | nothing | enforced |
| `scripts/run_dev.sh --self-test` | app smoke: cleanup and safety classification | nothing | enforced |
| `make bench-smoke` | end-to-end benchmark on the fake backend | nothing | enforced |
| `make ui-snap` | 36 portable offscreen UI scenes against committed goldens | nothing | non-blocking job |
| `make ui-snap-os26` | 12 native Liquid Glass scenes | macOS 26 host | local only |
| `make ui-flow` | deterministic interactive journeys and host-independent semantic journals | nothing | enforced |
| `make ui-coverage` | required UI surface, state, and journey coverage ledger | nothing | enforced |
| `make ui-flow-frames` | flow capture rasters and AX dumps against committed goldens | nothing | non-blocking job |
| `make ui-all` | portable scenes followed by flows with captured-frame reconciliation | nothing | local full gate |
| `VOICEOOUR_MLX_INTEGRATION=1 swift test` | real MLX sidecar | model download | local only |
| `VOICEOOUR_OMP_INTEGRATION=1 swift test` | real Oh My Pi RPC refiner | `omp` installed and signed in | local only |
| `VOICEOOUR_FM_INTEGRATION=1 swift test` | Apple on-device refiner | macOS 26, Apple Intelligence on | local only |
| `VOICEOOUR_APPLE_SPEECH_INTEGRATION=1 swift test` | Apple SpeechAnalyzer backend | macOS 26 | local only |
| `make bench-stt` / `bench-e2e` | accuracy and latency on real corpora | model download, datasets | local only |
| `scripts/sign_notarize.sh` | signed and notarized release | Developer ID credentials | local only |

The env-gated integration tests are deliberately **not** in CI: each needs a
credential, a model download, or a newer OS than the runner has. They are skipped,
not failed, when their variable is unset.

Accuracy and speed benchmarks (WER/RTFx/latency on LibriSpeech and FLEURS, refinement quality on curated cases) run through the production pipeline via `voiceoour-bench` — see `docs/benchmarks.md`.

Run the menu-bar app in fake-ASR development mode:

```sh
scripts/run_dev.sh
```

This is the fake dev launch: it avoids microphone/model requirements for the first run. It records a synthetic short WAV, asks the fake sidecar for a canned transcript, cleans it, then uses the same insertion path as the real backend.

Run the real Parakeet app interactively:

```sh
scripts/run_real.sh
```

`scripts/run_real.sh` is the recommended interactive test path for real ASR. It launches the `.app` bundle with microphone metadata and passes `--repo-root`, `--asr-dir`, and `--asr-backend mlx` through `open --args`, so macOS can attribute any microphone prompt to VoiceOour and the sidecar uses the MLX backend. The macOS microphone prompt may appear when you first start a real recording, not merely when the app launches; Parakeet may cold-load on first use, and the model and inference remain local.

Backend changes in the Voice pane are applied with its one-click `RESTART TO APPLY` action; it preserves the current launch context while resolving the newly saved backend.

Optional network refinement is configured from the Refinement pane. Pick a provider (Gemini by default; **OpenRouter** for the fastest models, e.g. `meta-llama/llama-3.3-70b-instruct` routed to Groq; **Oh My Pi** for subscription-backed refinement through the installed `omp` CLI), then paste an API key or use the provider environment variable (`GEMINI_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`) for direct-API providers. VoiceOour derives the base URL for Gemini, OpenAI, and OpenRouter; only `Custom` asks for an OpenAI-compatible base URL.

For Oh My Pi, the Refinement pane groups connected providers first and keeps ChatGPT, Claude, Gemini, and Kimi visible even when disconnected. **CONNECT** and **RECONNECT** open OMP's own interactive login in a temporary Terminal window; **ADD** adds another account, and **BROWSE** delegates to OMP's full live provider list. After sign-in, VoiceOour selects a matching `provider/model`. **REFRESH** reads only aggregate provider/account status from `omp usage --json --redact`; OMP stores and refreshes every credential in its own vault, and VoiceOour never reads OAuth tokens, API keys, or account identities from that flow. Oh My Pi reuses a persistent `omp --mode rpc` child process for a warm refine of about 1.4–2.7s depending on the model. Manual fallback: `omp auth-broker login <provider>`.

While recording, VoiceOour shows a compact draggable graphite pill with cancel/check discs. The island opens on the focused target window's display and follows app, display, and Space focus changes during the active session; a manual drag position is transferred relatively between displays instead of pinning the island to one monitor. Dragging the body repositions the island. Escape discards the session from wherever you are typing — the same action as the pill's cancel disc — and is claimed only while the island is on screen. Recording shows the live waveform, initially flat until levels arrive; processing shows an uppercase state label and comet. There is no transcript preview; the last transcript is available in the menu popover and Sessions view. In real recording, the waveform is driven by live microphone levels: silence should keep the bars low, and speaking should raise and move them. After you finish, the island stays open during finalization/transcription/cleanup/refinement and keeps showing processing state until insertion finishes. If a transcript for a normal text target only lands on the clipboard, grant the macOS Accessibility permission VoiceOour requests for synthetic paste and Fn/Globe capture, then retry. Copy-only remains expected for terminal, code-editor, secure, unknown-risky, and post-snapshot focus-race cases.

If you are only restarting the already-built test app after granting Accessibility/event-post permission, use:

```sh
scripts/restart_real.sh
```

That reopens the existing signed `.build/VoiceOour.app` without rebuilding it, which avoids invalidating the local macOS TCC permission entry during repeated tests.

The Diagnostics pane reports machine-facing install evidence rather than anything the user configures, so it is hidden from the console rail unless the app is launched with `--debug`; `scripts/restart_real.sh --debug` passes the argument through.

## Vocabulary and technical terms

VoiceOour keeps a local vocabulary of protected technical terms so recognized commands, flags, paths, versions, and product names survive cleanup and refinement. You teach and correct it from the app; none of this is required for basic dictation.

- **Fix and Teach (Sessions).** From the Sessions view, select the mangled words in a transcript and the TEACH bar appears under it; teach the term by entering its canonical spelling, optionally the DETECTED AS surface it should replace, and a scope: Global, This app, or This project. Right-clicking a word still works, and so does the FIX / TEACH button when nothing is selected. Taught terms are protected in future dictation for the chosen scope.
- **Suggestion accept/reject.** When VoiceOour proposes a correction, accepting it teaches the term for future dictation only — it never edits text that was already pasted or copied. Rejecting drops the suggestion.
- **Project-lexicon import.** Settings > Glossary imports a project lexicon from a file (a plain one-term-per-line list or JSON). Imported terms are sanitized, scoped to the active project, and kept local — they are ineligible for the cloud refiner.
- **Clear vocabulary.** System offers "Clear vocabulary", which after a type-`CLEAR` confirmation removes the terms you added and puts the bundled defaults back to their shipped surfaces — including any DETECTED AS surface you taught onto one of them. Bundled default terms themselves are kept.
- **Literal spoken composition.** Spoken directives expand to exact orthography before cleanup: say "spell that" or "literal" to dictate letters verbatim, "snake case" or "dash dash" to join words, and "capital X" to force casing, producing the literal string you spoke rather than cleaned prose.

Only cloud-eligible, non-project-scoped terms are ever sent to the optional network refiner; project-scoped and imported terms stay local. Local backends always see the full active vocabulary.

Automatic term correction and decoder biasing are experimental and OFF by default: automatic replacement (`Settings.automaticTermCorrectionEnabled`) and decoder bias (`Settings.decoderBiasEnabled`) both stay disabled pending calibration against real-speaker data. Any accuracy gains from them are unproven so far — current measurements come from a text-to-speech smoke tier only, on which unconditional biasing showed no recall gain. Fix/Teach, import, and suggestions above work regardless of these settings.

## Real ASR proof (non-interactive)

```sh
scripts/make_fixture.sh
cd asr && uv --no-config run python ../scripts/phase0_asr_proof.py ../fixtures/audio/hello_16k_mono.wav
```

Example output on Apple Silicon after downloading the model:

```text
transcript=Hello world testing NVIDIA Parakeet NN Spaceport.
cold_load_ms=193738 warm_inference_ms=4360 rss_kb=1743880192
```

The transcript is non-empty and contains the required `hello`/`world` proof terms.

## Measured performance

All figures below were measured on an Apple M4 Pro (10P+4E, 24 GB) running macOS 26.5.2, with
`mlx 0.31.2` / `parakeet-mlx 0.5.2` and Apple's on-device Foundation Models. Latency percentiles come
from 353 real dictation sessions; the controlled A/B numbers come from ~1,240 timed on-device model
calls. Full methodology, the dead ends, and the statistics are in [`docs/performance-roadmap.md`](docs/performance-roadmap.md).

These are one machine's observed numbers, recorded to justify specific engineering decisions. They are
not a specification, a guarantee, or a target: your hardware, OS version, refiner provider, and speech
length will all move them.

### Stage latencies from real sessions

| stage | p50 | p90 | p95 | n |
|---|---:|---:|---:|---:|
| ASR | 347 ms | 843 ms | 1052 ms | 167 |
| refinement | 2257 ms | 3995 ms | 5426 ms | 155 |
| insertion | 4 ms | 32 ms | 43 ms | 188 |
| start latency (hotkey → capture) | 188 ms | 219 ms | 231 ms | 43 |

Refinement is roughly 87% of post-speech latency. Note that this is a sum of independently measured
stage medians, not a single stopwatch span — these sessions predate the per-session end-to-end
`stopReleaseToInsertionOutcomeMs` timing the app now records.

### Accuracy

| tier | metric | Parakeet TDT 0.6B v3 (default) | Apple SpeechTranscriber (opt-in) |
|---|---|---:|---:|
| LibriSpeech | U-WER | **2.845%** (n=128) | 3.070% (n=64) |
| LibriSpeech | CER | **0.920%** | 1.106% |
| LibriSpeech | RTFx | 44.6x | — |
| TechTerms — *TTS, inadmissible* | U-WER | 6.731% | 13.462% |
| TechTerms — *TTS, inadmissible* | canonical-term recall | 63.6% | 27.3% |

LibriSpeech figures are reports `20260717T132024Z` (mlx) and `20260717T132040Z` (apple-speech): a
**+0.2247 pp** U-WER delta against this project's +0.35 pp gate. The two runs are not row-matched
(128 vs 64 rows), so treat the delta as indicative rather than a clean paired result.

The TechTerms rows are recorded for completeness but **carry no weight**: that tier is entirely
`macos-say` TTS, and [`docs/benchmarks.md`](docs/benchmarks.md) states such rows "must not be used as
evidence for … technical term accuracy, or the production gate". The gap is 7/11 vs 3/11 utterances
(exact McNemar p ≥ 0.125).

So: **`mlx` remains the default as status quo, not as a demonstrated accuracy win.** Apple's fused
engine is markedly faster post-stop (**15.9 ms vs 119 ms** on identical 10.56 s audio, because it
transcribes *during* capture). Which backend should be default is **unsettled** pending the consented
real-speaker corpus that `docs/benchmarks.md` records as not yet existing.

### Refiner: prewarm placement

Apple's on-device model benefits from a session prewarmed shortly before use. Holding idle time
constant at 30 s and varying only *when* the prewarm happens (240 accepted trials, globally shuffled
schedule, 8 per transcript × arm):

| prewarm placement | median |
|---|---:|
| before the idle (previous behaviour) | 1849.6 ms |
| **after the idle, ~400 ms before use (current)** | **1455.6 ms** |
| never | 1888.0 ms |

**−383.5 ms paired median** (95% CI [−399.0, −361.6], 10/10 transcripts, sign p = 0.002). VoiceOour
therefore prewarms at recording stop, where recorder finalization plus ASR supply the lead time.

### Where the cost actually is

| quantity | value |
|---|---:|
| refiner system prompt | 677 tokens |
| user message (58-term glossary) | 1085 tokens |
| output for a 45-word transcript | ~59 tokens |
| context window | 4096 tokens |
| time to first token | ~60% of the call |
| refines returning byte-identical text | **29.2%** |
| emitted words that differ from the model's input | **8.56%** |

The bottleneck is prefill, not generation: ~1,762 tokens in to produce ~59 out. Decode itself runs at
~131 tok/s and ASR at RTFx 44 — the model math is not the limiting factor.

### Things that were measured and rejected

Kept here because negative results are load-bearing:

| idea | measured result |
|---|---|
| Emit a structured diff/patch instead of the full rewrite | **+873 ms slower** (+88%), 30/50 patch-application failures |
| Streaming Parakeet (`transcribe_stream`) | **+66 ms slower** at the 10.5 s median, 5.56% of words changed |
| Trimming the glossary out of the prompt | 55–464 ms available, but every variant produced worse output |
| Shorter system prompt | −331 ms, but caused command-as-text execution failures |
| Encoder `mx.compile` | +1.7 ms fixed-shape win, −5.9 ms penalty per unseen input length |
| INT8 quantization | −32 ms, but unvalidated for accuracy and needs a new model pin |
| MLX 0.31.2 → 0.32.0 | 0.35 ms — noise |
| Wired memory / residency | 0.3–1.4 ms *slower* |
| Replacing the Python sidecar IPC | total non-inference overhead is only 1.2–1.6 ms |
| Rust or hand-written Metal kernels | no viable path; see the roadmap for why |

## Build an app bundle

```sh
scripts/bundle.sh
scripts/verify_bundle.sh
open .build/VoiceOour.app
```

The bundle uses `Resources/Info.plist` with `LSUIElement=true` and the microphone usage string, plus `Resources/VoiceOour.entitlements` with audio input only. For password-free local rebuilds, run `scripts/setup_local_signing.sh` once; it creates a dedicated `voiceoour-dev` identity that `scripts/bundle.sh` prefers automatically. An explicit `VOICEOOUR_CODESIGN_IDENTITY` still overrides the local identity, and the bundler falls back to ad-hoc signing when neither is available. Run `scripts/verify_bundle.sh` after bundling for a non-credentialed local check of plist values, signature validity, and shipped entitlements. The stable local identity keeps the macOS Accessibility/TCC designated requirement unchanged across rebuilds; ad-hoc signing does not. It is not sandboxed.

## Release signing

`scripts/sign_notarize.sh` builds the bundle with the configured Developer ID identity, signs it with hardened runtime, verifies signature and entitlements, submits it to notarytool, staples and validates the result, assesses Gatekeeper, writes `.build/VoiceOour-release-manifest.txt`, and prints a SHA-256 checksum. The preferred flow stores notary credentials in the login keychain. Run once; `notarytool` prompts for the credentials:

```sh
xcrun notarytool store-credentials "VoiceOour-notary"
```

Then release with the keychain profile:

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export NOTARY_KEYCHAIN_PROFILE="VoiceOour-notary"
scripts/sign_notarize.sh
```

Direct `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` credentials remain supported for existing release environments, but expose the app-specific password in the process table while `notarytool` runs.

```sh
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export APPLE_ID="..."
export APPLE_TEAM_ID="..."
export APPLE_APP_SPECIFIC_PASSWORD="..."
scripts/sign_notarize.sh
```

Signing/notarization is the only v0 task intentionally gated on credentials.

## Dependency note

`sindresorhus/KeyboardShortcuts` 2.x was evaluated but cannot compile under the command-line toolchain because its SwiftUI `#Preview` macro requires a missing `PreviewsMacros` plugin, so VoiceOour uses a small first-party Carbon/`CGEventTap` binder instead: an active session-level `CGEventTap` (`.cgSessionEventTap`) with pure detectors covered by tests. When Accessibility is granted, it toggles on a standalone Fn/Globe tap and consumes the Globe "assigned action" key event so macOS never shows its emoji/dictation popup, while Fn+other-key combinations pass through untouched. While a session is live it also claims an unmodified, non-repeating Escape to discard that session, swallowing both the keyDown and its keyUp so the focused app never sees the press; modified Escape, held Escape, and every Escape outside a session pass straight through. A session tap is used rather than the HID tap because a non-root process can only actively consume events at the session tap. If Accessibility is missing, VoiceOour falls back to a passive monitor: the toggle and the Escape cancel still work, but macOS may also show its Fn/Globe popup and the focused app also receives the Escape. Tests use the Swift Testing package pinned to the recorded `swiftlang/swift-testing` Git revision because command-line toolchains without Xcode ship neither XCTest nor the built-in Testing module.

## Security and privacy

- The app writes dictated text to the general pasteboard and posts Cmd-V for eligible targets after the macOS event-post/Accessibility synthetic-paste permission is available.
- It never reads or restores the previous clipboard.
- After a successful synthetic paste, the dictated text is cleared from the clipboard about a second later, unless something else was copied in the meantime (checked via pasteboard change count, never by reading contents). Copy-only outcomes keep the text on the clipboard, since that is the delivery mechanism.
- It strips one trailing newline for terminal copy-only targets.
- It does not use Accessibility mutation for insertion.
- Network access happens only when real model download is needed or when the optional refiner is explicitly enabled/configured; Gemini/OpenAI/OpenRouter refiner endpoints are provider-derived, and only Custom uses a typed base URL.

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) — contributor workflow, local checks, and subsystem rules.
- [SECURITY.md](SECURITY.md) — supported versions and how to report a vulnerability.
- [docs/architecture.md](docs/architecture.md) — design contracts and layering boundaries.
- [docs/developer-setup.md](docs/developer-setup.md) — setup and run instructions.
- [docs/ui-harness.md](docs/ui-harness.md) — the offscreen SwiftUI harness and its goldens.
- [docs/permissions.md](docs/permissions.md) — macOS microphone and Accessibility permissions.
- [docs/benchmarks.md](docs/benchmarks.md) — accuracy and latency benchmarks.
- [docs/performance-roadmap.md](docs/performance-roadmap.md) — measured performance state, ranked candidates, and rejected optimizations.
- [docs/v0-non-goals.md](docs/v0-non-goals.md) — v0 scope and non-goals.
- [docs/archive/keyword-comprehension-exploration.md](docs/archive/keyword-comprehension-exploration.md) — research notes on technical-keyword comprehension.
- [docs/archive/refinement-exploration.md](docs/archive/refinement-exploration.md) — research notes on refiner latency and quality.

## License

VoiceOour is released under the MIT License; see [LICENSE](LICENSE). Third-party components and model artifacts are attributed in [NOTICE](NOTICE).
