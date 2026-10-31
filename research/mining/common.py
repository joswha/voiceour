"""Shared helpers for the real-speaker technical-speech mining pipeline.

Every stage writes a manifest.json next to its outputs recording: stage name,
argv, input digests, parameters, timings, output digests, and an environment
fingerprint (python/torch/nemo versions + uv.lock digest). Manifests are the
reproducibility contract; nothing in this pipeline is allowed to be implicit.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

RESEARCH_ROOT = Path(os.environ.get("VOICEOUR_RESEARCH_ROOT", "/srv/devbox/research/voiceour"))
NEMO_ENV_DIR = RESEARCH_ROOT / "envs" / "nemo"


def sha256_file(path: str | Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest_record(path: str | Path) -> dict[str, Any]:
    p = Path(path)
    return {
        "path": str(p),
        "bytes": p.stat().st_size,
        "sha256": sha256_file(p),
    }


def _pkg_version(name: str) -> str | None:
    try:
        from importlib.metadata import version

        return version(name)
    except Exception:
        return None


def env_fingerprint() -> dict[str, Any]:
    lock = NEMO_ENV_DIR / "uv.lock"
    pyproject = NEMO_ENV_DIR / "pyproject.toml"
    fp: dict[str, Any] = {
        "env_dir": str(NEMO_ENV_DIR),
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "packages": {
            name: _pkg_version(name)
            for name in (
                "torch",
                "torchaudio",
                "nemo_toolkit",
                "transformers",
                "silero-vad",
                "static-ffmpeg",
                "soundfile",
                "rapidfuzz",
                "numpy",
            )
        },
    }
    if lock.exists():
        fp["uv_lock_sha256"] = sha256_file(lock)
    if pyproject.exists():
        fp["pyproject_sha256"] = sha256_file(pyproject)
    try:
        import torch

        fp["cuda_available"] = bool(torch.cuda.is_available())
        if torch.cuda.is_available():
            fp["cuda_device"] = torch.cuda.get_device_name(0)
            fp["cuda_capability"] = list(torch.cuda.get_device_capability(0))
            fp["torch_cuda"] = torch.version.cuda
    except Exception as exc:  # pragma: no cover - torch always present in envs/nemo
        fp["torch_import_error"] = repr(exc)
    return fp


def gpu_snapshot() -> dict[str, Any]:
    """nvidia-smi snapshot; used to prove the GPU was idle/ours during a run."""
    try:
        out = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.used,memory.total,utilization.gpu",
                "--format=csv,noheader",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        ).stdout.strip()
        apps = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory", "--format=csv,noheader"],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        ).stdout.strip()
        return {"gpu": out, "compute_apps": apps or "(none)"}
    except Exception as exc:
        return {"error": repr(exc)}


def write_manifest(out_dir: str | Path, stage: str, payload: dict[str, Any]) -> Path:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    manifest = {
        "stage": stage,
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "argv": sys.argv,
        "command": " ".join(shlex.quote(a) for a in [sys.executable.split("/")[-1], *sys.argv]),
        "cwd": os.getcwd(),
        "env": env_fingerprint(),
        **payload,
    }
    path = out / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n")
    cmd_path = out / "command.txt"
    cmd_path.write_text(
        "# stage: %s\n# run from %s inside `uv run` in %s\nuv run python %s\n"
        % (
            stage,
            os.getcwd(),
            NEMO_ENV_DIR,
            " ".join(shlex.quote(a) for a in sys.argv),
        )
    )
    return path


def read_jsonl(path: str | Path) -> list[dict[str, Any]]:
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def write_jsonl(path: str | Path, rows: list[dict[str, Any]]) -> dict[str, Any]:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "w") as fh:
        for row in rows:
            fh.write(json.dumps(row, sort_keys=False) + "\n")
    return file_digest_record(p)


class Timer:
    def __init__(self) -> None:
        self.t0 = time.perf_counter()

    def lap(self) -> float:
        return round(time.perf_counter() - self.t0, 3)



# NeMo emits U+2047 (⁇) for unknown/OOV output. On non-speech input (applause,
# music, room noise) parakeet-tdt degenerates into long ⁇ runs — observed at up
# to 127 "words"/s vs 2.6 for real speech. Such hypotheses carry no text and
# must not be counted as transcribed speech.
UNK_TOKEN = "\u2047"


def unk_stats(text: str | None) -> dict[str, Any]:
    toks = (text or "").split()
    unk = sum(1 for t in toks if t == UNK_TOKEN)
    return {
        "tokens": len(toks),
        "unk_tokens": unk,
        "unk_ratio": round(unk / len(toks), 4) if toks else 0.0,
        "degenerate": bool(toks) and unk / len(toks) >= 0.5,
    }