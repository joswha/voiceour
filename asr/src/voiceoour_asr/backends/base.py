from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path
from threading import Event

from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import (
    Cancelled,
    ErrorMessage,
    HealthResponse,
    Result,
    TranscribeRequest,
    protocol_error,
)


def validate_transcribe_request(
    request: TranscribeRequest,
    *,
    model_id: str,
    model_revision: str,
) -> Path | ErrorMessage:
    if request.expected_model:
        if request.expected_model.model_id and request.expected_model.model_id != model_id:
            return protocol_error(
                ErrorCode.MANIFEST_MISMATCH,
                request_id=request.request_id,
                detail="expected_model model_id mismatch",
            )
        if request.expected_model.revision and request.expected_model.revision != model_revision:
            return protocol_error(
                ErrorCode.MANIFEST_MISMATCH,
                request_id=request.request_id,
                detail="expected_model revision mismatch",
            )
    audio_path = Path(request.audio.path)
    if not audio_path.exists():
        return protocol_error(ErrorCode.AUDIO_NOT_FOUND, request_id=request.request_id, detail=str(audio_path))
    if request.audio.format.lower() != "wav":
        return protocol_error(
            ErrorCode.UNSUPPORTED_AUDIO_FORMAT,
            request_id=request.request_id,
            detail=request.audio.format,
        )
    return audio_path


class Backend(ABC):
    backend_id: str

    @abstractmethod
    def health(self) -> HealthResponse:
        raise NotImplementedError

    @abstractmethod
    def transcribe(self, request: TranscribeRequest, cancelled: Event) -> Result | ErrorMessage | Cancelled:
        raise NotImplementedError
