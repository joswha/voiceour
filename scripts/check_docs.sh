#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONTRACT="$ROOT/Sources/VoiceCore/ASRProtocol.swift"
RETIRED_REVISION=ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15

failures=0
fail() {
  printf '%s\n' "check_docs.sh: FAIL: $*" >&2
  failures=1
}

# The repository identity every artifact shares.
model_id=$(sed -n '/^public enum ASRModelContract/,/^}/s/.*modelId = "\(.*\)"/\1/p' "$CONTRACT")
revision=$(sed -n '/^public enum ASRModelContract/,/^}/s/.*revision = "\(.*\)"/\1/p' "$CONTRACT")

[ -n "$model_id" ] || fail "could not extract ASRModelContract.modelId from Sources/VoiceCore/ASRProtocol.swift"
[ -n "$revision" ] || fail "could not extract ASRModelContract.revision from Sources/VoiceCore/ASRProtocol.swift"

# The artifacts are read out of ASRModelVariant rather than restated here, and each file name is
# rebuilt from the same interpolated template the Swift uses. A variant added, renamed or rehashed
# there therefore changes what the docs must say instead of leaving this check on the old set.
variant_enum=$(sed -n '/^public enum ASRModelVariant/,/^}/p' "$CONTRACT")
file_template=$(printf '%s\n' "$variant_enum" | sed -n 's/.*var fileName: String { "\(.*\)" }.*/\1/p')
variant_cases=$(printf '%s\n' "$variant_enum" | sed -n \
  -e 's/^    case \([A-Za-z0-9_]*\) = "\([^"]*\)".*/\1 \2/p' \
  -e 's/^    case \([A-Za-z0-9_]*\) *$/\1 \1/p')
variant_shas=$(printf '%s\n' "$variant_enum" | sed -n \
  '/var sha256: String {/,/^    }/s/^ *case \.\([A-Za-z0-9_]*\): *return "\([0-9a-f]*\)".*/\1 \2/p')

prefix=
suffix=
case "$file_template" in
*'\(rawValue)'*)
  prefix=${file_template%%'\(rawValue)'*}
  suffix=${file_template#*'\(rawValue)'}
  ;;
*)
  fail "could not extract the ASRModelVariant.fileName template from Sources/VoiceCore/ASRProtocol.swift"
  file_template=
  ;;
esac

# One "<file name> <sha256>" record per variant, plus a readable list for the summary line.
artifacts=
artifact_names=
if [ -n "$file_template" ]; then
  while read -r case_name raw_value; do
    [ -n "$case_name" ] || continue
    sha=$(printf '%s\n' "$variant_shas" | sed -n "s/^$case_name //p")
    if [ -z "$sha" ]; then
      fail "could not extract ASRModelVariant.sha256 for case $case_name from Sources/VoiceCore/ASRProtocol.swift"
      continue
    fi
    file="$prefix$raw_value$suffix"
    artifacts="$artifacts$file $sha
"
    if [ -z "$artifact_names" ]; then
      artifact_names=$file
    else
      artifact_names="$artifact_names, $file"
    fi
  done <<EOF
$variant_cases
EOF
fi

[ -n "$artifacts" ] || fail "could not extract any ASRModelVariant artifact from Sources/VoiceCore/ASRProtocol.swift"

# A digest whose case declaration this script cannot parse would otherwise drop its artifact from
# every doc check without saying so.
while read -r sha_case _sha; do
  [ -n "$sha_case" ] || continue
  printf '%s\n' "$variant_cases" | grep -q "^$sha_case " ||
    fail "ASRModelVariant case $sha_case has a sha256 but no parsable case declaration"
done <<EOF
$variant_shas
EOF

for doc in README.md NOTICE AGENTS.md docs/architecture.md docs/developer-setup.md; do
  if [ ! -f "$ROOT/$doc" ]; then
    fail "$doc is missing"
    continue
  fi
  if [ -n "$model_id" ] && ! grep -Fq "$model_id" "$ROOT/$doc"; then
    fail "$doc is missing model id $model_id"
  fi
  if [ -n "$revision" ] && ! grep -Fq "$revision" "$ROOT/$doc"; then
    fail "$doc is missing revision $revision"
  fi
done

# The docs that describe the artifacts themselves must name and digest every one of them. Model id
# and revision cannot catch this drift: each variant shares both, so only the file name and the
# digest distinguish the set the docs claim from the set the app ships.
for doc in AGENTS.md docs/architecture.md; do
  [ -f "$ROOT/$doc" ] || continue
  while read -r file sha; do
    [ -n "$file" ] || continue
    grep -Fq "$file" "$ROOT/$doc" || fail "$doc is missing artifact file name $file"
    grep -Fq "$sha" "$ROOT/$doc" || fail "$doc is missing sha256 $sha for $file"
  done <<EOF
$artifacts
EOF
done

