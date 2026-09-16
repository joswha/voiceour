"""Compare CoreAI Swift stage captures against pinned PyTorch graph traces."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from coreai_common import read_json, write_json


def difference(reference: np.ndarray, candidate: np.ndarray) -> dict:
    if reference.shape != candidate.shape:
        raise ValueError(f"Shape mismatch: {reference.shape} versus {candidate.shape}")
    expected = reference.astype(np.float64)
    actual = candidate.astype(np.float64)
    if not np.isfinite(expected).all() or not np.isfinite(actual).all():
        raise ValueError("Non-finite parity tensor")
    delta = actual - expected
    denominator = np.linalg.norm(expected.ravel())
    return {
        "shape": list(reference.shape),
        "reference_dtype": str(reference.dtype),
        "candidate_dtype": str(candidate.dtype),
        "maximum_absolute_error": float(np.max(np.abs(delta))),
        "mean_absolute_error": float(np.mean(np.abs(delta))),
        "root_mean_square_error": float(np.sqrt(np.mean(delta * delta))),
        "relative_l2_error": float(np.linalg.norm(delta.ravel()) / denominator) if denominator else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--capture-prefix", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prefix = str(args.capture_prefix)
    capture = read_json(Path(prefix + ".json"))
    with np.load(args.reference, allow_pickle=False) as reference:
        mel = np.fromfile(prefix + ".mel.f32", dtype="<f4").reshape(capture["mel_shape"])
        encoder = np.fromfile(prefix + ".encoder.f32", dtype="<f4").reshape(capture["encoder_shape"])
        report = {
            "schema_version": 1,
            "id": capture["id"],
            "reference": str(args.reference),
            "capture_prefix": prefix,
            "mel": difference(reference["input_features"], mel),
            "encoder": difference(reference["encoder_hidden_states"], encoder),
            "transcript": capture["text"],
            "tokens": capture["tokens"],
            "interpretation": (
                "Numerical differences are reported, not converted into an arbitrary "
                "accuracy verdict; evaluate transcripts on the shared corpus."
            ),
        }
    write_json(args.output, report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
