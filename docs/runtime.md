# Runtime contract

How a dictation runs, what it may touch and store, and how the app is run locally. [AGENTS.md](../AGENTS.md) maps the other contracts; [`.omp/RULES.md`](../.omp/RULES.md) holds the invariants every change keeps.

## Runtime flow

```text
idle -> checkingPermissions -> recording -> finalizingAudio -> transcribing -> cleaning
     -> readyToInsert -> pasteAttempted | copiedOnly | insertFailed -> idle
```

`error` and `cancelled` also return to `idle`.

- Capture target: snapshot before recording; record-start label only. Delivery target: snapshot immediately before persistence/insertion; determines delivery. Agent binding captures Tern's focused pane right after the delivery snapshot and resolves it after the paste; it NEVER delays or changes delivery ([Agent session binding](#agent-session-binding)).
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
- Agent session bindings (`RecentSession.agentSession`): nil = unbound. Attached once per row by [Agent session binding](#agent-session-binding); later title, resumability and send updates go through the same journal FIFO. `send`: nil = pending, `.sent(sentAt:text:)`, or `.notSent` once the 30-minute send window closes and the bound session's records were read without the dictation; a session that cannot be read stays pending. A malformed binding decodes as nil and an unknown send status as pending; neither quarantines History. The retired `agentLink` field and `agent_session_linking_enabled` key are neither read nor written, and no row is ever backfilled. Turning `Settings.agentSessionBindingEnabled` off strips every binding and persists History without them. Bindings never enter the ledger.
- Ledger: sessions/words/seconds by local day and destination bundle id; totals, active days, longest streak; no text/session ids. Prune day buckets >400 days before the recorded day, preserving totals, active-day count, and longest streak. Empty ledger → remove file. Retired `dictation-stats.json` is swept at launch.
- App buckets MUST NOT be capped/pruned. Keep sessions/words/seconds, last non-nil display name, latest day key.
- Missing ledger → seed once from remaining History. Missing `captureMs` contributes words and zero seconds. `totalSessions > 0 && apps.isEmpty` → seed app buckets only; NEVER recount totals.
- Clear History erases History + ledger. Clear Vocabulary removes user terms and restores surviving bundled terms' shipped surfaces.
- Diagnostics MUST include build/backend/model/health/permissions/microphone/session-count/agent-session-binding on-off/storage paths. NEVER transcript text, agent session ids or session paths.

## Local-first and network policy

- Only compiled model URL: Granite's pinned host/repository/revision and digest. NEVER network text processing, telemetry, crash reporting, accounts, update checks, arbitrary URLs, or a second recognizer beyond `granite`.
- Agent session binding reads, only while it is on and only on this Mac: the decoded focus, window-client, pane-id, identity-method and `omp_session_file` fields of `tern` output; the process-table entry, executable path and open file paths of the pane's foreground process and of processes on its terminal; `~/.omp/agent/terminal-sessions/<tty>`; the bound omp session file's head and appended records; `~/.claude/sessions/<pid>.json` records; `~/.claude/history.jsonl` records of the bound session id; title records of `~/.claude/projects/*/<sessionId>.jsonl`. NEVER written, uploaded, logged, or used for anything but binding History rows.
- Sidecar env allowlist: `PATH`, `HOME`, `TMPDIR`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` + lowercase forms, `SSL_CERT_FILE`, `VOICEOUR_*`. NEVER inherit full parent env. Always write `VOICEOUR_ASR_BACKEND`, `VOICEOUR_PRELOAD=1`.
- No credential UI, credential environment contract, configurable base URL, secret store, or keychain item. `Resources/Voiceour.entitlements`: audio-input only; no provisioning profile. Data-protection Keychain is unavailable: `SecItemAdd` returns `errSecMissingEntitlement` (-34018); ad-hoc `keychain-access-groups` fails AMFI. NEVER add a feature depending on it.

## Agent session binding

Binds a History row to the omp or Claude Code session running in Tern's focused pane, exactly or not at all; NEVER infer a session from text similarity across sessions. Coordinator: `AgentSessionLinking.swift`. Ports: `AgentSessionResolving` (`LiveAgentSessionResolver`) and `AgentSessionReading` (`AgentSessionFileReader`); the send check is `AgentPromptSendMatcher`.

- Gates, all REQUIRED: `Settings.agentSessionBindingEnabled` (`agent_session_binding_enabled`, off by default); the History row exists; outcome `.pasteAttempted`; delivery target `.normalText` with bundle id `so.stencil.tern`. Tern is the only host; omp and Claude Code are the only agents; Codex is never bound. Rows delivered while the setting was off stay unbound.
- Timing: `capture(target:)` starts off-main right after the delivery snapshot, which is also `boundAt`, and records Tern's focused pane and foreground pid. After the row's outcome is written, `resolve(target:before:)` runs off-main and binds only when the same pane and the same foreground pid have focus after the paste. Neither delays delivery, state changes or the next dictation. One capture or resolve runs at a time per resolver; a `tern` timeout skips all binding work for 10 s.
- Resolution, any failure → no binding: exactly one window client, all its identity hops `local`; the shown session's shown tab's focused block equals `tern process @focused`'s pane and the captured pane; the pane's hops all `local`; Tern's focused AX element (250 ms messaging timeout) has role `AXTextArea` and title `Terminal input` or `Terminal`; the foreground process is alive, same uid, has a controlling tty, leads its tty's foreground process group, and shares the pane shell's tty. The agent comes from the executable path and name only.
- omp identity: Tern's `omp_session_file` for the pane and the foreground process's open `~/.omp/agent/sessions/<dir>/<ISO>Z_<uuid>.jsonl` (depth exactly one) MUST name the same standardized path when both are present. Only when both are absent, line 2 of `~/.omp/agent/terminal-sessions/<tty>` counts, if its mtime ≥ the process start and no other live omp process shares the tty. The session id is the filename's UUID; a not-yet-written file still binds, unresumable until it exists.
- Claude Code identity: `~/.claude/sessions/<pid>.json` whose `pid` matches and whose `procStart` is within ±1 s of the kernel start time; a `parkedJobId` follows to exactly one live, same-uid, non-spare `bg` record with that `jobId` and a matching `procStart`. Title: `name` unless `nameSource` is `derived`, else the last `custom-title`/`ai-title` record in the last 256 KB of `~/.claude/projects/*/<sessionId>.jsonl`.
- `tern` CLI: runs only from `Contents/MacOS/tern` of the `so.stencil.tern` process being pasted into, after both that running code and that file satisfy `identifier "so.stencil.tern" and anchor apple generic and certificate leaf[subject.OU] = "VTLHGQC72S"` (the file check is cached by device, inode, size and mtime). Only `process @focused --json` and `inspect --json`: argv only, environment exactly `HOME` and `PATH=/usr/bin:/bin`, stdin/stderr `/dev/null`, stdout drained concurrently and capped at 1 MiB, 1 s deadline → SIGTERM → 100 ms bounded join → SIGKILL; NEVER `waitUntilExit()`. Non-zero exit, cap overrun or timeout → no binding. Decode only the fields the checks need; NEVER keep argv, cwd, titles or raw output, and zero the output buffer after decoding.
- Process inspection: process-table entry (uid, process group, terminal foreground group, tty, start time, name), executable path and open file paths only. NEVER read another process's argv or environment (`KERN_PROCARGS`, `KERN_PROCARGS2`, `KERN_PROCENV`).
- File access: open only canonical (`realpath`) paths under `~/.omp/agent/` or `~/.claude/`; an omp session file elsewhere binds by its filename id and nothing is read from it. Session heads ≤ 64 KB. NEVER read Claude Code's `.key` files or open or stat a working directory; working directories stay strings.
- Ownership: the coordinator owns each row's binding task (`agentBindingTasks`, identity-checked removal) and one refresh task. Binding uses `currentToken(.agentLinking)`, NEVER `begin`. Quit cancels every task; Clear History and turning the setting off invalidate `.agentLinking` and cancel them; deleting a row cancels its task; cancelling a later dictation touches none. Cancellation terminates in-flight `tern` children. A binding attaches once through the journal FIFO only while the token is current, the setting is on, termination has not begun, and the row exists unbound.
- Send check: `refreshAgentSessions()` runs single-flight with a rerun flag, on History appear, row-set change, selection, and after a binding attaches. Candidates: bound rows with `send == nil`, or untitled or unresumable rows inside the send window. Off-main, `AgentSessionReading` reads only the bound session's records — the omp session file's user messages, or `~/.claude/history.jsonl` lines of the bound id decoding only `sessionId`, `timestamp`, `display`, `pastedContents` — starting 256 KiB before `promptLogOffset`, which is measured when the binding resolves, a moment after the paste; when the file shrank, the offset is not at a line start, or there is none, it reads the last 16 MiB instead. It reads at most 16 MiB, NEVER parses a partial line, and keeps only prompts sent from 1 s before `boundAt`: `boundAt` precedes the paste, so an earlier matching prompt is another prompt with the same words. A Claude Code title is the live registry `name` unless `nameSource` is `derived`, else the transcript's last `custom-title`/`ai-title`. `AgentPromptSendMatcher` takes the earliest prompt within 30 minutes of `boundAt` whose tokens align with the dictation at score ≥ 0.6, or, under three dictation tokens, equal the prompt's leading or trailing tokens → `.sent`, storing the matching part of the prompt only when it differs from the delivered text after whitespace collapse; none once the window closes → `.notSent`; a session that cannot be read stays pending. Results apply under the attach gates, change only differing fields, and write the journal once per pass. Changing matcher thresholds requires measured counts on real History.

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
- Run/dev flags use `ARGS`, e.g. `make run ARGS="--debug --show-console"`. Supported: `--debug`, `--show-console`, `--console-section=<home|glossary|history|settings>` (`history` opens the Journal tab), `--no-activate`, `--asr-backend <id>`, `--self-test`; `--ui-harness` only with `-DUI_HARNESS`.
- Logs: subsystem `com.voiceour.app`, categories `hotkey`, `audio`, `model` (retired model-cache sweep failures). `stop-path` signposts require Instruments/`xctrace`.
