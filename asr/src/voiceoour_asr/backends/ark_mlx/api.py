from __future__ import annotations

from pathlib import Path

import mlx.core as mx
import numpy as np

from .config import ArkASRConfig
from .generation import TranscriptionResult, generate_transcription
from .model import ArkASRModel
from .processor import ArkASRProcessor


class ArkASR:
    def __init__(self, model: ArkASRModel, processor: ArkASRProcessor) -> None:
        self.model = model
        self.processor = processor

    @classmethod
    def from_pretrained(cls, model_path: str | Path) -> ArkASR:
        model_path = Path(model_path)
        config = ArkASRConfig.from_file(model_path / "config.json")
        model = ArkASRModel(config)
        weights = mx.load(str(model_path / "model.safetensors"))
        model.load_weights(list(weights.items()), strict=True)
        mx.eval(model.parameters())
        processor = ArkASRProcessor.from_pretrained(model_path, config.merge_factor)
        return cls(model, processor)

    def transcribe(
        self,
        audio: str | Path | np.ndarray,
        sample_rate: int | None = None,
        max_new_tokens: int = 256,
    ) -> TranscriptionResult:
        inputs = self.processor.process(audio, sample_rate)
        return generate_transcription(
            self.model,
            self.processor,
            inputs,
            max_new_tokens=max_new_tokens,
        )

