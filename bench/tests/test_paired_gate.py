from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from voiceour_bench.paired_gate import (
    GateConfig,
    GateInputError,
    _audio_manifest_sha256,
    combine_interval_bounds,
    evaluate_files,
)


def _write_jsonl(path: Path, rows: list[dict]) -> Path:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    return path


def _write_report(
    path: Path,
    rows: list[dict],
    *,
    manifest_sha256: str | None = None,
    audio_manifest_sha256: str | None = None,
) -> Path:
    meta = {
        "type": "bench_meta",
        "mode": "pipeline",
        "backend": path.stem,
        "model_id": path.stem,
        "model_revision": "revision",
        "model_file": f"{path.stem}.gguf",
    }
    if manifest_sha256 is not None:
        meta["manifest_sha256"] = manifest_sha256
    if audio_manifest_sha256 is not None:
        meta["audio_manifest_sha256"] = audio_manifest_sha256
    return _write_jsonl(path, [meta, *({"type": "row", **row} for row in rows)])


def _paths(tmp_path: Path, cases: list[tuple[str, str, str, str]]) -> tuple[Path, Path, Path]:
    manifest_rows = []
    incumbent_rows = []
    candidate_rows = []
    for index, (reference, incumbent, candidate, cluster) in enumerate(cases):
        row_id = f"row-{index}"
        manifest_rows.append(
            {
                "id": row_id,
                "reference": reference,
                "formatted_reference": reference,
                "speaker": cluster,
                "split": "clean" if index % 2 == 0 else "other",
                "audio_bytes": index + 1,
                "audio_sha256": hashlib.sha256(f"audio-{row_id}".encode()).hexdigest(),
            }
        )
        incumbent_rows.append({"id": row_id, "final_text": incumbent, "error": None})
        candidate_rows.append({"id": row_id, "final_text": candidate, "error": None})
    manifest = _write_jsonl(tmp_path / "manifest.jsonl", manifest_rows)
    manifest_sha256 = hashlib.sha256(manifest.read_bytes()).hexdigest()
    audio_manifest_sha256 = _audio_manifest_sha256(manifest_rows, str(manifest))
    return (
        manifest,
        _write_report(
            tmp_path / "incumbent.jsonl",
            incumbent_rows,
            manifest_sha256=manifest_sha256,
            audio_manifest_sha256=audio_manifest_sha256,
        ),
        _write_report(
            tmp_path / "candidate.jsonl",
            candidate_rows,
            manifest_sha256=manifest_sha256,
            audio_manifest_sha256=audio_manifest_sha256,
        ),
    )


def _config(**overrides) -> GateConfig:
    values = {
        "cluster_fields": ("speaker",),
        "stratum_fields": (),
        "claim_scope": "frozen_row_conditional",
        "seed": 717,
        "bootstrap_samples": 192,
        "permutation_samples": 192,
    }
    values.update(overrides)
    return GateConfig(**values)


def _codes(result: dict) -> set[str]:
    return {reason["code"] for reason in result["decision"]["reasons"]}


def test_tied_systems_produce_legitimate_zero_width_intervals(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("Hello, Morgan!", "Hello, Morgan!", "Hello, Morgan!", "a"),
            ("Call Sam.", "Call Sam.", "Call Sam.", "a"),
            ("Are you ready?", "Are you ready?", "Are you ready?", "b"),
            ("Yes, I am.", "Yes, I am.", "Yes, I am.", "b"),
        ],
    )

    result = evaluate_files(*paths, config=_config())

    interval = result["accuracy"]["upper_interval"]
    assert result["accuracy"]["delta_candidate_minus_incumbent"] == 0.0
    assert interval["bca"]["bound"] == 0.0
    assert interval["studentized"]["bound"] == 0.0
    assert interval["decision_bound"] == 0.0
    assert interval["interval_unstable"] is False
    assert interval["studentized"]["degenerate_zero_width"] is True


