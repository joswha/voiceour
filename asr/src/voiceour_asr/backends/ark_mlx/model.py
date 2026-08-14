from __future__ import annotations

import mlx.core as mx
import mlx.nn as nn

from .cache import KVCache
from .config import ArkASRConfig
from .decoder import Qwen2Decoder
from .encoder import WhisperRoPEEncoder


class AudioAdapter(nn.Module):
    def __init__(self, config: ArkASRConfig) -> None:
        super().__init__()
        self.merge_factor = config.merge_factor
        audio_width = config.whisper_config.d_model
        self.whisper = WhisperRoPEEncoder(config.whisper_config)
        self.layer_norm = nn.LayerNorm(audio_width)
        self.linear1 = nn.Linear(audio_width * self.merge_factor, config.hidden_size * 2)
        self.linear2 = nn.Linear(config.hidden_size * 2, config.hidden_size)

    def __call__(self, input_features: mx.array) -> mx.array:
        encoded = self.layer_norm(self.whisper(input_features))
        sequence_length = encoded.shape[1]
        target_length = (sequence_length // self.merge_factor) * self.merge_factor
        if target_length <= 0:
            padding = mx.zeros(
                (
                    encoded.shape[0],
                    self.merge_factor - sequence_length,
                    encoded.shape[2],
                ),
                dtype=encoded.dtype,
            )
            encoded = mx.concatenate([encoded, padding], axis=1)
            target_length = self.merge_factor
        elif target_length != sequence_length:
            encoded = encoded[:, :target_length, :]
        encoded = encoded.reshape(
            encoded.shape[0],
            target_length // self.merge_factor,
            encoded.shape[2] * self.merge_factor,
        )
        return self.linear2(nn.gelu(self.linear1(encoded)))


class ArkASRModel(nn.Module):
    def __init__(self, config: ArkASRConfig) -> None:
        super().__init__()
        self.config = config
        self.model = Qwen2Decoder(config)
        self.audio_encoder = AudioAdapter(config)

    def make_cache(self) -> list[KVCache]:
        return [KVCache() for _ in range(self.config.num_hidden_layers)]

    def prepare_prompt_embeddings(
        self,
        input_ids: mx.array,
        input_features: mx.array,
        audio_start: int,
        audio_count: int,
    ) -> mx.array:
        audio_features = self.audio_encoder(input_features)
        if audio_features.shape[1] != audio_count:
            raise ValueError(
                "Audio feature/token mismatch: "
                f"encoder produced {audio_features.shape[1]}, prompt contains {audio_count}."
            )
        embeddings = self.model.embed_tokens(input_ids)
        return mx.concatenate(
            [
                embeddings[:, :audio_start, :],
                audio_features.astype(embeddings.dtype),
                embeddings[:, audio_start + audio_count :, :],
            ],
            axis=1,
        )

    def __call__(
        self,
        input_ids: mx.array,
        cache: list[KVCache] | None = None,
        input_embeddings: mx.array | None = None,
    ) -> mx.array:
        hidden_states = self.model(input_ids, cache, input_embeddings)
        return self.model.embed_tokens.as_linear(hidden_states)

