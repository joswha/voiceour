from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace

import pytest

from voiceoour_bench.capture_matrix import (
    CAPTURE_MODES,
    CONDITIONS,
    build_report,
    dry_run_commands,
    ingest_results,
    main,
    plan_matrix,
    run_matrix,
    write_jsonl,
)


def _plan(tmp_path: Path, *, speaker_kind: str = "real") -> list[dict[str, object]]:
    return plan_matrix(
        [{"id": "kubectl", "reference": "Run kubectl get pods."}],
        tmp_path / "audio",
        speaker_id="speaker-01",
        speaker_kind=speaker_kind,
    )


def _result_for(row: dict[str, object]) -> dict[str, object]:
    return {
        "type": "capture_result",
        "id": row["id"],
        "pair_id": row["pair_id"],
        "prompt_id": row["prompt_id"],
        "prompt": row["prompt"],
        "take_id": row["take_id"],
        "mode": row["mode"],
        "condition": row["condition"],
        "output_path": row["output_path"],
        "telemetry": {"clip_ratio": 0.0},
    }


def test_default_plan_is_stable_and_covers_full_paired_matrix(tmp_path: Path) -> None:
    first = _plan(tmp_path)
    second = _plan(tmp_path)

    assert first == second
    assert len(first) == 2 * len(CONDITIONS) * 2 * 2 * len(CAPTURE_MODES)
    assert {row["mode"] for row in first} == set(CAPTURE_MODES)
    assert {row["condition"] for row in first} == set(CONDITIONS)
    assert {row["pre_roll_ms"] for row in first} == {100, 200}
    assert {row["post_roll_ms"] for row in first} == {300, 500}
    assert {row["take_id"] for row in first} == {"take-01", "take-02"}

    by_pair: defaultdict[object, list[dict[str, object]]] = defaultdict(list)
    for row in first:
        by_pair[row["pair_id"]].append(row)
    for paired_rows in by_pair.values():
        assert {row["mode"] for row in paired_rows} == set(CAPTURE_MODES)
        assert len({row["prompt_id"] for row in paired_rows}) == 1
        assert len({row["prompt"] for row in paired_rows}) == 1
        assert len({row["take_id"] for row in paired_rows}) == 1


