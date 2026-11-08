# Runtime contract

How a dictation runs, what it may touch and store, and how the app is run locally. [AGENTS.md](../AGENTS.md) maps the other contracts; [`.omp/RULES.md`](../.omp/RULES.md) holds the invariants every change keeps.

## Runtime flow

```text
idle -> checkingPermissions -> recording -> finalizingAudio -> transcribing -> cleaning
     -> readyToInsert -> pasteAttempted | copiedOnly | insertFailed -> idle
```

`error` and `cancelled` also return to `idle`.

- Capture target: snapshot before recording; record-start label only. Delivery target: snapshot immediately before persistence/insertion; determines delivery.
- Fn/Globe toggles on solitary release. Shift, Control, Option, Command, Caps Lock, or another key during the hold disarms it. Toggle during recording stops; during `checkingPermissions` cancels; during finalizing/transcribing/cleaning/delivery does nothing.
- Trusted event tap consumes Globe assigned-action keycode 179, the toggling Fn release, and active-session unmodified Escape keyDown/repeats/keyUp. Passive monitors never suppress and MUST ignore keycode 179. A 2 s watchdog promotes to the tap when trust appears; prompt at most once/process, never mid-session.
- MUST recreate `HotkeyEventRouter` whenever the tap is rebuilt or torn down.
- Escape/island Cancel discards checking-permission, recording, finalizing, or transcribing work. Cancellation after the pasteboard write reports copy-only, not failure.
- Real start MUST reject an unready model with `model_not_installed` before prompting for Microphone; request Microphone only if undetermined. Fake skips both gates.
- Stop MUST finalize one WAV and decode once. No in-progress ASR requests or recording-length cap. No input signal within 6 s → stop and report no audio.
- MUST reject stale recording/decode/suggestion work using `AsyncGenerationGate` and cancellation checks.
- Capture: 16 kHz, mono, 16-bit WAV in `$TMPDIR/voiceour/`. Startup failure removes it. Once finalization starts, the pipeline alone owns discard. Launch scavenging removes recordings older than one hour.
- MUST latch runtime errors, device disconnects, conversion failures, WAV-write failures. Finalization drains the converter, closes WAV, rejects latched failures, zero written frames, or all-zero recordings. Liveness MUST scan every channel, including interleaved Int16/Int32.
- `AVCaptureSession` start/stop MUST share serial `com.voiceour.capture-session`; never main actor. Telemetry analysis also runs off-main.
- `CoreAudioInputDevice.preferredCaptureUID`: connected explicit selection > system default. Bluetooth/BLE default + open lid → built-in microphone. Unresolved selection → fallback, not capture failure.
- Before ASR: non-synthetic capture with `snrDB < DictationPolicy.minimumCaptureSNRDB` (6 dB) → `cancelled`. Missing telemetry or synthetic capture proceeds.
- Compile `VocabularyCompiler` snapshot once after finalization, before ASR. Apply text stages once after ASR; snapshot delivery target next.
- Failures MUST use `UserFacingDictationFailure`: title, plain cause, retryability, recovery destination. Raw codes MUST NOT be primary UI text.
- Wire `SidecarASRClientError.protocolError` preserves its code/detail. Local timeout → `timeout`; launch/no greeting/process exit/pipe write → `backend_unavailable`; incompatible greeting/unexpected response → `incompatible_protocol`. Preserve the public client error enum.
- Muting applies to `granite`, never `fake`. Start cue before mute; begin restore immediately when capture ends, without awaiting the 120 ms fade; end cue after restore.
- Mute ownership is durable and device-UID-bound. Unresolved UID → retain ownership and refuse another mute. Clear only after a real restore attempt. Disk-loaded/interrupted fades restore partial volumes; completed live fades retain the user-adjusted-volume check.
- A duplicate bundled instance MUST quit at launch. Quit MUST discard active work and restore audio before exit.

## Privacy and insertion safety

