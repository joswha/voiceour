# Permissions and insertion matrix

## Permission model

- **Microphone** is required only for real recording. `scripts/run_real.sh` launches the bundle carrying `NSMicrophoneUsageDescription`; macOS normally prompts when the first recording starts, not at application launch. The fake path is microphone-free.
- **Accessibility trust** enables the active session-level `CGEventTap` and synthetic Cmd-V. With trust, Voiceour consumes a solitary Fn/Globe tap before macOS opens its assigned action and consumes an unmodified Escape while a session is active. Fn/Globe plus another key passes through.
- Without Accessibility trust, a passive monitor still observes the toggle and Escape, but cannot suppress the key in the focused app. Delivery is clipboard-only because Voiceour cannot post Cmd-V.
- Accessibility inspection is used to identify focused secure controls. It is never used to mutate text.
- Voiceour does not request Input Monitoring.

The hotkey tap is recreated after teardown and watchdog rebuild so armed state cannot leak across taps. Passive routing explicitly ignores Globe keycode 179. A fresh install that grants Accessibility later upgrades from passive to active capture without requiring an app restart.

Use `scripts/setup_local_signing.sh` before repeated real-bundle testing. A stable local identity lets one Accessibility grant survive rebuilds. Ad-hoc signatures can change code identity and require a new grant.

## Target-safety policy

Insertion is pasteboard plus synthetic Cmd-V, never Accessibility text mutation. `InsertionSafetyPolicy` allows automatic paste only for verified normal text.

| target class | delivery | reason |
| --- | --- | --- |
| Normal text | Clipboard write, then Cmd-V when permission and identity checks pass | The focused destination is verified as ordinary text. |
| Terminal | Copy-only; strip exactly one trailing newline | A trailing newline can execute a command. |
| Code editor | Copy-only | Source-editing targets are deliberately never auto-pasted into. |
| Secure | Concealed copy-only; no history row | Spoken secrets must not be auto-pasted or stored in the transcript journal. |
| Unknown-risky | Copy-only; strip exactly one trailing newline | Missing or failed inspection is not evidence of safety and may hide a shell. |

Known terminal mappings include Ghostty (`com.mitchellh.ghostty`); known code-editor mappings include Zed (`dev.zed.Zed`). Active secure input and secure AX roles outrank bundle classification.

Secure copy uses both `.string` and `org.nspasteboard.ConcealedType`. Text written for an attempted normal paste uses `org.nspasteboard.TransientType`. Other copy-only writes use plain string without either marker.

Voiceour writes only its transcript. It never reads, saves, or restores the user's previous clipboard. Clipboard contents are not later cleared by a timer: after the write, the pasteboard is the delivery mechanism.

## Focus-race rules

The capture target and delivery target are intentionally different snapshots:

1. The capture target selects app-scoped vocabulary before recording.
2. Immediately before persistence/insertion, the coordinator snapshots the current frontmost target.
3. Immediately before the pasteboard write, `PasteboardInserter` checks full target identity: bundle id, pid, safety class, and secure-input flag.
4. Immediately before Cmd-V, it checks identity again.

A change at either delivery check becomes copy-only. A focus move from app A to eligible app B before the delivery snapshot may paste into B. A focus move after that snapshot can never redirect a paste.

An AX inspection failure maps to unknown-risky. `kAXErrorNoValue` is the narrow exception: the attribute exists and reports no focused element, common when an Electron composer has not been clicked, so bundle classification still applies. Secure input and known risky bundle sets continue to outrank it.

## Persistence rule for secure targets

The delivery snapshot is taken before the history append. If its safety class is secure, Voiceour delivers a concealed clipboard item and does not create or update a `recent-sessions.json` entry. The absence covers transcript text, raw ASR text, timings, and destination metadata. Audio is temporary and is removed through the ordinary pipeline cleanup.

## Automated contracts

`make test` covers these outcomes without posting Cmd-V into a live application:

- terminals and unknown-risky targets strip one trailing newline and never post Cmd-V;
- code editors and secure targets remain copy-only;
- secure delivery appends no history row;
- missing event-post permission prompts at most once per run and degrades to copy-only;
- target changes before copy or after copy become distinct copy-only outcomes;
- cancellation or event-post failure after the pasteboard write stays copy-only;
- Ghostty and Zed classify into their intended risky classes;
- unreadable focus stays fail-closed;
- normal focus switching before delivery records the delivery destination, not the capture destination.

No required automated check sends keys to another live app. That boundary stays manual so CI remains TCC-free and cannot modify a user's documents.

## Manual fake E2E

Run:

```sh
scripts/run_dev.sh
```

1. Focus TextEdit and tap Fn/Globe once. With Accessibility trust, macOS's assigned Globe action must not appear; without it, both Voiceour and macOS may observe the tap.
2. Confirm the movable island appears on the focused target's display. Fake capture becomes live immediately.
3. Move focus to another eligible app/display. The island should follow while keeping its display-relative placement.
4. Tap Fn/Globe, press the finish control, or press Escape as appropriate. The stop path performs one final fake decode, deterministic cleanup, clipboard write, and eligible Cmd-V.
5. Confirm a pre-delivery move to an eligible app B attempts delivery in B.
6. Confirm a terminal, editor, secure field, unknown target, denied permission, or post-snapshot focus change remains copy-only.
7. In a secure field, confirm no new History row appears.

Headless fake wiring proof:

```sh
scripts/run_dev.sh --self-test
```

## Manual real Parakeet E2E

Run:

```sh
scripts/run_real.sh
```

1. On a fresh cache, confirm the menu reports the 1.26 GB model download percentage and the System tab reports acquisition state. Wait for readiness.
2. Focus TextEdit and tap Fn/Globe. Grant microphone permission if prompted.
3. Confirm the island says the microphone is warming until a non-zero audio buffer arrives, then shows the waveform. A cold Bluetooth route may take longer; when a built-in microphone is available, Voiceour deliberately pins capture there.
4. Speak one English utterance and stop once. The app finalizes one WAV and performs one final local decode through the sibling `voiceour-asr` process.
5. During finalization or transcription, move to another eligible target. Confirm the island follows and delivery uses the target current at insertion time.
6. Confirm deterministic cleanup and glossary canonicalization preserve protected terms.
7. Confirm normal text receives Cmd-V when trusted; otherwise it receives clipboard-only delivery with a reason.
8. Confirm Ghostty, Zed, a secure field, and an unreadable target never receive Cmd-V. Verify a terminal/unknown copied command has no single trailing newline.
9. Confirm secure-field dictation creates no History entry.

## Release matrix

| target | expected behavior | qualification |
| --- | --- | --- |
| TextEdit | Paste attempted | Manual clean-account run required. |
| Notes / Mail | Paste attempted | Manual run required. |
| Safari / Chrome contenteditable | Paste attempted | Manual run required. |
| Electron/chat composer | Paste attempted when ordinary text is established | Manual run required. |
| Terminal / iTerm / Ghostty | Copy-only, one trailing newline stripped | Classifier and policy tests; manual run required. |
| VS Code / Xcode / Zed | Copy-only | Classifier tests; manual run required. |
| Password field | Concealed copy-only and no History row | Automated policy/history tests; manual run required. |
| Focus switch before delivery | Paste into the latest eligible target | Automated race test; multi-display manual run required. |
| Focus switch after snapshot | Copy-only; never redirect Cmd-V | Automated race test; manual run required. |

Release qualification uses the bundled, signed, notarized app on a clean macOS account. Verify microphone prompting, Accessibility grant persistence, one eligible paste target, one risky copy-only target, secure no-history behavior, and the real model path.
