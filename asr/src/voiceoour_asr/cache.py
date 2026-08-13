from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

from huggingface_hub import snapshot_download


@dataclass(frozen=True)
class ModelSpec:
    """A pinned model repo and the app-owned directory its snapshot lives in."""

    model_id: str
    revision: str
    cache_dir: Path
    allow_patterns: tuple[str, ...] | None = None


def _app_cache(name: str) -> Path:
    return Path.home() / "Library" / "Caches" / "VoiceOour" / name


#: Weights plus tokenizer/feature-extractor assets. The ARK model repos also ship
#: their Python runtime (src/**, scripts/**, tests/**); that code is vendored under
#: backends/ark_mlx, so the download must not pull it in.
_ARK_ALLOW_PATTERNS = (
    "model.safetensors",
    "config.json",
    "generation_config.json",
    "preprocessor_config.json",
    "processor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "added_tokens.json",
    "special_tokens_map.json",
    "chat_template.jinja",
)

PARAKEET = ModelSpec(
    model_id="mlx-community/parakeet-tdt-0.6b-v3",
    revision="ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15",
    cache_dir=Path(os.environ.get("VOICEOOUR_MODEL_CACHE", _app_cache("parakeet"))),
)

ARK_06B = ModelSpec(
    model_id="leope/ark-asr-0.6B-mlx",
    revision="6ec069bd68cbbe165aa42728eac482c90cb58d2f",
    cache_dir=_app_cache("ark-0.6b"),
    allow_patterns=_ARK_ALLOW_PATTERNS,
)

ARK_3B = ModelSpec(
    model_id="leope/ark-asr-3B-mlx",
    revision="63d9fb8ba352c5c7c65ff2336019048170563d63",
    cache_dir=_app_cache("ark-3b"),
    allow_patterns=_ARK_ALLOW_PATTERNS,
)

#: Parakeet's identity as bare module constants: the default backend and its
#: callers predate ModelSpec and still read these.
MODEL_ID = PARAKEET.model_id
MODEL_REVISION = PARAKEET.revision


class ManifestMismatch(RuntimeError):
    pass


def _manifest_path(spec: ModelSpec) -> Path:
    return spec.cache_dir / "manifest.json"


def manifest(spec: ModelSpec) -> dict[str, str] | None:
    try:
        raw = _manifest_path(spec).read_text()
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


def cache_ok(spec: ModelSpec) -> bool:
    data = manifest(spec)
    return bool(
        data
        and data.get("model_id") == spec.model_id
        and data.get("revision") == spec.revision
        and _valid_snapshot_path(data) is not None
    )


def ensure_model(spec: ModelSpec) -> Path:
    spec.cache_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = _manifest_path(spec)
    existing = manifest(spec)
    if existing:
        if existing.get("model_id") != spec.model_id or existing.get("revision") != spec.revision:
            raise ManifestMismatch(f"manifest has {existing}")
        snapshot_path = _valid_snapshot_path(existing)
        if snapshot_path is not None:
            os.environ["HF_HUB_OFFLINE"] = "1"
            return snapshot_path
        manifest_path.unlink(missing_ok=True)
    snapshot_path = Path(
        snapshot_download(
            repo_id=spec.model_id,
            revision=spec.revision,
            cache_dir=str(spec.cache_dir),
            allow_patterns=list(spec.allow_patterns) if spec.allow_patterns else None,
        )
    )
    manifest_path.write_text(
        json.dumps(
            {"model_id": spec.model_id, "revision": spec.revision, "snapshot_path": str(snapshot_path)},
            indent=2,
            sort_keys=True,
        )
    )
    os.environ["HF_HUB_OFFLINE"] = "1"
    return snapshot_path
