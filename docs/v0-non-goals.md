# v0 non-goals

VoiceOour v0 deliberately defers the following:

- No Mac App Store or App Sandbox target.
- No bundled signed Python helper in the core development path.
- No streaming or partial transcription. Later status: the opt-in Apple backend now streams transcription internally during capture; partial transcripts are still not surfaced, and the default sidecar remains batch-only.
- No press-and-hold interaction.
- No Input Monitoring permission and no HID-level/root event tap. (Fn/Globe capture uses a session-level `CGEventTap` under the Accessibility permission; see `docs/permissions.md`.)
- No Transformers, NeMo, CoreML, remote, or cloud ASR fallback.
- No cloud-by-default cleanup or refinement.
- No blind Accessibility text mutation.
- No audio history; recent transcripts are stored locally for the Sessions view and can be cleared.
- No reading or restoring the user's previous clipboard contents.
- No automatic paste into terminal, code editor, secure, or unknown-risky flagged targets.
- No machine translation.