def test_bca_uses_delete_one_cluster_acceleration_on_skewed_data(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("one two three four five", "one two three four five", "one two three four", "large"),
            ("six seven eight nine ten", "six seven eight nine ten", "six seven eight nine", "large"),
            ("alpha beta", "alpha", "alpha beta", "small-a"),
            ("gamma delta", "gamma", "gamma delta", "small-b"),
            ("epsilon zeta", "epsilon", "epsilon zeta", "small-c"),
        ],
    )

    result = evaluate_files(*paths, config=_config(stratum_fields=()))

    assert result["accuracy"]["upper_interval"]["bca"]["acceleration"] != 0.0
    assert result["diagnostics"]["largest_cluster_influence"]["cluster"] == '["large"]'


def test_whole_cluster_resampling_retains_cluster_dependence(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("one two", "one", "one two", "speaker-a"),
            ("three four", "three", "three four", "speaker-a"),
            ("five six", "five", "five six", "speaker-a"),
            ("seven eight", "seven eight", "seven", "speaker-b"),
            ("nine ten", "nine ten", "nine", "speaker-b"),
            ("eleven twelve", "eleven twelve", "eleven", "speaker-b"),
        ],
    )

    clustered = evaluate_files(*paths, config=_config(stratum_fields=()))
    row_conditional = evaluate_files(
        *paths,
        config=_config(
            cluster_fields=(),
            stratum_fields=(),
            claim_scope="frozen_row_conditional",
        ),
    )

    clustered_width = clustered["accuracy"]["upper_interval"]["bca"]["bound"] - clustered["accuracy"][
        "delta_candidate_minus_incumbent"
    ]
    conditional_width = row_conditional["accuracy"]["upper_interval"]["bca"]["bound"] - row_conditional[
        "accuracy"
    ]["delta_candidate_minus_incumbent"]
    assert clustered_width >= conditional_width
    assert row_conditional["analysis"]["population_claim_permitted"] is False
    assert "CLUSTER_METADATA_MISSING" in row_conditional["warnings"]

def test_bootstrap_resamples_clusters_within_each_stratum(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("one two", "one", "one two", "clean-a"),
            ("three four", "three four", "three", "other-a"),
            ("five six", "five", "five six", "clean-b"),
            ("seven eight", "seven eight", "seven", "other-b"),
        ],
    )

    result = evaluate_files(*paths, config=_config(stratum_fields=("split",)))

    interval = result["accuracy"]["upper_interval"]
    assert interval["bca"]["bound"] == 0.0
    assert interval["bootstrap"]["standard_deviation"] == 0.0
    assert result["counts"]["strata"] == [
        {"stratum": '["clean"]', "clusters": 2},
        {"stratum": '["other"]', "clusters": 2},
    ]



def test_population_claims_are_refused() -> None:
    with pytest.raises(GateInputError, match="POPULATION_CLAIM_UNSUPPORTED"):
        _config(claim_scope="population")


def test_resampling_refuses_singleton_strata(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("one two", "one", "one two", "clean"),
            ("three four", "three", "three four", "other"),
        ],
    )

    with pytest.raises(GateInputError, match="CLUSTER_STRATUM_UNDERREPLICATED"):
        evaluate_files(*paths, config=_config(stratum_fields=("split",)))

def test_manifest_provenance_pin_must_match_supplied_manifest(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three four", "three four", "b")],
    )
    candidate_rows = [json.loads(line) for line in candidate.read_text(encoding="utf-8").splitlines()]
    candidate_rows[0]["manifest_sha256"] = "0" * 64
    _write_jsonl(candidate, candidate_rows)

    result = evaluate_files(manifest, incumbent, candidate, config=_config())

    assert result["decision"]["status"] == "reject"
    assert "PROVENANCE_FAIL" in _codes(result)
    assert result["provenance"]["manifest"]["sha256"] == hashlib.sha256(manifest.read_bytes()).hexdigest()


def test_manifest_provenance_pin_is_required_on_both_reports(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three four", "three four", "b")],
    )
    candidate_rows = [json.loads(line) for line in candidate.read_text(encoding="utf-8").splitlines()]
    del candidate_rows[0]["manifest_sha256"]
    _write_jsonl(candidate, candidate_rows)

    result = evaluate_files(manifest, incumbent, candidate, config=_config())

    assert result["decision"]["status"] == "reject"
    assert "PROVENANCE_FAIL" in _codes(result)
    assert result["validation"]["manifest_pins_present"] is False


