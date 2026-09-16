"""Pinned-artifact IO and speech decoding shared by the benchmark-only CLIs."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path

MODELS = {
    "parakeet": ("nvidia/parakeet-tdt-0.6b-v3",),
    "whisper": ("openai/whisper-large-v3-turbo", "openai/whisper-large-v3"),
    "wav2vec2": ("wav2vec2_asr_base_960h",),
}
WAV2VEC2_URL = "https://download.pytorch.org/torchaudio/models/wav2vec2_fairseq_base_ls960_asr_ls960.pth"
PACKAGES = (
    "coreai-core",
    "coreai-torch",
    "torch",
    "torchaudio",
    "transformers",
    "numpy",
    "scipy",
    "soundfile",
    "huggingface-hub",
)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def tree(path: Path) -> dict:
    """Sorted relative-path + space + file SHA + newline; follows HF blob links."""
    entries = (
        [(path.name, path)]
        if path.is_file()
        else sorted(
            (entry.relative_to(path).as_posix(), entry)
            for entry in path.rglob("*")
            if entry.is_file() and ".cache" not in entry.relative_to(path).parts
        )
    )
    if not entries:
        raise ValueError(f"Empty or missing artifact: {path}")
    files = [{"path": name, "sha256": digest(entry), "size_bytes": entry.stat().st_size} for name, entry in entries]
    value = "".join(f"{item['path']} {item['sha256']}\n" for item in files)
    return {
        "tree_sha256": hashlib.sha256(value.encode()).hexdigest(),
        "total_bytes": sum(item["size_bytes"] for item in files),
        "files": files,
    }


def verify_tree(path: Path, expected: dict) -> None:
    actual = tree(path)
    if actual != expected:
        raise ValueError(f"Artifact pin mismatch: {path}")


def versions() -> dict:
    result = {}
    for name in PACKAGES:
        try:
            result[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            result[name] = None
    return result


def check_environment(engine: str, *, exporting: bool) -> None:
    expected = {"coreai-core": "1.0.0b2"}
    if exporting:
        expected.update({"coreai-torch": "0.4.2", "torch": "2.11.0"})
    if engine in ("parakeet", "whisper"):
        expected["transformers"] = "5.9.0" if engine == "parakeet" else "4.57.3"
    if engine == "wav2vec2" and exporting:
        expected["torchaudio"] = "2.11.0"
    actual = versions()
    for name, value in expected.items():
        if actual[name] != value:
            raise RuntimeError(
                f"{engine} needs {name}=={value}, installed {actual[name]}; use its separate environment"
            )


def offline() -> None:
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_DATASETS_OFFLINE"] = "1"


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


def write_json(path: Path, value: dict) -> None:
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write("\n")


def audio(path: Path, maximum_seconds: float, minimum_samples: int = 1):
    """SoundFile decode, channel average, rational polyphase resample; never trim."""
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly

    samples, rate = sf.read(path, dtype="float32", always_2d=True)
    if rate <= 0 or len(samples) == 0 or samples.shape[1] == 0:
        raise ValueError("Empty or invalid audio")
    duration = len(samples) / rate
    if duration > maximum_seconds:
        raise ValueError(f"Audio {duration:.6f}s exceeds {maximum_seconds:g}s window; truncation forbidden")
    if not np.isfinite(samples).all():
        raise ValueError("Non-finite audio")
    mono = samples.mean(axis=1, dtype=np.float32)
    if rate != 16000:
        factor = math.gcd(rate, 16000)
        mono = resample_poly(mono, 16000 // factor, rate // factor).astype(np.float32)
    if len(mono) < minimum_samples:
        raise ValueError(f"Audio needs at least {minimum_samples} samples at 16kHz")
    if len(mono) > round(maximum_seconds * 16000):
        raise ValueError("Resampled audio exceeds export bound")
    return np.ascontiguousarray(mono), duration


def whisper_prefix(processor, config: dict) -> list[int]:
    tokenizer = processor.tokenizer
    ids = [int(config["decoder_start_token_id"])]
    forced = processor.get_decoder_prompt_ids(language="en", task="transcribe", no_timestamps=True)
    for position, token in forced:
        if position != len(ids):
            raise ValueError(f"Non-contiguous Whisper prompt at {position}")
        ids.append(int(token))
    names = ["<|startoftranscript|>", "<|en|>", "<|transcribe|>", "<|notimestamps|>"]
    if ids != [tokenizer.convert_tokens_to_ids(name) for name in names]:
        raise ValueError("Whisper English/transcribe/no-timestamps prompt mismatch")
    return ids


def whisper_features(processor, samples, dtype: str):
    import numpy as np

    features = processor.feature_extractor(
        samples,
        sampling_rate=16000,
        return_tensors="np",
        truncation=False,
        padding="max_length",
        max_length=480000,
    )["input_features"]
    result = np.asarray(features, dtype=dtype)
    if result.shape != (1, 128, 3000) or not np.isfinite(result).all():
        raise ValueError(f"Unexpected Whisper features {result.shape}; expected [1,128,3000]")
    return np.ascontiguousarray(result)


def ctc_text(token_ids, labels: list[str], blank: int) -> str:
    previous = None
    text = []
    for value in token_ids:
        token = int(value)
        if token < 0 or token >= len(labels):
            raise ValueError(f"Invalid CTC id {token}")
        if token != previous and token != blank:
            text.append(labels[token])
        previous = token
    return "".join(text).replace("|", " ").strip()
