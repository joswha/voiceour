"""Tests for the native WAV fast path that bypasses parakeet's ffmpeg decode."""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

from voiceoour_asr.backends.mlx import load_pcm16_mono_wav


def write_wav(
    path: Path, *, rate: int = 16000, channels: int = 1, sampwidth: int = 2, samples: np.ndarray | None = None
) -> np.ndarray:
    if samples is None:
        samples = (np.sin(np.linspace(0, 40 * np.pi, rate // 10)) * 12000).astype("<i2")
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(channels)
        writer.setsampwidth(sampwidth)
        writer.setframerate(rate)
        writer.writeframes(samples.tobytes())
    return samples


def test_loads_native_16k_mono_pcm16(tmp_path):
    path = tmp_path / "native.wav"
    samples = write_wav(path)

    decoded = load_pcm16_mono_wav(path, 16000)

    assert decoded is not None
    assert decoded.dtype == np.float32
    assert decoded.shape == samples.shape
    np.testing.assert_allclose(decoded, samples.astype(np.float32) / 32768.0)
    assert np.all(decoded >= -1.0)
    assert np.all(decoded < 1.0)


def test_rejects_wrong_sample_rate(tmp_path):
    path = tmp_path / "rate.wav"
    write_wav(path, rate=44100)

    assert load_pcm16_mono_wav(path, 16000) is None


def test_rejects_stereo(tmp_path):
    path = tmp_path / "stereo.wav"
    stereo = np.zeros(3200, dtype="<i2")
    write_wav(path, channels=2, samples=stereo)

    assert load_pcm16_mono_wav(path, 16000) is None


def test_rejects_non_16bit(tmp_path):
    path = tmp_path / "wide.wav"
    wide = np.zeros(1600, dtype="<i4")
    write_wav(path, sampwidth=4, samples=wide)

    assert load_pcm16_mono_wav(path, 16000) is None


def test_rejects_non_wav_bytes(tmp_path):
    path = tmp_path / "not-a.wav"
    path.write_bytes(b"definitely not RIFF data")

    assert load_pcm16_mono_wav(path, 16000) is None


def test_rejects_missing_file(tmp_path):
    assert load_pcm16_mono_wav(tmp_path / "absent.wav", 16000) is None