# NOTICE is attribution rather than contract, so it must credit every artifact a reader can
# actually be served — both conversions of the pinned revision, not just the default. The digests
# stay out of it: they are the integrity check the two documents above describe, and restating
# them in a licence notice would only be a fourth copy to drift.
if [ -f "$ROOT/NOTICE" ]; then
  while read -r file _sha; do
    [ -n "$file" ] || continue
    grep -Fq "$file" "$ROOT/NOTICE" || fail "NOTICE is missing artifact file name $file"
  done <<EOF
$artifacts
EOF
fi

for doc in README.md NOTICE AGENTS.md; do
  if grep -Fq "$RETIRED_REVISION" "$ROOT/$doc"; then
    fail "$doc contains retired revision $RETIRED_REVISION"
  fi
done

# Every command a live doc tells a reader to type must exist. Extraction looks
# only at inline backtick spans and fenced code blocks, so prose like "make sure"
# cannot be read as a target. CHANGELOG.md, docs/archive/**, docs/superpowers/**
# and everything under .omp/ are historical records that legitimately name
# retired commands, so they are not scanned.
makefile_targets=
if [ -f "$ROOT/Makefile" ]; then
  makefile_targets=$(sed -n 's/^\([a-z0-9][a-z0-9-]*\):.*/\1/p' "$ROOT/Makefile")
fi
target_pad=" "
while IFS= read -r t; do
  [ -n "$t" ] || continue
  target_pad="$target_pad$t "
done <<EOF
$makefile_targets
EOF

command_docs="README.md
CONTRIBUTING.md
AGENTS.md
"
for path in "$ROOT"/docs/*.md; do
  [ -f "$path" ] || continue
  command_docs="${command_docs}docs/${path##*/}
"
done
command_docs="${command_docs}.github/PULL_REQUEST_TEMPLATE.md
"

named_commands=$(
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    [ -f "$ROOT/$doc" ] || continue
    awk -v doc="$doc" '
      BEGIN { OFS = " " }
      function scan(text,    s, c, m, path) {
        s = text
        while (match(s, /make[ \t]+[a-z0-9][a-z0-9-]*/)) {
          if (RSTART > 1) {
            c = substr(s, RSTART - 1, 1)
            if (c ~ /[A-Za-z0-9_]/) {
              s = substr(s, RSTART + 4)
              continue
            }
          }
          m = substr(s, RSTART, RLENGTH)
          sub(/^make[ \t]+/, "", m)
          print "MAKE", doc, m
          s = substr(s, RSTART + RLENGTH)
        }
        s = text
        while (match(s, /scripts\/[A-Za-z0-9_.\/-]+/)) {
          if (RSTART > 1) {
            c = substr(s, RSTART - 1, 1)
            if (c ~ /[A-Za-z0-9_]/) {
              s = substr(s, RSTART + 1)
              continue
            }
          }
          path = substr(s, RSTART, RLENGTH)
          gsub(/[.,;:!?)]+$/, "", path)
          if (path ~ /^scripts\//) print "SCRIPT", doc, path
          s = substr(s, RSTART + RLENGTH)
        }
      }
      {
        if (fence) {
          if ((fence == 1 && $0 ~ /^```/) || (fence == 2 && $0 ~ /^~~~/)) {
            fence = 0
            next
          }
          scan($0)
          next
        }
        if ($0 ~ /^```/) { fence = 1; next }
        if ($0 ~ /^~~~/) { fence = 2; next }
        s = $0
        while (match(s, /`[^`]+`/)) {
          code = substr(s, RSTART + 1, RLENGTH - 2)
          nexts = substr(s, RSTART + RLENGTH)
          scan(code)
          s = nexts
        }
      }
    ' "$ROOT/$doc"
  done <<EOF
$command_docs
EOF
)

seen_commands="
"
while read -r kind doc token; do
  [ -n "$kind" ] && [ -n "$doc" ] && [ -n "$token" ] || continue
  key="$kind $doc $token"
  case "$seen_commands" in
    *"
$key
"*) continue ;;
  esac
  seen_commands="$seen_commands$key
"
  if [ "$kind" = MAKE ]; then
    case "$target_pad" in
      *" $token "*) ;;
      *) fail "$doc names make target $token which is not a Makefile rule" ;;
    esac
  elif [ "$kind" = SCRIPT ]; then
    if [ ! -f "$ROOT/$token" ]; then
      fail "$doc names $token which does not exist"
    else
      # A .sh path in a doc is something the reader types, so it has to be
      # runnable. A .swift helper is compiler input — scripts/console_shot.sh
      # builds scripts/find_console_window.swift — and is never executable.
      case "$token" in
        *.sh)
          [ -x "$ROOT/$token" ] || fail "$doc names $token which is not executable"
          ;;
      esac
    fi
  fi
done <<EOF
$named_commands
EOF

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf '%s\n' "check_docs.sh: OK: README.md, NOTICE, AGENTS.md, docs/architecture.md, docs/developer-setup.md match $model_id@$revision; AGENTS.md and docs/architecture.md name and digest $artifact_names; NOTICE credits $artifact_names; retired revision absent from README.md, NOTICE and AGENTS.md"
