# Voiceour engineering contract

You maintain Voiceour: local-only macOS dictation. Ship complete, verified changes. Correctness first; simple, maintainable code second.

<system-conventions>
RFC 2119 applies to MUST, REQUIRED, SHOULD, RECOMMENDED, MAY, OPTIONAL. NEVER = MUST NOT; AVOID = SHOULD NOT.
README.md owns the product contract. AGENTS.md owns engineering invariants and execution rules. Research and specialist docs provide evidence, not competing requirements.
</system-conventions>

<critical>
- MUST preserve local recognition, deterministic text processing, and explicit-only vocabulary learning.
- Only `.normalText` may paste. Secure delivery: concealed, host-only copy; no History or ledger entry.
- NEVER read, save, or restore the user's previous clipboard. NEVER retain recorded audio.
- Default verification MUST stay offscreen and silent. Window activation, live keystrokes, speaker playback, or microphone capture require agreement to that specific interruption. “Test end-to-end” is not permission.
- MUST preserve unrelated user work. Small verified changes get separate scoped commits and push directly to `origin/main` by default.
- MUST use tools to verify claims. Keep working until the requested result is verified or a concrete blocker is established. NEVER report unrun checks as passing.
</critical>

<communication>
Lead with the result. State changes, evidence, risks, blockers. Use exact paths, symbols, commands. No ceremony, filler, repeated summaries, or narrated internal reasoning.
</communication>

<workflow>
1. Inspect relevant code, tests, contracts, and existing changes. Resolve repo-answerable questions with tools. Plan multi-file changes before editing.
2. Fix the cause. Reuse existing patterns. Change only requested behavior; migrate affected callers; remove obsolete code. NEVER hide failures or add compatibility shims for internal APIs.
3. Run the smallest meaningful check, then required gates. Exercise changed behavior; compilation alone is not runtime proof. Use external results to fix failures, not self-assessment.
4. Update the owning contract and affected tests. Commit each completed, verified concern separately; push directly to `origin/main`. Preserve unrelated user changes; report verification and blockers.
</workflow>

## Architecture boundaries

Platform: Swift tools 6.4, Swift 6 language mode, macOS 27, arm64 only. Names: `Voiceour` app/target; `voiceour` package/repository. NEVER rename without instruction.

| path / target | responsibility / boundary |
| --- | --- |
| `Sources/VoiceCore/` | Foundation-only models, settings, state, text stages, glossary, ASR wire types, history/ledger, failures, safety policy |
| `Sources/VoiceMac/` | macOS adapters: capture, fake audio, sidecar, focus, pasteboard, permissions, hotkeys, muting, installed apps, word-list import; NEVER SwiftUI |
| `Sources/Voiceour/` | SwiftUI and orchestration; `DictationCoordinator` stays `@MainActor`; stop path in `TranscriptProcessingPipeline.swift` |
| `Sources/ASRSidecarCore/` | Acquisition/cache, WAV, Parakeet context/token mapping, optional CoreML, backends, server; imports `VoiceCore` + `CParakeet`, NEVER `VoiceMac` |
| `Sources/VoiceourASR/` | Signed sibling `voiceour-asr`; vendored parakeet.cpp/ggml; NDJSON v1 |
| `Sources/VoiceourBench/` | `voiceour-bench`: production-path measurement |
| `Sources/ASRSidecarStub/`, `Sources/ParakeetMixedQuantize/` | `ASRSidecarStub` protocol helper / `parakeet-mixed-quantize` research tool; non-shipping |
| `Sources/Voiceour/UIHarness/` | Compile-gated scene/flow renderer, AX/PNG reports, lint, mercury benchmark |
| `Vendor/parakeet/` | Native sources, pin, ordered patches, embedded Metal |
| `Tests/`, `fixtures/protocol/`, `fixtures/ui/` | Swift Testing suites; protocol-v1 fixtures; AX/digest/flow goldens |
| `bench/`, `benchmarks/` | Non-shipping Python tooling; prepared data and committed measurement reports |
| `scripts/`, `docs/`, `research/` | Workflows; specialist appendices; dated experiments |

- `VoiceCore` MUST NOT import AppKit, SwiftUI, AVFoundation, Accessibility, event posting, pasteboard, process-launch, or Keychain APIs. Put OS side effects behind `VoiceMac` contracts.
- Production targets MUST NOT import `Voiceour`; tests may.
- MUST preserve injection for recording, ASR, targets, insertion, permissions, hotkeys, muting, settings, recent sessions.
- `../syncour` consumes `VoiceCore` and `VoiceMac` by path dependency. Their public APIs are external contracts; Syncour's owner handles its platform/toolchain migration.
- Registered backends: `parakeet` (production default), `fake` (deterministic development). Retired `mlx`, `ark-0.6b`, `ark-3b`, `apple` ids normalize to `parakeet`.
- `voiceour-asr` is the only child process. Pinned model acquisition is the only network path.

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
- Muting applies only to Parakeet. Start cue before mute; begin restore immediately when capture ends, without awaiting the 120 ms fade; end cue after restore.
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

## Text pipeline

Order: `LiteralComposition.apply` always; `CleanupEngine.clean` + `VocabularyRepairEngine.repair` only when `Settings.cleanupEnabled`. Pure functions of transcript + utterance vocabulary snapshot. Empty output → `cancelled`. History keeps raw ASR and final text; least-confident word comes from raw words.

- Literal commands: `spell`, `spell that`, `letter by letter` / `letter-by-letter`, `literal`, `snake case`, `camel case`, `capital` / `uppercase`, `dash`, `dash dash`, `dot`, `underscore`. Whole-word, case-insensitive matching; runs cross single spaces and end at punctuation. No match → unchanged input. Standalone symbol words apply anywhere, including prose.
- Cleanup: normalize whitespace; remove fixed `um`, `uh`, `uhm`, `erm`, `mmm`, `hmm`; collapse immediate repeats up to four words; repair sentence case only when deletion exposes an all-lower-case token and the original sentence was capitalized; then `Glossary.canonicalize`.
- Protected from filler removal/recasing: glossary surfaces; tokens starting with `-` or containing `/`, `~`, `_`, digits, or internal capitals. MUST shelter multi-word glossary surfaces by applying the deletion passes to detect damage, not by duplicating their rules.
- Canonicalization MUST gather canonical/user/derived alias matches against original text, resolve longest-first then leftmost, apply right-to-left. Escape replacements with `NSRegularExpression.escapedTemplate`. `Glossary.derivedAliases`: `SwiftUI` → `swift ui`, `swift u i`; single-letter aliases and all-digit canonicals never generalize.
- Repair: exact aliases first/longest; highest-scoring phonetic candidates then occupy unclaimed spans of up to five words. `RepairVocabulary.frozenPhoneticThreshold = 0.95`; lowering it requires safety evidence, not a better score.
- Ordinary-English and ≤2-character canonicals MUST NOT be repair targets; protect their occurrences. Reject multi-word phonetic candidates composed entirely of ordinary words. Only `a` and `i` count as ordinary single letters.
- Cache the repair engine by ordered active canonicals; rebuild only when those change. `voiceour-bench pipeline` repairs only with `--vocabulary`; the sidecar never repairs its own transcript.
- `VocabularyCompiler.compile`: ≤100 terms; explicit corrections/protected terms (including bundled defaults) first; then trust, recency, index order with source quotas/backfill. Terms apply globally, never by app/project.
- Ordinary-word resource: `Sources/VoiceCore/Resources/ordinary-words.txt`, generated by `scripts/generate_ordinary_words.py` from frozen research vocabulary. `RepairVocabulary.bundledOrdinaryWords` uses packaged `voiceour_VoiceCore.bundle` or `Bundle.module`. Missing/unreadable list → precondition failure; bundling requires the resource bundle; bundle verification requires a non-empty list.
- `CandidateRetrieval` uses the utterance's vocabulary snapshot after delivery, on a detached utility task over final text; accept results only for the current generation; clear at next recording. Suggestions never edit delivered text or the target. Secure-target retrieval currently also runs; persistence still requires explicit acceptance.

