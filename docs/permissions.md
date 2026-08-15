# Permissions and insertion matrix

## Permissions

- Microphone: required only for real recording. `scripts/run_real.sh` launches the `.app` bundle with `NSMicrophoneUsageDescription`; the macOS microphone prompt may appear when you first start real recording, not merely when the app launches. `scripts/restart_real.sh` reopens the existing bundle without rebuilding it for repeated tests after permissions are granted. `scripts/run_dev.sh` stays fake-backed and TCC-free.
- Accessibility for synthetic paste and Fn/Globe capture: required to post Cmd-V and to install the active session-level `CGEventTap` (`.cgSessionEventTap`) that toggles on a standalone Fn/Globe tap. With it, Voiceour consumes the Globe "assigned action" key event so the macOS emoji/dictation popup is suppressed, while Fn+other-key combinations pass through. The same tap claims an unmodified Escape while a session is live, discarding it without the focused app seeing the key. Without it, Voiceour falls back to a passive monitor, so toggling and the Escape cancel still work but macOS may also show the popup and the focused app also receives the Escape; insertion falls back to copy-only when Cmd-V cannot be posted. The fallback is not permanent: when install-time tap creation fails the app requests Accessibility once (the system prompt adds Voiceour to the list), and a watchdog retries tap creation every two seconds, so granting — or restoring a grant an ad-hoc re-sign invalidated — upgrades the running app to the suppressing tap without a relaunch, and a tap whose mach port macOS invalidates mid-run is rebuilt the same way. A TCC entry can also stick in a denied state that System Settings does not surface; `tccutil reset Accessibility com.voiceour.app` clears it, and the next launch re-prompts. The active path is observable without a reproduction: `log stream --predicate 'subsystem == "com.voiceour.app" AND category == "hotkey"'` reports tap-vs-passive at install, every upgrade, and each consumed Globe key event (`keycode=179`).
- Accessibility target inspection: optional for secure-control detection. When trusted, Voiceour can detect secure focused controls and classify them as copy-only; it does not use Accessibility APIs to mutate focused controls.

Voiceour does not request Input Monitoring in v0 and does not mutate focused controls through AX APIs.

For real ASR, `scripts/run_real.sh` launches the bundle with the `parakeet` backend. The app starts the sibling Swift executable `voiceour-asr`, which links the vendored parakeet.cpp runtime. Parakeet may cold-load on first use, but the model and inference remain local.

Run `scripts/setup_local_signing.sh` once before repeated local builds. It installs a dedicated password-free `voiceour-dev` identity, and `scripts/bundle.sh` selects it without opening unrelated keychains. The stable certificate gives every rebuild the same designated requirement, so a single Accessibility grant survives later builds. `VOICEOUR_CODESIGN_IDENTITY` can explicitly select another identity; without either identity, the bundler warns and uses an ad-hoc signature whose per-build cdhash requires a new grant after code changes.

## Target-safety policy

Insertion is pasteboard plus synthetic `Cmd-V`, never Accessibility text mutation. The transcript is
always available on the clipboard, but automatic paste and refinement depend on the target:

| Target class | Insertion | Refinement | Reason |
| --- | --- | --- | --- |
| Normal text field | Paste attempted | Allowed | The focused control is verified as ordinary text. |
| Terminal | Copy-only; strip exactly one trailing newline | Never | A pasted newline could execute a command. |
| Code editor | Copy-only | Never | Source code is not prose and must not be rewritten by a refiner. |
| Secure field | Copy-only | Never | Detected through AX secure roles and `IsSecureEventInputEnabled()`, because AX cannot see every secure target. |
| Unknown or unreadable target | Copy-only | Allowed | Failure to classify is an insertion safety veto; refinement happens before the independent delivery decision. |

Secure copy-only text is flagged `org.nspasteboard.ConcealedType`; text written for an attempted
paste is flagged `org.nspasteboard.TransientType`. The plain `.string` type is always written.
Terminal, code-editor, unknown-risky, and other non-secure copy-only writes add neither marker.

## Automated insertion checks

`make test` passed these insertion contracts:

- Terminal targets strip one trailing newline, write clipboard, and never post Cmd-V.
- Missing synthetic paste permission is requested once per app run before falling back; subsequent attempts remain copy-only without reopening the prompt, and begin pasting automatically after the permission becomes granted.
- Target identity is bundle id, pid, safety class **and** the secure-input flag, re-checked immediately before the pasteboard write and again before Cmd-V. Any change, including a focus move to a secure field inside the same process, degrades to copy-only.
- An AX inspection that cannot be completed classifies the target `.unknownRisky` rather than ordinary text, so an unreadable focus is copy-only rather than pasteable.
- `kAXErrorNoValue` is the one AX status treated as an answer rather than a failure: the app supports the attribute and reports that nothing holds keyboard focus, which is the ordinary state of an Electron app whose composer has not been clicked. That target classifies by bundle id. Active secure input, a secure AX role, and the secure/terminal/code-editor bundle sets all still outrank it, and every other AX status stays `.unknownRisky`.
- Past the pasteboard write the clipboard is the delivery mechanism: a Cmd-V that cannot be posted, and cancellation after the write, both report copy-only and never schedule the transient clipboard clear.
- A focus switch during transcription uses the latest frontmost target when insertion begins; recent-session destination metadata records that delivery target.

