"""Dataset preparation for Voiceour benchmark tiers."""

from __future__ import annotations

import io
import json
import os
import subprocess
from collections.abc import Iterable
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import soundfile as sf
from datasets import Audio, load_dataset

SMOKE_UTTERANCES: tuple[tuple[str, str], ...] = (
    ("numbers_invoice", "The invoice total is 1,250 dollars."),
    ("proper_noun_voiceour", "Voiceour should paste this into Notes."),
    ("question_morgan", "Can you send this to Morgan at 3 PM?"),
    ("filler_ship", "Um I think we should ship the feature today."),
    ("technical_terms", "Use NVIDIA Parakeet with FastConformer TDT."),
    ("command_as_text", "Type the words git status into the note."),
    ("correction", "Set the timeout to 30 seconds, not 300."),
    ("short_message", "Please call me when the build finishes."),
)

TECHTERMS_CASES: tuple[dict[str, Any], ...] = (
    {
        "slug": "kubectl",
        "reference": "Run kubectl get pods in the staging namespace.",
        "canonical_term": "kubectl",
        "term_id": "term-kubectl",
        "term_class": "jargon",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "asr",
        "reference": "The ASR model finished loading.",
        "canonical_term": "ASR",
        "term_id": "term-asr",
        "term_class": "acronym",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "audio_buffer_size",
        "reference": "Set audioBufferSize before starting capture.",
        "canonical_term": "audioBufferSize",
        "term_id": "term-audio-buffer-size",
        "term_class": "camel_case",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "cplusplus",
        "reference": "Use C++ for the parser.",
        "canonical_term": "C++",
        "term_id": "term-cplusplus",
        "term_class": "symbols",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "ipv6",
        "reference": "The service listens on IPv6.",
        "canonical_term": "IPv6",
        "term_id": "term-ipv6",
        "term_class": "digits",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "core_audio",
        "reference": "Core Audio reported an input route change.",
        "canonical_term": "Core Audio",
        "term_id": "term-core-audio",
        "term_class": "multiword_name",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "voiceour",
        "reference": "Voiceour should preserve the selected microphone.",
        "canonical_term": "Voiceour",
        "term_id": "term-voiceour",
        "term_class": "coinage",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "voiceour",
    },
    {
        "slug": "c_language",
        "reference": "Compile the module as C.",
        "canonical_term": "C",
        "term_id": "term-c-language",
        "term_class": "symbols",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "rust_language",
        "reference": "The command line tool is written in Rust.",
        "canonical_term": "Rust",
        "term_id": "term-rust-language",
        "term_class": "jargon",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "go_language",
        "reference": "The network service is written in Go.",
        "canonical_term": "Go",
        "term_id": "term-go-language",
        "term_class": "jargon",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "metal_framework",
        "reference": "Metal renders the preview on the graphics processor.",
        "canonical_term": "Metal",
        "term_id": "term-metal-framework",
        "term_class": "jargon",
        "expect_term": True,
        "hard_negative_kind": None,
        "project_scope": "global",
    },
    {
        "slug": "cube_cuddle_negative",
        "reference": "Give the cube a cuddle before putting it away.",
        "canonical_term": "kubectl",
        "term_id": "term-kubectl",
        "term_class": "jargon",
        "expect_term": False,
        "hard_negative_kind": "minimal_pair",
        "project_scope": "global",
    },
    {
        "slug": "sea_negative",
        "reference": "We can see the sea from the window.",
        "canonical_term": "C",
        "term_id": "term-c-language",
        "term_class": "symbols",
        "expect_term": False,
        "hard_negative_kind": "homophone",
        "project_scope": "global",
    },
    {
        "slug": "rust_negative",
        "reference": "The old gate is covered in rust.",
        "canonical_term": "Rust",
        "term_id": "term-rust-language",
        "term_class": "jargon",
        "expect_term": False,
        "hard_negative_kind": "ordinary_language",
        "project_scope": "global",
    },
    {
        "slug": "go_negative",
        "reference": "We should go after lunch.",
        "canonical_term": "Go",
        "term_id": "term-go-language",
        "term_class": "jargon",
        "expect_term": False,
        "hard_negative_kind": "ordinary_language",
        "project_scope": "global",
    },
    {
        "slug": "metal_negative",
        "reference": "The metal plate felt cold.",
        "canonical_term": "Metal",
        "term_id": "term-metal-framework",
        "term_class": "multiword_name",
        "expect_term": False,
        "hard_negative_kind": "ordinary_language",
        "project_scope": "global",
    },
)

TECHTERMS_SPEAKER_ID = "macos-say-samantha"
TECHTERMS_SAY_VOICE = "Samantha"
TECHTERMS_SAY_RATE = "180"


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def benchmarks_data_dir(root: Path | None = None) -> Path:
    return (root or repo_root()) / "benchmarks" / "data"