## Glossary rules

- MUST reject generalizable aliases colliding case-insensitively with another canonical or alias. Enforce in Teach, Glossary add/save, suggestion acceptance, import. Reject the whole ambiguous proposal; validate the merged import before assignment.
- Import shapes: JSON spelling array, rows such as `[{"term":"kubectl","heard_as":["Qbectal"]}]`, or newline spellings. MUST filter unsafe/oversized surfaces with `VocabularySanitizer.isSafe`, not clean them; deduplicate case-insensitively against canonical and aliases. One invalid form MUST NOT discard valid forms in its row.
- `WordListLimits`: 500 terms, 64 characters/term, 8 aliases/term. Imported terms: unprotected `manualImport`.
- Confirm/reject/import/remove/clear vocabulary only on explicit user action. Background learning is forbidden.
- Both editors expose Term + Heard as inputs and read-only *Also matched* derived forms.
- History ⌘T on an owned surface MUST open its existing term, canonical and full user-alias set; save using that term id/full-set semantics. Unowned surface → blank canonical, additive save.
- Teach shows an empty additional-form field only when its form set is empty. Glossary editors always show it.

## Persistence

- Support directory: `~/Library/Application Support/Voiceour/`, overridden verbatim by `VOICEOUR_SUPPORT_DIR`. Files: `settings.json`, `recent-sessions.json`, `dictation-activity.json`; mute ownership: `mute-owned.flag`.
- Settings/history/ledger writes MUST be owner-only, atomic per file, off-main, on one detached FIFO tail. No cross-file transaction. History write failure MUST report “Dictation history could not be saved.” without blocking delivery or later saves.
- Unreadable settings/history/ledger → quarantine as `<name>.corrupt-<ISO8601>` and report reset + filename. Island values NEVER trigger it: `Settings.island` falls back per field ([Recording island](#recording-island)). NEVER suppress write failures.
- History: one file, newest-first, max 500. Fold ledger from the same journaled row in the same main-actor turn; enqueue both snapshots. Secure target → neither; every other disposition → both. Home and first-run checks read both records.
- Ledger: sessions/words/seconds by local day and destination bundle id; totals, active days, longest streak; no text/session ids. Prune day buckets >400 days before the recorded day, preserving totals, active-day count, and longest streak. Empty ledger → remove file. Retired `dictation-stats.json` is swept at launch.
- App buckets MUST NOT be capped/pruned. Keep sessions/words/seconds, last non-nil display name, latest day key.
- Missing ledger → seed once from remaining History. Missing `captureMs` contributes words and zero seconds. `totalSessions > 0 && apps.isEmpty` → seed app buckets only; NEVER recount totals.
- Clear History erases History + ledger. Clear Vocabulary removes user terms and restores surviving bundled terms' shipped surfaces.
- Diagnostics MUST include build/backend/model/health/permissions/microphone/session-count/storage paths. NEVER transcript text.

## ASR sidecar protocol

NDJSON v1 over stdin/stdout; stdout protocol-only, stderr continuously drained.

- MUST validate version 1 on every response, not just `hello`; mismatch is connection-fatal.
- Startup `hello`: sidecar version, backend id/status, capabilities. Requests: `health`, `transcribe`, `cancel`.
- Decode work serialized; health/cancel remain readable on the reader thread. Every decode request MUST produce exactly one terminal `result`, `error`, or `cancelled` with the original request id.
- `health`: `ready`, `model_loaded`, `cache_ok`; optional download fraction, warming state, unresolved acquisition failure. Failure = `ASRErrorCode` + diagnostic detail; both omission and presence MUST decode. No parallel taxonomy.
- `transcribe`: id, WAV metadata, `expected_model` (`model_id`, `revision`, `file`), timeout. WAV header is authoritative: 16 kHz mono 16-bit PCM. Dictation client deadline 30 s; timeout → `cancel`, 500 ms grace, kill child.
- Request handling NEVER downloads. Cold cache → immediate `model_not_installed`; preload thread acquires.
- MUST preserve ids end-to-end. Valid responses for retired ids are stale work, not framing errors.
- One persistent sidecar/client. Timeout, malformed frame, EOF, crash → fail pending work; allow later clean spawn. Inference failure → terminal error then sidecar exit.
- Line reader MUST pass exact `Data`; validate UTF-8 and reject literal NUL before Foundation's UTF-16/32 detection. NEVER repair malformed bytes; preserve legitimately encoded replacement characters.
- Invalid JSON/schema/type/version → fail all pending requests and terminate that process. Identity checks MUST discard buffered valid tails and stale callbacks. Invalid greeting → `incompatibleHello`; EOF before greeting → `noHello`.
- Server owns preload thread; set shutdown before EOF exit; bounded joins only. NEVER follow bounded shutdown with unbounded Darwin `waitUntilExit()`.
- Successful load MUST clear both load-failure and acquisition-failure latches. Sidecar owns acquisition diagnosis; app infers only where the sidecar states nothing.
- Serialize model-context construction/freeing under load ownership; concurrent contexts can destroy ggml's shared Metal device. Idle release after 30 minutes; next request reloads.
- MUST change protocol models, client/server encoding, and `fixtures/protocol/` together.

## Model contract and vendor rules

Model `ggml-org/parakeet-GGUF`, revision `35156454d1a39de06863303dd209fd2bed6ee079`; two conversions of one checkpoint:

| variant | file | SHA-256 | bytes |
| --- | --- | --- | ---: |
| `f16` — Balanced | `ggml-parakeet-tdt-0.6b-v3-f16.bin` | `833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f` | 1,255,897,319 |
| `q8_0` — Compact | `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | `4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e` | 668,757,119 |

- Default/unknown/stale value → `f16`. `q8_0` artifact is 587 MB smaller. Corpus cannot resolve an accuracy difference. NEVER claim superior accuracy or unqualified speed; changing default requires cross-SoC replication + [paired real-speaker gate](docs/benchmarks.md#paired-fixed-corpus-promotion-gate). [Dated measurements](docs/performance-roadmap.md) are not shipping promises.
- MUST update id/revision/filenames/digests/sizes, descriptors, manifest, README, AGENTS, NOTICE, fixtures, tests as one contract. `make check-docs` extracts pins from `Sources/VoiceCore/ASRProtocol.swift`; both root docs MUST name/hash every variant.
- Cache root: `~/Library/Caches/Voiceour/`. Preserve `f16` directory `parakeet-tdt-0.6b-v3-ggml`; `q8_0` uses `parakeet-tdt-0.6b-v3-ggml-q8_0`. `manifest.json`: `model_id`, `revision`, `file`, `sha256`, `size_bytes`.
- `cacheOK` = full manifest matches selected pin AND file size matches; no hash here. Download completion verifies digest. Load failure rehashes; mismatch removes artifact/manifest/base arena and reacquires once/process.
- Acquisition: preload thread only; ephemeral session; three resumable attempts; remaining bytes + 256 MiB free required before fetching.
- Selection precedence: `VOICEOUR_MODEL_VARIANT` > persisted `asr_model_variant`; invalid env → `f16`. App MUST write resolved variant last/unconditionally to model-backed sidecar env. Every decode MUST carry `expected_model.file`; shared id/revision cannot distinguish variants.
- Variant/backend changes require restart. Keep `DictationCoordinator.activeModelVariant` separate from `settings.asrModelVariant`; Settings shows *Restart to apply*. Restart removes `VOICEOUR_ASR_BACKEND` + `VOICEOUR_MODEL_VARIANT` overrides.
- One artifact resident. Delete other variant directories only after selected weights load successfully, never at selection time. NEVER prune under caller-owned `VOICEOUR_MODEL_CACHE`. Changing `HOME` does not relocate the cache; cold-download checks need an explicit empty cache directory.
- Derived `weights-<sha256>-<size>.arena`: exact layout manifest, cross-process `flock`, physically reserved storage, fsynced temporaries, atomic rename. Warm mapping is read-only after manifest match. Stale/partial arena → rebuild; creation failure → ordinary buffers. Artifact + arena ≈ twice artifact size.
- Vendor pin: `ggml-org/whisper.cpp` commit `592feef04a1802b18cbeffd0fd0eb5d02570c2ec` (v1.9.2 lineage); preserve upstream-relative paths.
- Every upstream-file change MUST carry `VOICEOUR PATCH`, an ordered `patches/*.patch`, and a `Vendor/parakeet/NOTICE.md` entry. Fix warnings at source; NEVER suppress them.
- `scripts/vendor_parakeet.sh --check`: exact file set + byte-reproducible embedded Metal; with upstream checkout, exact pin-plus-patches equality.
- NEVER add `-mcpu=native` or attempt a universal build. `Vendor/parakeet/ggml/embed/ggml-metal-embed.c` enforces arm64. Intel would require x86 `ggml/src/ggml-cpu/arch/x86/{quants.c,repack.cpp}`, manifest/NOTICE changes, and per-architecture targets: SwiftPM has no architecture build condition.

## Environment seams

Overrides apply to one run, never persist settings. App code MUST NOT enable experimental sidecar seams.

| variable | reader / contract |
| --- | --- |
| `VOICEOUR_ASR_BACKEND` | App: `--asr-backend` > env > persisted setting (`fake` only with `--debug`) > `parakeet`. Standalone sidecar default: `fake`. |
| `VOICEOUR_MODEL_VARIANT` | App/sidecar: `f16` or `q8_0`; overrides Settings. |
| `VOICEOUR_MODEL_CACHE` | Sidecar: caller-owned single directory; no variant subdirectory or pruning. |
| `VOICEOUR_SUPPORT_DIR` | App: exact support-directory replacement. |
| `VOICEOUR_PRELOAD` | Sidecar: `1` starts preload; app always sets it. |
| `VOICEOUR_IDLE_UNLOAD_MS` | Sidecar: default 1,800,000 ms; ≤0 disables idle release. |
| `VOICEOUR_ASR_LOG` | Sidecar: `debug`, `warn`, `error`, `none`; default info. |
| `VOICEOUR_FAKE_DELAY_MS` | Fake backend: transcription delay for cancellation tests. |
| `VOICEOUR_COREML_ENCODER_TINY`, `VOICEOUR_COREML_ENCODER_SHORT`, `VOICEOUR_COREML_ENCODER` | Sidecar: experimental tiers covering ≤6/8/15 s respectively. |
| `VOICEOUR_COREML_TINY_MAX_S`, `VOICEOUR_COREML_SHORT_MAX_S`, `VOICEOUR_COREML_MAX_S` | Lower the corresponding bound only; raising it fails. |
| `VOICEOUR_COREML_WARM` | `tiers` primes configured tiers on each context creation. |
| `VOICEOUR_TAIL_BACKEND` | `cpu` selects CPU/Accelerate TDT prediction/joint tail. |
| `VOICEOUR_TAIL_QUANT` | `q8_0`: CPU-tail-only repack of seven 2-D f16 matmul weights. |
| `VOICEOUR_CPU_POOL` | `persistent`: one ggml CPU threadpool sized to decode threads. |
| `VOICEOUR_ASSIST_MODEL`, `VOICEOUR_ASSIST_MODEL_2` … `_5`; `VOICEOUR_ASSIST_MAX_S`, `VOICEOUR_ASSIST_MODEL_3_MAX_S` … `_5_MAX_S` | Research-only second-opinion models/caps; configured-model failure is fatal. |
| `VOICEOUR_PARAKEET_INTEGRATION`, `VOICEOUR_CAPTURE_INTEGRATION` | Tests: set `1` to opt into real model / real microphone suites. |
| `VOICEOUR_CODESIGN_IDENTITY`, `VOICEOUR_CODESIGN_KEYCHAIN` | `scripts/bundle.sh`: signing pins; [precedence below](#macos-permissions-and-signing). |
| `VOICEOUR_REPO_ROOT` | Harness / `scripts/console_shot.sh`: fixture/capture root. |

Experimental constraints:

- Unknown seam values other than unset/`default` MUST fail startup. Validate CoreML paths/bounds during backend construction: existing `.mlmodelc` or `.mlpackage`, in-range bound. NEVER silently fall back to Metal.
- Shortest configured CoreML tier covering the utterance wins; longer audio uses native execution. Tiers load lazily; load/prediction failure fails that request, not retries elsewhere.
- `VOICEOUR_TAIL_QUANT=q8_0` preserves pinned artifact bytes/digest; caches separate `.tail-q8` arena. Zero converted records → load failure.
- `VOICEOUR_COREML_WARM=tiers`: own thread, throwaway clients, no decode state/lock. Prime failure logs and remains lazy. Cold ANE specialization ≈20 s/tier; system cache is purgeable.
- Experimental paths are deterministic, not byte-identical to native Metal. Non-inferiority evidence: `research/bet2-ane-encoder.md`, `research/bet3-quantization.md`. No compiled encoder artifacts ship.
- Benchmark-only `voiceour-bench external-encoder --engine coreai`: static 15 s Core AI versus one CoreML tier; native mel + four-thread ggml tail. ABI: `mel` float32 `[1,128,1501]`, `mel_length` int32 `[1]`, `encoder` float32 `[1,1024,188]`, `encoder_length` int32 `[1]`. `ParakeetContext.nativeMel` copies frame-major mel for async use; external-state decode retains mel recomputation. App/backend/env/settings MUST NOT select Core AI. [Experiment reference](docs/benchmarks.md#core-ai-encoder-experiment).

## Native UI contract

### Console

- Native `Window("Voiceour", id: "main")`, one `TabView`: Home, Glossary, History, Settings. Three grouped `Form`s; Home is a figures page. Last tab reopens unless first-run guidance requires Home.
- MUST use native controls: `TabView`, grouped `Form`, `Section`, `Toggle`, `Picker`, `TextField`, `LabeledContent`, `Button`, `Slider`, `ColorPicker`, `DisclosureGroup`, search, context menus. NEVER custom chrome, control skins, forced dark window appearance. Preserve system accent, focus, metrics, VoiceOver, accessibility settings.
- Sliders: integer UI units with an explicit `step`; `.labelsHidden()` + `.accessibilityLabel`/`.accessibilityValue` (the spoken readout); trailing monospaced readout, hidden from AX. NEVER `minimumValueLabel`/`maximumValueLabel`: they publish tiny step buttons (`tiny-hit-target`). Radio `Picker`s stay direct Form rows; an `HStack` wrapper splits one into a group per item.
- Destructive actions MUST use titled native confirmation dialogs with destructive roles.
- App styling inside Forms: monospaced code values, `ConsoleStateMark`, `ConsoleCaption`, `ConsoleRow`, `MeterBar`, the Island showroom (production `MercurySurface`). Native-plate meters/marks use system semantic colours; `StatusChip` uses app palette.
- Ground: `NSGlassEffectView(style: .regular)` behind native section plates; no app tint. Clear only `NSWindow.isOpaque` + `backgroundColor`. Reduce Transparency → `windowBackgroundColor`. NEVER place text directly on sampled desktop or use SwiftUI `.glassEffect` in shipping views.
- Settings order: Dictation, Audio, Model, debug-only Backend, Island, Readiness, Capture, Privacy, Danger. No General tab.
- Home/Settings MUST share `ConsoleReadiness` values, sentences, remediation. `DictationPolicy.owesFirstRunGuidance` = `Settings.hasCompletedFirstRun == false` AND both durable records empty; missing flag defaults false. `completeFirstRun()` stays outside the journaling branch: secure delivery completes onboarding; refusal/cancel/failed decode does not.
- All showing routes MUST use `ConsolePresentation`: menu, `--show-console`, `applicationShouldHandleReopen` (Dock, `open -a`, reopening), `onAppear`. Console open → `.regular`, front/deminiaturized; close → `.accessory`. `--no-activate` or `.prohibited` → no presentation management. Disable miniaturization and restoration.

### History

- Exactly one open transcript; its own grouped `Section` directly below selected row, inside that day. Each day names itself once and renders one–three plates.
- Closed rows: stamp, outcome mark, word count, destination icon/name, two-line preview. While one opens, others fade to 0.45 (0.8 under Increase Contrast). Open heading omits preview.
- Transcript is the control; no detail action buttons. Single click copies all delivered text as a plain, non-transient string; transient COPIED TO CLIPBOARD mark + VoiceOver confirmation. Selection/right-click `Fix / Teach “word”` + ⌘T teaches. One footer: selected teaching surface, instruction, or copy confirmation.
- `HistoryInputMonitor`: margin click/Escape close; ⌘T teaches. Transcript MUST expose named copy/teach accessibility actions.
- Row context menu: Copy Transcript, Fix / Teach a Word, Show Only *App*, Delete.
- Raw (only when different) and Details MUST be sibling `DisclosureGroup`s, independent bindings, both closed on each newly opened transcript. Details: Target (friendly app + non-normal safety chip), Timings, least-sure word. No evidence → omit Details. Labels MUST carry ids + explicit default AX actions; the SwiftUI triangle reports successful press without toggling.
- Search + app filter are ANDed. `Menu`-wrapped inline `Picker` exists only with delivery-target rows. Facets: count descending, display label, bundle id; app name from newest row. One `N of M sessions match` caption. Last matching app row disappears → drop filter. Menu re-sorts resolved labels; `RecentSessionQuery.appFacets` preserves its pure order.
- `AppIdentity`: installed Finder display name > persisted name > `AppDisplayName.label(bundleId:name:)`; bundle id stays key, never display label. Icon: Home badge (monogram if uninstalled), History `Control.inlineIcon`; Target/filter chip have names only.
- `InstalledAppCatalog`: sole bundle-id LaunchServices lookup, main-actor/process-lifetime cached. `RenderOverrides.installedApps` pins goldens. Live menu *Will paste into* uses `AppDisplayName` directly.

### Visual vocabulary

`DesignTokens.swift` owns values. App palette belongs to menu, island, Home only.

| token / role | contract |
| --- | --- |
| `Ink.void` | opaque sRGB (0.02, 0.03, 0.05) |
| `Text.high`, `Text.mid`, `Text.low` | (0.89, 0.91, 0.95); (0.64, 0.71, 0.80); (0.51, 0.56, 0.64) |
| cyan / mint / amber / crimson | active-live-focus / success / degraded-waiting / failure-destructive |
| `micro`, `caption`, `label` | 10 / 12 / 13 pt |
| `tileValue`, `metric`, `heroMetric` | 20 / 32 / 64 pt |
| `hair`, `xs`, `sm`, `md`, `lg`, `xl` | 2 / 4 / 8 / 12 / 16 / 24 pt |
| controls | 24 / 28 / 32 / 40 pt; compact status marks: 20 pt |

- One dominant signal colour/view. `Alien.bloom`/heat ladder: Home fill/glyph/glow only, NEVER text. Four steps = quartiles of busiest day; Differentiate Without Color substitutes size steps at one hue.
- `OnGlass` cyan/mint/amber/crimson: system-glass text only, ≥4.5:1 against white and black; not painted/opaque grounds.
- Home islands remain fixed-dark in either appearance. Paint `Ink.pane` + `glassTint` + specular/`Alien` rims; NEVER stack another material over the glass ground. Declare `surfaceGround` for contrast lint.
- `MenuBarExtra(.window)`: 280 pt, three whitespace-separated blocks: Status (state, optional mute, Fn, headline), Report (failure/transcript/outcome; absent when empty), Actions (primary + grouped commands). Download/warmup MUST stay visible; re-poll health while acquisition advances.
- Motion: quick 0.14 s, standard 0.18 s, deliberate 0.22 s. MUST respect Reduce Motion. Animate menu report/state resizing; native console keeps system behavior; resting settings stay static except the Island showroom (live only while visible, still under Reduce Motion).
- Controls MUST have stable human labels. NEVER encode state only in colour. Chips/marks carry words; Differentiate Without Color adds symbols. Captions stay separate from control AX labels. Gesture-only behavior requires named AX actions; completion announces.

### Recording island

- Clear borderless nonactivating panel, NEVER key/main; level `.mainMenu + 3` (above the macOS 27 menu bar window at 24, below open menus at 101); `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.canJoinAllApplications`. `RecordingOverlayLayout.forDisplay`: constructible camera housing → collar, else island. Island: 260×80 pt panel; centred body envelope 180×34 pt, 44 pt below visible top, centred, 16 pt screen margin; remainder is transparent bleed. Collar: panel = canvas (314×59 pt around a 185×32 housing), centred on the housing, flush with the display's top edge; the body frames the housing outline under its own 24 pt ceiling (`MercurySpine.maxHalfHeight`; the island's is 17), every collar rung's depth ×24/17; taper: full body along the bottom, corners and walls, 3.5 pt band film along the fillets and ears, a 12 pt smoothstep down each wall from its fillet; containment holds every station beside a wall short of its bisector with the screen's top edge (`MercurySpine.reach(at:under:)`), NEVER the ceiling alone; status frame = housing width × 27 pt directly under it.
- Display: focused app's frontmost-window display > pointer display. `RecordingOverlayMovePolicy` decides moves: a click waits 0.12 s for the activation it may cause; focus moves at once; a return to a display left <1.5 s ago must persist 0.4 s; 3 moves within 5 s make later moves instant until 3 s pass without one; an outcome dwell, a live drag, or a session the user placed (drag or Dock island) freezes the panel; a reconfiguration waits for 0.3 s of quiet. A move is a siphon (`RecordingOverlayConductor`, substep clock): drain (idle pose, lean ±1 toward the destination) until `L·H` < 1 pt² or 48 substeps, re-frame the EMPTY panel, emerge with arrival sway ±60 pt/s away from the source side + aspect −1.2 s⁻¹, settled after 60 substeps. Reduce Motion and storm moves re-frame at once, no drain or arrival. NEVER re-frame a visible body. `refreshTarget()` runs on the next main-actor turn after a re-frame, never during a drain.
- Placement (`RecordingOverlayPlacement`): docked = collar at a constructible housing, else the island's default spot; free `(u, v)` = the island envelope's origin normalized in the display's `screenPadding`-inset visible-frame origin range, an island at the same relative spot on every display, notched ones included; NEVER absolute monitor pinning. Every layout, session start and hand-off follows it. Persisted in `RenderOverrides.islandPlacementDefaults ?? UserDefaults.standard`, the one source the controller and Settings both read, as `Voiceour.RecordingOverlay.placement.u`/`.v`, absent = docked; the legacy `Voiceour.RecordingOverlay.origin.x`/`.y` are deleted at launch. Settings ▸ Island's Dock Island (`island.position.dock`), enabled only while the persisted placement is free, persists `.docked` and posts a notification the controller observes: a visible free island docks exactly as the Dock island action does (`dockIsland()`); a hidden one only takes the new placement.
- Drag (`RecordingOverlayDrag`, pure): direct manipulation from the hosting view's mouseDown/Dragged/Up, NEVER `performDrag` or a nested tracking loop. Docked body, pull <24 pt: panel stays, the pull rubber-bands the body as frame forcing `−κ·pull` on its spine axes, κ = 2500/3 s⁻² (24 pt leans 6 pt); released, it snaps back through the gel. At 24 pt: tear-off into a free island under the hand (grab offset kept, within the island canvas), the live body re-anchored on the island layout, NEVER reset or re-emerged, plus a snap arrival (sway 2.5·d_t pt/s, aspect −0.085·d_n s⁻¹ at the 24 pt pull; none under Reduce Motion). A free island follows the pointer at once, held in the padded visible frame. Release with the envelope centre ≤48 pt from the dock anchor (housing bottom centre; docked island centre) docks: into the collar by a relayout siphon (`RecordingOverlayConductor.relayout`), onto the island's dock by a 0.2 s critically damped glide (ω 35 rad/s, click-through), from farther by a siphon; Reduce Motion re-frames or jumps at once. Elsewhere it persists `.free(u, v)` for the display it is on. A dwell or hide ends a live drag where the body is.
- `RecordingOverlayPointerGate` drives `ignoresMouseEvents`, re-asked every presented frame and tracking-area event, written only on change: the panel takes the mouse only with the pointer on the drawn body (collar or island) within `dragSlop` and below the menu-bar band, and everywhere while a press on the body is held, so the drag's moves and release keep arriving; forced click-through while hidden or fading, through an outcome dwell, a hand-off and a glide. NEVER set `ignoresMouseEvents = false` unconditionally: it makes the whole panel a click sink.
- Pose context (controller-owned, written to the model only on change): lean −1…1 toward the frontmost window's centre from the anchor (housing midX or island centre) over half the display width, read on show and focus events, NEVER per frame; full screen = that window fills the display within 1 pt; pointer in the band within housing ±40 pt, read per frame; draining during a hand-off.
- CPU-rasterized `CGImage`; `MercuryField` alone defines pixels, drag hit-test, cursor silhouette. No capsule, glass, shadow, control disc, waveform, working mark, word, glyph, authored highlight, rim, painted tint.
- Physics/geometry/optics: every surface mode is a Zener gel (finite-depth capillary–gravity dispersion plus a relaxing Maxwell arm), advanced by the exact balanced Padé propagator, NEVER Euler; autonomous kicks are scaled by the exact discrete Lyapunov variance. Body shape (volume `L·H`, log-aspect, sway, skew, neck) advances by exact propagators inside Moreau walls; squash/stretch moves the aspect alone at constant volume; voice and panel motion are forces, pose steps load the arm. Half-elliptic crown at the look's fixed aspect, exact two-axis normal, static seed-drawn RGB room, bounded area sources, exact complex-index conductor Fresnel, two-anchor response with unreachable 0.94 linear-light ceiling. Room NEVER moves independently. User-chosen metal, coat, finish, room light, crown, body kit and motion law are physical inputs to that model (reflectance table, bake-time room, response targets, drawing transform, law constants), never authored colour, shading or motion. Rooms: Studio (Room of Ten, stock) and Overcast (Spectral Weather), both user choices; both MUST pass `make ui-mercury-bench`.
- Appearance: `Settings.island` (`IslandAppearance`, VoiceCore): integer UI units on fixed grids. Decode NEVER throws or quarantines over it: wrong type → that field stock; unknown metal/coat/room → stock; out of range → clamp + snap; non-object → whole island stock. Looks are derived (`IslandLook.matching`), never stored. `show()` latches the session seed and `MercuryLook(island: effectiveIsland)` (draft ?? committed) together, only while the panel is not visible: a show that reverses a fade or lands in an outcome dwell keeps the session, room and look it finds. The latched look dresses the island and the collar alike; NEVER apply a look mid-session.
- Stock: `MercuryLook.stock` (from `IslandAppearance.stock`) MUST render the stock renderer bit for bit on both layouts — pixels, geometry, responses and timing paths: its island and collar overlay goldens and its `make ui-mercury-bench` figures (timings aside) never move, and `MercuryStockBaselineTests` pins it against frozen digests. A look factor enters as one multiply by exactly 1.0 or a verbatim-equal constant, or as a step stock skips; NEVER algebraically rewrite a shipped expression.
- Look cost and metering: a look changes only bake-time inputs (its 1,024-entry μ→RGB paint table, read in the rasterizer's one Fresnel lerp through a pointer taken once per frame; room lighting; response) and per-instance scalars (crown aspect, law constants). NEVER add per-pixel work for a look. A look's response is metered per layout (island p98, collar p99 highlight) on its own tuned, body-kitted bodies under its paint, to `MercuryToneAnchors` targets; calibrated gains stay solved on the stock law.
- Tune (`MercuryTune`, [motion law](docs/mercury-renderer.md#motion-law)): each knob multiplies the gel's own constants in one multiplication, exactly 1 at stock. Tempo time-scales every surface mode's Zener law and viscosity its damping, each mode's voice force compensated for the following gain they change; shimmer scales the autonomous kicks (zero skips the draws); reactivity both calibrated gains; slither the contact-line gain and kicks; morph the body-shape laws (aspect, sway, skew, neck), NEVER the volume flow that paces emergence, swallow and the 48-substep hand-off drain; drama the lurch and collapse kicks. Ranges live in `MercuryTune` and `IslandGrids` together and stop where containment, stability or the hand-off would fail.
- Body kit (size, build, taper, crown): a drawing transform where the simulation emits `Geometry`; dynamics, containment and calibration stay on the stock law. Island: length ×size, edges ×size·build·G′/G, depth ×size·build. Collar: edges and depth alike, NEVER the length, which is the housing outline (moved stations would leave the `reach(at:under:)` proof). Crown on both. `endTaper ≤ gEnd` and `size·build ≤ 1` keep the drawn body inside the contained one.
- `MercurySurfaceView` MUST drive `NSView.displayLink(target:selector:)` on its window's screen, ≤120 fps. Physics fixed at 120 Hz: `MercuryClock` rounds each `targetTimestamp` to the nearest substep of a grid anchored on the first callback, one step per 120 Hz frame, two per 60 Hz frame; a stall >4 substeps presents 4 and re-anchors the grid on that frame; each rebuilt link's first callback MUST call `rephase` (the steps `steps` would present, then the grid moves ≤½ substep so that frame sits on its substep), later callbacks `steps`; NEVER reset the clock, including when the link is rebuilt for another display. Hidden/off-display → stop; screen change → rebuild. NEVER `TimelineView`, timer, or published SwiftUI frame clock.
- Panel motion reaches the body only through `MercuryPanelMotion`, a non-published object the controller writes at event rate and the surface reads in each live frame to replace `drive.forcing`: the tether's pull plus the panel's acceleration by central finite differences on the substep clock (exact for constant acceleration at any cadence), each component held to ±40 000 pt/s², in the panel's own sign. Pinned harness frames NEVER read it.
- Distinct listening/speaking/processing/unclean poses; processing is a held gathered pose, NEVER a working mark. `gathered`, `lurch`, `collapse` hold 1.2 s, click-through, without glyph/text/hue signaling: shape only, via squash (`gathered`), skew 0.4 + 8 pt offset (`lurch`), neck 0.7 (`collapse`); neck ≤0.85 keeps ≥15% of the waist, NEVER two bodies; every look keeps these silhouettes. Collar ladder along the housing outline (bottom `B`; per side corner `C`, wall `W`, fillet `F`, ear `E`): listening and speaking frame the notch, `B + 2C + 2W + 2F`, speaking deeper (`B + 2C` with the pointer in the menu-bar band; speaking over full screen adds `1.4E`), `collapse` `0.8B`, `gathered` 64×12 before the depth scaling; warming/processing/`lurch` keep island lengths. Draining and dismissing ask both ladders for idle. Paste, cancel, and a dwell's end dismiss without delay: the body swallows itself in the idle pose through the 0.18 s fade, then the panel orders out; Reduce Motion orders it out at once; paste/cancel withdraw the status element at once. Idle draws/publishes nothing.
- One fixed-frame `Dictation status` AX element; named Finish/Cancel actions, then "Dock island" while the island is free and the session live. Announce active states and unclean outcomes.
- Reduce Motion removes autonomous noise (shimmer and autonomous slither, whatever the look), emergence, body-shape gesture/arrival kicks, and squash/stretch overshoot (`L`, `H` critically damped, monotone; a takeover mid-swing projects `L̇`, `Ḣ` and the sway rate into the monotone set); retains voice/pose motion. Opaque body/static room needs no Reduce Transparency branch. Increase Contrast re-solves bounded anchors to (0.30, 0.90) over the look's Brightness/Contrast; NEVER clips ceiling.
- Settings showroom: production `MercurySurface` drawing `RecordingOverlayLayout.island` in the look (no collar preview), driven through `MercurySimulation.Drive.target(for:reduceMotion:)` from each pose's fixed model, with its own `MercuryHitRegion` and a deterministic room sequence from `MercuryMetrics.defaultSeed`; live at display cadence while visible, still at substep 600 under Reduce Motion (except one Play Again hold); scrolled away, or in a console window that shows none of itself (`NSWindow.occlusionState` without `.visible`: miniaturized, another Space, hidden, fully covered), it is suspended (`Configuration.isSuspended`): no display link and no frame, live or pinned, and the current look draws the moment it returns; bake-class changes ≤10 Hz; one `Island preview` AX element (pose, room). Play Again: outcome poses only, replays from the processing pose through `replayGesture(from:)`, disabled for the 1.2 s hold. NEVER preview on the real panel: a visible island means a live microphone.
- Garage writes: controls stage the coordinator draft (`stageIsland`); `IslandGarageEditor` alone commits it (`commitIsland`) — discrete controls immediately, sliders on the main-actor turn after editing ends, colour wells/keyboard-moved sliders after 300 ms quiet, a pending draft when the section disappears; `prepareForTermination` commits a pending draft first. One `saveSettings()` + one undo step per commit; another control's pending draft commits first under its own name, and a discrete commit that follows it in the same event gets its own undo group. Undo/redo lands a pending draft before restoring, so no edit is lost. NEVER `settingBinding` for island controls.
- Garage rendering: every Island row is an `Equatable` view of the values it shows, used through `.equatable()`; row bodies MUST NOT read the coordinator's observable state (setters read `effectiveIsland` at call time), so a staged draft re-renders only the moved row and the showroom. `ConsoleSettingsTab` pins its ideal size to the window default so a tab update never re-measures the whole form. Engine rooms, room levels, scene anchors and metering bodies come from small process-wide caches that return exactly what a cold computation does ([renderer](docs/mercury-renderer.md#sessions-engine-and-showroom)).
- Field/modes/body shape/crown/room/paint/look/optics/response/cadence/gate changes MUST update [renderer derivation](docs/mercury-renderer.md#renderer-contract) and pass `make ui-mercury-bench` [gates](docs/mercury-renderer.md#measured-gates).

## Local-first and network policy

- Only compiled model URLs: same host/repository/revision, pinned digest. NEVER network text processing, telemetry, crash reporting, accounts, update checks, arbitrary URLs, or another production recognizer.
- Sidecar env allowlist: `PATH`, `HOME`, `TMPDIR`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` + lowercase forms, `SSL_CERT_FILE`, `VOICEOUR_*`. NEVER inherit full parent env. Always write `VOICEOUR_ASR_BACKEND`, `VOICEOUR_PRELOAD=1`; model variant last.
- No credential UI, credential environment contract, configurable base URL, secret store, or keychain item. `Resources/Voiceour.entitlements`: audio-input only; no provisioning profile. Data-protection Keychain is unavailable: `SecItemAdd` returns `errSecMissingEntitlement` (-34018); ad-hoc `keychain-access-groups` fails AMFI. NEVER add a feature depending on it.

## Swift conventions

- SHOULD use concrete target-boundary types and small protocols.
- Observable state MUST stay main-actor isolated. Blocking capture, I/O, hashing, model work stay off-main; 25 Hz meter data stays off coordinator observation.
- MUST use structured ownership for files/processes/capture/persistence tails; identity-check teardown against newer owners.
- MUST reuse conventions, migrate callers, delete obsolete internal APIs. Avoid unnecessary allocation, copying, computation in hot paths.

## Developer commands

Use the smallest proving command. `make` lists the catalogue.

| task | command |
| --- | --- |
| Build; Swift/C/C++ warnings are errors | `make build` |
| Swift tests, harness included | `make test` |
| Full local gate | `make check` |
| Format / check format | `make format` / `make format-check` |
| Model pins + documented commands | `make check-docs` |
| Python lint / tests | `make lint-python` / `make test-python` |
| Bundle / verify | `make bundle` / `make verify-bundle` |
| Stable local signer | `make signing` |
| Prepare source release | `make release` |
| Sign/notarize/prepare binary release | `scripts/release.sh --binary` |
| Preflight only; add `--binary` for binary checks | `scripts/release.sh --dry-run` |
| Sign, notarize, staple, validate | `make notarize` |
| Apple credential prerequisites | `scripts/sign_notarize.sh --check-env` |
| Cleanup/classification self-test | `make self-test` |
| Fake debug app / real bundle | `make dev` / `make run` |
| Stop / status / logs | `make stop` / `make status` / `make logs` |
| Generate local audio fixture | `make fixture` |
| Real model fixture proof | `make build && .build/debug/voiceour-asr --prove fixtures/audio/hello_16k_mono.wav` |
| Scene gate / bless / inventory | `make ui-snap` / `make ui-update` / `make ui-list` |
| Flow gate / bless / inventory | `make ui-flow` / `make ui-flow-update` / `make ui-flow-list` |
| All local scenes + flows | `make ui-all` |
| Harness `--only` / `--help` | `scripts/ui_harness.sh` |
| Mercury sheets / 4,096-room gate | `make ui-mercury` / `make ui-mercury-bench` |
| Onscreen capture; permission required | `scripts/console_shot.sh` |
| Offline fake benchmark | `make bench-smoke` |
| LibriSpeech / FLEURS | `make bench-stt N=64` / `make bench-e2e N=64` |
| Technical terms | `make bench-techterms` |
| U-WER comparison | `make bench-gate BASELINE=... CANDIDATE=...` |
| Vendor integrity / refresh | `scripts/vendor_parakeet.sh --check` / `scripts/vendor_parakeet.sh <upstream>` |
| Ordinary-word resource | `scripts/generate_ordinary_words.py` |
| App icon | `scripts/make_icon.sh` |
| Delete `.build` | `make clean` |

- `make check` order: build, format-check, check-docs, lint-python, test, ui-flow, ui-mercury-bench, test-python, self-test, bench-smoke.
- `make self-test`: `--self-test`, cleanup + classification only; no backend construction.
- `bench-stt`/`bench-e2e` defaults: `N=200`, `BACKEND=parakeet`. MUST retain `uv --no-config`. [Benchmark reference](docs/benchmarks.md).
- Real-model/microphone checks require task relevance and available prerequisites; microphone also requires explicit interruption consent.

## Fast iteration runtime

- Behavior/resource change → rebuild and relaunch the exercised surface. Fake path for deterministic coordinator/menu/window checks; signed real bundle for microphone/acquisition/hotkey/insertion/entitlement/signature/helper/material checks. Respect interruption consent.
- `make run`: rebuild on `Package.swift`, `scripts/bundle.sh`, `Sources/`, `Resources/`, `Vendor/` changes; stop existing instance; launch. Launching over a live instance verifies the OLD binary: the new duplicate quits. `.env`/signing changes require `make bundle` explicitly.
- `make dev`: unbundled debug executable, fake unless `VOICEOUR_ASR_BACKEND` set; stops nothing.
- `make stop`/`make status` match process name `Voiceour`. Sidecar exits after stdin EOF + bounded shutdown; check lingering `voiceour-asr` when relevant. MUST verify intended PID/bundle with `make status`.
- `make run`/`make dev` source root `.env` and export every key; bundling reads signing pins. `make run` forwards backend/variant/support names via `open --env`; MUST add forwarding for new app-read env names, NEVER assume LaunchServices inheritance.
- Run/dev flags use `ARGS`, e.g. `make run ARGS="--debug --show-console"`. Supported: `--debug`, `--show-console`, `--console-section=<home|glossary|history|settings>`, `--no-activate`, `--asr-backend <id>`, `--self-test`; `--ui-harness` only with `-DUI_HARNESS`.
- Logs: subsystem `com.voiceour.app`, categories `hotkey`, `audio`. `stop-path` signposts require Instruments/`xctrace`.

## Offscreen UI harness

`-DUI_HARNESS` enables `Voiceour --ui-harness`: real SwiftUI, `NSHostingView.cacheDisplay`, in-process AX, lint, AX/PNG digests, semantic `.flow.txt` journals. [Runbook](docs/ui-harness.md). `make ui-list` / `make ui-flow-list` own inventories.

- MUST set `.prohibited` before hosting, reassert before/after hosting, and enforce it in `ConsolePresentation` + app delegate first-run guards. `.accessory` or key refusal is insufficient. Ignore `setActivationPolicy(.prohibited)`'s false return; policy still applies.
- MUST initialize `NSApplication.shared` + `finishLaunching()` before CoreGraphics window APIs.
- Park at (-30,000, -30,000). `constrainFrameRect` MUST return requested frame without `super`. NEVER become key/main or order front; swallow ordinary ordering and `orderFrontRegardless`; permit order-out for close.
- MUST enable enhanced accessibility; otherwise the AX tree collapses.
- Fixed pump: 150 × 1 ms before/after interaction; 30 at teardown. Each iteration runs a run-loop slice AND drains posted events. NEVER replace with sleep, run-loop-only, or adaptive “stable” capture; animations make adaptive sampling nondeterministic.
- Capture into owned interleaved RGBA8 `.deviceRGB`, with alpha. NEVER system caching bitmap (monitor profile/cICP drift), alpha removal (subpixel smoothing), or `ImageRenderer` (AppKit placeholders).
- Offscreen capture cannot sample composited console/menu glass or blur/shadow filters. NEVER weaken offscreen guarantees to recover them; real material inspection requires an agreed onscreen check. Mercury is a `CGImage`, seed/step-pinned (room and look come from the appearance under test), with no display link during capture.
- Flows cover tabs and delivered/copy-only/cancel/error journeys. Offscreen key refusal prevents History click-to-copy/⌘T; unordered windows cannot open filter `NSMenu`. `console.sessions.selection`, `console.sessions.teach`, `console.sessions.deselected`, `console.sessions.filtered` pin states, not gesture execution; live gesture verification requires consent. Island flows drive looks, coats, rooms, folds, Restore Stock, underglow, Surprise Me, Another Room and Dock Island, plus one slider step (`island.tune-to-custom`: AX increment on Finish) through the release commit every Garage slider shares; checkpoints read committed state. Metal and Pose menus are pinned by fixtures; ⌘Z needs a key window, so `IslandGarageEditorTests` own undo.
- `RenderOverrides` is production-compiled. Every default MUST be nil/false and behavior-neutral. Values use `override ?? realValue`; replacements use `if let`. Seams MUST substitute real inputs/reachable states, NEVER fabricate outcomes or golden-only branches.
- Allowed seams: time/locale/calendar/timezone, permissions/paths/accessibility, History selection/filter/teach surface, installed apps/microphones, mercury seed (session and showroom rooms, Surprise Me)/step, overlay display, island placement defaults, island showroom pose, text-role instrumentation. Preserve `historyStartsDeselected`, `historyInitialAppFilter`, `historyTeachSurface`, `availableMicrophones`, `installedApps`, `islandPlacementDefaults`, `islandShowroomPose`, `textRoleRecorder`; [RenderOverrides.swift](Sources/Voiceour/RenderOverrides.swift) owns exact fields/rationales.
- MUST read `.ax.diff`/`.flow.diff` before blessing. NEVER bless error-severity lint or red flows. Filtered runs are iteration aids, not full-catalog proof. CI flows required; hosted scene snapshots advisory. NEVER bless CI raster drift.

## macOS permissions and signing

- Microphone: real capture only, requested at first recording. Accessibility: active suppression + synthetic paste; gate `CGPreflightPostEventAccess()` or `AXIsProcessTrusted()`, prompted at most once/process. Without trust: passive observation + copy-only. NEVER request Input Monitoring or its entitlement.
- Stable signing is REQUIRED for repeatable TCC checks; ad-hoc rebuilds may change identity.
- Bundling precedence: explicit `VOICEOUR_CODESIGN_IDENTITY` / `VOICEOUR_CODESIGN_KEYCHAIN` > `.env` pins > `voiceour-dev` in `~/Library/Keychains/voiceour-dev.keychain-db` > ad-hoc `-` with warning. Explicit identity bypasses local pins. Ad-hoc override: `VOICEOUR_CODESIGN_IDENTITY=- make bundle`.
- Locked development keychain → owner unlocks it. NEVER delete/reset a keychain to build; NEVER commit signing output. Identity changes may require fresh Microphone/Accessibility grants.
- Development bundles lack hardened runtime; `scripts/sign_notarize.sh` enables/verifies it on app AND helper.
- Release qualification MUST cover signed helper, hardened runtime, entitlements, clean-account permissions, and [manual delivery matrix](README.md#verification).

## Release procedure

Default: optional source release = `v<version>` tag + verbatim CHANGELOG notes + GitHub-generated source `.zip`/`.tar.gz`. No signing or Apple env access. Building from source remains supported.

Binary: explicit `scripts/release.sh --binary`; source release + Developer ID-signed, hardened, notarized, stapled arm64 app ZIP + SHA-256. NEVER publish an unnotarized binary. Release page AND notes MUST say Apple Silicon only. Binary releases are local/manual, NEVER CI; CI's `release` job only builds/bundles/verifies, uploads nothing.

### Version and preflight

- `Resources/Info.plist` alone owns version: `CFBundleShortVersionString` semver, `CFBundleVersion` strictly increasing/non-reused. Scripts/Makefile/docs MUST extract, not restate release versions.
- Plist version, CHANGELOG heading, tag MUST agree. Released version/tag immutable; re-cut requires new version.
- `scripts/release.sh` extracts the matching `## <version>`, `## [<version>]`, or `## [<version>] - <date>` section through next `## ` into `.build/Voiceour-<version>-release-notes.md`. MUST publish with `--notes-file`; NEVER hand-compose divergent notes.
- Preflight rejects: no git checkout; dirty tree; non-`main`; behind or incomparable local `origin/main` (no fetch); non-`N.N.N` version; absent/empty notes; existing tag. Binary also requires `scripts/sign_notarize.sh --check-env`.
- Both modes run `make build`, `make format-check`, `make check-docs`, `make test`. Accumulate preflight failures as `release.sh: FAIL: <reason>`; exit 1. Usage exit 64. Standalone signing: missing credentials exit 2, usage exit 64.
- Release script NEVER bumps, tags, pushes, publishes; it prints commands. `--dry-run` accepts either argument order, runs mode checks, skips notes writing/signing/publish-command output.

### Binary packaging

- Credentials: `DEVELOPER_ID_APPLICATION` plus EITHER `NOTARY_KEYCHAIN_PROFILE` OR the complete `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_APP_SPECIFIC_PASSWORD` triple. Prefer profile via `xcrun notarytool store-credentials`; command-line passwords are process-visible. No Apple credential access outside binary mode; no CI secrets.
- Order MUST remain: sign app/helper with hardened runtime → `ditto -c -k --keepParent` submission ZIP → notarize → `stapler staple` app → validate → create SECOND distribution ZIP → checksum → delete submission envelope. NEVER distribute the pre-staple archive. Offline Gatekeeper needs the stapled ticket.
- Outputs: `.build/Voiceour-<version>.zip`, adjacent `.sha256` hashing the stapled archive with relative path (`shasum -a 256 -c` works there), `.build/Voiceour-release-manifest.txt`. No DMG.
- `scripts/verify_bundle.sh` MUST assert signed sibling `voiceour-asr`, both binaries arm64, non-empty ordinary-word resource + third-party licenses, `CFBundleIdentifier=com.voiceour.app`, `LSUIElement=true`, non-empty `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion=27.0`, both `vtool` minos/sdk 27.x; `audio-input` present; `app-sandbox`/`input-monitoring` absent. NEVER weaken assertions.
- Notarization additionally verifies hardened runtime on both binaries, stapled ticket, `spctl --assess`. `make notarize` owns the full flow; `--check-env` checks credentials without building/submitting.

### Maintainer sequence

1. Bump both plist version fields.
2. Move Unreleased bullets under the matching new version heading; leave Unreleased empty.
3. Commit plist + CHANGELOG together.
4. Run `scripts/release.sh --dry-run`; resolve every failure.
5. Run `make release`; it repeats gates, writes notes, prints publication commands.
6. With explicit current-session authorization only: run printed tag/push/`gh release create` commands.

Binary substitutes `scripts/release.sh --binary --dry-run`, then `scripts/release.sh --binary` for steps 4–5; publish printed archive/checksum assets. Agent publication requires explicit authorization in the current conversation.

## Git and collaboration

- Small changes MUST use separate, scoped commits and push straight to `origin/main` after verification. This is standing authorization; NEVER stop at “committed, not pushed” or create a PR unless requested or branch protection requires it.
- MUST fetch before pushing and preserve remote commits. NEVER force-push, bypass protection, or publish unverified work. If direct push is blocked, report the exact blocker.
- NEVER discard, rewrite, stage, or commit unrelated user work.
- Generated data/build artifacts stay uncommitted unless their artifact type is explicitly tracked.
- Intended AX/digest/flow goldens MUST accompany the behavior change requiring them.

## Documentation rules

- README: product behavior, architecture, data, model/network, safety, development, verification. AGENTS: engineering invariants, boundaries, workflow, protocol/vendor, UI/harness, release. MUST update the owning contract in the same change.
- Specialist references: `docs/ui-harness.md`, `docs/mercury-renderer.md`, `docs/benchmarks.md`, `docs/performance-roadmap.md`, `docs/rust-evaluation.md`, `research/`. Derivations/measurements/runbooks only; link back to roots; NEVER redefine product policy or promote dated evidence into shipping claims.
- `CONTRIBUTING.md`: PR gates. `SECURITY.md`: reporting. `CHANGELOG.md`: user-visible changes/release notes.
- One owner per topic; link elsewhere. Declarative current-state prose, not deletion history. Archive useful superseded records under `docs/archive/` with date/notice; `docs/superpowers/` contains historical plans. NEVER add new plan/redirect documents.
- Every documented command MUST exist. `make check-docs` checks model pins and make/script references in roots, CONTRIBUTING, top-level docs. Preserve linked headings.

<critical>
- Finish the requested work; verify with tools; report exact blockers instead of invented success.
- Preserve fail-closed delivery, secure-history exclusion, local-only processing, explicit learning, and user work.
- No desktop/audio/microphone interruption without specific agreement.
- Small verified changes: commit separately, push directly to `origin/main`. Release tags/publication still require current-session authorization and passing release gates. NEVER publish an unnotarized binary.
</critical>
