from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import librosa
import numpy as np
from transformers import AutoTokenizer, WhisperFeatureExtractor
from transformers.tokenization_utils import PreTrainedTokenizer

SAMPLE_RATE = 16_000
MAX_AUDIO_SAMPLES = 30 * SAMPLE_RATE
TRANSCRIPTION_PROMPT = "Please transcribe this audio."


@dataclass(frozen=True)
class ProcessedInput:
    input_ids: np.ndarray
    input_features: np.ndarray
    audio_start: int
    audio_count: int


class ArkASRProcessor:
    def __init__(
        self,
        tokenizer: PreTrainedTokenizer,
        feature_extractor: WhisperFeatureExtractor,
        merge_factor: int,
        audio_token: str = "<|audio|>",
    ) -> None:
        self.tokenizer = tokenizer
        self.feature_extractor = feature_extractor
        self.merge_factor = merge_factor
        self.audio_token = audio_token
        self.audio_token_id = tokenizer.convert_tokens_to_ids(audio_token)

    @classmethod
    def from_pretrained(cls, model_path: str | Path, merge_factor: int) -> ArkASRProcessor:
        tokenizer = AutoTokenizer.from_pretrained(
            model_path,
            trust_remote_code=False,
            fix_mistral_regex=True,
        )
        feature_extractor = WhisperFeatureExtractor.from_pretrained(model_path)
        return cls(tokenizer, feature_extractor, merge_factor)

    def load_audio(
        self,
        audio: str | Path | np.ndarray,
        sample_rate: int | None = None,
    ) -> np.ndarray:
        if isinstance(audio, (str, Path)):
            waveform, _ = librosa.load(audio, sr=SAMPLE_RATE, mono=True)
        else:
            waveform = np.asarray(audio, dtype=np.float32).reshape(-1)
            if sample_rate is None:
                raise ValueError("sample_rate is required when audio is a NumPy array.")
            if sample_rate != SAMPLE_RATE:
                waveform = librosa.resample(
                    waveform,
                    orig_sr=sample_rate,
                    target_sr=SAMPLE_RATE,
                )
        waveform = np.asarray(waveform, dtype=np.float32)
        if waveform.size == 0:
            raise ValueError("Audio input is empty.")
        if waveform.size > MAX_AUDIO_SAMPLES:
            duration = waveform.size / SAMPLE_RATE
            raise ValueError(
                f"Audio is {duration:.2f}s long; ARK-ASR supports at most 30.00s per clip."
            )
        return waveform

    def calculate_audio_token_count(self, sample_count: int) -> int:
        mel_frames = sample_count // int(self.feature_extractor.hop_length)
        downsampled = (mel_frames + 1) // 2
        return max(downsampled // self.merge_factor, 1)

    def process(
        self,
        audio: str | Path | np.ndarray,
        sample_rate: int | None = None,
    ) -> ProcessedInput:
        waveform = self.load_audio(audio, sample_rate)
        features = self.feature_extractor(
            [waveform],
            sampling_rate=SAMPLE_RATE,
            return_tensors="np",
            return_attention_mask=False,
            padding="longest",
            max_length=MAX_AUDIO_SAMPLES,
        )["input_features"]
        audio_count = self.calculate_audio_token_count(waveform.size)
        prompt = (
            "<|user|><|begin_of_audio|>"
            + self.audio_token * audio_count
            + f"<|end_of_audio|>{TRANSCRIPTION_PROMPT}<|assistant|>"
        )
        tokenized = self.tokenizer(
            prompt,
            add_special_tokens=False,
            return_tensors="np",
        )
        input_ids = np.asarray(tokenized["input_ids"], dtype=np.int32)
        positions = np.flatnonzero(input_ids[0] == self.audio_token_id)
        if positions.size != audio_count:
            raise ValueError(
                f"Tokenizer produced {positions.size} audio tokens; expected {audio_count}."
            )
        if positions.size > 1 and not np.all(np.diff(positions) == 1):
            raise ValueError("Audio placeholder tokens are not contiguous.")
        return ProcessedInput(
            input_ids=input_ids,
            input_features=np.asarray(features),
            audio_start=int(positions[0]),
            audio_count=audio_count,
        )

    def suppressed_token_ids(self, eos_token_id: int) -> list[int]:
        suppressed = set(self.tokenizer.all_special_ids)
        suppressed.update(
            token_id
            for token, token_id in self.tokenizer.get_added_vocab().items()
            if token.startswith("<") and token.endswith(">")
        )
        suppressed.discard(eos_token_id)
        return sorted(suppressed)
