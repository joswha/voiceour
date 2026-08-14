from __future__ import annotations

import json
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Any


def _known_values(cls: type, values: dict[str, Any]) -> dict[str, Any]:
    names = {field.name for field in fields(cls)}
    return {key: value for key, value in values.items() if key in names}


@dataclass(frozen=True)
class AudioEncoderConfig:
    d_model: int
    encoder_attention_heads: int
    encoder_ffn_dim: int
    encoder_layers: int
    num_mel_bins: int
    attention_dropout: float = 0.0

    @classmethod
    def from_dict(cls, values: dict[str, Any]) -> AudioEncoderConfig:
        return cls(**_known_values(cls, values))


@dataclass(frozen=True)
class ArkASRConfig:
    hidden_size: int
    intermediate_size: int
    num_attention_heads: int
    num_hidden_layers: int
    num_key_value_heads: int
    rms_norm_eps: float
    rope_theta: float
    vocab_size: int
    audio_token_id: int
    eos_token_id: int
    pad_token_id: int
    merge_factor: int
    whisper_config: AudioEncoderConfig
    max_position_embeddings: int = 32768
    tie_word_embeddings: bool = True
    mlp_adapter_act: str = "gelu"
    use_rope: bool = True

    @classmethod
    def from_dict(cls, values: dict[str, Any]) -> ArkASRConfig:
        config = dict(_known_values(cls, values))
        config["whisper_config"] = AudioEncoderConfig.from_dict(values["whisper_config"])
        return cls(**config)

    @classmethod
    def from_file(cls, path: str | Path) -> ArkASRConfig:
        with Path(path).open(encoding="utf-8") as file:
            return cls.from_dict(json.load(file))