- `InsertionSafetyPolicy` alone maps class to disposition. Only `.normalText` may synthesize Cmd-V; terminal, code-editor, secure, unknown-risky remain copy-only. NEVER add a bypass setting.
- `SafetyClassifier` precedence: secure input > secure AX role/subrole > missing bundle id (unknown-risky) > known secure/terminal/editor bundle > unavailable AX inspection (unknown-risky) > normal text.
- Preserve Ghostty `com.mitchellh.ghostty` as terminal, Zed `dev.zed.Zed` and `com.jetbrains.` prefixes as editors.
- `kAXErrorNoValue` means no focused element; classify by bundle. Readable element with nil role/subrole may be normal text after secure checks. Other AX failures MUST fail closed.
- MUST recheck bundle id, app name, pid, safety class, secure-input flag before clipboard write AND before Cmd-V.
- Terminal/unknown-risky copies strip exactly one trailing newline.
- Secure delivery MUST use concealed, host-only copy and skip both `recent-sessions.json` and ledger. Other copy-only output is plain string and never cleared.
- Ordinary paste attempts use the transient marker. Only a posted Cmd-V schedules clearing: 1.5 s later, clear only if pasteboard change count still matches.
- MUST publish transcript + markers as one `NSPasteboardItem`. `GeneralPasteboard.copy == nil` → `pasteboard_write_failed`; NEVER post Cmd-V, schedule clearing, confirm copying, or announce delivery after failure.
- Clipboard access writes only the transcript; NEVER read/save/restore previous clipboard content. AX reads focus only; NEVER mutate text through AX.
- MUST remove temporary audio after success, cancellation, error, and stale-file scavenging.

## Persistence

- Support directory: `~/Library/Application Support/Voiceour/`, overridden verbatim by `VOICEOUR_SUPPORT_DIR`. Files: `settings.json`, `recent-sessions.json`, `dictation-activity.json`; mute ownership: `mute-owned.flag`.
- Settings/history/ledger writes MUST be owner-only, atomic per file, off-main, on one detached FIFO tail. No cross-file transaction. History write failure MUST report “Dictation history could not be saved.” without blocking delivery or later saves.
- Unreadable settings/history/ledger → quarantine as `<name>.corrupt-<ISO8601>` and report reset + filename. Island values NEVER trigger it: `Settings.island` falls back per field ([Recording island](recording-island.md)). NEVER suppress write failures.
- History: one file, newest-first, max 500. Fold ledger from the same journaled row in the same main-actor turn; enqueue both snapshots. Secure target → neither; every other disposition → both. Home and first-run checks read both records.
- Agent session links (`RecentSession.agentLink`): nil = unresolved, `.linked`, or `.unmatched` once the 30-minute send window closes. Only while `Settings.agentSessionLinkingEnabled` (off by default): a pass reads `AgentPromptReading` (`AgentPromptLogReader`: omp, Claude Code, Codex logs under `HOME`; read-only, incremental) and runs `AgentSessionLinker` off-main, one pass at a time, and writes through the journal FIFO; `AsyncGenerationGate` scope `.agentLinking` discards a pass that lands after linking turns off or History clears. Turning linking off removes every link. A malformed link decodes as unresolved, NEVER quarantines History. Matching rules and thresholds live in `AgentSessionLinker`; changing them requires measured link counts on real History.
- Ledger: sessions/words/seconds by local day and destination bundle id; totals, active days, longest streak; no text/session ids. Prune day buckets >400 days before the recorded day, preserving totals, active-day count, and longest streak. Empty ledger → remove file. Retired `dictation-stats.json` is swept at launch.
- App buckets MUST NOT be capped/pruned. Keep sessions/words/seconds, last non-nil display name, latest day key.
- Missing ledger → seed once from remaining History. Missing `captureMs` contributes words and zero seconds. `totalSessions > 0 && apps.isEmpty` → seed app buckets only; NEVER recount totals.
- Clear History erases History + ledger. Clear Vocabulary removes user terms and restores surviving bundled terms' shipped surfaces.
- Diagnostics MUST include build/backend/model/health/permissions/microphone/session-count/agent-link setting/storage paths. NEVER transcript text.

## Local-first and network policy

