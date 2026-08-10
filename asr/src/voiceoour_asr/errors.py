from __future__ import annotations

from enum import StrEnum


class ErrorCode(StrEnum):
    INVALID_REQUEST = "invalid_request"
    INCOMPATIBLE_PROTOCOL = "incompatible_protocol"
    AUDIO_NOT_FOUND = "audio_not_found"
    UNSUPPORTED_AUDIO_FORMAT = "unsupported_audio_format"
    MODEL_NOT_INSTALLED = "model_not_installed"
    MANIFEST_MISMATCH = "manifest_mismatch"
    MODEL_LOAD_FAILED = "model_load_failed"
    INFERENCE_FAILED = "inference_failed"
    TIMEOUT = "timeout"
    CANCELLED = "cancelled"
    BACKEND_UNAVAILABLE = "backend_unavailable"
    INTERNAL_ERROR = "internal_error"
    BIAS_LIST_TOO_LARGE = "bias_list_too_large"
