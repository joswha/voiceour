from __future__ import annotations

import json

import pytest

from voiceoour_bench.compare import UWER_MAX_DELTA
from voiceoour_bench.compare import main as compare_main
from voiceoour_bench.metrics import (
    accepted_repair_precision,
    candidate_recall_at_k,
    canonical_term_prf,
    case_f1,
    cer,
    contains_exact_term,
    fwer,
    hard_negative_false_replacement_rate,
    nbest_oracle_coverage,
    no_op_preservation,
    over_edit_rate,
    percentiles,
    preservation_rate,
    punct_f1,
    reliability_metrics,
    risk_coverage_points,
    rtfx,
    selector_accuracy,
    uwer,
)
from voiceoour_bench.report import build_report


def test_uwer_identical_after_normalization() -> None:
    assert uwer(["I have twenty one apples."], ["i have 21 apples"]) == 0.0


def test_uwer_known_single_substitution() -> None:
    assert uwer(["ship the feature today"], ["ship the bug today"]) == pytest.approx(0.25)


def test_cer_known_single_character() -> None:
    assert cer(["abc"], ["adc"]) == pytest.approx(1 / 3)


def test_fwer_preserves_case_and_punctuation_tokens() -> None:
    # ref tokens: Hello , Morgan ! (4); hyp: hello Morgan. 3 edits (Hello->hello,
    # drop ",", drop "!") over 4 ref tokens = 3/4.
    assert fwer(["Hello, Morgan!"], ["hello Morgan"]) == pytest.approx(3 / 4)


def test_punct_f1_alignment_counts_trailing_marks() -> None:
    result = punct_f1(["Hello, Morgan! Are you ready?"], ["Hello Morgan! Are you ready."])
    assert result["marks"][","]["fn"] == 1
    assert result["marks"]["!"]["tp"] == 1
    assert result["marks"]["?"]["fn"] == 1
    assert result["marks"]["."]["fp"] == 1
    assert result["micro"]["precision"] == pytest.approx(0.5)
    assert result["micro"]["recall"] == pytest.approx(1 / 3)
    assert result["micro"]["f1"] == pytest.approx(0.4)


def test_case_f1_reports_sentence_initial_separately() -> None:
    result = case_f1(["Hello Morgan. Call Sam."], ["hello Morgan. call sam."])
    assert result["overall"]["tp"] == 1
    assert result["overall"]["fn"] == 3
    assert result["overall"]["f1"] == pytest.approx(0.4)
    assert result["sentence_initial"]["fn"] == 2
    assert result["non_sentence_initial"]["tp"] == 1
    assert result["non_sentence_initial"]["fn"] == 1


def test_over_edit_rate_uses_normalized_word_distance() -> None:
    assert over_edit_rate(["um ship the feature today"], ["ship the feature tomorrow"]) == pytest.approx(1 / 4)


def test_rtfx_aggregates_audio_over_asr_seconds() -> None:
    assert rtfx([2.0, 3.0], [1000, 4000]) == pytest.approx(1.0)


def test_percentiles_linear_interpolation() -> None:
    assert percentiles([10, 20, 30, 40]) == {"p50": 25.0, "p95": 38.5}


def test_exact_canonical_term_metrics_preserve_case_and_boundaries() -> None:
    assert contains_exact_term("Use Rust and kubectl.", "Rust")
    assert not contains_exact_term("Use rust and kubectl.", "Rust")
    assert not contains_exact_term("A Rustacean", "Rust")
    result = canonical_term_prf(
        ["kubectl", "Rust", "MLX"],
        [True, False, True],
        ["run kubectl now", "Rust is quick", "use mlx"],
    )
    assert result == {
        "precision": pytest.approx(0.5),
        "recall": pytest.approx(0.5),
        "f1": pytest.approx(0.5),
        "tp": 1,
        "fp": 1,
        "fn": 1,
        "opportunities": 3,
        "predicted_positive": 2,
    }


