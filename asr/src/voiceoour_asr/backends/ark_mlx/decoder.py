from __future__ import annotations

import mlx.core as mx
import mlx.nn as nn

from .cache import KVCache
from .config import ArkASRConfig


def _causal_mask(length: int, offset: int, dtype: mx.Dtype) -> mx.array | None:
    if length == 1:
        return None
    local = mx.triu(mx.full((length, length), -float("inf"), dtype=dtype), k=1)
    if offset == 0:
        return local
    prefix = mx.zeros((length, offset), dtype=dtype)
    return mx.concatenate([prefix, local], axis=1)


class Attention(nn.Module):
    def __init__(self, config: ArkASRConfig) -> None:
        super().__init__()
        hidden_size = config.hidden_size
        self.num_heads = config.num_attention_heads
        self.num_kv_heads = config.num_key_value_heads
        self.head_dim = hidden_size // self.num_heads
        self.scale = self.head_dim**-0.5

        self.q_proj = nn.Linear(hidden_size, self.num_heads * self.head_dim, bias=True)
        self.k_proj = nn.Linear(hidden_size, self.num_kv_heads * self.head_dim, bias=True)
        self.v_proj = nn.Linear(hidden_size, self.num_kv_heads * self.head_dim, bias=True)
        self.o_proj = nn.Linear(self.num_heads * self.head_dim, hidden_size, bias=False)
        self.rope = nn.RoPE(
            self.head_dim,
            traditional=False,
            base=config.rope_theta,
        )

    def __call__(
        self,
        hidden_states: mx.array,
        mask: mx.array | None,
        cache: KVCache | None,
    ) -> mx.array:
        batch, length, _ = hidden_states.shape
        queries = self.q_proj(hidden_states)
        keys = self.k_proj(hidden_states)
        values = self.v_proj(hidden_states)

        queries = queries.reshape(batch, length, self.num_heads, self.head_dim).transpose(
            0, 2, 1, 3
        )
        keys = keys.reshape(batch, length, self.num_kv_heads, self.head_dim).transpose(
            0, 2, 1, 3
        )
        values = values.reshape(batch, length, self.num_kv_heads, self.head_dim).transpose(
            0, 2, 1, 3
        )

        offset = cache.offset if cache is not None else 0
        queries = self.rope(queries, offset=offset)
        keys = self.rope(keys, offset=offset)
        if cache is not None:
            keys, values = cache.update_and_fetch(keys, values)

        output = mx.fast.scaled_dot_product_attention(
            queries,
            keys,
            values,
            scale=self.scale,
            mask=mask,
        )
        output = output.transpose(0, 2, 1, 3).reshape(batch, length, -1)
        return self.o_proj(output)


class MLP(nn.Module):
    def __init__(self, config: ArkASRConfig) -> None:
        super().__init__()
        self.gate_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=False)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=False)
        self.up_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=False)

    def __call__(self, hidden_states: mx.array) -> mx.array:
        gate = nn.silu(self.gate_proj(hidden_states))
        return self.down_proj(gate * self.up_proj(hidden_states))


class DecoderLayer(nn.Module):
    def __init__(self, config: ArkASRConfig) -> None:
        super().__init__()
        self.self_attn = Attention(config)
        self.mlp = MLP(config)
        self.input_layernorm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = nn.RMSNorm(
            config.hidden_size, eps=config.rms_norm_eps
        )

    def __call__(
        self,
        hidden_states: mx.array,
        mask: mx.array | None,
        cache: KVCache | None,
    ) -> mx.array:
        attention = self.self_attn(self.input_layernorm(hidden_states), mask, cache)
        hidden_states = hidden_states + attention
        return hidden_states + self.mlp(self.post_attention_layernorm(hidden_states))


class Qwen2Decoder(nn.Module):
    def __init__(self, config: ArkASRConfig) -> None:
        super().__init__()
        self.embed_tokens = nn.Embedding(config.vocab_size, config.hidden_size)
        self.layers = [DecoderLayer(config) for _ in range(config.num_hidden_layers)]
        self.norm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def __call__(
        self,
        input_ids: mx.array,
        cache: list[KVCache] | None = None,
        input_embeddings: mx.array | None = None,
    ) -> mx.array:
        hidden_states = (
            input_embeddings if input_embeddings is not None else self.embed_tokens(input_ids)
        )
        offset = cache[0].offset if cache else 0
        mask = _causal_mask(hidden_states.shape[1], offset, hidden_states.dtype)
        layer_caches: list[KVCache | None] = cache or [None] * len(self.layers)
        for layer, layer_cache in zip(self.layers, layer_caches, strict=True):
            hidden_states = layer(hidden_states, mask, layer_cache)
        return self.norm(hidden_states)

