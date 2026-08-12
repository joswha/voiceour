# Security Policy

VoiceOour is local-first dictation software. Each session's cleaned text and optional raw transcript are stored locally in `~/Library/Application Support/VoiceOour/recent-sessions.json`, capped at the 500 most recent sessions. Individual sessions can be deleted from the Sessions view and the whole history cleared from Diagnostics. Audio is not retained: temporary recording files are removed on success, cancellation, and error paths.

## Supported versions

Security fixes target the current `main` branch until tagged releases exist.

## Reporting a vulnerability

Report privately through GitHub security advisories: open the repository's Security tab and choose "Report a vulnerability". That advisory is the only reporting channel; please do not open a public issue. Include reproduction steps, affected commit, and whether microphone audio, clipboard contents, or transcript text can be exposed.

## Security boundaries

- Local ASR is the default path; the model is revision-pinned and loads offline once cached.
- Network access is disabled unless the user enables and configures the optional refiner. Refinement has two opt-in backends and VoiceOour holds no credential for either: a persistent locally installed `omp --mode rpc` child process, which brokers whichever subscription the user signed into and keeps every token in its own vault (`OmpRpcRefiner`); and Apple's on-device system model (`FoundationModelsRefiner`, macOS 26+, no network at all). There is no API-key field, no keychain item, and no credential environment variable in this app, and no refinement destination is user-typed. The OMP child runs with a hermetic VoiceOour profile that disables OMP memory and hides all tool schemas, so refine requests carry only the dictation prompt and each refine runs in a fresh conversation. OMP sign-in is delegated to OMP's interactive CLI in a mode-`0700` temporary `.command` opened by Terminal; VoiceOour receives only an exit status and the public provider-scoped model catalog. Provider status comes from `omp usage --json --redact`; VoiceOour discards identities and quota payloads and retains only aggregate provider/account counts. It never reads OMP's credential database and deletes the temporary command/session directory after completion. No backend is enabled by default, and there is no silent fallback between them.
- The app writes dictated text to the general pasteboard for insertion and intentionally does not read or restore the previous clipboard.
- `normalText` is the only target class that receives a synthetic Cmd-V. Terminal, code editor, secure, and unknown-risky targets are copy-only unconditionally, with no setting that widens it. A target-focus inspection that cannot be completed classifies as unknown-risky, so an unreadable focus is copy-only rather than pasteable.
- Refined text must pass faithfulness guards (length, protected glossary terms, exact number preservation, and rejection of assistant-style artifacts such as conversational preambles or answered questions) or the deterministic cleanup result is used instead.
