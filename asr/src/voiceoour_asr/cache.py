from __future__ import annotations

import json
import os
from pathlib import Path

from huggingface_hub import snapshot_download

MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"
MODEL_REVISION = "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
APP_CACHE = Path(os.environ.get("VOICEOOUR_MODEL_CACHE", Path.home() / "Library" / "Caches" / "VoiceOour" / "parakeet"))
MANIFEST = APP_CACHE / "manifest.json"


class ManifestMismatch(RuntimeError):
    pass


def manifest() -> dict[str, str] | None:
    try:
        raw = MANIFEST.read_text()
        data = json.loads(raw)
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _valid_snapshot_path(data: dict[str, str]) -> Path | None:
    snapshot_path = data.get("snapshot_path")
    if not isinstance(snapshot_path, str) or not snapshot_path:
        return None
    path = Path(snapshot_path)
    return path if path.is_dir() else None


def cache_ok() -> bool:
    data = manifest()
    return bool(
        data
        and data.get("model_id") == MODEL_ID
        and data.get("revision") == MODEL_REVISION
        and _valid_snapshot_path(data) is not None
    )


def ensure_model() -> Path:
    APP_CACHE.mkdir(parents=True, exist_ok=True)
    existing = manifest()
    if existing:
        if existing.get("model_id") != MODEL_ID or existing.get("revision") != MODEL_REVISION:
            raise ManifestMismatch(f"manifest has {existing}")
        snapshot_path = _valid_snapshot_path(existing)
        if snapshot_path is not None:
            os.environ["HF_HUB_OFFLINE"] = "1"
            return snapshot_path
        MANIFEST.unlink(missing_ok=True)
    snapshot_path = Path(snapshot_download(repo_id=MODEL_ID, revision=MODEL_REVISION, cache_dir=str(APP_CACHE)))
    MANIFEST.write_text(
        json.dumps(
            {"model_id": MODEL_ID, "revision": MODEL_REVISION, "snapshot_path": str(snapshot_path)},
            indent=2,
            sort_keys=True,
        )
    )
    os.environ["HF_HUB_OFFLINE"] = "1"
    return snapshot_path
