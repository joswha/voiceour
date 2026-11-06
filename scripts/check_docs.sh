#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONTRACT="$ROOT/Sources/VoiceCore/ASRProtocol.swift"

failures=0
fail() {
  printf '%s\n' "check_docs.sh: FAIL: $*" >&2
  failures=1
}

# Granite, the only recognizer, downloads one artifact, so its pins are read out of
# GraniteModelContract rather than restated here. Each field must be declared exactly once; two
# matches would make grep -F accept either line and hide drift in the other.
granite_enum=$(sed -n '/^public enum GraniteModelContract/,/^}/p' "$CONTRACT")
[ -n "$granite_enum" ] || fail "could not find public enum GraniteModelContract in Sources/VoiceCore/ASRProtocol.swift"
granite_field() {
  value=$(printf '%s\n' "$granite_enum" | sed -n "s/^ *public static let $1 = \"\([^\"]*\)\".*/\1/p")
  case "$value" in
    '')
      [ -z "$granite_enum" ] ||
        fail "could not extract GraniteModelContract.$1 from Sources/VoiceCore/ASRProtocol.swift"
      ;;
    *'
'*)
      fail "GraniteModelContract.$1 is declared more than once in Sources/VoiceCore/ASRProtocol.swift"
      value=
      ;;
  esac
  eval "$2=\$value"
}
granite_field modelId granite_model_id
granite_field revision granite_revision
granite_field fileName granite_file
granite_field sha256 granite_sha
granite_field sourceCheckpoint granite_source
granite_field sourceRevision granite_source_revision

for doc in README.md NOTICE AGENTS.md; do
  if [ ! -f "$ROOT/$doc" ]; then
    fail "$doc is missing"
    continue
  fi
  if [ -n "$granite_model_id" ] && ! grep -Fq "$granite_model_id" "$ROOT/$doc"; then
    fail "$doc is missing Granite model id $granite_model_id"
  fi
  if [ -n "$granite_revision" ] && ! grep -Fq "$granite_revision" "$ROOT/$doc"; then
    fail "$doc is missing Granite revision $granite_revision"
  fi
done

for doc in README.md AGENTS.md; do
  [ -f "$ROOT/$doc" ] || continue
  if [ -n "$granite_file" ] && ! grep -Fq "$granite_file" "$ROOT/$doc"; then
    fail "$doc is missing Granite artifact file name $granite_file"
  fi
  if [ -n "$granite_sha" ] && ! grep -Fq "$granite_sha" "$ROOT/$doc"; then
    fail "$doc is missing Granite sha256 $granite_sha for $granite_file"
  fi
done

# NOTICE credits the downloaded conversion by file name and the IBM checkpoint it was converted
# from by repository and revision; the digest stays in the two canonical documents.
if [ -f "$ROOT/NOTICE" ]; then
  if [ -n "$granite_file" ] && ! grep -Fq "$granite_file" "$ROOT/NOTICE"; then
    fail "NOTICE is missing Granite artifact file name $granite_file"
  fi
  if [ -n "$granite_source" ] && ! grep -Fq "$granite_source" "$ROOT/NOTICE"; then
    fail "NOTICE is missing Granite source checkpoint $granite_source"
  fi
  if [ -n "$granite_source_revision" ] && ! grep -Fq "$granite_source_revision" "$ROOT/NOTICE"; then
    fail "NOTICE is missing Granite source revision $granite_source_revision"
  fi
fi

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

printf '%s\n' "check_docs.sh: OK: README.md, NOTICE and AGENTS.md match Granite $granite_model_id@$granite_revision; README.md and AGENTS.md name and digest $granite_file; NOTICE credits $granite_file from $granite_source@$granite_source_revision"