## Manual fake E2E checklist

Run:

```sh
scripts/run_dev.sh
```

Then:

1. Focus TextEdit on one display.
2. Tap Fn/Globe to start. With Accessibility granted, Voiceour consumes the standalone tap and suppresses the macOS emoji popup; without it, the passive fallback may let the popup also appear.
3. Expect the compact movable island on the focused target's display. Drag its body to reposition it. Fake capture is live from the first tick, so its waveform appears without the `WARMING` phase a real microphone can show.
4. Focus a normal text target on another display. The island should follow while preserving its relative placement.
5. Tap Fn/Globe again or use the check control to stop. The island should remain open through finalization. Expected fake mode: the app obtains `fake transcript duration_ms=<n>`, runs cleanup/glossary, writes it to the clipboard, and attempts Cmd-V for the target focused when insertion begins.
6. If a normal text target only receives the clipboard copy, grant the macOS event-post/Accessibility synthetic-paste permission Voiceour requests and retry.
7. Switch from app A to an eligible app B before insertion begins. Expected: Cmd-V is attempted in B.
8. A focus change after the delivery snapshot, denied paste permission, or a terminal/code/secure/unknown-risky delivery target remains copy-only.

## Manual real Parakeet E2E checklist

Run:

```sh
scripts/run_real.sh
```

Then:

1. Focus TextEdit or another normal text target.
2. Tap Fn/Globe to start recording. If this is your first real recording, macOS may request microphone permission at this point. With Accessibility granted, Voiceour consumes the standalone tap and suppresses the macOS emoji popup; without it, the passive fallback may let the popup also appear.
3. While recording, expect a compact movable graphite island with cancel/check controls on the focused target's display. Drag the island body to reposition it. The centre reads `WARMING` until the selected microphone delivers real audio, and only then does the live waveform replace it; processing displays the uppercase state label and comet. The overlay has no transcript preview. When a Bluetooth device is the default input and a built-in microphone exists, Voiceour deliberately captures from the built-in microphone, so the waveform should replace `WARMING` promptly; without a built-in input a cold Bluetooth microphone can remain warming for over a second. Silence should keep the waveform bars low, and speaking should raise and move them.
4. Speak one utterance and finish with the check control or Fn/Globe. During finalization/transcription, focus an eligible text target in another app or on another display. The island should follow that display and remain visible through insertion.
5. Expected real mode: Parakeet may cold-load on first use, then the local Swift ASR sidecar produces a transcript that follows the normal cleanup/glossary path and attempts Cmd-V in the target focused when insertion begins.
6. If a normal text target only receives the clipboard copy, grant the macOS event-post/Accessibility synthetic-paste permission Voiceour requests and retry.
7. A focus change after the final delivery snapshot, denied paste permission, or a terminal/code/secure/unknown-risky delivery target must show copy-only and never post Cmd-V into an unverified target.

Example headless verification run:

```sh
scripts/run_dev.sh --self-test
```

Result: passed. It verifies app launch wiring plus cleanup/classifier invariants without opening a GUI session.

## Release insertion matrix

| Target | Expected v0 behavior | Recorded result |
| --- | --- | --- |
| TextEdit | Paste attempted | Manual GUI run required; automated self-test passed only |
| Notes/Mail | Paste attempted | Manual GUI run required |
| Safari/Chrome contenteditable | Paste attempted | Manual GUI run required |
| Electron/chat app | Paste attempted unless classified risky | Manual GUI run required |
| Terminal | Copy-only, strip one trailing newline | Covered by Swift unit test |
| iTerm | Copy-only | Classifier covered by map; manual GUI run required |
| VS Code | Copy-only | Classifier covered by map; manual GUI run required |
| Xcode | Copy-only | Classifier covered by map; manual GUI run required |
| Password field | Copy-only when AX secure role is detectable | Classifier covered; manual GUI run required |
| Focus switch before insertion | Paste into the latest eligible target; a post-snapshot race is copy-only | Covered by Swift unit test; multi-display GUI run required |

Release qualification also requires a clean-account launch from the notarized app/archive, then confirmation that the microphone prompt, Accessibility grant, paste-eligible target, and copy-only unsafe target still behave as listed above.

No automated test posts Cmd-V into a live app. That is intentional: the PR gate remains TCC-free and fake-backed. The real Parakeet checklist above is not recorded as passed here unless a future session updates the matrix; release qualification still requires the manual matrix on a logged-in macOS account.
