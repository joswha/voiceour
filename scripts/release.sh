#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# There are two kinds of release and this cuts either one.
#
# A source release is the default and needs no Apple identity at all: a tag plus notes is a
# complete release, GitHub attaches the source archives itself, and the version becomes
# citable with a working releases/latest. A binary release is --binary: everything the
# source release does, plus the signed, notarized and stapled .zip and its checksum as
# assets. Publishing an un-notarized binary is not an option: it is source-only or properly
# notarized, never a bare zip.
#
# --dry-run runs every check for the selected mode and then stops without producing
# anything. In source mode it is the whole procedure minus its output, which makes it the
# way this script is exercised on a machine with no Developer ID.
DRY_RUN=0
BINARY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --binary) BINARY=1 ;;
    *)
      printf '%s\n' "usage: $0 [--binary] [--dry-run]" >&2
      exit 64
      ;;
  esac
done

# Preflight accumulates, like scripts/check_docs.sh: one failed check should name every
# other thing that also needs fixing instead of hiding behind the first exit.
failures=0
fail() {
  printf '%s\n' "release.sh: FAIL: $*" >&2
  failures=1
}
note() {
  printf '%s\n' "release.sh: $*"
}

git rev-parse --git-dir >/dev/null 2>&1 || {
  printf '%s\n' "release.sh: FAIL: $ROOT is not a git checkout; a release must point at a commit" >&2
  exit 1
}

# A release built from a dirty tree cannot be reproduced from its tag.
if [ -n "$(git status --porcelain)" ]; then
  fail "working tree is dirty; commit or stash every change before releasing, because a release built from a dirty tree cannot be reproduced from its tag"
fi

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" != main ]; then
  fail "HEAD is on branch '$branch'; releases are cut from main"
fi

# Nothing here fetches or pushes: the comparison is against the remote-tracking ref this
# checkout already has, so it is only as fresh as the last fetch.
if git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
  behind=$(git rev-list --count HEAD..refs/remotes/origin/main)
  ahead=$(git rev-list --count refs/remotes/origin/main..HEAD)
  if [ "$behind" -ne 0 ]; then
    fail "main is $behind commit(s) behind the local origin/main ref; run 'git fetch origin main' and rebase before releasing"
  fi
  git_dir=$(git rev-parse --git-dir)
  if [ -f "$git_dir/FETCH_HEAD" ]; then
    note "origin/main comparison is local only, last fetched $(date -r "$git_dir/FETCH_HEAD" '+%Y-%m-%d %H:%M:%S'); it is stale if anyone has pushed since"
  else
    note "origin/main comparison is local only and this checkout has never fetched; it may be stale"
  fi
  if [ "$ahead" -ne 0 ]; then
    note "main is $ahead commit(s) ahead of the local origin/main ref; push them together with the tag"
  fi
else
  fail "no local origin/main ref to compare against; run 'git fetch origin main' before releasing"
fi

# Resources/Info.plist is the single source of truth for the version. It is never restated.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || true)
version_ok=1
case "$VERSION" in
  ''|*[!0-9.]*|.*|*.|*..*) version_ok=0 ;;
esac
if [ "$version_ok" -eq 1 ]; then
  dots=$(printf '%s' "$VERSION" | tr -cd . | wc -c | tr -d ' ')
  [ "$dots" -eq 2 ] || version_ok=0
fi

NOTES_BODY=
if [ "$version_ok" -eq 0 ]; then
  fail "CFBundleShortVersionString in Resources/Info.plist is '$VERSION', which is not an N.N.N version; fix it there, never anywhere else"
elif [ ! -f CHANGELOG.md ]; then
  fail "CHANGELOG.md is missing; a release takes its notes from the changelog section for its version"
else
  # The changelog section for this version is the release notes, read out of CHANGELOG.md
  # rather than composed here, so the tag and the changelog cannot disagree. One rule finds
  # the section and decides whether the heading exists, so the two cannot drift apart. The
  # version reaches awk as a plain string and is compared as one: a dynamic regex would be
  # mangled by awk's own escape processing of -v assignments, which silently matched nothing.
  section=$(awk -v want="$VERSION" '
    /^## / {
      if (found) exit
      heading = $2
      gsub(/^\[|\]$/, "", heading)
      if (heading != want) next
      found = 1
    }
    found { print }
  ' CHANGELOG.md)
  if [ -z "$section" ]; then
    fail "CHANGELOG.md has no '## $VERSION' heading; promote the '## Unreleased' section to '## $VERSION' before releasing $VERSION, because a release with no changelog section of its own is undocumented"
  else
    NOTES_BODY=$(printf '%s\n' "$section" | sed '1d' | sed '/./,$!d')
    if [ -z "$NOTES_BODY" ]; then
      fail "the '## $VERSION' section of CHANGELOG.md is empty; it is the release notes, so write it before releasing $VERSION"
    fi
  fi
  # A version is released exactly once.
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    fail "tag v$VERSION already exists; bump CFBundleShortVersionString in Resources/Info.plist, because a version is released only once"
  fi
