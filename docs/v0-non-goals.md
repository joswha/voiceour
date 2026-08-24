# v0 non-goals

These are product decisions, not deferred roadmap items.

- **No live in-progress transcript rendering.** Parakeet is a batch model, so each update required decoding the entire growing utterance again. The cost grew quadratically across a dictation and the text was never safe to insert or reuse as the final decode. Voiceour records one WAV and performs one final decode at stop.
- **No model-based rewriting after ASR.** A second language-model pass added most of the post-speech latency, introduced privacy and credential questions, and often re-emitted text with little change. Voiceour instead uses bounded deterministic cleanup and glossary canonicalization whose output is testable and local.
- **No per-hour or per-record analytics.** Home reports one aggregate ledger — total dictation time, words, time saved against a fixed 40 wpm typing baseline, average speaking speed, the five destinations that receive the most dictations, active days, streaks, and a day-resolution activity grid — from `dictation-activity.json`. Per-app counts are part of that ledger: a bundle id, its last-seen display name, and sessions/words/seconds, which is what lets Home rank destinations past the 500-transcript cap. What it still does not keep is the rest of what the deleted dashboard did: what hour of the day a dictation happened, per-record rows in the ledger, and quoted "personal records". Nothing in the ledger identifies an utterance. Transcripts remain a separate single local FIFO of the newest 500.
- **No second production recognizer.** The shipped local Parakeet path won the row-matched content and latency comparison. `fake` remains only as development infrastructure.
- **No language or locale picker.** The pinned model and current product are English-only.
- **No background listening, wake word, or continuous dictation.** One solitary Fn/Globe tap starts one utterance; another tap, finish control, Escape, cancellation, or auto-stop ends it.
- **No automatic paste into risky targets.** Terminal, code-editor, secure, and unknown-risky destinations remain copy-only. This is not user-configurable.
- **No persisted audio.** WAVs are temporary pipeline inputs and are removed on success, cancellation, and failure.
- **No telemetry, crash reporting, account, or credential storage.** The pinned model download is the only network path.
- **No local control socket or terminal client.** Microphone and Accessibility grants stay inside the signed app identity rather than being brokered to another process.
