from __future__ import annotations

import json
from pathlib import Path

import pytest

from voiceour_bench.calibrate import (
    DEFAULT_ACCEPTED_ERROR_BOUND,
    calibrate_profile,
    select_operating_point,
)
from voiceour_bench.calibrate import (
    main as calibrate_main,
)
from voiceour_bench.disagreement import (
    align_ids,
    build_run,
    disagreement_summary,
)
from voiceour_bench.disagreement import (
    main as disagreement_main,
)

# --- disagreement -----------------------------------------------------------

_MANIFEST = [
    {"id": "u1", "canonical_term": "kubectl", "expect_term": True},
    {"id": "u2", "canonical_term": "MLX", "expect_term": True},
    {"id": "u3", "reference": "hello world"},
    {"id": "u4", "canonical_term": "IPv6", "expect_term": True},
]

_RESULTS_A = [
    {"type": "row", "id": "u1", "raw_transcript": "run kubectl now"},
    {"type": "row", "id": "u2", "raw_transcript": "em ell ex"},
    {"type": "row", "id": "u3", "raw_transcript": "hello world"},
    {"type": "row", "id": "u4", "raw_transcript": "use IPv6"},
]

_RESULTS_B = [
    {"type": "row", "id": "u1", "raw_transcript": "run cube cuddle now"},
    {"type": "row", "id": "u2", "raw_transcript": "use MLX"},
    {"type": "row", "id": "u3", "raw_transcript": "hello world"},
    {"type": "row", "id": "u4", "raw_transcript": "use IPv6"},
]


def _run_pair() -> tuple:
    run_a = build_run(_RESULTS_A, _MANIFEST, label="apple")
    run_b = build_run(_RESULTS_B, _MANIFEST, label="parakeet")
    return run_a, run_b


def test_disagreement_alignment_and_routing_signal_math() -> None:
    run_a, run_b = _run_pair()
    summary = disagreement_summary(run_a, run_b)

    assert summary["run_a"] == "apple"
    assert summary["run_b"] == "parakeet"
    assert summary["aligned"] == 4
    # u1 (kubectl vs cube cuddle) and u2 (em ell ex vs use MLX) differ; u3/u4 agree.
    assert summary["disagreements"] == 2
    assert summary["disagreement_rate"] == pytest.approx(0.5)
    assert summary["disagreeing_ids"] == ["u1", "u2"]

    assert summary["term_opportunities"] == 3
    recovery = summary["term_recovery"]
    assert recovery["both"] == 1  # u4
    assert recovery["only_run_a"] == 1  # u1 kubectl
    assert recovery["only_run_b"] == 1  # u2 MLX
    assert recovery["neither"] == 0
    assert recovery["exclusive_recovery"] == 2
    assert recovery["exclusive_recovery_rate"] == pytest.approx(2 / 3)

    routing = summary["routing_signal"]
    assert routing["disagreement_term_opportunities"] == 2  # u1, u2
    assert routing["term_recovery_on_disagreement"] == 2
    assert routing["term_recovery_on_disagreement_rate"] == pytest.approx(1.0)
    assert routing["run_a_recovers_on_disagreement"] == 1  # u1
    assert routing["run_b_recovers_on_disagreement"] == 1  # u2


def test_disagreement_uses_normalization_not_casing_or_punctuation() -> None:
    manifest = [{"id": "x", "reference": "twenty one apples"}]
    run_a = build_run([{"type": "row", "id": "x", "raw_transcript": "I have twenty one apples."}], manifest, label="a")
    run_b = build_run([{"type": "row", "id": "x", "raw_transcript": "i have 21 apples"}], manifest, label="b")

    summary = disagreement_summary(run_a, run_b)
    assert summary["disagreements"] == 0
    assert summary["disagreement_rate"] == pytest.approx(0.0)


def test_disagreement_rejects_mismatched_id_sets() -> None:
    run_a = build_run(
        [{"type": "row", "id": "u1", "raw_transcript": "a"}, {"type": "row", "id": "u2", "raw_transcript": "b"}],
        _MANIFEST,
        label="apple",
    )
    run_b = build_run(
        [{"type": "row", "id": "u1", "raw_transcript": "a"}, {"type": "row", "id": "u3", "raw_transcript": "c"}],
        _MANIFEST,
        label="parakeet",
    )
    with pytest.raises(ValueError, match="mismatched id"):
        align_ids(run_a, run_b)
    with pytest.raises(ValueError, match="mismatched id"):
        disagreement_summary(run_a, run_b)


def test_disagreement_cli_writes_summary(tmp_path: Path) -> None:
    def _write(path: Path, rows: list[dict]) -> None:
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

    manifest_path = tmp_path / "manifest.jsonl"
    results_a = tmp_path / "a.results.jsonl"
    results_b = tmp_path / "b.results.jsonl"
    out = tmp_path / "summary.json"
    _write(manifest_path, _MANIFEST)
    _write(results_a, _RESULTS_A)
    _write(results_b, _RESULTS_B)

    code = disagreement_main(
        [
            "--run-a-results",
            str(results_a),
            "--run-a-manifest",
            str(manifest_path),
            "--run-b-results",
            str(results_b),
            "--run-b-manifest",
            str(manifest_path),
            "--run-a-label",
            "apple",
            "--run-b-label",
            "parakeet",
            "--out",
            str(out),
        ]
    )
    assert code == 0
    summary = json.loads(out.read_text(encoding="utf-8"))
    assert summary["disagreements"] == 2
    assert summary["routing_signal"]["term_recovery_on_disagreement"] == 2