fi

# Only the binary release needs an Apple identity, and the credential rule itself lives in
# sign_notarize.sh; this only asks it. A source release must never fail for its absence.
if [ "$BINARY" -eq 1 ]; then
  if signing_env=$("$ROOT/scripts/sign_notarize.sh" --check-env 2>&1); then
    note "$signing_env"
  else
    fail "$signing_env"
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf '%s\n' "release.sh: preflight failed; nothing was built, signed, tagged or published" >&2
  exit 1
fi

# The full local gate runs in both modes: a release points at a commit, and that commit has
# to be green whether or not anything is being signed.
gate() {
  note "gate: $*"
  if ! "$@"; then
    printf '%s\n' "release.sh: FAIL: '$*' failed; fix it before releasing $VERSION" >&2
    exit 1
  fi
}
gate make build
gate make format-check
gate make check-docs
gate make test

NOTES=".build/Voiceour-$VERSION-release-notes.md"
ARCHIVE=".build/Voiceour-$VERSION.zip"

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry run: every check passed for $VERSION"
  if [ "$BINARY" -eq 1 ]; then
    note "dry run: stopping before scripts/sign_notarize.sh, which signs with the hardened runtime, submits to Apple notarization over the network, staples the ticket and writes $ARCHIVE"
  fi
  note "dry run: stopping before writing $NOTES and printing the publish commands"
  note "dry run: re-run without --dry-run to cut the release"
  exit 0
fi

if [ "$BINARY" -eq 1 ]; then
  note "signing, notarizing and stapling $VERSION; the Apple submission can take several minutes"
  "$ROOT/scripts/sign_notarize.sh"
  [ -f "$ARCHIVE" ] || {
    printf '%s\n' "release.sh: FAIL: scripts/sign_notarize.sh did not produce $ARCHIVE; nothing was tagged or published" >&2
    exit 1
  }
  [ -f "$ARCHIVE.sha256" ] || {
    printf '%s\n' "release.sh: FAIL: scripts/sign_notarize.sh did not produce $ARCHIVE.sha256; nothing was tagged or published" >&2
    exit 1
  }
fi

mkdir -p .build
printf '%s\n' "$NOTES_BODY" > "$NOTES"
commit=$(git rev-parse --short HEAD)
build_number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
min_macos=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)

# release.sh never tags, pushes or publishes. It prints what the maintainer runs next.
if [ "$BINARY" -eq 1 ]; then
  sha=$(awk '{ print $1; exit }' "$ARCHIVE.sha256")
  cat <<EOF

Voiceour $VERSION is ready to publish as a binary release. Nothing has been tagged yet.

  mode           binary release, signed, notarized and stapled
  commit         $commit
  version        $VERSION (build $build_number)
  minimum macOS  $min_macos
  artifact       $ARCHIVE
  sha256         $sha
  notes          $NOTES
  manifest       .build/Voiceour-release-manifest.txt

Publish it yourself; release.sh does not tag, push or create the GitHub release:

  git tag -a v$VERSION -m 'Voiceour $VERSION'
  git push origin main
  git push origin v$VERSION
  gh release create v$VERSION --title 'Voiceour $VERSION' --notes-file $NOTES $ARCHIVE $ARCHIVE.sha256
EOF
else
  cat <<EOF

Voiceour $VERSION is ready to publish as a source release. Nothing has been tagged yet.

  mode           source release; GitHub attaches the source archives itself
  commit         $commit
  version        $VERSION (build $build_number)
  minimum macOS  $min_macos
  notes          $NOTES

Publish it yourself; release.sh does not tag, push or create the GitHub release:

  git tag -a v$VERSION -m 'Voiceour $VERSION'
  git push origin main
  git push origin v$VERSION
  gh release create v$VERSION --title 'Voiceour $VERSION' --notes-file $NOTES

A signed binary is a separate, optional release kind that needs a Developer ID:
run scripts/release.sh --binary instead.
EOF
fi