def _write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def _audio_seconds(path: Path) -> float:
    info = sf.info(path)
    return float(info.frames) / float(info.samplerate)


def _run_checked(args: list[str]) -> None:
    subprocess.run(args, check=True, capture_output=True, text=True)


def prepare_smoke(root: Path | None = None) -> Path:
    """Synthesize deterministic offline smoke WAVs with `say` and `afconvert`."""

    root = root or repo_root()
    tier_dir = benchmarks_data_dir(root) / "smoke"
    audio_dir = tier_dir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    for index, (slug, text) in enumerate(SMOKE_UTTERANCES, start=1):
        stem = f"smoke_{index:02d}_{slug}"
        aiff_path = audio_dir / f"{stem}.aiff"
        wav_path = audio_dir / f"{stem}.wav"
        if not wav_path.exists():
            _run_checked(["say", "-o", str(aiff_path), text])
            _run_checked(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff_path), str(wav_path)])
            aiff_path.unlink(missing_ok=True)
        rows.append(
            {
                "id": stem,
                "audio_path": str(wav_path.relative_to(root)),
                "reference": text,
                "formatted_reference": text,
                "audio_s": _audio_seconds(wav_path),
            }
        )
    manifest = tier_dir / "manifest.jsonl"
    _write_jsonl(manifest, rows)
    return manifest


def prepare_techterms(root: Path | None = None) -> Path:
    """Synthesize deterministic TTS smoke coverage for technical-term scoring."""

    root = root or repo_root()
    tier_dir = benchmarks_data_dir(root) / "techterms"
    audio_dir = tier_dir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    for index, case in enumerate(TECHTERMS_CASES, start=1):
        stem = f"techterms_{index:02d}_{case['slug']}"
        aiff_path = audio_dir / f"{stem}.aiff"
        wav_path = audio_dir / f"{stem}.wav"
        if not wav_path.exists():
            _run_checked(
                [
                    "say",
                    "-v",
                    TECHTERMS_SAY_VOICE,
                    "-r",
                    TECHTERMS_SAY_RATE,
                    "-o",
                    str(aiff_path),
                    case["reference"],
                ]
            )
            _run_checked(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff_path), str(wav_path)])
            aiff_path.unlink(missing_ok=True)
        rows.append(
            {
                "id": stem,
                "audio_path": str(wav_path.relative_to(root)),
                "reference": case["reference"],
                "formatted_reference": case["reference"],
                "audio_s": _audio_seconds(wav_path),
                "canonical_term": case["canonical_term"],
                "term_id": case["term_id"],
                "term_class": case["term_class"],
                "expect_term": case["expect_term"],
                "hard_negative_kind": case["hard_negative_kind"],
                "speaker_id": TECHTERMS_SPEAKER_ID,
                "speaker_kind": "tts",
                "condition": "clean",
                "project_scope": case["project_scope"],
            }
        )
    manifest = tier_dir / "manifest.jsonl"
    _write_jsonl(manifest, rows)
    return manifest


@contextmanager
def _hf_cache_env(root: Path):
    cache = benchmarks_data_dir(root) / "hf-cache"
    cache.mkdir(parents=True, exist_ok=True)
    old_hf_home = os.environ.get("HF_HOME")
    old_datasets_cache = os.environ.get("HF_DATASETS_CACHE")
    os.environ["HF_HOME"] = str(cache)
    os.environ["HF_DATASETS_CACHE"] = str(cache / "datasets")
    try:
        yield
    finally:
        if old_hf_home is None:
            os.environ.pop("HF_HOME", None)
        else:
            os.environ["HF_HOME"] = old_hf_home
        if old_datasets_cache is None:
            os.environ.pop("HF_DATASETS_CACHE", None)
        else:
            os.environ["HF_DATASETS_CACHE"] = old_datasets_cache


def _to_mono_samples(array: Any) -> Any:
    """Return mono audio samples, averaging channels when needed."""

    shape = getattr(array, "shape", None)
    if shape is not None and len(shape) == 2:
        return array.mean(axis=1)
    return array


def _write_dataset_audio(audio: dict[str, Any], path: Path) -> float:
    # datasets>=4 requires torchcodec for decoded audio access; we cast columns
    # to Audio(decode=False) and decode the raw bytes with soundfile instead.
    if audio.get("array") is not None:
        samples = _to_mono_samples(audio["array"])
        sampling_rate = int(audio["sampling_rate"])
    else:
        raw = audio.get("bytes")
        source: Any = io.BytesIO(raw) if raw is not None else audio["path"]
        data, rate = sf.read(source)
        samples = _to_mono_samples(data)
        sampling_rate = int(rate)
    if sampling_rate != 16000:
        samples = _linear_resample(samples, sampling_rate, 16000)
        sampling_rate = 16000
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, samples, sampling_rate, subtype="PCM_16")
    return _audio_seconds(path)


