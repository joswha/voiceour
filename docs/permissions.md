# Permissions and delivery safety

## What Voiceour asks for

- **Microphone** is required only for real recording. macOS prompts at the first recording, not at launch.
- **Accessibility** is optional. It lets Voiceour swallow a solitary Fn/Globe tap before macOS acts on it, swallow an unmodified Escape during a session, and post Cmd-V. Fn/Globe with another key passes through.
- Without it, Voiceour still sees the toggle and Escape but cannot hide either from the focused app, and delivery is copy-only. Granting it later upgrades capture without an app restart.
- Accessibility inspection only reads the focused control; it never mutates text.
- Voiceour never requests Input Monitoring.

## Where the text goes

Delivery is a clipboard write plus a synthetic Cmd-V, never Accessibility text mutation. `InsertionSafetyPolicy` maps the target's class to one disposition below. Voiceour never reads, saves, or restores your previous clipboard.

| target class | delivery |
| --- | --- |
| Normal text | Clipboard write, then Cmd-V when permission and identity checks pass |
| Terminal | Copy-only; strips exactly one trailing newline |
| Code editor | Copy-only |
| Secure | Host-only concealed copy; no Universal Clipboard transfer or History row |
| Unknown-risky | Copy-only; strips exactly one trailing newline |

`SafetyClassifier` lists known terminal and editor bundle ids. Secure input and secure Accessibility roles outrank them; failed inspection counts as unknown-risky.

Transcript text and its concealed/transient markers are published as one pasteboard item, so a clipboard manager never sees an unmarked intermediate transcript. These opt-out markers remain advisory to local clipboard managers. Ordinary and transient copies keep the system's Universal Clipboard policy.

A failed pasteboard write is failed delivery: Voiceour posts no Cmd-V, schedules no transient clear, and gives no copied confirmation. The menu and recording announcement do not claim the transcript reached the clipboard.

## Focus races

Voiceour takes a capture snapshot before recording and a delivery snapshot immediately before insertion. `PasteboardInserter` re-checks bundle id, pid, safety class, and secure input before the clipboard write and again before Cmd-V. Focus moving before that delivery snapshot redirects delivery; moving after it cannot, so delivery is copy-only.

## Manual check before release

`make test` covers these outcomes without posting keystrokes into a live app. Qualify the rest by hand on a clean macOS account with the notarized bundle.

```sh
make run
```

1. Tap Fn/Globe in TextEdit, grant Microphone when prompted, speak once, and stop.
2. Confirm normal text pastes with Accessibility granted, and copies with a reason without it.
3. Confirm Ghostty, Zed, a password field, and an unreadable target only copy, and a terminal copy has no trailing newline.
4. Confirm the password field creates no History row.
5. Switch to another eligible app during transcription; delivery lands there.
6. Switch focus after the delivery snapshot; delivery is copy-only.

## Release matrix

| target class | expected behavior | verified by |
| --- | --- | --- |
| TextEdit, Notes, Mail, browser contenteditable | Paste attempted | Manual |
| Electron chat composer | Paste attempted for ordinary text | Manual |
| Terminal, iTerm, Ghostty | Copy-only, newline stripped | Tests, manual |
| VS Code, Xcode, Zed | Copy-only | Tests, manual |
| Password field | Concealed copy-only, no History row | Tests, manual |
| Focus switch before delivery | Paste into the new target | Tests, multi-display manual |
| Focus switch after snapshot | Copy-only | Tests, manual |
