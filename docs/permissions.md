# Permissions and insertion matrix

## Permissions

- Microphone: required only for real recording. `scripts/run_real.sh` launches the `.app` bundle with `NSMicrophoneUsageDescription`; the macOS microphone prompt may appear when you first start real recording, not merely when the app launches. `scripts/restart_real.sh` reopens the existing bundle without rebuilding it for repeated tests after permissions are granted. `scripts/run_dev.sh` stays fake-backed and TCC-free.
- Accessibility for synthetic paste and Fn/Globe capture: required to post Cmd-V and to install the active session-level `CGEventTap` (`.cgSessionEventTap`) that toggles on a standalone Fn/Globe tap. With it, VoiceOour consumes the Globe "assigned action" key event so the macOS emoji/dictation popup is suppressed, while Fn+other-key combinations pass through. The same tap claims an unmodified Escape while a session is live, discarding it without the focused app seeing the key. Without it, VoiceOour falls back to a passive monitor, so toggling and the Escape cancel still work but macOS may also show the popup and the focused app also receives the Escape; insertion falls back to copy-only when Cmd-V cannot be posted.
- Accessibility target inspection: optional for secure-control detection. When trusted, VoiceOour can detect secure focused controls and classify them as copy-only; it does not use Accessibility APIs to mutate focused controls.

VoiceOour does not request Input Monitoring in v0 and does not mutate focused controls through AX APIs.

For real ASR, `scripts/run_real.sh` launches the bundle and passes `--repo-root`, `--asr-dir`, and `--asr-backend mlx` through `open --args`. Parakeet may cold-load on first use, but the model and inference remain local.

Run `scripts/setup_local_signing.sh` once before repeated local builds. It installs a dedicated password-free `voiceoour-dev` identity, and `scripts/bundle.sh` selects it without opening unrelated keychains. The stable certificate gives every rebuild the same designated requirement, so a single Accessibility grant survives later builds. `VOICEOOUR_CODESIGN_IDENTITY` can explicitly select another identity; without either identity, the bundler warns and uses an ad-hoc signature whose per-build cdhash requires a new grant after code changes.

## Automated insertion checks

`make test` passed these insertion contracts:

- Terminal targets strip one trailing newline, write clipboard, and never post Cmd-V.
- Missing synthetic paste permission is requested once per app run before falling back; subsequent attempts remain copy-only without reopening the prompt, and begin pasting automatically after the permission becomes granted.
- Target identity is bundle id, pid **and** safety class, re-checked immediately before the pasteboard write and again before Cmd-V. Any change, including a focus move to a secure field inside the same process, degrades to copy-only.
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

1. Focus TextEdit.
2. Tap Fn/Globe to start. With Accessibility granted, VoiceOour consumes the standalone tap and suppresses the macOS emoji popup; without it, the passive fallback may let the popup also appear.
3. Tap Fn/Globe again to stop.
4. Expected fake mode: the app obtains `fake transcript duration_ms=<n>`, runs cleanup/glossary, writes it to the clipboard, and attempts Cmd-V for a normal text target.
5. If a normal text target only receives the clipboard copy, grant the macOS event-post/Accessibility synthetic-paste permission VoiceOour requests and retry.
6. Switch from app A to an eligible app B before insertion begins. Expected: Cmd-V is attempted in B. A change after the delivery snapshot, denied paste permission, or a terminal/code/secure/unknown-risky delivery target remains copy-only.

## Manual real Parakeet E2E checklist

Run:

```sh
scripts/run_real.sh
```

Then:

1. Focus TextEdit or another normal text target.
2. Tap Fn/Globe to start recording. If this is your first real recording, macOS may request microphone permission at this point. With Accessibility granted, VoiceOour consumes the standalone tap and suppresses the macOS emoji popup; without it, the passive fallback may let the popup also appear.
3. While recording, expect a compact movable graphite island with cancel/check controls on the focused target's display. Drag the island body to reposition it. The centre reads `WARMING` until the microphone is really delivering audio — on a cold Bluetooth headset that is over a second — and only then does the live waveform replace it; processing displays the uppercase state label and comet. The overlay has no transcript preview. Silence should keep the waveform bars low, and speaking should raise and move them.
4. Speak one utterance and finish with the check control or Fn/Globe. During finalization/transcription, focus an eligible text target in another app or on another display. The island should follow that display and remain visible through insertion.
5. Expected real mode: Parakeet may cold-load on first use, then the local MLX backend produces a transcript that follows the normal cleanup/glossary path and attempts Cmd-V in the target focused when insertion begins.
6. If a normal text target only receives the clipboard copy, grant the macOS event-post/Accessibility synthetic-paste permission VoiceOour requests and retry.
7. A focus change after the final delivery snapshot, denied paste permission, or a terminal/code/secure/unknown-risky delivery target must show copy-only and never post Cmd-V into an unverified target.

Example headless verification run:

```sh
scripts/run_dev.sh --self-test
```

Result: passed. It verifies app launch wiring plus cleanup/classifier invariants without opening a GUI session.

## Insertion matrix

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
