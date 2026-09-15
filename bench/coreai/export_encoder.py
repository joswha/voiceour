"""Stage 1 of the Core AI encoder experiment: export the pinned NeMo encoder.

Runs where NeMo already installs — the devbox `envs/nemo` project — and never on
the Mac, which deliberately has no NeMo environment. The output is a
`torch.export` program (`.pt2`) holding the static 15 s, raw-1024-channel
FastConformer encoder, plus a machine-readable sidecar so stage 2
(`convert_encoder.py`, on the Mac) can record source provenance without
importing NeMo.

On the export host, set paths for its existing NeMo project, caches, and checkpoint:

    export PATH="$HOME/.local/bin:$PATH" UV_CACHE_DIR="<uv-cache>" \
           UV_PYTHON_INSTALL_DIR="<uv-python-installations>" \
           HF_HOME="<huggingface-cache>"
    cd "<nemo-project>"
    uv run python <repo>/bench/coreai/export_encoder.py \
        --nemo "<checkpoint>/parakeet-tdt-0.6b-v3.nemo" \
        --output encoder-15s.pt2

Copy `encoder-15s.pt2` and `encoder-15s.export.json` back to the Mac and pass
the `.pt2` to `convert_encoder.py`.

The checkpoint's SHA-256 and byte size are measured here and must equal the
pinned values below: every number the experiment reports is meaningful only for
that one checkpoint, so a mismatch is a hard failure rather than a warning.

This file duplicates the small digest helpers in `convert_encoder.py` instead of
importing them. The two stages run on different machines, and each one has to be
a single file to copy.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
import traceback
from datetime import UTC, datetime
from importlib import metadata
from pathlib import Path

import nemo
import torch
from nemo.collections.asr.models import ASRModel
from nemo.core.classes import typecheck

TOOL = "export_encoder.py"

# The pinned checkpoint, from research/bet3-mixed-quantize-provenance.json.
NEMO_MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"
NEMO_REVISION = "541d1f99c6b0c3cd0b11a95167540bb8edefd82b"
NEMO_SHA256 = "3cbdc85877e668ca7b82d0d56770eb1fac76691f55d6b97545e8d61ca588d10d"
NEMO_SIZE_BYTES = 2_509_332_480

# The IO contract is the Core ML tier's, verbatim (CoreMLEncoder.validate):
# a static 15 s window, 128 mel bins, 1024 raw encoder channels, subsampling 8.
MEL_BINS = 128
MEL_FRAMES = 1_501
ENCODER_CHANNELS = 1_024
SUBSAMPLING = 8
ENCODER_FRAMES = (MEL_FRAMES + SUBSAMPLING - 1) // SUBSAMPLING

SIDECAR_SCHEMA = "voiceour.coreai.export/1"

IO_CONTRACT = {
    "function": "main",
    "inputs": [
        {"name": "mel", "dtype": "float32", "shape": [1, MEL_BINS, MEL_FRAMES]},
        {"name": "mel_length", "dtype": "int32", "shape": [1]},
    ],
    "outputs": [
        {"name": "encoder", "dtype": "float32", "shape": [1, ENCODER_CHANNELS, ENCODER_FRAMES]},
        {"name": "encoder_length", "dtype": "int32", "shape": [1]},
    ],
}

READ_CHUNK_BYTES = 8 * 1024 * 1024


class EncoderOnly(torch.nn.Module):
    """The FastConformer encoder alone, carrying the tail's own IO dtypes.

    The length crosses the boundary as int32 — the contract the Core ML tier and
    the Swift adapter already use — while NeMo's encoder wants an int64 length
    internally, so the cast happens inside the exported graph rather than in
    whatever calls it.
    """

    def __init__(self, encoder: torch.nn.Module) -> None:
        super().__init__()
        self.encoder = encoder

    def forward(self, mel: torch.Tensor, mel_length: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        states, lengths = self.encoder(audio_signal=mel, length=mel_length.to(torch.int64))
        return states, lengths.to(torch.int32)


def sha256_file(path: Path) -> tuple[str, int]:
    """Return the file's hex SHA-256 and its byte size, read in one pass."""
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(READ_CHUNK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def nemo_version() -> str:
    """The installed NeMo version, from the package first and metadata second."""
    reported = getattr(nemo, "__version__", None)
    if reported:
        return str(reported)
    try:
        return metadata.version("nemo_toolkit")
    except metadata.PackageNotFoundError:
        return "unknown"


def stage_versions() -> dict:
    return {
        "python": platform.python_version(),
        "torch": torch.__version__,
        "nemo_toolkit": nemo_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
    }


def now_utc() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def verify_checkpoint(path: Path) -> dict:
    """Measure the checkpoint and refuse anything but the pinned one."""
    if not path.is_file():
        raise SystemExit(f"{TOOL}: missing checkpoint: {path}")
    print(f"{TOOL}: digesting {path} ({path.stat().st_size} bytes)", flush=True)
    digest, size = sha256_file(path)
    if digest != NEMO_SHA256 or size != NEMO_SIZE_BYTES:
        raise SystemExit(
            f"{TOOL}: {path} is not the pinned checkpoint.\n"
            f"  measured sha256={digest} size={size}\n"
            f"  expected sha256={NEMO_SHA256} size={NEMO_SIZE_BYTES}\n"
            f"  fetch {NEMO_MODEL_ID} at revision {NEMO_REVISION}."
        )
    return {
        "model_id": NEMO_MODEL_ID,
        "revision": NEMO_REVISION,
        "file": path.name,
        "path": str(path),
        "sha256": digest,
        "size_bytes": size,
    }


def load_encoder(path: Path) -> torch.nn.Module:
    """Restore the pinned checkpoint on the CPU and hand back its encoder."""
    # NeMo's NeuralType checking wraps every forward in Python-level validation
    # that torch.export has no reason to trace; NeMo's own export path disables
    # it the same way.
    typecheck.set_typecheck_enabled(enabled=False)
    model = ASRModel.restore_from(restore_path=str(path), map_location=torch.device("cpu"))
    model.eval()
    encoder = getattr(model, "encoder", None)
    if encoder is None:
        raise SystemExit(f"{TOOL}: the model restored from {path} has no `encoder` submodule")
    return encoder


def export_program(module: torch.nn.Module, mel: torch.Tensor, mel_length: torch.Tensor) -> tuple:
    """Export strictly, then exactly once more non-strictly if strict failed.

    Returns ``(program, strict, attempts)``; ``attempts`` holds the formatted
    traceback of every failed attempt so a blocked export can be recorded whole.
    """
    attempts: list[dict] = []
    for strict in (True, False):
        print(f"{TOOL}: torch.export.export(strict={strict})", flush=True)
        try:
            program = torch.export.export(module, (mel, mel_length), strict=strict)
        except Exception:
            attempts.append({"strict": strict, "traceback": traceback.format_exc()})
            continue
        return program, strict, attempts
    return None, None, attempts


def check_program_outputs(program: torch.export.ExportedProgram, mel: torch.Tensor, mel_length: torch.Tensor) -> dict:
    """Run the exported program once and hold it to the IO contract."""
    with torch.no_grad():
        states, lengths = program.module()(mel, mel_length)

    expected_states = (1, ENCODER_CHANNELS, ENCODER_FRAMES)
    if tuple(states.shape) != expected_states or states.dtype != torch.float32:
        raise SystemExit(
            f"{TOOL}: the exported encoder output is {tuple(states.shape)} {states.dtype}, "
            f"expected {expected_states} torch.float32"
        )
    if tuple(lengths.shape) != (1,) or lengths.dtype != torch.int32:
        raise SystemExit(
            f"{TOOL}: the exported encoder_length output is {tuple(lengths.shape)} {lengths.dtype}, "
            f"expected (1,) torch.int32"
        )
    length_value = int(lengths[0])
    if length_value != ENCODER_FRAMES:
        raise SystemExit(
            f"{TOOL}: the exported program reports {length_value} encoder frames for "
            f"{MEL_FRAMES} mel frames, expected {ENCODER_FRAMES}"
        )
    return {
        "encoder_shape": list(states.shape),
        "encoder_dtype": str(states.dtype).removeprefix("torch."),
        "encoder_length_shape": list(lengths.shape),
        "encoder_length_dtype": str(lengths.dtype).removeprefix("torch."),
        "encoder_length_value": length_value,
    }


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=TOOL,
        description="Export the pinned Parakeet FastConformer encoder to a static 15 s torch.export program.",
    )
    parser.add_argument("--nemo", required=True, type=Path, help="the pinned parakeet-tdt-0.6b-v3.nemo checkpoint")
    parser.add_argument("--output", required=True, type=Path, help="the .pt2 exported program to write")
    parser.add_argument(
        "--metadata",
        type=Path,
        default=None,
        help="the JSON export sidecar to write; defaults to the output with a .export.json suffix",
    )
    parser.add_argument("--force", action="store_true", help="overwrite an existing output or sidecar")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    output: Path = args.output
    metadata_path: Path = args.metadata if args.metadata is not None else output.with_suffix(".export.json")

    if output.suffix != ".pt2":
        raise SystemExit(f"{TOOL}: --output must name a .pt2 file: {output}")
    for existing in (output, metadata_path):
        if existing.exists() and not args.force:
            raise SystemExit(f"{TOOL}: refusing to overwrite {existing}; pass --force or remove it")

    source = verify_checkpoint(args.nemo)
    encoder = load_encoder(args.nemo)

    mel = torch.zeros(1, MEL_BINS, MEL_FRAMES)
    mel_length = torch.tensor([MEL_FRAMES], dtype=torch.int32)

    program, strict, attempts = export_program(EncoderOnly(encoder).eval(), mel, mel_length)
    if program is None:
        failure = {
            "schema": SIDECAR_SCHEMA,
            "status": "export blocked",
            "created_at": now_utc(),
            "source_checkpoint": source,
            "io": IO_CONTRACT,
            "versions": stage_versions(),
            "export_attempts": attempts,
        }
        write_json(metadata_path, failure)
        detail = "\n\n".join(
            f"--- torch.export.export(strict={attempt['strict']}) ---\n{attempt['traceback']}" for attempt in attempts
        )
        raise SystemExit(
            f"{TOOL}: torch.export failed both strictly and non-strictly for {args.nemo}.\n"
            f"{TOOL}: recorded in {metadata_path}\n\n{detail}"
        )

    observed = check_program_outputs(program, mel, mel_length)

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    torch.export.save(program, output)
    program_sha256, program_size = sha256_file(output)

    sidecar = {
        "schema": SIDECAR_SCHEMA,
        "status": "ok",
        "created_at": now_utc(),
        "source_checkpoint": source,
        "exported_program": {
            "file": output.name,
            "sha256": program_sha256,
            "size_bytes": program_size,
            "tree_sha256": hashlib.sha256(f"{output.name} {program_sha256}\n".encode()).hexdigest(),
            "strict": strict,
            "retried_non_strict": bool(attempts),
        },
        "io": IO_CONTRACT,
        "observed": observed,
        "versions": stage_versions(),
    }
    if attempts:
        sidecar["export_attempts"] = attempts
    write_json(metadata_path, sidecar)

    print(f"{TOOL}: nemo            {source['file']}")
    print(f"{TOOL}: nemo sha256     {source['sha256']}")
    print(f"{TOOL}: nemo size       {source['size_bytes']} bytes")
    print(f"{TOOL}: nemo revision   {source['revision']}")
    print(f"{TOOL}: program         {output}")
    print(f"{TOOL}: program sha256  {sidecar['exported_program']['sha256']}")
    print(f"{TOOL}: program size    {sidecar['exported_program']['size_bytes']} bytes")
    print(f"{TOOL}: strict export   {strict} (retried non-strictly: {bool(attempts)})")
    print(f"{TOOL}: encoder         {observed['encoder_shape']} {observed['encoder_dtype']}")
    print(
        f"{TOOL}: encoder_length  {observed['encoder_length_shape']} "
        f"{observed['encoder_length_dtype']} = {observed['encoder_length_value']}"
    )
    print(f"{TOOL}: torch           {torch.__version__}")
    print(f"{TOOL}: nemo_toolkit    {nemo_version()}")
    print(f"{TOOL}: sidecar         {metadata_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
