from __future__ import annotations

import dataclasses
import importlib
import json
from threading import Event

import pytest

from voiceoour_asr import cache
from voiceoour_asr.__main__ import make_backend
from voiceoour_asr.backends.ark import ArkBackend
from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import AudioMeta, ExpectedModel, TranscribeRequest

ARK_BACKENDS = [("ark-0.6b", cache.ARK_06B), ("ark-3b", cache.ARK_3B)]


@pytest.fixture
def default_cache(monkeypatch: pytest.MonkeyPatch):
    """The cache module as an install without VOICEOOUR_MODEL_CACHE sees it."""
    with monkeypatch.context() as isolated_env:
        isolated_env.delenv("VOICEOOUR_MODEL_CACHE", raising=False)
        yield importlib.reload(cache)
    importlib.reload(cache)


def transcribe_request(model_id: str, revision: str) -> TranscribeRequest:
    return TranscribeRequest(
        request_id="req",
        audio=AudioMeta(
            path="/tmp/voiceoour-absent.wav",
            format="wav",
            sample_rate_hz=16000,
            channels=1,
            duration_ms=1000,
            byte_count=32000,
        ),
        timeout_ms=30000,
        expected_model=ExpectedModel(model_id=model_id, revision=revision),
    )


def local_spec(spec: cache.ModelSpec, tmp_path) -> cache.ModelSpec:
    return dataclasses.replace(spec, cache_dir=tmp_path / spec.cache_dir.name)


@pytest.mark.parametrize("backend_name", [name for name, _ in ARK_BACKENDS])
def test_make_backend_maps_ark_ids_to_ark_backend(monkeypatch: pytest.MonkeyPatch, backend_name):
    monkeypatch.setenv("VOICEOOUR_ASR_BACKEND", backend_name)

    backend = make_backend()

    assert isinstance(backend, ArkBackend)
    assert backend.backend_id == backend_name


@pytest.mark.parametrize(("backend_name", "spec"), ARK_BACKENDS)
def test_ark_backend_accepts_its_own_pinned_model(monkeypatch: pytest.MonkeyPatch, backend_name, spec):
    """A matching expected_model gets past the identity gate; the absent audio proves no model was loaded."""
    monkeypatch.setenv("VOICEOOUR_ASR_BACKEND", backend_name)

    result = make_backend().transcribe(transcribe_request(spec.model_id, spec.revision), Event())

    assert result.code == ErrorCode.AUDIO_NOT_FOUND


@pytest.mark.parametrize(("backend_name", "spec"), ARK_BACKENDS)
def test_ark_backend_rejects_the_other_ark_model(monkeypatch: pytest.MonkeyPatch, backend_name, spec):
    other = next(other for name, other in ARK_BACKENDS if name != backend_name)
    monkeypatch.setenv("VOICEOOUR_ASR_BACKEND", backend_name)

    result = make_backend().transcribe(transcribe_request(other.model_id, other.revision), Event())

    assert result.code == ErrorCode.MANIFEST_MISMATCH
    assert result.detail == "expected_model model_id mismatch"


@pytest.mark.parametrize(("backend_name", "spec"), ARK_BACKENDS)
def test_ark_backend_rejects_a_stale_revision(monkeypatch: pytest.MonkeyPatch, backend_name, spec):
    monkeypatch.setenv("VOICEOOUR_ASR_BACKEND", backend_name)

    result = make_backend().transcribe(transcribe_request(spec.model_id, "0" * 40), Event())

    assert result.code == ErrorCode.MANIFEST_MISMATCH
    assert result.detail == "expected_model revision mismatch"


def test_model_caches_do_not_collide(default_cache):
    specs = [default_cache.PARAKEET, default_cache.ARK_06B, default_cache.ARK_3B]

    assert len({spec.cache_dir for spec in specs}) == len(specs)
    assert len({spec.model_id for spec in specs}) == len(specs)


def test_parakeet_keeps_its_existing_cache_directory(default_cache):
    assert default_cache.PARAKEET.cache_dir.name == "parakeet"
    assert default_cache.PARAKEET.cache_dir.parent.name == "VoiceOour"


@pytest.mark.parametrize("spec", [cache.ARK_06B, cache.ARK_3B])
def test_ark_downloads_assets_but_never_the_repo_source(spec):
    patterns = spec.allow_patterns

    assert patterns is not None
    assert "model.safetensors" in patterns
    assert "tokenizer.json" in patterns
    assert not [pattern for pattern in patterns if pattern.split("/")[0] in {"src", "scripts", "tests"}]


def test_cache_state_is_scoped_to_its_spec(tmp_path):
    """One model's manifest never satisfies another's cache check."""
    downloaded = local_spec(cache.ARK_06B, tmp_path)
    snapshot = downloaded.cache_dir / "snapshot"
    snapshot.mkdir(parents=True)
    (downloaded.cache_dir / "manifest.json").write_text(
        json.dumps(
            {"model_id": downloaded.model_id, "revision": downloaded.revision, "snapshot_path": str(snapshot)}
        )
    )
    absent = local_spec(cache.ARK_3B, tmp_path)

    assert cache.cache_ok(downloaded) is True
    assert cache.manifest(absent) is None
    assert cache.cache_ok(absent) is False


def test_health_reports_a_missing_ark_cache(tmp_path):
    backend = ArkBackend(local_spec(cache.ARK_3B, tmp_path), "ark-3b")

    health = backend.health()

    assert health.cache_ok is False
    assert health.ready is False
    assert health.model_loaded is False
