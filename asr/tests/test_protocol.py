from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import (
    Cancelled,
    CancelRequest,
    ErrorMessage,
    HealthRequest,
    HealthResponse,
    Hello,
    Result,
    TranscribeRequest,
    protocol_error,
)

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "fixtures" / "protocol"


FIXTURE_MODELS = {
    "hello.json": Hello,
    "health_request.json": HealthRequest,
    "health_response.json": HealthResponse,
    "transcribe.json": TranscribeRequest,
    "result.json": Result,
    "result_with_evidence.json": Result,
    "cancel.json": CancelRequest,
    "cancelled.json": Cancelled,
    "error.json": ErrorMessage,
}
DISCOVERED_FIXTURES = frozenset(path.name for path in FIXTURES.glob("*.json"))


def test_protocol_fixture_set_matches_type_mapping():
    assert DISCOVERED_FIXTURES == set(FIXTURE_MODELS)


@pytest.mark.parametrize("filename", sorted(DISCOVERED_FIXTURES))
def test_protocol_fixtures_round_trip(filename):
    data = json.loads((FIXTURES / filename).read_text())
    parsed = FIXTURE_MODELS[filename].model_validate(data)
    assert parsed.model_dump(mode="json", exclude_none=False) == data
    if filename == "error.json":
        assert parsed.user_message_key == f"asr.{parsed.code.value}"


def test_protocol_error_message_keys_match_error_codes():
    for code in ErrorCode:
        message = protocol_error(code)
        assert message.user_message_key == f"asr.{code.value}"


def test_protocol_rejects_extra_fields():
    data = json.loads((FIXTURES / "health_request.json").read_text())
    data["unexpected"] = "must not be accepted"

    with pytest.raises(ValidationError):
        HealthRequest.model_validate(data)
