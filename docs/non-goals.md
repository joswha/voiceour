# Non-goals

These are product decisions, not deferred roadmap items.

- **No live transcript while you speak.** Voiceour records one utterance and decodes it once at stop.
- **No model-based rewriting after recognition.** The only text stage is deterministic cleanup and glossary canonicalization, so the same input always produces the same output.
- **No background listening, wake word, or continuous dictation.** One Fn or Globe tap starts one utterance; a second tap, the finish control, Escape, or auto-stop ends it.
- **No automatic paste into risky targets.** Terminal, code-editor, secure, and unknown destinations are copy-only, and that is not configurable. See [permissions](permissions.md).
- **No per-record or per-hour analytics.** Home reads one aggregate ledger: totals, streaks, a day-resolution activity grid, and per-app counts. Nothing in it identifies an utterance.
- **No saved audio.** Recordings are temporary files, removed after success, cancellation, and failure.
- **No telemetry, crash reporting, account, or stored credentials.** Downloading the pinned model is the only network request.
- **No second production recognizer.** Local Parakeet is the shipping path; the fake backend exists for development.
- **No language picker.** The pinned model is English-only.
- **No control socket or terminal client.** Microphone and Accessibility grants stay inside the signed app.
