from __future__ import annotations

import importlib
import json

import pytest


@pytest.fixture
def cache_module(monkeypatch: pytest.MonkeyPatch, tmp_path):
    import voiceoour_asr.cache as cache

    with monkeypatch.context() as isolated_env:
        isolated_env.setenv("VOICEOOUR_MODEL_CACHE", str(tmp_path))
        cache = importlib.reload(cache)
        yield cache
    importlib.reload(cache)


def write_manifest(cache_module, data: dict[str, str] | str) -> None:
    cache_module.APP_CACHE.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        cache_module.MANIFEST.write_text(data)
    else:
        cache_module.MANIFEST.write_text(json.dumps(data))


def matching_manifest(cache_module, snapshot_path: str | None = None) -> dict[str, str]:
    data = {
        "model_id": cache_module.MODEL_ID,
        "revision": cache_module.MODEL_REVISION,
    }
    if snapshot_path is not None:
        data["snapshot_path"] = snapshot_path
    return data


def test_cache_ok_returns_false_for_malformed_manifest_json(cache_module):
    write_manifest(cache_module, "{not-json")

    assert cache_module.cache_ok() is False


@pytest.mark.parametrize(
    ("name", "snapshot_path"),
    [
        ("missing field", None),
        ("missing directory", "missing-snapshot"),
    ],
)
def test_cache_ok_returns_false_when_matching_manifest_has_no_existing_snapshot(cache_module, name, snapshot_path):
    path = None if snapshot_path is None else str(cache_module.APP_CACHE / snapshot_path)
    write_manifest(cache_module, matching_manifest(cache_module, path))

    assert cache_module.cache_ok() is False, name


def test_cache_ok_returns_true_for_matching_manifest_with_existing_snapshot_dir(cache_module):
    snapshot = cache_module.APP_CACHE / "snapshot"
    snapshot.mkdir(parents=True)
    write_manifest(cache_module, matching_manifest(cache_module, str(snapshot)))

    assert cache_module.cache_ok() is True
