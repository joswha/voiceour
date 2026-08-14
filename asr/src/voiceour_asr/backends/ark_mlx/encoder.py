from __future__ import annotations

import mlx.core as mx
import mlx.nn as nn

from .config import AudioEncoderConfig


def apply_interleaved_rope(
    values: mx.array,
    rotary_dim: int,
    base: float = 10_000.0,
) -> mx.array:
    sequence_length = values.shape[2]
    inv_freq = 1.0 / (
        base ** (mx.arange(0, rotary_dim, 2, dtype=mx.float32) / rotary_dim)
    )
    positions = mx.arange(sequence_length, dtype=mx.float32)
    frequencies = positions[:, None] * inv_freq[None, :]
    cos = mx.cos(frequencies).astype(values.dtype)[None, None, :, :]
    sin = mx.sin(frequencies).astype(values.dtype)[None, None, :, :]

    rotated = values[..., :rotary_dim].reshape(
        *values.shape[:-1], rotary_dim // 2, 2
    )
    real = rotated[..., 0]
    imaginary = rotated[..., 1]
    output = mx.stack(
        [real * cos - imaginary * sin, imaginary * cos + real * sin],
        axis=-1,
    ).reshape(*values.shape[:-1], rotary_dim)
    return mx.concatenate([output, values[..., rotary_dim:]], axis=-1)


class AudioAttention(nn.Module):
    def __init__(self, config: AudioEncoderConfig) -> None:
        super().__init__()
        self.num_heads = config.encoder_attention_heads
        self.head_dim = config.d_model // self.num_heads
        self.rotary_dim = self.head_dim // 2
        self.scale = self.head_dim**-0.5
        self.q_proj = nn.Linear(config.d_model, config.d_model)
        self.k_proj = nn.Linear(config.d_model, config.d_model, bias=False)
        self.v_proj = nn.Linear(config.d_model, config.d_model)
        self.out_proj = nn.Linear(config.d_model, config.d_model)

    def __call__(self, hidden_states: mx.array) -> mx.array:
        batch, length, width = hidden_states.shape
        queries = self.q_proj(hidden_states).reshape(
            batch, length, self.num_heads, self.head_dim
        )
        keys = self.k_proj(hidden_states).reshape(
            batch, length, self.num_heads, self.head_dim
        )
        values = self.v_proj(hidden_states).reshape(
            batch, length, self.num_heads, self.head_dim
        )
        queries = queries.transpose(0, 2, 1, 3)
        keys = keys.transpose(0, 2, 1, 3)
        values = values.transpose(0, 2, 1, 3)
        queries = apply_interleaved_rope(queries, self.rotary_dim)
        keys = apply_interleaved_rope(keys, self.rotary_dim)
        output = mx.fast.scaled_dot_product_attention(
            queries,
            keys,
            values,
            scale=self.scale,
        )
        output = output.transpose(0, 2, 1, 3).reshape(batch, length, width)
        return self.out_proj(output)


class AudioEncoderLayer(nn.Module):
    def __init__(self, config: AudioEncoderConfig) -> None:
        super().__init__()
        self.self_attn = AudioAttention(config)
        self.self_attn_layer_norm = nn.LayerNorm(config.d_model)
        self.fc1 = nn.Linear(config.d_model, config.encoder_ffn_dim)
        self.fc2 = nn.Linear(config.encoder_ffn_dim, config.d_model)
        self.final_layer_norm = nn.LayerNorm(config.d_model)

    def __call__(self, hidden_states: mx.array) -> mx.array:
        hidden_states = hidden_states + self.self_attn(
            self.self_attn_layer_norm(hidden_states)
        )
        residual = hidden_states
        hidden_states = self.final_layer_norm(hidden_states)
        hidden_states = self.fc2(nn.gelu(self.fc1(hidden_states)))
        return residual + hidden_states


class WhisperRoPEEncoder(nn.Module):
    def __init__(self, config: AudioEncoderConfig) -> None:
        super().__init__()
        self.conv1 = nn.Conv1d(
            config.num_mel_bins,
            config.d_model,
            kernel_size=3,
            padding=1,
        )
        self.conv2 = nn.Conv1d(
            config.d_model,
            config.d_model,
            kernel_size=3,
            stride=2,
            padding=1,
        )
        self.layers = [AudioEncoderLayer(config) for _ in range(config.encoder_layers)]

    def __call__(self, input_features: mx.array) -> mx.array:
        hidden_states = input_features.transpose(0, 2, 1)
        hidden_states = nn.gelu(self.conv1(hidden_states))
        hidden_states = nn.gelu(self.conv2(hidden_states))
        for layer in self.layers:
            hidden_states = layer(hidden_states)
        return hidden_states