# --- calibration ------------------------------------------------------------


def _report(*, count: int = 100, speaker_kind: str | None = None, points: list[dict] | None = None) -> dict:
    if points is None:
        points = [
            {"threshold": None, "covered": 0, "coverage": 0.0, "risk": None},
            {"threshold": 0.9, "covered": 10, "coverage": 0.10, "risk": 0.0},
            {"threshold": 0.8, "covered": 30, "coverage": 0.30, "risk": 0.005},
            {"threshold": 0.7, "covered": 60, "coverage": 0.60, "risk": 0.02},
            {"threshold": 0.6, "covered": count, "coverage": 1.0, "risk": 0.05},
        ]
    report: dict = {
        "tier": "techterms",
        "mode": "e2e",
        "generated_at": "2026-07-19T00:00:00+00:00",
        "metrics": {
            "confidence_by_mode": {
                "posterior": {
                    "count": count,
                    "mean_confidence": 0.75,
                    "reliability": {"brier": 0.1, "ece": 0.05, "count": count, "bins": []},
                    "risk_coverage": points,
                }
            }
        },
    }
    if speaker_kind is not None:
        report["meta"] = {"speaker_kind": speaker_kind}
    return report


def test_select_operating_point_maximizes_coverage_within_bound() -> None:
    report = _report()
    points = report["metrics"]["confidence_by_mode"]["posterior"]["risk_coverage"]
    operating = select_operating_point(points, DEFAULT_ACCEPTED_ERROR_BOUND)
    assert operating is not None
    # 0.9 (risk 0) and 0.8 (risk 0.005) are eligible; 0.8 has larger coverage.
    assert operating["threshold"] == pytest.approx(0.8)
    assert operating["coverage"] == pytest.approx(0.30)
    assert operating["risk"] <= DEFAULT_ACCEPTED_ERROR_BOUND


def test_calibration_recommends_safe_threshold_for_real_high_n_source() -> None:
    profile = calibrate_profile(_report(), speaker_kind="real")
    assert profile["provisional"] is False
    mode = profile["modes"]["posterior"]
    assert mode["recommended_threshold"] == pytest.approx(0.8)
    assert mode["risk"] <= DEFAULT_ACCEPTED_ERROR_BOUND
    assert mode["provisional"] is False


def test_calibration_never_recommends_threshold_violating_bound() -> None:
    unsafe_points = [
        {"threshold": None, "covered": 0, "coverage": 0.0, "risk": None},
        {"threshold": 0.9, "covered": 20, "coverage": 0.20, "risk": 0.03},
        {"threshold": 0.8, "covered": 50, "coverage": 0.50, "risk": 0.04},
        {"threshold": 0.7, "covered": 100, "coverage": 1.0, "risk": 0.08},
    ]
    profile = calibrate_profile(_report(points=unsafe_points), speaker_kind="real")
    mode = profile["modes"]["posterior"]
    assert mode["recommended_threshold"] is None
    assert mode["risk"] is None
    assert "no_threshold_satisfies_bound" in mode["provisional_reasons"]
    assert profile["provisional"] is True


def test_calibration_flags_tts_source_as_provisional() -> None:
    profile = calibrate_profile(_report(speaker_kind="tts"), speaker_kind="tts")
    assert profile["provisional"] is True
    assert "speaker_kind=tts" in profile["provisional_reasons"]
    mode = profile["modes"]["posterior"]
    # A threshold can still be suggested, but the profile is marked provisional.
    assert mode["recommended_threshold"] == pytest.approx(0.8)
    assert mode["provisional"] is True


def test_calibration_flags_low_opportunity_count_as_provisional() -> None:
    profile = calibrate_profile(_report(count=5), speaker_kind="real")
    assert profile["provisional"] is True
    mode = profile["modes"]["posterior"]
    assert any(reason.startswith("low_n") for reason in mode["provisional_reasons"])
    # Even below the count floor the recommended threshold still honors the bound.
    assert mode["recommended_threshold"] == pytest.approx(0.8)


def test_calibration_flags_unverified_speaker_source() -> None:
    profile = calibrate_profile(_report(), speaker_kind=None)
    assert profile["provisional"] is True
    assert "speaker_kind_unverified" in profile["provisional_reasons"]
    assert profile["source"]["speaker_kind"] == "unknown"


def test_calibration_reads_risk_coverage_points_alias() -> None:
    report = _report()
    entry = report["metrics"]["confidence_by_mode"]["posterior"]
    entry["risk_coverage_points"] = entry.pop("risk_coverage")
    profile = calibrate_profile(report, speaker_kind="real")
    assert profile["modes"]["posterior"]["recommended_threshold"] == pytest.approx(0.8)


def test_calibration_requires_confidence_by_mode() -> None:
    with pytest.raises(ValueError, match="confidence_by_mode"):
        calibrate_profile({"tier": "techterms", "metrics": {}})


def test_calibration_cli_writes_profile(tmp_path: Path) -> None:
    report_path = tmp_path / "report.json"
    out = tmp_path / "profile.json"
    report_path.write_text(json.dumps(_report(speaker_kind="tts")), encoding="utf-8")

    code = calibrate_main([str(report_path), "--speaker-kind", "tts", "--out", str(out)])
    assert code == 0
    profile = json.loads(out.read_text(encoding="utf-8"))
    assert profile["provisional"] is True
    assert profile["modes"]["posterior"]["risk"] <= DEFAULT_ACCEPTED_ERROR_BOUND
