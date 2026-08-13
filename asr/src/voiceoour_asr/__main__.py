from __future__ import annotations

import json
import os
import sys
import time
from threading import Event, Lock, Thread

from pydantic import ValidationError

from voiceoour_asr import __version__, cache
from voiceoour_asr.backends.ark import ArkBackend
from voiceoour_asr.backends.fake import FakeBackend
from voiceoour_asr.backends.mlx import MLXBackend
from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import (
    PROTOCOL_VERSION,
    BackendStatus,
    CancelRequest,
    Capabilities,
    ErrorMessage,
    HealthRequest,
    HealthResponse,
    Hello,
    TranscribeRequest,
    protocol_error,
)

_EMIT_LOCK = Lock()
_JOIN_TIMEOUT_SECONDS = 0.2


def make_backend():
    backend_name = os.environ.get("VOICEOOUR_ASR_BACKEND", "fake")
    if backend_name == "fake":
        return FakeBackend()
    if backend_name == "mlx":
        return MLXBackend()
    if backend_name == "ark-0.6b":
        return ArkBackend(cache.ARK_06B, "ark-0.6b")
    if backend_name == "ark-3b":
        return ArkBackend(cache.ARK_3B, "ark-3b")
    return None


def emit(message) -> None:
    line = message.model_dump_json() + "\n"
    with _EMIT_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


def emit_error(code: ErrorCode, *, request_id: str | None = None, detail: str | None = None) -> None:
    emit(protocol_error(code, request_id=request_id, detail=detail))


def parse_message(line: str):
    try:
        raw = json.loads(line)
    except json.JSONDecodeError as exc:
        return protocol_error(ErrorCode.INVALID_REQUEST, detail=str(exc))
    if raw.get("protocol_version") != PROTOCOL_VERSION:
        return protocol_error(
            ErrorCode.INCOMPATIBLE_PROTOCOL, request_id=raw.get("request_id"), detail="protocol_version mismatch"
        )
    typ = raw.get("type")
    try:
        if typ == "health":
            return HealthRequest.model_validate(raw)
        if typ == "transcribe":
            return TranscribeRequest.model_validate(raw)
        if typ == "cancel":
            return CancelRequest.model_validate(raw)
    except ValidationError as exc:
        return protocol_error(ErrorCode.INVALID_REQUEST, request_id=raw.get("request_id"), detail=str(exc))
    return protocol_error(ErrorCode.INVALID_REQUEST, request_id=raw.get("request_id"), detail=f"unknown type {typ!r}")


def start_preload(backend) -> None:
    if os.environ.get("VOICEOOUR_PRELOAD") != "1" or not hasattr(backend, "warm_up"):
        return

    def preload() -> None:
        try:
            start = time.perf_counter()
            backend.warm_up()
            elapsed_ms = int((time.perf_counter() - start) * 1000)
            print(f"VOICEOOUR_PRELOAD warm in {elapsed_ms}ms", file=sys.stderr)
        except Exception as exc:  # pragma: no cover - best-effort warm path
            print(f"VOICEOOUR_PRELOAD failed: {exc}", file=sys.stderr)

    Thread(target=preload, name="voiceoour-asr-preload", daemon=True).start()


def main() -> int:
    backend = make_backend()
    if backend is None:
        emit(
            Hello(
                sidecar_version=__version__,
                backend_id="unknown",
                backend_status=BackendStatus.BACKEND_UNAVAILABLE,
                capabilities=Capabilities(),
            )
        )
    else:
        status = BackendStatus.READY
        if not backend.health().cache_ok:
            status = BackendStatus.MODEL_MISSING
        emit(
            Hello(
                sidecar_version=__version__,
                backend_id=backend.backend_id,
                backend_status=status,
                capabilities=Capabilities(),
            )
        )
        start_preload(backend)

    inflight_lock = Lock()
    inflight: dict[str, tuple[Thread, Event]] = {}

    def run_transcribe(request: TranscribeRequest, cancelled: Event) -> None:
        try:
            if backend is None:
                terminal = protocol_error(
                    ErrorCode.BACKEND_UNAVAILABLE, request_id=request.request_id, detail="unknown backend"
                )
            else:
                terminal = backend.transcribe(request, cancelled)
        except Exception as exc:  # never crash the loop
            terminal = protocol_error(ErrorCode.INTERNAL_ERROR, request_id=request.request_id, detail=str(exc))
        emit(terminal)
        with inflight_lock:
            inflight.pop(request.request_id, None)

    for line in sys.stdin:
        parsed = parse_message(line)
        if isinstance(parsed, ErrorMessage):
            emit(parsed)
            continue
        if backend is None:
            emit_error(
                ErrorCode.BACKEND_UNAVAILABLE, request_id=getattr(parsed, "request_id", None), detail="unknown backend"
            )
            continue
        if isinstance(parsed, HealthRequest):
            try:
                health = backend.health()
            except Exception as exc:  # never crash the loop
                emit_error(ErrorCode.INTERNAL_ERROR, request_id=parsed.request_id, detail=str(exc))
            else:
                emit(
                    HealthResponse(
                        request_id=parsed.request_id,
                        ready=health.ready,
                        model_loaded=health.model_loaded,
                        cache_ok=health.cache_ok,
                    )
                )
        elif isinstance(parsed, CancelRequest):
            with inflight_lock:
                current = inflight.get(parsed.request_id)
            if current is not None:
                current[1].set()
        elif isinstance(parsed, TranscribeRequest):
            event = Event()
            thread = Thread(
                target=run_transcribe, args=(parsed, event), name=f"voiceoour-asr-{parsed.request_id}", daemon=True
            )
            with inflight_lock:
                if parsed.request_id in inflight:
                    thread = None
                else:
                    inflight[parsed.request_id] = (thread, event)
            if thread is None:
                emit_error(
                    ErrorCode.INVALID_REQUEST, request_id=parsed.request_id, detail="request_id already in flight"
                )
            else:
                thread.start()

    with inflight_lock:
        threads = [thread for thread, _ in inflight.values()]
    for thread in threads:
        thread.join(timeout=_JOIN_TIMEOUT_SECONDS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
