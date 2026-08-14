"""Generate deterministic noisy LibriSpeech benchmark inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import sys
import wave
from array import array
from collections.abc import Iterable
from pathlib import Path
from typing import Any

SEED = 20260718
SNRS_DB = (20, 10, 5, 0)
BASE_MANIFEST = Path("benchmarks/data/librispeech/manifest.jsonl")
BASE_RESULTS = Path("benchmarks/results/20260717T131734Z-librispeech-apple-stt.results.jsonl")
OUTPUT_ROOT = Path("benchmarks/data/librispeech-noise")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def _write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def canonical_subset(manifest_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Select test-clean/test-other utterances 000001 through 000032."""

    selected: list[dict[str, Any]] = []
    counts = {"clean": 0, "other": 0}
    for row in manifest_rows:
        row_id = row.get("id")
        if not isinstance(row_id, str):
            continue
        for split in counts:
            prefix = f"librispeech-test.{split}-"
            if not row_id.startswith(prefix):
                continue
            suffix = row_id.removeprefix(prefix)
            if suffix.isdigit() and 1 <= int(suffix) <= 32:
                selected.append(row)
                counts[split] += 1
            break

    if counts != {"clean": 32, "other": 32} or len(selected) != 64:
        raise ValueError(f"expected 32 test-clean and 32 test-other rows, got {counts}")
    return selected


def verify_baseline_subset(rows: list[dict[str, Any]], results_path: Path) -> None:
    """Ensure the selected IDs exactly match the prior Apple baseline run."""

    baseline_ids = {
        row["id"] for row in _read_jsonl(results_path) if row.get("type") == "row" and isinstance(row.get("id"), str)
    }
    selected_ids = {row["id"] for row in rows}
    if baseline_ids != selected_ids:
        missing = sorted(baseline_ids - selected_ids)
        extra = sorted(selected_ids - baseline_ids)
        raise ValueError(f"canonical subset differs from baseline results: missing={missing}, extra={extra}")


def _rng(seed: int, row_id: str, snr_db: int) -> random.Random:
    material = f"{seed}:{row_id}:{snr_db}".encode()
    derived_seed = int.from_bytes(hashlib.sha256(material).digest()[:16], "big")
    return random.Random(derived_seed)


def _read_pcm16_mono(path: Path) -> tuple[wave._wave_params, array[int]]:
    with wave.open(str(path), "rb") as source:
        params = source.getparams()
        if params.nchannels != 1 or params.sampwidth != 2 or params.comptype != "NONE":
            raise ValueError(
                f"{path} must be uncompressed 16-bit mono PCM; got "
                f"channels={params.nchannels}, sample_width={params.sampwidth}, compression={params.comptype}"
            )
        payload = source.readframes(params.nframes)

    samples = array("h")
    samples.frombytes(payload)
    if sys.byteorder != "little":
        samples.byteswap()
    if len(samples) != params.nframes:
        raise ValueError(f"{path} declared {params.nframes} frames but contained {len(samples)}")
    return params, samples


def _write_pcm16_mono(path: Path, params: wave._wave_params, samples: array[int]) -> None:
    payload = array("h", samples)
    if sys.byteorder != "little":
        payload.byteswap()
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as destination:
        destination.setparams(params)
        destination.writeframes(payload.tobytes())


def add_gaussian_noise(source: Path, destination: Path, row_id: str, snr_db: int, seed: int = SEED) -> None:
    """Add Gaussian noise at an exact pre-quantization RMS ratio.

    If the mixture would clip, speech and noise are attenuated together, which
    preserves the requested SNR while keeping the output valid PCM16.
    """

    params, speech = _read_pcm16_mono(source)
    if not speech:
        raise ValueError(f"cannot synthesize noise for empty WAV: {source}")

    speech_rms = math.sqrt(math.fsum(float(sample) * sample for sample in speech) / len(speech))
    if speech_rms == 0:
        raise ValueError(f"cannot scale noise against silent WAV: {source}")

    generator = _rng(seed, row_id, snr_db)
    noise = array("d", (generator.gauss(0.0, 1.0) for _ in speech))
    raw_noise_rms = math.sqrt(math.fsum(value * value for value in noise) / len(noise))
    target_noise_rms = speech_rms / math.pow(10.0, snr_db / 20.0)
    noise_gain = target_noise_rms / raw_noise_rms

    peak = max(abs(sample + value * noise_gain) for sample, value in zip(speech, noise, strict=True))
    mix_gain = min(1.0, 32767.0 / peak) if peak else 1.0
    mixed = array(
        "h",
        (
            max(-32768, min(32767, round((sample + value * noise_gain) * mix_gain)))
            for sample, value in zip(speech, noise, strict=True)
        ),
    )
    _write_pcm16_mono(destination, params, mixed)


def generate(
    root: Path | None = None,
    manifest_path: Path = BASE_MANIFEST,
    baseline_results_path: Path = BASE_RESULTS,
    output_root: Path = OUTPUT_ROOT,
    snrs_db: tuple[int, ...] = SNRS_DB,
    seed: int = SEED,
) -> list[Path]:
    """Generate all noisy WAVs and one 64-row manifest per SNR."""

    root = (root or repo_root()).resolve()
    manifest_path = root / manifest_path if not manifest_path.is_absolute() else manifest_path
    baseline_results_path = (
        root / baseline_results_path if not baseline_results_path.is_absolute() else baseline_results_path
    )
    output_root = root / output_root if not output_root.is_absolute() else output_root

    rows = canonical_subset(_read_jsonl(manifest_path))
    verify_baseline_subset(rows, baseline_results_path)
    manifests: list[Path] = []
    for snr_db in snrs_db:
        snr_dir = output_root / f"snr{snr_db:02d}"
        output_rows: list[dict[str, Any]] = []
        for row in rows:
            source = root / row["audio_path"]
            destination = snr_dir / source.name
            add_gaussian_noise(source, destination, row["id"], snr_db, seed)
            output_row = dict(row)
            output_row["audio_path"] = str(destination.relative_to(root))
            output_rows.append(output_row)
        manifest = snr_dir / "manifest.jsonl"
        _write_jsonl(manifest, output_rows)
        manifests.append(manifest)
    return manifests


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate deterministic Gaussian-noise LibriSpeech benchmark WAVs.")
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--snr", type=int, nargs="+", default=list(SNRS_DB), metavar="DB")
    args = parser.parse_args(argv)
    for manifest in generate(seed=args.seed, snrs_db=tuple(args.snr)):
        print(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
