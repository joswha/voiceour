from __future__ import annotations

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict

from .errors import ErrorCode

PROTOCOL_VERSION = 1


class BackendStatus(StrEnum):
    READY = "ready"
    MODEL_MISSING = "model_missing"
    BACKEND_UNAVAILABLE = "backend_unavailable"


class WireModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Capabilities(WireModel):
    final_utterance: bool = True


class Hello(WireModel):
    type: Literal["hello"] = "hello"
    protocol_version: int = PROTOCOL_VERSION
    sidecar_version: str
    backend_id: str
    backend_status: BackendStatus
    capabilities: Capabilities


class HealthRequest(WireModel):
    type: Literal["health"] = "health"
    protocol_version: int = PROTOCOL_VERSION
    request_id: str


class HealthResponse(WireModel):
    type: Literal["health"] = "health"
    protocol_version: int = PROTOCOL_VERSION
    request_id: str
    ready: bool
    model_loaded: bool
    cache_ok: bool


class AudioMeta(WireModel):
    path: str
    format: str
    sample_rate_hz: int
    channels: int
    duration_ms: int
    byte_count: int


class ExpectedModel(WireModel):
    model_id: str
    revision: str


class BiasPhrase(WireModel):
    text: str
    weight: float | None = None


class TranscribeRequest(WireModel):
    type: Literal["transcribe"] = "transcribe"
    protocol_version: int = PROTOCOL_VERSION
    request_id: str
    audio: AudioMeta
    expected_model: ExpectedModel | None = None
    timeout_ms: int = 30000
    bias_phrases: list[BiasPhrase] | None = None
    bias_snapshot_id: str | None = None


class CancelRequest(WireModel):
    type: Literal["cancel"] = "cancel"
    protocol_version: int = PROTOCOL_VERSION
    request_id: str


class ConfidenceMode(StrEnum):
    NONE = "none"
    GREEDY_ENTROPY = "greedy_entropy"
    BEAM_LOGPROB = "beam_logprob"


class Word(WireModel):
    text: str
    start_ms: int
    end_ms: int
    confidence: float | None = None


class Segment(WireModel):
    start_ms: int
    end_ms: int
    text: str
    words: list[Word] | None = None


class Transcript(WireModel):
    text: str
    language: str | None = "en"
    segments: list[Segment] | None = None
    confidence: float | None = None
    confidence_mode: ConfidenceMode | None = None


class Timings(WireModel):
    load: int
    inference: int
    total: int


class Hypothesis(WireModel):
    rank: int
    text: str
    score: float
    raw_score: float | None = None
    transcript: Transcript | None = None


class DecoderInfo(WireModel):
    mode: str
    beam_size: int | None = None
    bias_enabled: bool = False
    bias_snapshot_id: str | None = None


class Result(WireModel):
    type: Literal["result"] = "result"
    protocol_version: int = PROTOCOL_VERSION
    request_id: str
    backend_id: str
    model_id: str
    model_revision: str
    transcript: Transcript
    timings_ms: Timings
    hypotheses: list[Hypothesis] | None = None
    decoder: DecoderInfo | None = None


class Cancelled(WireModel):
    type: Literal["cancelled"] = "cancelled"
    protocol_version: int = PROTOCOL_VERSION
    request_id: str


class ErrorMessage(WireModel):
    type: Literal["error"] = "error"
    protocol_version: int = PROTOCOL_VERSION
    request_id: str | None = None
    code: ErrorCode
    category: str
    retryable: bool
    user_message_key: str
    detail: str | None = None


def protocol_error(code: ErrorCode, *, request_id: str | None = None, detail: str | None = None) -> ErrorMessage:
    category = (
        "setup"
        if code in {ErrorCode.MODEL_NOT_INSTALLED, ErrorCode.MANIFEST_MISMATCH, ErrorCode.BACKEND_UNAVAILABLE}
        else "runtime"
    )
    return ErrorMessage(
        request_id=request_id,
        code=code,
        category=category,
        retryable=code in {ErrorCode.TIMEOUT, ErrorCode.INTERNAL_ERROR, ErrorCode.INFERENCE_FAILED},
        user_message_key=f"asr.{code.value}",
        detail=detail,
    )
