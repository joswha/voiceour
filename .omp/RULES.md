# Voiceour invariants

Every change keeps these. Before editing a subsystem, read its contract doc; AGENTS.md lists them.

- Recognition and text processing run on this Mac, and text stages stay deterministic. The app's only network access is the pinned Granite model download.
- Only `.normalText` targets receive a synthesized Cmd-V; every other target class is copy-only. Secure targets get a concealed, host-only copy and no History or ledger entry.
- The clipboard is write-only: write the transcript; never read, save or restore the user's previous clipboard.
- Recorded audio is temporary: remove it after success, cancellation, error and stale-file scavenging.
- Vocabulary changes only on an explicit user action.
- Verify offscreen and silently. Window activation, live keystrokes, speaker playback and microphone capture each need the user's agreement to that specific interruption; "test end-to-end" is not that agreement.
- Leave unrelated work untouched: never discard, stash, reset, rewrite or stage it; commit explicit file lists.
- Ship each verified change as its own scoped commit pushed to `origin/main`; this is standing authorization. Fetch first, keep remote commits, never force-push, and open a PR only when asked or when branch protection requires it. Release tags and publication need the user's authorization in the current conversation.
