from __future__ import annotations

import os
import time
from threading import Event

from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import (
    Cancelled,
    ConfidenceMode,
    DecoderInfo,
    HealthResponse,
    Hypothesis,
    Result,
    Segment,
    Timings,
    TranscribeRequest,
    Transcript,
    Word,
    protocol_error,
)

from .base import Backend


class FakeBackend(Backend):
    backend_id = "fake"

    def health(self) -> HealthResponse:
        return HealthResponse(request_id="health", ready=True, model_loaded=True, cache_ok=True)

    def transcribe(self, request: TranscribeRequest, cancelled: Event):
        delay_ms = int(os.environ.get("VOICEOOUR_FAKE_DELAY_MS", "0"))
        if delay_ms > 0:
            deadline = time.monotonic() + delay_ms / 1000
            while time.monotonic() < deadline:
                if cancelled.is_set():
                    return Cancelled(request_id=request.request_id)
                time.sleep(0.01)
        if cancelled.is_set():
            return Cancelled(request_id=request.request_id)
        if request.timeout_ms <= 0:
            return protocol_error(ErrorCode.TIMEOUT, request_id=request.request_id, detail="fake timeout")
        text = f"fake transcript duration_ms={request.audio.duration_ms}"
        tokens = text.split()
        duration_ms = max(request.audio.duration_ms, len(tokens))
        per = duration_ms // len(tokens)
        words = [
            Word(
                text=token,
                start_ms=index * per,
                end_ms=(index + 1) * per if index + 1 < len(tokens) else duration_ms,
                confidence=1.0,
            )
            for index, token in enumerate(tokens)
        ]
        segments = [Segment(start_ms=0, end_ms=duration_ms, text=text, words=words)]
        bias_enabled = bool(request.bias_phrases)
        transcript = Transcript(
            text=text,
            language="en",
            segments=segments,
            confidence=1.0,
            confidence_mode=ConfidenceMode.NONE,
        )
        hypotheses = [Hypothesis(rank=0, text=text, score=0.0, raw_score=0.0, transcript=None)]
        if bias_enabled:
            biased = f"{text} {request.bias_phrases[0].text}".strip()
            hypotheses.append(Hypothesis(rank=1, text=biased, score=-1.0, raw_score=-1.0, transcript=None))
        return Result(
            request_id=request.request_id,
            backend_id=self.backend_id,
            model_id="fake",
            model_revision="dev",
            transcript=transcript,
            timings_ms=Timings(load=0, inference=0, total=0),
            hypotheses=hypotheses,
            decoder=DecoderInfo(
                mode="greedy",
                beam_size=None,
                bias_enabled=bias_enabled,
                bias_snapshot_id=request.bias_snapshot_id,
            ),
        )
