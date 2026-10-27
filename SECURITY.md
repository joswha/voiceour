# Security policy

Voiceour touches the microphone, active workspace, clipboard and keyboard. Its authoritative privacy and safety contracts live in [README.md](README.md#safety-and-permissions); [AGENTS.md](AGENTS.md#privacy-and-insertion-safety) defines the implementation invariants.

## Reporting a vulnerability

Report privately through GitHub security advisories: open the repository's **Security** tab and choose **Report a vulnerability**. That advisory is the only reporting channel; please do not open a public issue.

Include reproduction steps, the affected commit, and whether microphone audio, clipboard contents, or transcript text can be exposed.

## Supported versions

Security fixes target the current `main` branch. Include the affected release tag or commit in your report.

## Security boundaries

The technical contract is maintained in one place:

- [Runtime and data](README.md#runtime-and-data): temporary audio, local transcript history, aggregate activity and retention.
- [Model and network contract](README.md#model-and-network-contract): pinned model acquisition, integrity checks, local recognition and no credentials.
- [Safety and permissions](README.md#safety-and-permissions): fail-closed target classification, concealed secure copies, focus rechecks and TCC grants.
- [Non-goals](README.md#non-goals): no network text processing, telemetry or local control socket.

Report any behavior that violates those boundaries through the private channel above.

## Third-party code

Vendored parakeet.cpp and ggml sources under `Vendor/parakeet/` come from a pinned upstream commit; every local change is marked `VOICEOUR PATCH` and listed in `Vendor/parakeet/NOTICE.md`. See [NOTICE](NOTICE) for attribution of third-party source and model artifacts.
