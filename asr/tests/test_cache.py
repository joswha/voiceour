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


def write_manifest(spec, data: dict[str, str] | str) -> None:
    spec.cache_dir.mkdir(parents=True, exist_ok=True)
    manifest = spec.cache_dir / "manifest.json"
    if isinstance(data, str):
        manifest.write_text(data)
    else:
        manifest.write_text(json.dumps(data))


def matching_manifest(spec, snapshot_path: str | None = None) -> dict[str, str]:
    data = {
        "model_id": spec.model_id,
        "revision": spec.revision,
    }
    if snapshot_path is not None:
        data["snapshot_path"] = snapshot_path
    return data


def test_cache_ok_returns_false_for_malformed_manifest_json(cache_module):
    write_manifest(cache_module.PARAKEET, "{not-json")

    assert cache_module.cache_ok(cache_module.PARAKEET) is False


@pytest.mark.parametrize(
    ("name", "snapshot_path"),
    [
        ("missing field", None),
        ("missing directory", "missing-snapshot"),
    ],
)
def test_cache_ok_returns_false_when_matching_manifest_has_no_existing_snapshot(cache_module, name, snapshot_path):
    spec = cache_module.PARAKEET
    path = None if snapshot_path is None else str(spec.cache_dir / snapshot_path)
    write_manifest(spec, matching_manifest(spec, path))

    assert cache_module.cache_ok(spec) is False, name


def test_cache_ok_returns_true_for_matching_manifest_with_existing_snapshot_dir(cache_module):
    spec = cache_module.PARAKEET
    snapshot = spec.cache_dir / "snapshot"
    snapshot.mkdir(parents=True)
    write_manifest(spec, matching_manifest(spec, str(snapshot)))

    assert cache_module.cache_ok(spec) is True


def test_cache_ok_returns_false_for_a_manifest_pinning_another_revision(cache_module):
    spec = cache_module.PARAKEET
    snapshot = spec.cache_dir / "snapshot"
    snapshot.mkdir(parents=True)
    stale = matching_manifest(spec, str(snapshot)) | {"revision": "0" * 40}
    write_manifest(spec, stale)

    assert cache_module.cache_ok(spec) is False


def test_model_cache_env_override_moves_parakeet_only(cache_module, tmp_path):
    assert cache_module.PARAKEET.cache_dir == tmp_path
    assert tmp_path not in cache_module.ARK_06B.cache_dir.parents
    assert tmp_path not in cache_module.ARK_3B.cache_dir.parents


def test_module_constants_still_name_parakeet(cache_module):
    assert cache_module.MODEL_ID == cache_module.PARAKEET.model_id
    assert cache_module.MODEL_REVISION == cache_module.PARAKEET.revision