- Only compiled model URL: Granite's pinned host/repository/revision and digest. NEVER network text processing, telemetry, crash reporting, accounts, update checks, arbitrary URLs, or a second recognizer beyond `granite`.
- Agent prompt logs are read from the local home folder only while agent session linking is on; NEVER written, uploaded, or read for anything but linking History rows.
- Sidecar env allowlist: `PATH`, `HOME`, `TMPDIR`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` + lowercase forms, `SSL_CERT_FILE`, `VOICEOUR_*`. NEVER inherit full parent env. Always write `VOICEOUR_ASR_BACKEND`, `VOICEOUR_PRELOAD=1`.
- No credential UI, credential environment contract, configurable base URL, secret store, or keychain item. `Resources/Voiceour.entitlements`: audio-input only; no provisioning profile. Data-protection Keychain is unavailable: `SecItemAdd` returns `errSecMissingEntitlement` (-34018); ad-hoc `keychain-access-groups` fails AMFI. NEVER add a feature depending on it.

## Environment seams

Overrides apply to one run, never persist settings.

| variable | reader / contract |
| --- | --- |
| `VOICEOUR_ASR_BACKEND` | App: `--asr-backend` > env > persisted setting (any id, `--debug` launches only) > `granite`; invalid values fall through to the next source. Values `granite`, `fake`. Standalone sidecar default: `fake`; `voiceour-asr --prove` runs Granite only. |
| `VOICEOUR_MODEL_CACHE` | Sidecar, Granite: caller-owned single directory; no subdirectory or pruning. |
| `VOICEOUR_SUPPORT_DIR` | App: exact support-directory replacement. |
| `VOICEOUR_PRELOAD` | Sidecar: `1` starts preload; app always sets it. |
| `VOICEOUR_IDLE_UNLOAD_MS` | Sidecar: default 1,800,000 ms; ≤0 disables idle release. |
| `VOICEOUR_ASR_LOG` | Sidecar, Granite native logs: `debug`, `warn`, `error`, `none`; default info. |
| `VOICEOUR_FAKE_DELAY_MS` | Fake backend: transcription delay for cancellation tests. |
| `VOICEOUR_GRANITE_INTEGRATION`, `VOICEOUR_CAPTURE_INTEGRATION` | Tests: set `1` to opt into real Granite model / real microphone suites. |
| `VOICEOUR_GRANITE_MODEL` | Granite integration tests: explicit GGUF path; default the Granite cache. |
| `VOICEOUR_CODESIGN_IDENTITY`, `VOICEOUR_CODESIGN_KEYCHAIN` | `scripts/bundle.sh`: signing pins; [precedence below](#macos-permissions-and-signing). |
| `VOICEOUR_REPO_ROOT` | Harness / `scripts/console_shot.sh`: fixture/capture root. |

## macOS permissions and signing

- Microphone: real capture only, requested at first recording. Accessibility: active suppression + synthetic paste; gate `CGPreflightPostEventAccess()` or `AXIsProcessTrusted()`, prompted at most once/process. Without trust: passive observation + copy-only. NEVER request Input Monitoring or its entitlement.
- Stable signing is REQUIRED for repeatable TCC checks; ad-hoc rebuilds may change identity.
- Bundling precedence: explicit `VOICEOUR_CODESIGN_IDENTITY` / `VOICEOUR_CODESIGN_KEYCHAIN` > `.env` pins > `voiceour-dev` in `~/Library/Keychains/voiceour-dev.keychain-db` > ad-hoc `-` with warning. Explicit identity bypasses local pins. Ad-hoc override: `VOICEOUR_CODESIGN_IDENTITY=- make bundle`.
- Locked development keychain → owner unlocks it. NEVER delete/reset a keychain to build; NEVER commit signing output. Identity changes may require fresh Microphone/Accessibility grants.
- Development bundles lack hardened runtime; `scripts/sign_notarize.sh` enables/verifies it on app AND helper.
- Release qualification MUST cover signed helper, hardened runtime, entitlements, clean-account permissions, and [manual delivery matrix](../README.md#verification).

## Fast iteration runtime

- Behavior/resource change → rebuild and relaunch the exercised surface. Fake path for deterministic coordinator/menu/window checks; signed real bundle for microphone/acquisition/hotkey/insertion/entitlement/signature/helper/material checks. Respect interruption consent.
- `make run`: rebuild on `Package.swift`, `scripts/bundle.sh`, `Sources/`, `Resources/`, `Vendor/` changes; stop existing instance; launch. Launching over a live instance verifies the OLD binary: the new duplicate quits. `.env`/signing changes require `make bundle` explicitly.
- `make dev`: unbundled debug executable, fake unless `VOICEOUR_ASR_BACKEND` set; stops nothing.
- `make stop`/`make status` match process name `Voiceour`. Sidecar exits after stdin EOF + bounded shutdown; check lingering `voiceour-asr` when relevant. MUST verify intended PID/bundle with `make status`.
- `make run`/`make dev` source root `.env` and export every key; bundling reads signing pins. `make run` forwards backend/support names via `open --env`; MUST add forwarding for new app-read env names, NEVER assume LaunchServices inheritance.
- Run/dev flags use `ARGS`, e.g. `make run ARGS="--debug --show-console"`. Supported: `--debug`, `--show-console`, `--console-section=<home|glossary|history|settings>`, `--no-activate`, `--asr-backend <id>`, `--self-test`; `--ui-harness` only with `-DUI_HARNESS`.
- Logs: subsystem `com.voiceour.app`, categories `hotkey`, `audio`, `model` (retired model-cache sweep failures). `stop-path` signposts require Instruments/`xctrace`.
