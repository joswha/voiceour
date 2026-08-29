"""Keep-time correctness gate for `parakeet-native-latency` candidates.

Runs nothing. Scores an already-produced pair of `voiceour-bench pipeline`
result sets against the recorded incumbent on the two frozen promotion corpora
(400 LibriSpeech rows, 100 FLEURS rows) and reports three things:

- error rows, which must be zero;
- raw-transcript drift, row for row, which must be zero for this segment;
- U-WER and CER deltas against the recorded incumbent, which must stay inside
  the repository's 0.0035 margin.

Raw-transcript drift is the gate the 96-row harness corpus cannot supply. One
candidate in this segment passed the harness's own transcript hash and both
U-WER margins while still flipping a capitalisation on a row the harness does
not contain, so byte identity has to be asserted over the wider frozen corpora
before a candidate is kept.

Produce the candidate results first, from the repository root:

    mkdir -p .build/autoresearch/gate
    for t in librispeech-200-per-split fleurs-100; do
        env -i PATH=/usr/bin:/bin HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
            VOICEOUR_MODEL_VARIANT=f16 .build/release/voiceour-bench pipeline \
            --input ".build/asr-research/$t.manifest.jsonl" \
            --output ".build/autoresearch/gate/$t.results.jsonl" \
            --timeout-ms 300000 >/dev/null
    done

then score them:

    cd bench && uv --no-config run --offline python autoresearch/frozen_gate.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from voiceour_bench.metrics import cer, uwer

REPO_ROOT = Path(__file__).resolve().parents[2]
UWER_MARGIN = 0.0035

CORPORA = (
    (
        "librispeech-400",
        ".build/asr-research/librispeech-200-per-split.manifest.jsonl",
        ".build/asr-research/parakeet-current-librispeech400.results.jsonl",
        ".build/autoresearch/gate/librispeech-200-per-split.results.jsonl",
    ),
    (
        "fleurs-100",
        ".build/asr-research/fleurs-100.manifest.jsonl",
        ".build/asr-research/parakeet-current-fleurs100.results.jsonl",
        ".build/autoresearch/gate/fleurs-100.results.jsonl",
    ),
)


def read_jsonl(relative: str) -> list[dict]:
    path = REPO_ROOT / relative
    if not path.is_file():
        raise SystemExit(f"frozen_gate.py: FAIL: missing {relative}")
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def rows_by_id(relative: str) -> dict[str, dict]:
    return {row["id"]: row for row in read_jsonl(relative) if row.get("type") == "row"}


def main() -> int:
    failures: list[str] = []

    for label, manifest, incumbent_path, candidate_path in CORPORA:
        manifest_rows = {row["id"]: row for row in read_jsonl(manifest)}
        incumbent = rows_by_id(incumbent_path)
        candidate = rows_by_id(candidate_path)

        if set(candidate) != set(manifest_rows):
            failures.append(f"{label}: candidate row set differs from the manifest")
            continue
        if set(incumbent) != set(manifest_rows):
            failures.append(f"{label}: recorded incumbent row set differs from the manifest")
            continue

        ids = sorted(manifest_rows)
        errors = [row_id for row_id in ids if candidate[row_id].get("error") is not None]
        drift = [
            row_id for row_id in ids if candidate[row_id]["raw_transcript"] != incumbent[row_id]["raw_transcript"]
        ]

        references = [manifest_rows[row_id]["reference"] for row_id in ids]
        incumbent_final = [incumbent[row_id]["final_text"] for row_id in ids]
        candidate_final = [candidate[row_id]["final_text"] for row_id in ids]
        uwer_delta = uwer(references, candidate_final) - uwer(references, incumbent_final)
        cer_delta = cer(references, candidate_final) - cer(references, incumbent_final)

        print(f"{label}: rows={len(ids)} error_rows={len(errors)} raw_transcript_drift={len(drift)}")
        print(f"  U-WER delta {uwer_delta:+.6f} (margin {UWER_MARGIN})   CER delta {cer_delta:+.6f}")
        if drift:
            print(f"  drifted rows: {drift[:5]}")
            for row_id in drift[:2]:
                print(f"    incumbent {row_id}: {incumbent[row_id]['raw_transcript'][-120:]!r}")
                print(f"    candidate {row_id}: {candidate[row_id]['raw_transcript'][-120:]!r}")

        if errors:
            failures.append(f"{label}: {len(errors)} error rows")
        if drift:
            failures.append(f"{label}: {len(drift)} rows changed their raw transcript")
        if uwer_delta > UWER_MARGIN:
            failures.append(f"{label}: U-WER delta {uwer_delta:+.6f} exceeds {UWER_MARGIN}")

    if failures:
        for reason in failures:
            print(f"frozen_gate.py: FAIL: {reason}", file=sys.stderr)
        print("\nGATE: FAILED")
        return 1

    print("\nGATE: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
