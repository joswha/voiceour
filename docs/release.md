# Release procedure

[AGENTS.md](../AGENTS.md) maps the other contracts; [`.omp/RULES.md`](../.omp/RULES.md) holds the invariants every change keeps.

Default: optional source release = `v<version>` tag + verbatim CHANGELOG notes + GitHub-generated source `.zip`/`.tar.gz`. No signing or Apple env access. Building from source remains supported.

Binary: explicit `scripts/release.sh --binary`; source release + Developer ID-signed, hardened, notarized, stapled arm64 app ZIP + SHA-256. NEVER publish an unnotarized binary. Release page AND notes MUST say Apple Silicon only. Binary releases are local/manual, NEVER CI; CI's `release` job only builds/bundles/verifies, uploads nothing.

## Version and preflight

- `Resources/Info.plist` alone owns version: `CFBundleShortVersionString` semver, `CFBundleVersion` strictly increasing/non-reused. Scripts/Makefile/docs MUST extract, not restate release versions.
- Plist version, CHANGELOG heading, tag MUST agree. Released version/tag immutable; re-cut requires new version.
- `scripts/release.sh` extracts the matching `## <version>`, `## [<version>]`, or `## [<version>] - <date>` section through next `## ` into `.build/Voiceour-<version>-release-notes.md`. MUST publish with `--notes-file`; NEVER hand-compose divergent notes.
- Preflight rejects: no git checkout; dirty tree; non-`main`; behind or incomparable local `origin/main` (no fetch); non-`N.N.N` version; absent/empty notes; existing tag. Binary also requires `scripts/sign_notarize.sh --check-env`.
- Both modes run `make build`, `make format-check`, `make check-docs`, `make test`. Accumulate preflight failures as `release.sh: FAIL: <reason>`; exit 1. Usage exit 64. Standalone signing: missing credentials exit 2, usage exit 64.
- Release script NEVER bumps, tags, pushes, publishes; it prints commands. `--dry-run` accepts either argument order, runs mode checks, skips notes writing/signing/publish-command output.

## Binary packaging

- Credentials: `DEVELOPER_ID_APPLICATION` plus EITHER `NOTARY_KEYCHAIN_PROFILE` OR the complete `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_APP_SPECIFIC_PASSWORD` triple. Prefer profile via `xcrun notarytool store-credentials`; command-line passwords are process-visible. No Apple credential access outside binary mode; no CI secrets.
- Order MUST remain: sign app/helper with hardened runtime → `ditto -c -k --keepParent` submission ZIP → notarize → `stapler staple` app → validate → create SECOND distribution ZIP → checksum → delete submission envelope. NEVER distribute the pre-staple archive. Offline Gatekeeper needs the stapled ticket.
- Outputs: `.build/Voiceour-<version>.zip`, adjacent `.sha256` hashing the stapled archive with relative path (`shasum -a 256 -c` works there), `.build/Voiceour-release-manifest.txt`. No DMG.
- `scripts/verify_bundle.sh` MUST assert signed sibling `voiceour-asr`, both binaries arm64, non-empty ordinary-word resource + third-party licenses (ggml and transcribe.cpp notices, Granite model attribution), `CFBundleIdentifier=com.voiceour.app`, `LSUIElement=true`, non-empty `NSMicrophoneUsageDescription`, `LSMinimumSystemVersion=27.0`, both `vtool` minos/sdk 27.x; `audio-input` present; `app-sandbox`/`input-monitoring` absent. NEVER weaken assertions.
- Notarization additionally verifies hardened runtime on both binaries, stapled ticket, `spctl --assess`. `make notarize` owns the full flow; `--check-env` checks credentials without building/submitting.

## Maintainer sequence

1. Bump both plist version fields.
2. Move Unreleased bullets under the matching new version heading; leave Unreleased empty.
3. Commit plist + CHANGELOG together.
4. Run `scripts/release.sh --dry-run`; resolve every failure.
5. Run `make release`; it repeats gates, writes notes, prints publication commands.
6. With explicit current-session authorization only: run printed tag/push/`gh release create` commands.

Binary substitutes `scripts/release.sh --binary --dry-run`, then `scripts/release.sh --binary` for steps 4–5; publish printed archive/checksum assets. Agent publication requires explicit authorization in the current conversation.
