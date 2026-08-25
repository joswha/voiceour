# Security policy

Voiceour is local-first dictation software. It touches the microphone, the active workspace, the clipboard, and the keyboard, so the boundaries below are part of the product rather than implementation detail.

## Reporting a vulnerability

Report privately through GitHub security advisories: open the repository's **Security** tab and choose **Report a vulnerability**. That advisory is the only reporting channel; please do not open a public issue.

Include reproduction steps, the affected commit, and whether microphone audio, clipboard contents, or transcript text can be exposed.

## Supported versions

Security fixes target the current `main` branch until tagged releases exist.

## What is stored, and where

| data | location | retention |
| --- | --- | --- |
| Cleaned text and raw transcript | `~/Library/Application Support/Voiceour/recent-sessions.json` | Newest 500 sessions. Deletable per row from History; the Settings tab's Clear History erases the file. |
| Aggregate counts per day and per destination app | `~/Library/Application Support/Voiceour/dictation-activity.json` | Day buckets pruned past 400 days; totals, active-day count, and longest streak survive. Erased by the same Clear History. |
| Settings and learned vocabulary | `~/Library/Application Support/Voiceour/settings.json` | Until the user changes or clears them. |
| Recorded audio | Temporary file | Removed after success, cancellation, error, and stale-file scavenging. Never persisted. |

A delivery target that is classified as secure — a password field or any secure-input context — writes no history row at all.

## Network boundary

Exactly one network request exists: fetching the pinned recognition model from `ggml-org/parakeet-GGUF` at revision `35156454d1a39de06863303dd209fd2bed6ee079`. The download is verified against a compiled SHA-256 digest before use.

There is no telemetry, crash reporting, update check, account, analytics, or network text processing. Recognition and text cleanup are entirely local.

The app holds no credential and has no credential UI, API-key field, base URL, environment contract, or keychain item. The sidecar's launch environment is an allowlist (`PATH`, `HOME`, `TMPDIR`, the proxy/TLS names model acquisition needs, and `VOICEOUR_*`) rather than the inherited parent environment.

## Insertion boundary

Dictated text is delivered by writing the pasteboard and, for one target class only, synthesizing Cmd-V.

- `InsertionSafetyPolicy` is the single class-to-disposition mapping. Only `.normalText` receives a synthetic Cmd-V.
- Terminal, code-editor, secure, and unknown-risky targets are copy-only unconditionally. There is no setting that widens this.
- A focus inspection that cannot be completed classifies as unknown-risky, so an unreadable target is copy-only rather than pasteable.
- Bundle id, pid, safety class, and the secure-input flag are re-checked before the pasteboard is written and again before Cmd-V.
- Secure output is written concealed and remains copy-only.
- Voiceour never reads, saves, restores, or later clears the user's previous clipboard. It writes only the transcript.

## Permission boundary

- **Microphone** is required for real capture. Fake-backend development needs no grant.
- **Accessibility** trust enables active key suppression and the synthetic Cmd-V. Without it, Voiceour degrades to a passive hotkey monitor and copy-only delivery; it never silently pastes.
- Accessibility inspection reads focus to classify the target. It never mutates text.
- **Input Monitoring** is not requested.
- The bundle ships an audio-input-only entitlement set (`Resources/Voiceour.entitlements`) and cannot use the macOS data-protection keychain.

## No local control plane

Voiceour deliberately exposes no local IPC surface. A socket brokering this app's microphone and Accessibility grants to any same-uid process would launder a per-code-identity TCC decision, so there is no control socket and no terminal client. `.github/workflows/ci.yml` asserts that absence on every run.

## Third-party code

Vendored parakeet.cpp and ggml sources under `Vendor/parakeet/` come from a pinned upstream commit; every local change is marked `VOICEOUR PATCH` and listed in `Vendor/parakeet/NOTICE.md`. See [NOTICE](NOTICE) for attribution of third-party source and model artifacts.
