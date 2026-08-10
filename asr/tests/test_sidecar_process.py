from __future__ import annotations

import json
import os
import selectors
import subprocess
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest

ASR_DIR = Path(__file__).resolve().parents[1]
PROTOCOL_VERSION = 1


def health_request(request_id: str, *, protocol_version: int = PROTOCOL_VERSION) -> dict[str, object]:
    return {"type": "health", "protocol_version": protocol_version, "request_id": request_id}


def transcribe_request(request_id: str) -> dict[str, object]:
    return {
        "type": "transcribe",
        "protocol_version": PROTOCOL_VERSION,
        "request_id": request_id,
        "audio": {
            "path": "/tmp/voiceoour-fake.wav",
            "format": "wav",
            "sample_rate_hz": 16000,
            "channels": 1,
            "duration_ms": 321,
            "byte_count": 654,
        },
        "timeout_ms": 30000,
    }


@contextmanager
def sidecar(*, backend: str = "fake", extra_env: dict[str, str] | None = None) -> Iterator[subprocess.Popen[str]]:
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["VOICEOOUR_ASR_BACKEND"] = backend
    env.pop("VOICEOOUR_FAKE_DELAY_MS", None)
    if extra_env:
        env.update(extra_env)

    proc = subprocess.Popen(
        [sys.executable, "-m", "voiceoour_asr"],
        cwd=ASR_DIR,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        yield proc
    finally:
        if proc.stdin is not None and not proc.stdin.closed:
            proc.stdin.close()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)


def read_stdout_line(proc: subprocess.Popen[str], *, timeout: float = 2.0) -> str:
    assert proc.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    try:
        events = selector.select(timeout)
    finally:
        selector.close()
    if not events:
        pytest.fail(f"timed out waiting for sidecar stdout; exit_code={proc.poll()}")
    line = proc.stdout.readline()
    if line == "":
        pytest.fail(f"sidecar stdout closed before a protocol line; exit_code={proc.poll()}")
    assert line.endswith("\n")
    return line


def read_protocol(proc: subprocess.Popen[str], *, timeout: float = 2.0) -> dict[str, object]:
    line = read_stdout_line(proc, timeout=timeout)
    try:
        message = json.loads(line)
    except json.JSONDecodeError as exc:
        pytest.fail(f"stdout line was not valid NDJSON: {line!r}; error={exc}")
    assert isinstance(message, dict)
    assert message.get("protocol_version") == PROTOCOL_VERSION
    return message


def write_message(proc: subprocess.Popen[str], message: dict[str, object]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def assert_fake_hello(message: dict[str, object]) -> None:
    assert message["type"] == "hello"
    assert message["backend_id"] == "fake"
    assert message["backend_status"] == "ready"


def test_health_request_returns_ready_fake_backend_status():
    with sidecar() as proc:
        assert_fake_hello(read_protocol(proc))

        write_message(proc, health_request("health-1"))
        response = read_protocol(proc)

    assert response == {
        "type": "health",
        "protocol_version": PROTOCOL_VERSION,
        "request_id": "health-1",
        "ready": True,
        "model_loaded": True,
        "cache_ok": True,
    }


def test_protocol_version_mismatch_returns_incompatible_protocol_error():
    with sidecar() as proc:
        assert_fake_hello(read_protocol(proc))

        write_message(proc, health_request("bad-version", protocol_version=PROTOCOL_VERSION + 1))
        response = read_protocol(proc)

    assert response["type"] == "error"
    assert response["request_id"] == "bad-version"
    assert response["code"] == "incompatible_protocol"


def test_unknown_request_type_returns_invalid_request_error():
    with sidecar() as proc:
        assert_fake_hello(read_protocol(proc))

        write_message(proc, {"type": "wat", "protocol_version": PROTOCOL_VERSION, "request_id": "unknown-type"})
        response = read_protocol(proc)

    assert response["type"] == "error"
    assert response["request_id"] == "unknown-type"
    assert response["code"] == "invalid_request"


def test_malformed_line_returns_invalid_request():
    with sidecar() as proc:
        assert_fake_hello(read_protocol(proc))

        assert proc.stdin is not None
        proc.stdin.write("not-json\n")
        proc.stdin.flush()
        response = read_protocol(proc)

    assert response["type"] == "error"
    assert response["code"] == "invalid_request"


def test_unknown_backend_env_returns_backend_unavailable_error():
    with sidecar(backend="not-a-backend") as proc:
        hello = read_protocol(proc)
        assert hello["type"] == "hello"
        assert hello["backend_id"] == "unknown"
        assert hello["backend_status"] == "backend_unavailable"

        write_message(proc, health_request("backend-missing"))
        response = read_protocol(proc)

    assert response["type"] == "error"
    assert response["request_id"] == "backend-missing"
    assert response["code"] == "backend_unavailable"


def test_delayed_transcribe_can_be_cancelled_before_fake_delay():
    delay_ms = 1000
    with sidecar(extra_env={"VOICEOOUR_FAKE_DELAY_MS": str(delay_ms)}) as proc:
        assert_fake_hello(read_protocol(proc))

        start_ns = time.monotonic_ns()
        write_message(proc, transcribe_request("cancel-me"))
        write_message(proc, {"type": "cancel", "protocol_version": PROTOCOL_VERSION, "request_id": "cancel-me"})
        response = read_protocol(proc, timeout=delay_ms / 1000 + 1)
        latency_ms = (time.monotonic_ns() - start_ns) / 1_000_000

    print(f"cancel_latency_ms={latency_ms:.3f}")
    assert response["type"] == "cancelled"
    assert response["request_id"] == "cancel-me"
    assert latency_ms < delay_ms, f"cancel latency {latency_ms:.3f}ms exceeded fake delay {delay_ms}ms"


def test_two_sequential_transcribes_share_one_sidecar_process():
    with sidecar() as proc:
        assert_fake_hello(read_protocol(proc))
        pid = proc.pid

        write_message(proc, transcribe_request("first"))
        first = read_protocol(proc)
        assert proc.pid == pid
        assert proc.poll() is None

        write_message(proc, transcribe_request("second"))
        second = read_protocol(proc)
        assert proc.pid == pid

    assert first["type"] == "result"
    assert first["request_id"] == "first"
    assert first["transcript"]["text"] == "fake transcript duration_ms=321"
    assert second["type"] == "result"
    assert second["request_id"] == "second"
    assert second["transcript"]["text"] == "fake transcript duration_ms=321"


def test_stdout_emits_only_protocol_ndjson_lines():
    with sidecar() as running:
        lines = [read_stdout_line(running)]
        write_message(running, health_request("stdout-health"))
        write_message(running, transcribe_request("stdout-transcribe"))
        assert running.stdin is not None
        running.stdin.close()
        running.wait(timeout=2)
        assert running.stdout is not None
        lines.extend(running.stdout.readlines())

    messages: list[dict[str, object]] = []
    for line in lines:
        assert line.endswith("\n")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            pytest.fail(f"stdout line was not valid NDJSON: {line!r}; error={exc}")
        assert isinstance(message, dict)
        assert message.get("protocol_version") == PROTOCOL_VERSION
        messages.append(message)

    assert [message["type"] for message in messages] == ["hello", "health", "result"]
    assert messages[1]["request_id"] == "stdout-health"
    assert messages[2]["request_id"] == "stdout-transcribe"