def _linear_resample(samples: Any, source_rate: int, target_rate: int) -> list[float]:
    """Small dependency-free mono linear resampler for non-16 kHz HF rows."""

    if source_rate <= 0:
        raise ValueError(f"invalid source sampling rate: {source_rate}")
    values = samples.tolist() if hasattr(samples, "tolist") else list(samples)
    if not values:
        return []
    target_len = max(1, round(len(values) * target_rate / source_rate))
    if target_len == 1:
        return [float(values[0])]
    scale = (len(values) - 1) / (target_len - 1)
    output: list[float] = []
    for index in range(target_len):
        position = index * scale
        lower = int(position)
        upper = min(lower + 1, len(values) - 1)
        fraction = position - lower
        output.append(float(values[lower]) * (1.0 - fraction) + float(values[upper]) * fraction)
    return output


def prepare_librispeech(n: int = 200, root: Path | None = None) -> Path:
    """Prepare first-N LibriSpeech test.clean/test.other rows from HF."""

    root = root or repo_root()
    tier_dir = benchmarks_data_dir(root) / "librispeech"
    audio_dir = tier_dir / "audio"
    rows: list[dict[str, Any]] = []
    with _hf_cache_env(root):
        for split in ("test.clean", "test.other"):
            dataset = load_dataset("hf-audio/open-asr-leaderboard", "librispeech", split=split)
            dataset = dataset.cast_column("audio", Audio(decode=False))
            for index, item in enumerate(dataset.select(range(min(n, len(dataset)))), start=1):
                split_slug = split.replace(".", "_")
                row_id = f"librispeech-{split}-{index:06d}"
                wav_path = audio_dir / f"{split_slug}_{index:06d}.wav"
                audio_s = (
                    _write_dataset_audio(item["audio"], wav_path) if not wav_path.exists() else _audio_seconds(wav_path)
                )
                rows.append(
                    {
                        "id": row_id,
                        "audio_path": str(wav_path.relative_to(root)),
                        "reference": item["text"],
                        "formatted_reference": None,
                        "audio_s": float(item.get("audio_length_s") or audio_s),
                    }
                )
    manifest = tier_dir / "manifest.jsonl"
    _write_jsonl(manifest, rows)
    return manifest


def prepare_fleurs(n: int = 100, root: Path | None = None) -> Path:
    """Prepare first-N English FLEURS test rows from HF."""

    root = root or repo_root()
    tier_dir = benchmarks_data_dir(root) / "fleurs"
    audio_dir = tier_dir / "audio"
    rows: list[dict[str, Any]] = []
    with _hf_cache_env(root):
        dataset = load_dataset("google/fleurs", "en_us", split="test")
        dataset = dataset.cast_column("audio", Audio(decode=False))
        for index, item in enumerate(dataset.select(range(min(n, len(dataset)))), start=1):
            row_id = f"fleurs-en_us-test-{index:06d}"
            wav_path = audio_dir / f"en_us_test_{index:06d}.wav"
            audio_s = (
                _write_dataset_audio(item["audio"], wav_path) if not wav_path.exists() else _audio_seconds(wav_path)
            )
            rows.append(
                {
                    "id": row_id,
                    "audio_path": str(wav_path.relative_to(root)),
                    "reference": item["transcription"],
                    "formatted_reference": item.get("raw_transcription"),
                    "audio_s": audio_s,
                }
            )
    manifest = tier_dir / "manifest.jsonl"
    _write_jsonl(manifest, rows)
    return manifest


def prepare_tier(tier: str, n: int | None = None, root: Path | None = None) -> Path:
    if tier == "smoke":
        return prepare_smoke(root=root)
    if tier == "librispeech":
        return prepare_librispeech(n=200 if n is None else n, root=root)
    if tier == "fleurs":
        return prepare_fleurs(n=100 if n is None else n, root=root)
    if tier == "techterms":
        return prepare_techterms(root=root)
    raise ValueError(f"unknown tier: {tier}")


def fleurs_manifest_to_refine_cases(manifest_path: Path, root: Path | None = None) -> Path:
    """Convert a FLEURS pipeline manifest into text-only refine cases."""

    root = root or repo_root()
    output = benchmarks_data_dir(root) / "fleurs" / "refine_cases.jsonl"
    rows: list[dict[str, Any]] = []
    with manifest_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            item = json.loads(line)
            rows.append(
                {
                    "id": item["id"],
                    "raw_text": item["reference"],
                    "reference": item["reference"],
                    "formatted_reference": item.get("formatted_reference"),
                }
            )
    _write_jsonl(output, rows)
    return output
