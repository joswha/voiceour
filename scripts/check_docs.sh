#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONTRACT="$ROOT/Sources/VoiceCore/ASRProtocol.swift"
RETIRED_REVISION=ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15

model_id=$(sed -n 's/.*modelId = "\(.*\)"/\1/p' "$CONTRACT")
revision=$(sed -n 's/.*revision = "\(.*\)"/\1/p' "$CONTRACT")
file_name=$(sed -n 's/.*fileName = "\(.*\)"/\1/p' "$CONTRACT")

failures=0
fail() {
  printf '%s\n' "check_docs.sh: FAIL: $*" >&2
  failures=1
}

[ -n "$model_id" ] || fail "could not extract ASRModelContract.modelId from Sources/VoiceCore/ASRProtocol.swift"
[ -n "$revision" ] || fail "could not extract ASRModelContract.revision from Sources/VoiceCore/ASRProtocol.swift"
[ -n "$file_name" ] || fail "could not extract ASRModelContract.fileName from Sources/VoiceCore/ASRProtocol.swift"

for doc in README.md AGENTS.md docs/architecture.md docs/developer-setup.md; do
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

for doc in README.md AGENTS.md; do
  if grep -Fq "$RETIRED_REVISION" "$ROOT/$doc"; then
    fail "$doc contains retired revision $RETIRED_REVISION"
  fi
done

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf '%s\n' "check_docs.sh: OK: README.md, AGENTS.md, docs/architecture.md, docs/developer-setup.md match $model_id@$revision ($file_name); retired revision absent from README.md and AGENTS.md"
