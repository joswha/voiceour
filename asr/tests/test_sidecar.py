from __future__ import annotations

from threading import Event

from voiceoour_asr.backends.fake import FakeBackend
from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import AudioMeta, Cancelled, TranscribeRequest


def request(timeout_ms: int = 30000) -> TranscribeRequest:
    return TranscribeRequest(
        request_id="req",
        audio=AudioMeta(
            path="/tmp/fake.wav", format="wav", sample_rate_hz=16000, channels=1, duration_ms=123, byte_count=456
        ),
        timeout_ms=timeout_ms,
    )


def test_fake_transcribe():
    result = FakeBackend().transcribe(request(), Event())
    assert result.type == "result"
    assert "duration_ms=123" in result.transcript.text


def test_fake_cancel():
    event = Event()
    event.set()
    result = FakeBackend().transcribe(request(), event)
    assert isinstance(result, Cancelled)


def test_fake_timeout():
    result = FakeBackend().transcribe(request(timeout_ms=0), Event())
    assert result.type == "error"
    assert result.code == ErrorCode.TIMEOUT
