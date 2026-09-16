"""Freeze existing public audio rows and isolated boundary controls for Apple 27 prototypes."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np
import soundfile as sf
from coreai_common import digest

SOURCES = (
    ("fleurs", ".build/coreai/fleurs.le15.manifest.jsonl"),
    ("librispeech", ".build/coreai/librispeech.le15.manifest.jsonl"),
    ("techterms", "benchmarks/data/techterms/manifest.jsonl"),
)


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("x") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")


def pinned_row(path: Path, row_id: str, reference: str, **extra: object) -> dict:
    info = sf.info(path)
    return {
        "id": row_id,
        "audio_path": str(path.resolve()),
        "audio_s": info.frames / info.samplerate,
        "audio_bytes": path.stat().st_size,
        "audio_sha256": digest(path),
        "reference": reference,
        "formatted_reference": reference,
        **extra,
    }


def prepare(root: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    primary: list[dict] = []
    source_pins: list[dict] = []
    for tier, relative in SOURCES:
        source = root / relative
        rows = [json.loads(line) for line in source.read_text().splitlines() if line.strip()]
        source_pins.append({"path": relative, "sha256": digest(source), "rows": len(rows)})
        for original in rows:
            row = {**original, "tier": tier}
            audio = root / row["audio_path"]
            info = sf.info(audio)
            if info.samplerate != 16_000 or info.channels != 1:
                raise ValueError(f"Expected mono 16 kHz audio: {audio}")
            if audio.stat().st_size != row["audio_bytes"] or digest(audio) != row["audio_sha256"]:
                raise ValueError(f"Audio pin mismatch: {row['id']}")
            actual_seconds = info.frames / info.samplerate
            if actual_seconds > 15.0 + 1 / 16_000:
                raise ValueError(f"Primary clip exceeds 15 seconds: {row['id']}")
            if abs(actual_seconds - row["audio_s"]) > 1 / 16_000:
                raise ValueError(f"Audio duration mismatch: {row['id']}")
            row["audio_path"] = str(audio.resolve())
            primary.append(row)
    if len({row["id"] for row in primary}) != len(primary):
        raise ValueError("Duplicate ids across source corpora")
    write_jsonl(output / "primary.manifest.jsonl", primary)

    # A global public term catalog, never per-row reference text or user settings.
    vocabulary = sorted({row["canonical_term"] for row in primary if row.get("canonical_term")})
    (output / "vocabulary.json").write_text(json.dumps(vocabulary, indent=2) + "\n")

    controls_dir = output / "audio"
    controls_dir.mkdir()
    controls: list[dict] = []
    for seconds in (1, 10):
        path = controls_dir / f"silence-{seconds}s.wav"
        sf.write(path, np.zeros(16_000 * seconds, dtype=np.int16), 16_000, subtype="PCM_16")
        controls.append(pinned_row(path, f"control-silence-{seconds}s", "", tier="controls", expect_silence=True))
    seed = next(row for row in primary if row["tier"] == "fleurs")
    samples, sample_rate = sf.read(seed["audio_path"], dtype="int16")
    for repetitions in (2, 3):
        path = controls_dir / f"long-{repetitions}x.wav"
        sf.write(path, np.tile(samples, repetitions), sample_rate, subtype="PCM_16")
        controls.append(
            pinned_row(
                path,
                f"control-long-{repetitions}x",
                " ".join([seed["reference"]] * repetitions),
                tier="controls",
                construction="repeated public FLEURS clip; length-boundary check, not natural speech",
            )
        )
    write_jsonl(output / "controls.manifest.jsonl", controls)
    smoke = [
        next(row for row in primary if row["tier"] == "fleurs"),
        next(row for row in primary if row["tier"] == "librispeech"),
        next(row for row in primary if row["id"] == "techterms_01_kubectl"),
        next(row for row in primary if row["id"] == "techterms_12_cube_cuddle_negative"),
    ]
    write_jsonl(output / "smoke.manifest.jsonl", smoke)
    write_jsonl(output / "parity.manifest.jsonl", [smoke[0], smoke[2]])
    summary = {
        "schema_version": 1,
        "sources": source_pins,
        "rows": len(primary),
        "tiers": dict(Counter(row["tier"] for row in primary)),
        "audio_seconds": sum(row["audio_s"] for row in primary),
        "manifest_sha256": digest(output / "primary.manifest.jsonl"),
        "vocabulary_sha256": digest(output / "vocabulary.json"),
        "vocabulary_source": "global canonical_term catalog from public techterms fixture; no reference sentences",
        "controls": [{"id": row["id"], "audio_s": row["audio_s"]} for row in controls],
        "limitations": [
            "Primary natural-speech rows are the existing <=15-second subsets; not representative of long audio.",
            "Technical-term rows are synthetic speech, reported separately from natural-speech corpora.",
            "No microphone, user recordings, history transcripts, or private vocabulary are used.",
        ],
    }
    (output / "corpus.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    print(json.dumps(prepare(arguments.root.resolve(), arguments.output.resolve()), indent=2))


if __name__ == "__main__":
    main()
