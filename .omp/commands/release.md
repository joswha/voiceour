---
description: Prepare a Voiceour release — version bump, changelog section, preflight, then hand the maintainer the exact publish commands.
---

# Release

Prepare a release of the app. Two kinds, differing only in assets: a **source release** (the default, needs no Apple identity) and a **binary release** (`--binary`, adds the signed, notarized, stapled archive). `AGENTS.md` § Release procedure is authoritative; this command executes it.

## Arguments

`$ARGUMENTS` optional, in any order:

- `X.Y.Z` — the exact version to cut.
- `major` | `minor` | `patch` — bump from the last tag.
- `--binary` — cut a binary release instead of a source release.
- `--dry-run` — stop after preflight; write and publish nothing.

No version → read `git tag --list 'v*' --sort=-v:refname | head -1`, review `git log <last-tag>..HEAD`, choose major/minor/patch from what actually changed, and state the choice before editing anything. No tags yet → the version already in `Resources/Info.plist` is the one being cut; do not invent a higher one.

## 1. Version

`Resources/Info.plist` is the single source of truth. No version literal is restated in a script, the Makefile, a workflow, or a document.

- `CFBundleShortVersionString` — the semver a human reads. MUST match `N.N.N`.
- `CFBundleVersion` — monotonic build number. MUST increase and MUST NEVER repeat a value.

```bash
plutil -extract CFBundleShortVersionString raw Resources/Info.plist
plutil -extract CFBundleVersion raw Resources/Info.plist
```

Edit both. A version is released exactly once: a re-cut takes a new version rather than moving a tag.

## 2. Changelog

Move the `## Unreleased` bullets beneath a new `## <version>` heading — or `## [<version>] - <date>` — leaving `Unreleased` empty above them. That section **is** the release notes: `scripts/release.sh` extracts it verbatim and the published release carries it unedited.

- Empty section → preflight fails. Nothing to say means nothing to release.
- Binary release → the notes MUST state Apple Silicon only. Same disclosure rule as the release page.
- Notes describe user-visible behavior, not the commits that produced it.

## 3. Commit

One commit carrying exactly `Resources/Info.plist` and `CHANGELOG.md`, so the version and the notes that describe it are one revision. Subject in this repository's voice — an imperative sentence, never a conventional-commit prefix.

```bash
git add Resources/Info.plist CHANGELOG.md
git commit -m "Cut <version>"
```

## 4. Preflight

```bash
scripts/release.sh --dry-run              # source
scripts/release.sh --binary --dry-run     # binary
```

Preflight accumulates: every failure prints its own `release.sh: FAIL: <reason>` on stderr before exit 1, so one run names everything to fix. Exit 64 is a usage error; exit 2 is a binary release with incomplete Apple credentials.

It refuses a dirty tree, a branch other than `main`, a `main` behind or incomparable with local `origin/main`, a `CFBundleShortVersionString` that is not `N.N.N`, a missing or empty `## <version>` section, and an existing `v<version>` tag. Then it runs `make build`, `make format-check`, `make check-docs`, and `make test` — in both modes, because a release points at a commit and that commit must be green.

Fix everything it names and re-run until clean. `--dry-run` given in `$ARGUMENTS` → stop here and report.

Binary mode also needs `DEVELOPER_ID_APPLICATION` plus either `NOTARY_KEYCHAIN_PROFILE` or the `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_SPECIFIC_PASSWORD` triple. Check that alone with `scripts/sign_notarize.sh --check-env`. Prefer the keychain profile: a password on a command line is visible in the process table.

## 5. Cut

```bash
make release                    # source: preflight, notes file, printed publish commands
scripts/release.sh --binary     # binary: the above plus sign, notarize, staple, archive, checksum
```

The script never bumps, tags, pushes, or publishes. It writes `.build/Voiceour-<version>-release-notes.md` and prints the exact `git tag`, `git push`, and `gh release create` lines for the mode it ran.

## 6. Hand off

Print the script's commands verbatim and stop.

<critical>
NEVER run `git tag`, `git push`, or `gh release create`. Tagging and publishing are the maintainer's, always. Print them; do not execute them.
</critical>

The maintainer runs the printed `git tag -a v<version>`, the two `git push` lines, then `gh release create`. GitHub attaches the source `.zip` and `.tar.gz` itself; a binary release additionally carries the stapled archive and its `.sha256`.

## Report

```
Version:   <old> → <new>   (CFBundleVersion <old> → <new>)
Mode:      source | binary   (dry-run: yes | no)
Changelog: <heading cut>, <n> bullets
Commit:    <sha> <subject>
Preflight: pass | FAIL: <each reason>
Gate:      build ✓  format-check ✓  check-docs ✓  test ✓
Notes:     .build/Voiceour-<version>-release-notes.md
Publish:   <the exact commands the script printed, unedited>
```

## Rules

- MUST derive the version from `Resources/Info.plist`; NEVER restate it anywhere else.
- MUST keep the tag `v<version>`, the plist version, and the `CHANGELOG.md` heading in agreement.
- MUST fix every accumulated preflight failure rather than the first one.
- NEVER publish an un-notarized binary. The choice is a source release or a properly notarized one; a bare zip of an ad-hoc `.app` arrives quarantined and reads as a broken app.
- NEVER add a release workflow to CI. Notarization needs Apple credentials, and this repository holds none by design; `.github/workflows/ci.yml`'s `release` job is a packaging smoke test that uploads nothing.
- NEVER tag, push, publish, or amend history.