def test_audio_manifest_pin_must_match_declared_audio(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three four", "three four", "b")],
    )
    candidate_rows = [json.loads(line) for line in candidate.read_text(encoding="utf-8").splitlines()]
    candidate_rows[0]["audio_manifest_sha256"] = "0" * 64
    _write_jsonl(candidate, candidate_rows)

    result = evaluate_files(manifest, incumbent, candidate, config=_config())

    assert result["decision"]["status"] == "reject"
    assert "PROVENANCE_FAIL" in _codes(result)
    assert result["validation"]["audio_manifest_pins_match"] is False


def test_audio_manifest_pin_is_required_on_both_reports(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three four", "three four", "b")],
    )
    candidate_rows = [json.loads(line) for line in candidate.read_text(encoding="utf-8").splitlines()]
    del candidate_rows[0]["audio_manifest_sha256"]
    _write_jsonl(candidate, candidate_rows)

    result = evaluate_files(manifest, incumbent, candidate, config=_config())

    assert result["decision"]["status"] == "reject"
    assert "PROVENANCE_FAIL" in _codes(result)
    assert result["validation"]["audio_manifest_pins_present"] is False


def test_manifest_rows_require_audio_size_and_digest(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three four", "three four", "b")],
    )
    manifest_rows = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines()]
    del manifest_rows[0]["audio_sha256"]
    _write_jsonl(manifest, manifest_rows)

    with pytest.raises(GateInputError, match="AUDIO_PROVENANCE_MISSING"):
        evaluate_files(manifest, incumbent, candidate, config=_config())


def test_audio_size_must_fit_native_int(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three four", "three four", "b")],
    )
    manifest_rows = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines()]
    manifest_rows[0]["audio_bytes"] = 1 << 63
    _write_jsonl(manifest, manifest_rows)

    with pytest.raises(GateInputError, match="AUDIO_PROVENANCE_MISSING"):
        evaluate_files(manifest, incumbent, candidate, config=_config())


def test_mismatched_row_sets_are_a_hard_reject(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three", "three four", "b")],
    )
    lines = candidate.read_text(encoding="utf-8").splitlines()
    candidate.write_text("\n".join(lines[:-1]) + "\n", encoding="utf-8")

    result = evaluate_files(manifest, incumbent, candidate, config=_config(stratum_fields=()))

    assert result["decision"]["status"] == "reject"
    assert "ROWSET_FAIL" in _codes(result)
    assert "accuracy" not in result


def test_error_sets_must_match_and_be_empty(tmp_path: Path) -> None:
    manifest, incumbent, candidate = _paths(
        tmp_path,
        [("one two", "one two", "one two", "a"), ("three four", "three", "three four", "b")],
    )
    candidate_lines = [json.loads(line) for line in candidate.read_text(encoding="utf-8").splitlines()]
    candidate_lines[-1]["error"] = "timeout"
    _write_jsonl(candidate, candidate_lines)

    result = evaluate_files(manifest, incumbent, candidate, config=_config(stratum_fields=()))

    assert result["decision"]["status"] == "reject"
    assert {"ERRORSET_FAIL", "RUNTIME_FAIL"} <= _codes(result)


def test_formatting_f1_is_recomputed_for_each_paired_resample(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("Hello, Morgan!", "Hello, Morgan!", "hello Morgan", "a"),
            ("Are you ready?", "Are you ready?", "are you ready.", "b"),
            ("Call Sam.", "Call Sam.", "Call sam", "c"),
        ],
    )

    result = evaluate_files(*paths, config=_config(stratum_fields=()))

    case = result["formatting"]["case_f1"]
    punct = result["formatting"]["punctuation_micro_f1"]
    assert case["candidate"] < case["incumbent"]
    assert punct["candidate"] < punct["incumbent"]
    assert case["lower_interval"]["bootstrap"]["recomputed_from_aggregate_counts"] is True
    assert punct["lower_interval"]["bootstrap"]["recomputed_from_aggregate_counts"] is True
    assert "FORMAT_POINT_INFERIOR" in _codes(result)