def test_canonical_term_metrics_expose_empty_denominators() -> None:
    result = canonical_term_prf([], [], [])
    assert result["precision"] is None
    assert result["recall"] is None
    assert result["f1"] is None
    assert result["opportunities"] == 0


def test_hard_negative_rate_and_preservation_metrics() -> None:
    result = hard_negative_false_replacement_rate([True, False, False], [None, True, False])
    assert result == {
        "false_replacements": 1,
        "opportunities": 2,
        "rate": pytest.approx(0.5),
        "per_10k_opportunities": pytest.approx(5000.0),
    }
    empty = hard_negative_false_replacement_rate([True], [None])
    assert empty["rate"] is None
    assert empty["per_10k_opportunities"] is None
    assert preservation_rate([True, None, False])["rate"] == pytest.approx(0.5)
    assert no_op_preservation(["keep", "change"], ["keep", "changed"], [True, False])["rate"] == 1.0


def test_candidate_recall_oracle_and_selector_metrics() -> None:
    expected = ["term-a", "term-b", None]
    candidates = [["term-a", "other"], ["other", "x", "term-b"], ["term-a"]]
    assert candidate_recall_at_k(expected, candidates, 1)["recall"] == pytest.approx(0.5)
    assert candidate_recall_at_k(expected, candidates, 5)["recall"] == 1.0
    assert candidate_recall_at_k(["term-a"], [None], 1)["recall"] is None
    oracle = nbest_oracle_coverage(
        ["kubectl", "MLX", None],
        [["cube cuddle", "use kubectl"], ["use mlx"], ["kubectl"]],
    )
    assert oracle["coverage"] == pytest.approx(0.5)
    selector = selector_accuracy(expected, candidates, ["term-a", "wrong", "term-a"])
    assert selector == {"correct": 1, "opportunities": 2, "accuracy": pytest.approx(0.5)}


def test_accepted_repair_precision_includes_measured_prevalence() -> None:
    result = accepted_repair_precision(
        ["term-a", None, "term-b", None],
        ["term-a", "wrong", None, None],
        [True, True, False, False],
    )
    assert result["precision"] == pytest.approx(0.5)
    assert result["correct"] == 1
    assert result["accepted"] == 2
    assert result["term_prevalence"] == pytest.approx(0.5)
    assert accepted_repair_precision([None], [None], [False])["precision"] is None


def test_reliability_bins_and_risk_coverage_are_deterministic() -> None:
    reliability = reliability_metrics([0.9, 0.6], [True, False], bin_count=2)
    assert reliability is not None
    assert reliability["brier"] == pytest.approx(0.185)
    assert reliability["ece"] == pytest.approx(0.25)
    assert reliability["bins"][0]["count"] == 0
    assert reliability["bins"][1]["mean_confidence"] == pytest.approx(0.75)
    assert reliability_metrics([None], [True]) is None

    points = risk_coverage_points([0.6, 0.9], [False, True])
    assert points == [
        {"threshold": None, "covered": 0, "coverage": 0.0, "risk": None},
        {"threshold": 0.9, "covered": 1, "coverage": pytest.approx(0.5), "risk": 0.0},
        {"threshold": 0.6, "covered": 2, "coverage": 1.0, "risk": pytest.approx(0.5)},
    ]
    assert risk_coverage_points([None], [True]) == []


