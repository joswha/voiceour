from __future__ import annotations

from abc import ABC, abstractmethod
from threading import Event

from voiceoour_asr.protocol import Cancelled, ErrorMessage, HealthResponse, Result, TranscribeRequest


class Backend(ABC):
    backend_id: str

    @abstractmethod
    def health(self) -> HealthResponse:
        raise NotImplementedError

    @abstractmethod
    def transcribe(self, request: TranscribeRequest, cancelled: Event) -> Result | ErrorMessage | Cancelled:
        raise NotImplementedError