def test_manifest_bytes_and_dry_run_commands_are_stable_without_subprocess(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    rows = plan_matrix(
        [{"prompt_id": "c-plus-plus", "prompt": "Open the C plus plus project."}],
        Path("captures"),
        modes=("standard", "native"),
        conditions=("quiet",),
        pre_roll_ms=(100,),
        post_roll_ms=(300,),
        takes=1,
        duration_ms=4_000,
        speaker_id="speaker-02",
        speaker_kind="real",
    )
    first_path = tmp_path / "first.jsonl"
    second_path = tmp_path / "second.jsonl"
    write_jsonl(first_path, rows)
    write_jsonl(second_path, rows)

    def microphone_must_not_be_touched(*args: object, **kwargs: object) -> None:
        raise AssertionError("dry-run started a subprocess")

    monkeypatch.setattr("voiceoour_bench.capture_matrix.subprocess.run", microphone_must_not_be_touched)
    commands = dry_run_commands(rows)

    assert first_path.read_bytes() == second_path.read_bytes()
    assert commands == [row["command"] for row in rows]
    assert commands[0] == [
        "voiceoour-capture-bench",
        "--mode",
        "standard",
        "--duration-ms",
        "4000",
        "--pre-roll-ms",
        "100",
        "--post-roll-ms",
        "300",
        "--output",
        "captures/quiet/c-plus-plus/c-plus-plus__take-01__quiet__pre-100__post-300__standard.wav",
    ]


def test_plan_cli_dry_run_writes_manifest_and_prints_commands_without_capture(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    prompts_path = tmp_path / "prompts.jsonl"
    manifest_path = tmp_path / "manifest.jsonl"
    write_jsonl(prompts_path, [{"prompt_id": "rust", "prompt": "Open the Rust workspace."}])

    def microphone_must_not_be_touched(*args: object, **kwargs: object) -> None:
        raise AssertionError("dry-run started a subprocess")

    monkeypatch.setattr("voiceoour_bench.capture_matrix.subprocess.run", microphone_must_not_be_touched)
    exit_code = main(
        [
            "plan",
            "--prompts",
            str(prompts_path),
            "--manifest",
            str(manifest_path),
            "--output-dir",
            "captures",
            "--speaker-id",
            "speaker-04",
            "--speaker-kind",
            "real",
            "--modes",
            "standard,native",
            "--conditions",
            "quiet",
            "--pre-roll-ms",
            "100",
            "--post-roll-ms",
            "300",
            "--takes",
            "1",
            "--duration-ms",
            "4000",
            "--dry-run",
        ]
    )

    output_lines = capsys.readouterr().out.splitlines()
    assert exit_code == 0
    assert len(read_json_lines := manifest_path.read_text(encoding="utf-8").splitlines()) == 2
    assert all(json.loads(line)["type"] == "capture_plan" for line in read_json_lines)
    assert output_lines[-2:] == [f"Manifest: {manifest_path}", "Planned captures: 2"]
    assert output_lines[0].startswith("voiceoour-capture-bench --mode standard ")
    assert output_lines[1].startswith("voiceoour-capture-bench --mode native ")


@pytest.mark.parametrize(
    ("field", "wrong_value"),
    (("prompt_id", "different-prompt"), ("prompt", "Say something else."), ("take_id", "take-99")),
)
def test_ingestion_rejects_mismatched_prompt_or_take(tmp_path: Path, field: str, wrong_value: str) -> None:
    manifest = _plan(tmp_path)[:1]
    result = _result_for(manifest[0])
    result[field] = wrong_value

    with pytest.raises(ValueError, match=rf"{field} mismatch"):
        ingest_results(manifest, [result])


def test_ingestion_rejects_missing_identity_even_when_capture_id_matches(tmp_path: Path) -> None:
    manifest = _plan(tmp_path)[:1]
    result = _result_for(manifest[0])
    del result["take_id"]

    with pytest.raises(ValueError, match="take_id mismatch"):
        ingest_results(manifest, [result])


def test_report_keeps_missing_manual_and_hardware_rows_explicit(tmp_path: Path) -> None:
    manifest = plan_matrix(
        [{"id": "rust", "reference": "Open the Rust workspace."}],
        tmp_path / "audio",
        modes=("standard", "native"),
        conditions=("quiet", "bluetooth", "route-change"),
        pre_roll_ms=(100,),
        post_roll_ms=(300,),
        takes=1,
        duration_ms=4_000,
        speaker_id="speaker-03",
        speaker_kind="real",
    )
    captured = [_result_for(manifest[0])]

    report = build_report(manifest, captured)

    assert report["collection_status"] == "incomplete"
    assert report["quality_verdict"] == "not-evaluated"
    assert report["counts"] == {
        "planned": 6,
        "captured": 1,
        "capture_errors": 0,
        "missing": 5,
        "missing_manual": 5,
        "missing_hardware_dependent": 4,
    }
    missing_rows = [row for row in report["rows"] if row["collection_status"] != "captured"]
    assert all(row["collection_status"] == "missing-manual" for row in missing_rows)
    assert sum(bool(row["hardware_dependent"]) for row in missing_rows) == 4
    assert all("passed" not in row for row in report["rows"])


def test_tts_rows_are_labeled_smoke_only(tmp_path: Path) -> None:
    rows = _plan(tmp_path, speaker_kind="tts")

    assert {row["evidence_scope"] for row in rows} == {"smoke-only"}
    assert {row["speaker_kind"] for row in rows} == {"tts"}


def test_run_requires_real_speaker_consent_before_starting_subprocess(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    rows = _plan(tmp_path)[:1]

    def must_not_run(*args: object, **kwargs: object) -> None:
        raise AssertionError("capture started without consent")

    monkeypatch.setattr("voiceoour_bench.capture_matrix.subprocess.run", must_not_run)
    with pytest.raises(ValueError, match="consent"):
        run_matrix(rows, tmp_path / "results.jsonl")


def test_run_decorates_single_json_result_for_strict_ingestion(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    rows = _plan(tmp_path, speaker_kind="tts")[:1]
    executable_result = {
        "mode": rows[0]["mode"],
        "output_path": rows[0]["output_path"],
        "requested_duration_ms": rows[0]["duration_ms"],
        "captured_duration_ms": 3_950,
        "pre_roll_ms": rows[0]["pre_roll_ms"],
        "post_roll_ms": rows[0]["post_roll_ms"],
        "implementation": "production-av-audio-recorder",
        "endpoint_bounding_applied": False,
        "telemetry": {"clip_ratio": 0.001, "processing_mode": rows[0]["mode"]},
    }

    def fake_run(*args: object, **kwargs: object) -> SimpleNamespace:
        return SimpleNamespace(stdout=json.dumps(executable_result) + "\n")

    monkeypatch.setattr("voiceoour_bench.capture_matrix.subprocess.run", fake_run)
    results_path = tmp_path / "results.jsonl"
    result_rows = run_matrix(rows, results_path)

    assert ingest_results(rows, result_rows) == {rows[0]["id"]: result_rows[0]}
    assert result_rows[0]["telemetry"] == executable_result["telemetry"]
    assert result_rows[0]["captured_duration_ms"] == 3_950
    assert result_rows[0]["implementation"] == "production-av-audio-recorder"
    assert result_rows[0]["endpoint_bounding_applied"] is False
    assert json.loads(results_path.read_text(encoding="utf-8")) == result_rows[0]