def _write_jsonl(path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def test_report_keeps_old_tier_schema_without_tech_terms(tmp_path) -> None:
    manifest = tmp_path / "manifest.jsonl"
    results = tmp_path / "results.jsonl"
    _write_jsonl(manifest, [{"id": "old", "reference": "hello"}])
    _write_jsonl(
        results,
        [
            {"type": "bench_meta"},
            {"type": "row", "id": "old", "raw_transcript": "hello", "final_text": "hello"},
        ],
    )
    report, _ = build_report(results, manifest, "smoke", "stt", tmp_path / "reports")
    assert "tech_terms" not in report["metrics"]


def test_report_adds_tech_terms_and_omits_unobserved_candidate_evidence(tmp_path) -> None:
    manifest = tmp_path / "manifest.jsonl"
    results = tmp_path / "results.jsonl"
    _write_jsonl(
        manifest,
        [
            {
                "id": "positive",
                "reference": "use kubectl",
                "canonical_term": "kubectl",
                "term_id": "term-k",
                "term_class": "jargon",
                "expect_term": True,
                "hard_negative_kind": None,
                "project_scope": "project",
            },
            {
                "id": "negative",
                "reference": "rust is common",
                "canonical_term": "Rust",
                "term_id": "term-r",
                "term_class": "ambiguous",
                "expect_term": False,
                "hard_negative_kind": "case_ambiguity",
                "project_scope": "global",
            },
        ],
    )
    _write_jsonl(
        results,
        [
            {"type": "bench_meta"},
            {"type": "row", "id": "positive", "raw_transcript": "use cube cuddle", "final_text": "use kubectl"},
            {"type": "row", "id": "negative", "raw_transcript": "rust is common", "final_text": "Rust is common"},
        ],
    )
    report, _ = build_report(results, manifest, "techterms", "e2e", tmp_path / "reports")
    tech = report["metrics"]["tech_terms"]
    assert tech["canonical_term"]["f1"] == pytest.approx(2 / 3)
    assert tech["hard_negatives"]["per_10k_opportunities"] == 10_000.0
    assert tech["no_op_preservation"]["rate"] == 0.0
    assert set(tech["breakdowns"]) == {"source", "class", "risk"}
    assert "candidate_recall" not in tech
    assert "reliability" not in tech
    assert "risk_coverage" not in tech


def test_report_uses_observed_candidate_and_confidence_evidence(tmp_path) -> None:
    manifest = tmp_path / "manifest.jsonl"
    results = tmp_path / "results.jsonl"
    _write_jsonl(
        manifest,
        [
            {"id": "a", "reference": "kubectl", "canonical_term": "kubectl", "term_id": "a", "expect_term": True},
            {"id": "b", "reference": "MLX", "canonical_term": "MLX", "term_id": "b", "expect_term": True},
        ],
    )
    _write_jsonl(
        results,
        [
            {"type": "bench_meta"},
            {
                "type": "row",
                "id": "a",
                "raw_transcript": "cube cuddle",
                "final_text": "kubectl",
                "candidate_term_ids": ["a", "x"],
                "nbest_hypotheses": ["cube cuddle", "kubectl"],
                "selected_term_id": "a",
                "repair_accepted": True,
                "repair_confidence": 0.9,
                "untouched_span_preserved": True,
            },
            {
                "type": "row",
                "id": "b",
                "raw_transcript": "em ell ex",
                "final_text": "em ell ex",
                "candidate_term_ids": ["x"],
                "nbest_hypotheses": ["MLX"],
                "selected_term_id": None,
                "repair_accepted": False,
                "repair_confidence": 0.4,
                "untouched_span_preserved": False,
            },
        ],
    )
    report, _ = build_report(results, manifest, "techterms", "e2e", tmp_path / "reports")
    tech = report["metrics"]["tech_terms"]
    assert tech["candidate_recall"]["at_1"]["recall"] == pytest.approx(0.5)
    assert tech["candidate_recall"]["at_5"]["recall"] == pytest.approx(0.5)
    assert tech["nbest_oracle_coverage"]["coverage"] == 1.0
    assert tech["selector_accuracy"]["accuracy"] == 1.0
    assert tech["accepted_repair"]["precision"] == 1.0
    assert tech["untouched_span_preservation"]["rate"] == pytest.approx(0.5)
    assert tech["reliability"]["count"] == 2
    assert tech["risk_coverage"][-1]["coverage"] == 1.0


def test_report_populates_nbest_and_confidence_from_asr_evidence(tmp_path) -> None:
    manifest = tmp_path / "manifest.jsonl"
    _write_jsonl(
        manifest,
        [
            {"id": "a", "reference": "cube cuddle", "canonical_term": "kubectl", "term_id": "a", "expect_term": True},
            {"id": "b", "reference": "mlx", "canonical_term": "MLX", "term_id": "b", "expect_term": True},
        ],
    )

    results = tmp_path / "results.jsonl"
    _write_jsonl(
        results,
        [
            {"type": "bench_meta"},
            {
                "type": "row",
                "id": "a",
                "raw_transcript": "cube cuddle",
                "final_text": "kubectl",
                "hypotheses": [
                    {"rank": 0, "text": "cube cuddle", "score": -0.1},
                    {"rank": 1, "text": "use kubectl", "score": -0.9},
                ],
                "confidence": 0.9,
                "confidence_mode": "greedy_entropy",
            },
            {
                "type": "row",
                "id": "b",
                "raw_transcript": "MLX",
                "final_text": "MLX",
                "hypotheses": [{"rank": 0, "text": "MLX", "score": -0.2}],
                "confidence": 0.6,
                "confidence_mode": "greedy_entropy",
            },
        ],
    )
    report, _ = build_report(results, manifest, "techterms", "e2e", tmp_path / "reports")
    tech = report["metrics"]["tech_terms"]
    assert tech["nbest_oracle_coverage"]["coverage"] == 1.0
    by_mode = report["metrics"]["confidence_by_mode"]
    assert set(by_mode) == {"greedy_entropy"}
    assert by_mode["greedy_entropy"]["count"] == 2
    assert by_mode["greedy_entropy"]["mean_confidence"] == pytest.approx(0.75)
    assert by_mode["greedy_entropy"]["reliability"]["count"] == 2
    assert by_mode["greedy_entropy"]["risk_coverage"][-1]["coverage"] == 1.0

    plain = tmp_path / "plain.jsonl"
    _write_jsonl(
        plain,
        [
            {"type": "bench_meta"},
            {"type": "row", "id": "a", "raw_transcript": "cube cuddle", "final_text": "kubectl"},
            {"type": "row", "id": "b", "raw_transcript": "MLX", "final_text": "MLX"},
        ],
    )
    plain_report, _ = build_report(plain, manifest, "techterms", "e2e", tmp_path / "reports")
    assert "nbest_oracle_coverage" not in plain_report["metrics"]["tech_terms"]
    assert "confidence_by_mode" not in plain_report["metrics"]


def test_compare_gate_uses_formal_uwer_delta_and_returns_nonzero(tmp_path, capsys) -> None:
    baseline = tmp_path / "baseline.json"
    candidate = tmp_path / "candidate.json"
    baseline.write_text(json.dumps({"metrics": {"uwer_final": 0.1}}), encoding="utf-8")
    candidate.write_text(json.dumps({"metrics": {"uwer_final": 0.104}}), encoding="utf-8")
    assert UWER_MAX_DELTA == 0.0035
    assert compare_main([str(baseline), str(candidate), "--gate", f"uwer_final:{UWER_MAX_DELTA}"]) == 1
    assert "GATE FAILED" in capsys.readouterr().err

    candidate.write_text(json.dumps({"metrics": {"uwer_final": 0.1035}}), encoding="utf-8")
    assert compare_main([str(baseline), str(candidate), "--gate", f"uwer_final:{UWER_MAX_DELTA}"]) == 0


def test_compare_gate_fails_closed_when_metric_is_missing(tmp_path, capsys) -> None:
    baseline = tmp_path / "baseline.json"
    candidate = tmp_path / "candidate.json"
    baseline.write_text(json.dumps({"metrics": {}}), encoding="utf-8")
    candidate.write_text(json.dumps({"metrics": {"uwer_final": 0.1}}), encoding="utf-8")
    assert compare_main([str(baseline), str(candidate), "--gate", "uwer_final:0.0035"]) == 1
    assert "unavailable" in capsys.readouterr().err
