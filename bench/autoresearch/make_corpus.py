"""Build the frozen `parakeet-native-latency` benchmark corpus.

The corpus is a strict subset of the two frozen promotion corpora in
`.build/asr-research/`, so the harness workload can never drift away from the
400/100 accuracy gate that keeps a candidate: every harness row is also a gate
row.

Selection is deterministic and carries no seed. For each source the rows are
grouped into fixed duration buckets, each bucket is sorted by row id, and rows
are drawn round-robin from the buckets in ascending bucket order until the
source quota is met. Round-robin rather than head-of-list because the frozen
manifests are not duration-shuffled: a plain first-N draw from LibriSpeech
returns one narrow length band and measures one encoder shape class.

The emitted manifest is ordered by (source, id) so a run's row order is a
property of the file and not of this script.

Run from the repository root:

    cd bench && uv --no-config run python autoresearch/make_corpus.py
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_PATH = Path(__file__).resolve().parent / "corpus.manifest.jsonl"

# Bucket lower bounds in audio seconds. The last bucket is open-ended.
BUCKET_EDGES = (0.0, 8.0, 14.0, 20.0, 26.0)
BUCKET_NAMES = ("d0_lt8s", "d1_8to14s", "d2_14to20s", "d3_20to26s", "d4_ge26s")

# source label -> (frozen manifest, row-id substring selecting the split, quota)
SOURCES = (
    ("librispeech-clean", ".build/asr-research/librispeech-200-per-split.manifest.jsonl", "test.clean", 32),
    ("librispeech-other", ".build/asr-research/librispeech-200-per-split.manifest.jsonl", "test.other", 32),
    ("fleurs-en-us", ".build/asr-research/fleurs-100.manifest.jsonl", "fleurs-en_us", 32),
)


def bucket_of(audio_s: float) -> str:
    index = 0
    for position, edge in enumerate(BUCKET_EDGES):
        if audio_s >= edge:
            index = position
    return BUCKET_NAMES[index]


def read_manifest(relative: str) -> list[dict]:
    rows = []
    with (REPO_ROOT / relative).open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def select(rows: list[dict], quota: int) -> list[dict]:
    buckets: dict[str, list[dict]] = {name: [] for name in BUCKET_NAMES}
    for row in rows:
        buckets[bucket_of(float(row["audio_s"]))].append(row)
    for name in BUCKET_NAMES:
        buckets[name].sort(key=lambda row: row["id"])

    chosen: list[dict] = []
    cursor = 0
    while len(chosen) < quota:
        drawn = 0
        for name in BUCKET_NAMES:
            if len(chosen) == quota:
                break
            if cursor < len(buckets[name]):
                chosen.append(buckets[name][cursor])
                drawn += 1
        if drawn == 0:
            raise SystemExit(f"quota {quota} exceeds the {len(rows)} available rows")
        cursor += 1
    return chosen


def main() -> None:
    selected: list[dict] = []
    for source, manifest, split_marker, quota in SOURCES:
        rows = [row for row in read_manifest(manifest) if split_marker in row["id"]]
        if not rows:
            raise SystemExit(f"no rows matched {split_marker} in {manifest}")
        for row in select(rows, quota):
            audio_s = float(row["audio_s"])
            selected.append(
                {
                    "audio_path": row["audio_path"],
                    "audio_s": audio_s,
                    "duration_bucket": bucket_of(audio_s),
                    "id": row["id"],
                    "reference": row["reference"],
                    "source": source,
                }
            )

    selected.sort(key=lambda row: (row["source"], row["id"]))
    for row in selected:
        missing = REPO_ROOT / row["audio_path"]
        if not missing.is_file():
            raise SystemExit(f"missing audio: {row['audio_path']}")

    body = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in selected)
    OUT_PATH.write_text(body, encoding="utf-8")

    counts: dict[str, int] = {}
    for row in selected:
        counts[row["duration_bucket"]] = counts.get(row["duration_bucket"], 0) + 1
    print(f"wrote {len(selected)} rows to {OUT_PATH.relative_to(REPO_ROOT)}")
    print(f"sha256 {hashlib.sha256(body.encode('utf-8')).hexdigest()}")
    print(f"audio seconds {sum(row['audio_s'] for row in selected):.1f}")
    print("buckets " + " ".join(f"{name}={counts.get(name, 0)}" for name in BUCKET_NAMES))


if __name__ == "__main__":
    main()