def test_candidate_induced_contiguous_multiword_deletion_is_a_hard_reject(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("one two three four", "one two three four", "one four", "a"),
            ("alpha beta", "alpha beta", "alpha beta", "b"),
        ],
    )

    result = evaluate_files(*paths, config=_config(stratum_fields=()))

    assert result["decision"]["status"] == "reject"
    assert "DELETION_HAZARD" in _codes(result)
    assert result["diagnostics"]["deletion_hazards"] == [
        {"id": "row-0", "reference_end": 3, "reference_start": 1, "words": ["two", "three"]}
    ]


def test_number_canonicalization_is_not_a_deletion_hazard(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("one two three four", "one two three four", "1234", "a"),
            ("alpha beta", "alpha beta", "alpha beta", "b"),
        ],
    )

    result = evaluate_files(*paths, config=_config(stratum_fields=()))

    assert "DELETION_HAZARD" not in _codes(result)
    assert result["diagnostics"]["deletion_hazards"] == []


def test_lossy_text_normalization_cannot_hide_a_deletion_hazard(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            (
                "please do not (under any circumstances) delete this",
                "please do not under any circumstances delete this",
                "please do not delete this",
                "a",
            ),
            ("alpha beta", "alpha beta", "alpha beta", "b"),
        ],
    )

    result = evaluate_files(*paths, config=_config(stratum_fields=()))

    assert "DELETION_HAZARD" in _codes(result)
    assert result["diagnostics"]["deletion_hazards"][0]["words"] == [
        "under",
        "any",
        "circumstances",
    ]


def test_less_favorable_bound_and_method_disagreement_are_not_cherry_picked() -> None:
    upper = combine_interval_bounds(0.0010, 0.0016, side="upper", disagreement_tolerance=0.0005)
    lower = combine_interval_bounds(-0.0100, -0.0106, side="lower", disagreement_tolerance=0.0005)

    assert upper["decision_bound"] == 0.0016
    assert lower["decision_bound"] == -0.0106
    assert upper["interval_unstable"] is True
    assert lower["interval_unstable"] is True
    at_tolerance = combine_interval_bounds(0.0010, 0.0015, side="upper", disagreement_tolerance=0.0005)
    assert at_tolerance["interval_unstable"] is False


def test_gate_emits_pass_for_uniform_cluster_level_benefit(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [(f"word{index} tail", f"word{index}", f"word{index} tail", f"speaker-{index}") for index in range(6)],
    )

    result = evaluate_files(*paths, config=_config(bootstrap_samples=10_000))

    assert result["decision"]["status"] == "pass"
    assert result["decision"]["reasons"] == []
    assert set(result["decision"]["gates"].values()) == {"pass"}




def test_gate_emits_inconclusive_when_point_benefit_lacks_cluster_evidence(tmp_path: Path) -> None:
    cases = [
        (f"word{index} tail", f"word{index}", f"word{index} tail", f"speaker-{index}")
        for index in range(3)
    ]
    cases.extend(
        (f"same{index} tail", f"same{index} tail", f"same{index} tail", f"speaker-{index + 3}")
        for index in range(3)
    )
    paths = _paths(tmp_path, cases)

    result = evaluate_files(*paths, config=_config())

    assert result["decision"]["status"] == "inconclusive"
    assert _codes(result) & {"BENEFIT_INCONCLUSIVE", "INTERVAL_UNSTABLE"}


def test_fixed_seed_reproduces_every_machine_readable_statistic(tmp_path: Path) -> None:
    paths = _paths(
        tmp_path,
        [
            ("one two three", "one two", "one two three", "a"),
            ("four five six", "four five six", "four five", "b"),
            ("seven eight nine", "seven eight", "seven eight nine", "c"),
            ("ten eleven twelve", "ten eleven twelve", "ten eleven", "d"),
        ],
    )

    first = evaluate_files(*paths, config=_config(stratum_fields=()))
    second = evaluate_files(*paths, config=_config(stratum_fields=()))

    assert first == second
