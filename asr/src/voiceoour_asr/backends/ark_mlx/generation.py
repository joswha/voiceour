from __future__ import annotations

from dataclasses import dataclass

import mlx.core as mx
import numpy as np

from .model import ArkASRModel
from .processor import ArkASRProcessor, ProcessedInput


@dataclass(frozen=True)
class TranscriptionResult:
    text: str
    token_ids: tuple[int, ...]
    prompt_tokens: int
    generation_tokens: int


def _next_token(logits: mx.array, suppression_mask: mx.array) -> int:
    next_logits = mx.where(suppression_mask, -float("inf"), logits[0, -1])
    token = mx.argmax(next_logits)
    mx.eval(token)
    return int(token.item())


def generate_transcription(
    model: ArkASRModel,
    processor: ArkASRProcessor,
    inputs: ProcessedInput,
    max_new_tokens: int = 256,
) -> TranscriptionResult:
    if max_new_tokens <= 0:
        raise ValueError("max_new_tokens must be positive.")

    input_ids = mx.array(inputs.input_ids)
    input_features = mx.array(inputs.input_features).astype(
        model.audio_encoder.whisper.conv1.weight.dtype
    )
    prompt_embeddings = model.prepare_prompt_embeddings(
        input_ids,
        input_features,
        inputs.audio_start,
        inputs.audio_count,
    )
    cache = model.make_cache()
    logits = model(input_ids, cache=cache, input_embeddings=prompt_embeddings)
    mx.eval(logits)

    suppressed = processor.suppressed_token_ids(model.config.eos_token_id)
    mask = np.zeros(model.config.vocab_size, dtype=np.bool_)
    mask[suppressed] = True
    suppression_mask = mx.array(mask)

    generated: list[int] = []
    for _ in range(max_new_tokens):
        token = _next_token(logits, suppression_mask)
        if token == model.config.eos_token_id:
            break
        generated.append(token)
        token_array = mx.array([[token]], dtype=mx.int32)
        logits = model(token_array, cache=cache)
        mx.eval(logits)

    text = processor.tokenizer.decode(generated, skip_special_tokens=True).strip()
    return TranscriptionResult(
        text=text,
        token_ids=tuple(generated),
        prompt_tokens=int(input_ids.shape[1]),
        generation_tokens=len(generated),
    )
