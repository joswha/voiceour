"""Deterministic paired, cluster-aware ASR promotion inference.

The gate consumes row-level outputs; aggregate benchmark reports do not contain
sufficient evidence for paired resampling. Candidate minus incumbent is the
sign convention throughout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from statistics import NormalDist
from typing import Any, Literal

import jiwer
import numpy as np

from .metrics import case_f1, punct_f1
from .normalizer import english_normalize, english_number_normalize

DEFAULT_SEED = 20260830
DEFAULT_BOOTSTRAP_SAMPLES = 100_000
DEFAULT_ALPHA = 0.05
DEFAULT_NI_MARGIN = 0.0035
DEFAULT_BENEFIT_MARGIN = 0.005
DEFAULT_FORMAT_MARGIN = 0.02
INTERVAL_DISAGREEMENT_TOLERANCE = 0.0005
MONTE_CARLO_BOUNDARY_TOLERANCE = 0.0005
MONTE_CARLO_EXTENSION_SAMPLES = 1_000_000
MINIMUM_BOOTSTRAP_SAMPLES = 10_000
MINIMUM_MONTE_CARLO_PERMUTATIONS = 100_000
_EXACT_PERMUTATION_MAX_CLUSTERS = 20
_NORMAL = NormalDist()
_DELETION_WORD_RE = re.compile(r"[^\W_]+(?:['’][^\W_]+)?", re.UNICODE)


class GateInputError(ValueError):
    """An input cannot support the requested analysis."""

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


@dataclass(frozen=True)
class GateConfig:
    cluster_fields: tuple[str, ...]
    stratum_fields: tuple[str, ...] = ()
    claim_scope: Literal["frozen_row_conditional"] = "frozen_row_conditional"
    seed: int = DEFAULT_SEED
    bootstrap_samples: int = DEFAULT_BOOTSTRAP_SAMPLES
    permutation_samples: int | None = None
    alpha: float = DEFAULT_ALPHA
    ni_margin: float = DEFAULT_NI_MARGIN
    benefit_margin: float = DEFAULT_BENEFIT_MARGIN
    format_margin: float = DEFAULT_FORMAT_MARGIN
    incumbent_text_field: str = "final_text"
    candidate_text_field: str = "final_text"
    interval_disagreement_tolerance: float = INTERVAL_DISAGREEMENT_TOLERANCE
    monte_carlo_boundary_tolerance: float = MONTE_CARLO_BOUNDARY_TOLERANCE
    monte_carlo_extension_samples: int = MONTE_CARLO_EXTENSION_SAMPLES

    def __post_init__(self) -> None:
        if self.claim_scope != "frozen_row_conditional":
            raise GateInputError(
                "POPULATION_CLAIM_UNSUPPORTED",
                "this gate supports fixed-corpus decisions only; population inference "
                "requires a separately calibrated design",
            )
        if self.seed < 0:
            raise GateInputError("CONFIG_FAIL", "seed must be non-negative")
        if self.bootstrap_samples < 2:
            raise GateInputError("CONFIG_FAIL", "B must be at least 2")
        if self.permutation_samples is not None and self.permutation_samples < 1:
            raise GateInputError("CONFIG_FAIL", "permutation samples must be positive")
        if not 0.0 < self.alpha < 0.5:
            raise GateInputError("CONFIG_FAIL", "alpha must be between 0 and 0.5")
        for name, value in (
            ("NI margin", self.ni_margin),
            ("benefit margin", self.benefit_margin),
            ("format margin", self.format_margin),
            ("interval disagreement tolerance", self.interval_disagreement_tolerance),
            ("Monte Carlo boundary tolerance", self.monte_carlo_boundary_tolerance),
        ):
            if not math.isfinite(value) or value < 0.0:
                raise GateInputError("CONFIG_FAIL", f"{name} must be finite and non-negative")
        if self.monte_carlo_extension_samples < 2:
            raise GateInputError("CONFIG_FAIL", "Monte Carlo extension sample target must be at least 2")
        if not self.incumbent_text_field or not self.candidate_text_field:
            raise GateInputError("CONFIG_FAIL", "text fields must be non-empty")


@dataclass(frozen=True)
class _Report:
    path: Path
    sha256: str
    meta: dict[str, Any]
    rows: list[dict[str, Any]]
    successful_evidence: set[str] | None
    error_evidence: set[str] | None
    manifest_pin: str | None
    audio_manifest_pin: str | None


@dataclass(frozen=True)
class _MetricData:
    name: str
    features: np.ndarray
    kind: Literal["wer", "f1"]


@dataclass(frozen=True)
class _IntervalInputs:
    point: float
    bootstrap_estimates: np.ndarray
    bootstrap_ses: np.ndarray
    jackknife_values: np.ndarray
    strata: list[np.ndarray]


@dataclass(frozen=True)
class _ClusterLayout:
    labels: list[str]
    strata: list[np.ndarray]
    stratum_labels: list[str]
    row_cluster_indices: list[int]


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _audio_manifest_sha256(rows: list[dict[str, Any]], source: str) -> str:
    digest = hashlib.sha256()
    digest.update(b"voiceour-audio-manifest-v1\x00")
    for index, row in enumerate(rows):
        row_id = row.get("id")
        audio_bytes = row.get("audio_bytes")
        audio_sha256 = row.get("audio_sha256")
        if (
            not isinstance(row_id, str)
            or not row_id
            or not isinstance(audio_bytes, int)
            or isinstance(audio_bytes, bool)
            or audio_bytes < 0
            or audio_bytes > (1 << 63) - 1
            or not isinstance(audio_sha256, str)
            or re.fullmatch(r"[0-9a-fA-F]{64}", audio_sha256) is None
        ):
            raise GateInputError(
                "AUDIO_PROVENANCE_MISSING",
                f"{source} row {index} has invalid id, audio_bytes, or audio_sha256",
            )
        id_bytes = row_id.encode("utf-8")
        digest.update(len(id_bytes).to_bytes(8, "big"))
        digest.update(id_bytes)
        digest.update(audio_bytes.to_bytes(8, "big"))
        digest.update(bytes.fromhex(audio_sha256))
    digest.update(len(rows).to_bytes(8, "big"))
    return digest.hexdigest()


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise GateInputError("INPUT_FORMAT_FAIL", f"{path}:{line_number}: {error.msg}") from error
        if not isinstance(value, dict):
            raise GateInputError("INPUT_FORMAT_FAIL", f"{path}:{line_number}: expected a JSON object")
        values.append(value)
    return values


def _validated_ids(rows: list[dict[str, Any]], source: str) -> list[str]:
    ids: list[str] = []
    seen: set[str] = set()
    duplicates: set[str] = set()
    for index, row in enumerate(rows):
        row_id = row.get("id")
        if not isinstance(row_id, str) or not row_id:
            raise GateInputError("ROWSET_FAIL", f"{source} row {index} has invalid id {row_id!r}")
        ids.append(row_id)
        if row_id in seen:
            duplicates.add(row_id)
        seen.add(row_id)
    if duplicates:
        raise GateInputError("ROWSET_FAIL", f"{source} contains duplicate ids: {', '.join(sorted(duplicates)[:10])}")
    return ids


def _evidence_set(value: Any, source: str) -> set[str] | None:
    if value is None:
        return None
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise GateInputError("ROWSET_FAIL", f"{source} row-id evidence must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise GateInputError("ROWSET_FAIL", f"{source} row-id evidence contains duplicates")
    return set(value)


def _find_manifest_pin(document: dict[str, Any], meta: dict[str, Any]) -> str | None:
    containers = [document, meta]
    inputs = document.get("inputs")
    if isinstance(inputs, dict):
        containers.append(inputs)
    found: set[str] = set()
    for container in containers:
        for key in ("manifest_sha256", "manifest_digest", "manifest_hash"):
            value = container.get(key)
            if isinstance(value, str) and value:
                found.add(value.lower())
    if len(found) > 1:
        raise GateInputError("PROVENANCE_FAIL", "report contains conflicting manifest digest pins")
    return next(iter(found)) if found else None


def _find_audio_manifest_pin(document: dict[str, Any], meta: dict[str, Any]) -> str | None:
    containers = [document, meta]
    inputs = document.get("inputs")
    if isinstance(inputs, dict):
        containers.append(inputs)
    found = {
        value.lower()
        for container in containers
        if isinstance((value := container.get("audio_manifest_sha256")), str) and value
    }
    if len(found) > 1:
        raise GateInputError("PROVENANCE_FAIL", "report contains conflicting audio-manifest digest pins")
    return next(iter(found)) if found else None


def _load_report(path: Path) -> _Report:
    raw = path.read_text(encoding="utf-8")
    document: dict[str, Any] = {}
    entries: list[dict[str, Any]]
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        entries = _read_jsonl(path)
    else:
        if isinstance(parsed, dict):
            document = parsed
            raw_rows = parsed.get("rows")
            if not isinstance(raw_rows, list):
                raise GateInputError(
                    "REPORT_ROWS_MISSING",
                    f"{path} has no row-level rows; aggregate reports cannot support paired inference",
                )
            if not all(isinstance(row, dict) for row in raw_rows):
                raise GateInputError("INPUT_FORMAT_FAIL", f"{path} rows must be JSON objects")
            entries = list(raw_rows)
        elif isinstance(parsed, list) and all(isinstance(row, dict) for row in parsed):
            entries = list(parsed)
        else:
            raise GateInputError("INPUT_FORMAT_FAIL", f"{path} must be JSONL or a JSON object containing rows")

    meta_entries = [entry for entry in entries if entry.get("type") == "bench_meta"]
    if len(meta_entries) > 1:
        raise GateInputError("PROVENANCE_FAIL", f"{path} contains multiple bench_meta records")
    document_meta = document.get("meta")
    if document_meta is not None and not isinstance(document_meta, dict):
        raise GateInputError("PROVENANCE_FAIL", f"{path} meta must be an object")
    meta = dict(document_meta or {})
    if meta_entries:
        if meta and meta != meta_entries[0]:
            raise GateInputError("PROVENANCE_FAIL", f"{path} has conflicting metadata records")
        meta = dict(meta_entries[0])

    rows = [entry for entry in entries if entry.get("type") != "bench_meta"]
    if not rows:
        raise GateInputError("REPORT_ROWS_MISSING", f"{path} contains no row-level records")
    _validated_ids(rows, str(path))
    successful_evidence = _evidence_set(document.get("successful_row_ids"), f"{path} successful")
    error_evidence = _evidence_set(document.get("error_row_ids"), f"{path} error")
    if (successful_evidence is None) != (error_evidence is None):
        raise GateInputError("ROWSET_FAIL", f"{path} must provide both successful and error row-id evidence")
    return _Report(
        path=path,
        sha256=_sha256(path),
        meta=meta,
        rows=rows,
        successful_evidence=successful_evidence,
        error_evidence=error_evidence,
        manifest_pin=_find_manifest_pin(document, meta),
        audio_manifest_pin=_find_audio_manifest_pin(document, meta),
    )


def _is_error_row(row: dict[str, Any]) -> bool:
    return row.get("error") not in (None, "") or any(
        row.get(field) is True for field in ("timeout", "timed_out", "duration_rejected")
    )


def _format_ids(ids: set[str], limit: int = 10) -> list[str]:
    ordered = sorted(ids)
    return ordered[:limit]


def _reason(code: str, message: str, **details: Any) -> dict[str, Any]:
    value: dict[str, Any] = {"code": code, "message": message}
    if details:
        value["details"] = details
    return value


def _field_value(row: dict[str, Any], field: str) -> Any:
    value: Any = row
    for component in field.split("."):
        if not isinstance(value, dict) or component not in value:
            raise GateInputError("CLUSTER_METADATA_MISSING", f"manifest row {row.get('id')!r} has no {field!r}")
        value = value[component]
    if value is None or value == "":
        raise GateInputError("CLUSTER_METADATA_MISSING", f"manifest row {row.get('id')!r} has empty {field!r}")
    if isinstance(value, dict | list):
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return value


def _key(row: dict[str, Any], fields: tuple[str, ...]) -> tuple[Any, ...]:
    return tuple(_field_value(row, field) for field in fields)


def _key_label(key: tuple[Any, ...]) -> str:
    return json.dumps(list(key), ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _cluster_layout(manifest_rows: list[dict[str, Any]], config: GateConfig) -> _ClusterLayout:
    cluster_fields = config.cluster_fields
    clusters: dict[tuple[Any, ...], int] = {}
    cluster_strata: dict[int, tuple[Any, ...]] = {}
    row_cluster_indices: list[int] = []
    labels: list[str] = []
    for row in manifest_rows:
        stratum = _key(row, config.stratum_fields) if config.stratum_fields else ("all",)
        cluster = _key(row, cluster_fields) if cluster_fields else (row["id"],)
        index = clusters.get(cluster)
        if index is None:
            index = len(clusters)
            clusters[cluster] = index
            cluster_strata[index] = stratum
            labels.append(_key_label(cluster))
        elif cluster_strata[index] != stratum:
            raise GateInputError(
                "CLUSTER_STRATUM_CONFLICT",
                f"cluster {_key_label(cluster)} crosses strata; whole-cluster resampling cannot split it",
            )
        row_cluster_indices.append(index)

    strata_clusters: dict[tuple[Any, ...], list[int]] = {}
    for index in range(len(labels)):
        strata_clusters.setdefault(cluster_strata[index], []).append(index)
    sorted_strata = sorted(strata_clusters.items(), key=lambda item: repr(item[0]))
    strata = [np.asarray(indices, dtype=np.int64) for _, indices in sorted_strata]
    stratum_labels = [_key_label(stratum) for stratum, _ in sorted_strata]
    if not labels:
        raise GateInputError("ROWSET_FAIL", "manifest contains no rows")
    return _ClusterLayout(
        labels=labels,
        strata=strata,
        stratum_labels=stratum_labels,
        row_cluster_indices=row_cluster_indices,
    )


def _edit_counts(reference: str, hypothesis: str) -> tuple[int, int, bool]:
    normalized_reference = english_normalize(reference)
    normalized_hypothesis = english_normalize(hypothesis)
    if not normalized_reference:
        edits = len(normalized_hypothesis.split())
        return 0, edits, edits == 0
    output = jiwer.process_words(normalized_reference, normalized_hypothesis)
    reference_words = output.hits + output.substitutions + output.deletions
    edits = output.substitutions + output.deletions + output.insertions
    return reference_words, edits, edits == 0


def _f1_counts(metric: dict[str, Any], bucket: str) -> tuple[int, int, int]:
    counts = metric[bucket]
    return int(counts["tp"]), int(counts["fp"]), int(counts["fn"])


def _deletion_tokens(text: str) -> list[str]:
    return [
        match.group().casefold().replace("’", "'")
        for match in _DELETION_WORD_RE.finditer(text)
    ]


def _number_canonicalization_deletion_spans(
    reference_tokens: list[str],
    hypothesis_tokens: list[str],
    alignments: list[Any],
) -> set[tuple[int, int]]:
    exempt: set[tuple[int, int]] = set()
    index = 0
    while index < len(alignments):
        if alignments[index].type == "equal":
            index += 1
            continue
        end = index + 1
        while end < len(alignments) and alignments[end].type != "equal":
            end += 1
        run = alignments[index:end]
        reference_start = run[0].ref_start_idx
        reference_end = run[-1].ref_end_idx
        hypothesis_start = run[0].hyp_start_idx
        hypothesis_end = run[-1].hyp_end_idx
        reference_surface = " ".join(reference_tokens[reference_start:reference_end])
        hypothesis_surface = " ".join(hypothesis_tokens[hypothesis_start:hypothesis_end])
        if (
            any(character.isdigit() for character in hypothesis_surface)
            and english_number_normalize(reference_surface)
            == english_number_normalize(hypothesis_surface)
        ):
            exempt.update(
                (chunk.ref_start_idx, chunk.ref_end_idx)
                for chunk in run
                if chunk.type == "delete"
            )
        index = end
    return exempt


def _multiword_deletions(reference: str, hypothesis: str) -> tuple[list[str], list[tuple[int, int]]]:
    reference_tokens = _deletion_tokens(reference)
    hypothesis_tokens = _deletion_tokens(hypothesis)
    if not reference_tokens:
        return reference_tokens, []
    if not hypothesis_tokens:
        return reference_tokens, [(0, len(reference_tokens))] if len(reference_tokens) >= 2 else []
    output = jiwer.process_words(" ".join(reference_tokens), " ".join(hypothesis_tokens))
    alignments = output.alignments[0]
    number_equivalent = _number_canonicalization_deletion_spans(
        reference_tokens,
        hypothesis_tokens,
        alignments,
    )
    spans = [
        (chunk.ref_start_idx, chunk.ref_end_idx)
        for chunk in alignments
        if chunk.type == "delete"
        and chunk.ref_end_idx - chunk.ref_start_idx >= 2
        and (chunk.ref_start_idx, chunk.ref_end_idx) not in number_equivalent
    ]
    return reference_tokens, spans


def _candidate_deletion_hazards(
    row_id: str,
    reference: str,
    incumbent_hypothesis: str,
    candidate_hypothesis: str,
) -> list[dict[str, Any]]:
    reference_tokens, candidate_spans = _multiword_deletions(reference, candidate_hypothesis)
    incumbent_tokens, incumbent_spans = _multiword_deletions(reference, incumbent_hypothesis)
    if reference_tokens != incumbent_tokens:
        raise AssertionError("normalization changed between paired deletion analyses")
    hazards: list[dict[str, Any]] = []
    for start, end in candidate_spans:
        incumbent_already_deletes_span = any(
            incumbent_start <= start and incumbent_end >= end
            for incumbent_start, incumbent_end in incumbent_spans
        )
        if incumbent_already_deletes_span:
            continue
        hazards.append(
            {
                "id": row_id,
                "reference_start": start,
                "reference_end": end,
                "words": reference_tokens[start:end],
            }
        )
    return hazards


def _metric_value(totals: np.ndarray, kind: Literal["wer", "f1"]) -> np.ndarray:
    if kind == "wer":
        denominator = totals[..., 0]
        numerator = totals[..., 2] - totals[..., 1]
        return np.divide(
            numerator,
            denominator,
            out=np.full(np.shape(numerator), np.nan, dtype=np.float64),
            where=denominator > 0,
        )
    incumbent_denominator = 2.0 * totals[..., 0] + totals[..., 1] + totals[..., 2]
    candidate_denominator = 2.0 * totals[..., 3] + totals[..., 4] + totals[..., 5]
    incumbent = np.divide(
        2.0 * totals[..., 0],
        incumbent_denominator,
        out=np.zeros(np.shape(incumbent_denominator), dtype=np.float64),
        where=incumbent_denominator > 0,
    )
    candidate = np.divide(
        2.0 * totals[..., 3],
        candidate_denominator,
        out=np.zeros(np.shape(candidate_denominator), dtype=np.float64),
        where=candidate_denominator > 0,
    )
    return candidate - incumbent


def _estimate_and_jackknife(
    counts: np.ndarray,
    metric: _MetricData,
    layout: _ClusterLayout,
) -> tuple[np.ndarray, np.ndarray, np.ndarray | None]:
    counts_2d = np.atleast_2d(counts.astype(np.float64, copy=False))
    totals = counts_2d @ metric.features
    estimates = _metric_value(totals, metric.kind)
    deleted_totals = np.empty(
        (counts_2d.shape[0], len(layout.labels), metric.features.shape[1]),
        dtype=np.float64,
    )
    for indices in layout.strata:
        stratum_size = len(indices)
        stratum_totals = counts_2d[:, indices] @ metric.features[indices]
        remaining = stratum_totals[:, np.newaxis, :] - metric.features[np.newaxis, indices, :]
        deleted_totals[:, indices, :] = (
            totals[:, np.newaxis, :]
            - metric.features[np.newaxis, indices, :]
            + remaining / (stratum_size - 1.0)
        )

    deleted_estimates = _metric_value(deleted_totals, metric.kind)
    active = counts_2d > 0
    invalid = np.any(active & ~np.isfinite(deleted_estimates), axis=1)
    variances = np.zeros(counts_2d.shape[0], dtype=np.float64)
    for indices in layout.strata:
        stratum_size = len(indices)
        stratum_counts = counts_2d[:, indices]
        stratum_estimates = deleted_estimates[:, indices]
        means = np.sum(
            np.where(stratum_counts > 0, stratum_counts * stratum_estimates, 0.0),
            axis=1,
        ) / stratum_size
        squared = np.where(
            stratum_counts > 0,
            stratum_counts * (stratum_estimates - means[:, np.newaxis]) ** 2,
            0.0,
        )
        variances += (stratum_size - 1.0) / stratum_size * np.sum(squared, axis=1)
    ses = np.sqrt(variances)
    ses[invalid] = np.nan
    return estimates, ses, deleted_estimates if counts_2d.shape[0] == 1 else None


def _bootstrap_counts(rng: np.random.Generator, batch: int, layout: _ClusterLayout) -> np.ndarray:
    counts = np.zeros((batch, len(layout.labels)), dtype=np.int32)
    for indices in layout.strata:
        cluster_count = len(indices)
        probabilities = np.full(cluster_count, 1.0 / cluster_count)
        counts[:, indices] = rng.multinomial(cluster_count, probabilities, size=batch)
    return counts


def _bootstrap_metrics(
    rng: np.random.Generator,
    samples: int,
    layout: _ClusterLayout,
    metrics: list[_MetricData],
) -> dict[str, tuple[np.ndarray, np.ndarray]]:
    estimates = {metric.name: np.empty(samples, dtype=np.float64) for metric in metrics}
    ses = {metric.name: np.empty(samples, dtype=np.float64) for metric in metrics}
    batch_size = min(1024, max(64, 2_000_000 // len(layout.labels)))
    offset = 0
    while offset < samples:
        size = min(batch_size, samples - offset)
        counts = _bootstrap_counts(rng, size, layout)
        for metric in metrics:
            batch_estimates, batch_ses, _ = _estimate_and_jackknife(counts, metric, layout)
            estimates[metric.name][offset : offset + size] = batch_estimates
            ses[metric.name][offset : offset + size] = batch_ses
        offset += size
    return {name: (estimates[name], ses[name]) for name in estimates}


def _quantile(values: np.ndarray, probability: float) -> float:
    return float(np.quantile(values, min(1.0, max(0.0, probability)), method="linear"))


def _jackknife_acceleration(values: np.ndarray, strata: list[np.ndarray]) -> float | None:
    if not len(values) or not np.all(np.isfinite(values)):
        return None
    influence_parts: list[np.ndarray] = []
    for indices in strata:
        if len(indices) < 2:
            return None
        stratum_values = values[indices]
        influence_parts.append(
            (len(indices) - 1.0) * (float(np.mean(stratum_values)) - stratum_values)
        )
    influences = np.concatenate(influence_parts)
    sum_squares = float(np.sum(influences**2))
    if sum_squares == 0.0:
        return 0.0
    return float(np.sum(influences**3) / (6.0 * sum_squares**1.5))


def _stratified_jackknife_se(values: np.ndarray, strata: list[np.ndarray]) -> float | None:
    if not len(values) or not np.all(np.isfinite(values)):
        return None
    variance = 0.0
    for indices in strata:
        if len(indices) < 2:
            return None
        stratum_values = values[indices]
        centered = stratum_values - float(np.mean(stratum_values))
        variance += (len(indices) - 1.0) / len(indices) * float(np.sum(centered**2))
    return math.sqrt(variance)


def _bca_bound(inputs: _IntervalInputs, side: Literal["upper", "lower"], alpha: float) -> dict[str, Any]:
    estimates = inputs.bootstrap_estimates[np.isfinite(inputs.bootstrap_estimates)]
    acceleration = _jackknife_acceleration(inputs.jackknife_values, inputs.strata)
    if not len(estimates) or acceleration is None:
        return {"bound": None, "defined": False, "reason": "BCa acceleration or bootstrap distribution is undefined"}
    less = int(np.sum(estimates < inputs.point))
    equal = int(np.sum(estimates == inputs.point))
    raw_probability = (less + 0.5 * equal) / len(estimates)
    clipped_probability = min(1.0 - 0.5 / len(estimates), max(0.5 / len(estimates), raw_probability))
    z0 = _NORMAL.inv_cdf(clipped_probability)
    tail_probability = 1.0 - alpha if side == "upper" else alpha
    tail_z = _NORMAL.inv_cdf(tail_probability)
    numerator = z0 + tail_z
    denominator = 1.0 - acceleration * numerator
    if denominator == 0.0:
        return {
            "bound": None,
            "defined": False,
            "reason": "BCa probability transform is singular",
            "acceleration": acceleration,
            "bias_correction": z0,
        }
    adjusted_probability = _NORMAL.cdf(z0 + numerator / denominator)
    bound = _quantile(estimates, adjusted_probability)
    return {
        "bound": bound,
        "defined": True,
        "adjusted_probability": adjusted_probability,
        "acceleration": acceleration,
        "bias_correction": z0,
        "less_than_point": less,
        "ties_at_point": equal,
        "tie_fraction": equal / len(estimates),
    }


def _studentized_bound(
    inputs: _IntervalInputs,
    side: Literal["upper", "lower"],
    alpha: float,
) -> dict[str, Any]:
    # The delete-one values preserve each stratum's original weight; their
    # within-stratum variation is the authoritative point-estimate SE.
    se_hat = _stratified_jackknife_se(inputs.jackknife_values, inputs.strata)
    if se_hat is None:
        if np.all(inputs.bootstrap_estimates == inputs.point):
            return {
                "bound": inputs.point,
                "defined": True,
                "se_hat": 0.0,
                "invalid_replicates": 0,
                "degenerate_zero_width": True,
            }
        return {"bound": None, "defined": False, "reason": "point jackknife SE is undefined"}
    if se_hat == 0.0 and np.all(inputs.bootstrap_estimates == inputs.point):
        return {
            "bound": inputs.point,
            "defined": True,
            "se_hat": 0.0,
            "invalid_replicates": 0,
            "degenerate_zero_width": True,
        }

    differences = inputs.bootstrap_estimates - inputs.point
    zero_consistent = (inputs.bootstrap_ses == 0.0) & (differences == 0.0)
    valid = np.isfinite(differences) & np.isfinite(inputs.bootstrap_ses) & (inputs.bootstrap_ses > 0.0)
    t_values = np.concatenate(
        (differences[valid] / inputs.bootstrap_ses[valid], np.zeros(int(np.sum(zero_consistent))))
    )
    invalid_count = len(differences) - len(t_values)
    if not len(t_values) or invalid_count / len(differences) > 0.01:
        return {
            "bound": None,
            "defined": False,
            "reason": "more than 1% of bootstrap-t replicates have undefined cluster jackknife SE",
            "se_hat": se_hat,
            "invalid_replicates": invalid_count,
        }
    probability = alpha if side == "upper" else 1.0 - alpha
    t_quantile = _quantile(t_values, probability)
    return {
        "bound": inputs.point - t_quantile * se_hat,
        "defined": True,
        "se_hat": se_hat,
        "t_probability": probability,
        "t_quantile": t_quantile,
        "invalid_replicates": invalid_count,
        "degenerate_zero_width": False,
    }


def combine_interval_bounds(
    bca_bound: float | None,
    studentized_bound: float | None,
    *,
    side: Literal["upper", "lower"],
    disagreement_tolerance: float = INTERVAL_DISAGREEMENT_TOLERANCE,
) -> dict[str, Any]:
    """Choose the preregistered less-favorable bound and expose disagreement."""

    if bca_bound is None or studentized_bound is None:
        return {
            "decision_bound": None,
            "method_disagreement": None,
            "interval_unstable": True,
        }
    disagreement = abs(bca_bound - studentized_bound)
    decision_bound = max(bca_bound, studentized_bound) if side == "upper" else min(bca_bound, studentized_bound)
    return {
        "decision_bound": decision_bound,
        "method_disagreement": disagreement,
        "interval_unstable": disagreement > disagreement_tolerance
        and not math.isclose(disagreement, disagreement_tolerance, rel_tol=1e-12, abs_tol=1e-15),
    }


def _bound_mc_se(values: np.ndarray, probability: float) -> float | None:
    finite = values[np.isfinite(values)]
    batch_count = min(20, len(finite) // 50)
    if batch_count < 4:
        return None
    batches = np.array_split(finite, batch_count)
    bounds = np.asarray([_quantile(batch, probability) for batch in batches])
    return float(np.std(bounds, ddof=1) / math.sqrt(batch_count))


def _distribution_diagnostics(values: np.ndarray, point: float) -> dict[str, Any]:
    finite = values[np.isfinite(values)]
    if not len(finite):
        return {"finite_replicates": 0, "skewness": None, "tie_fraction": None}
    standard_deviation = float(np.std(finite))
    skewness = (
        float(np.mean(((finite - float(np.mean(finite))) / standard_deviation) ** 3))
        if standard_deviation > 0.0
        else 0.0
    )
    return {
        "finite_replicates": len(finite),
        "mean": float(np.mean(finite)),
        "median": float(np.median(finite)),
        "standard_deviation": standard_deviation,
        "skewness": skewness,
        "tie_fraction": float(np.mean(finite == point)),
    }


def _interval_summary(
    inputs: _IntervalInputs,
    side: Literal["upper", "lower"],
    config: GateConfig,
    *,
    recomputed_f1: bool,
) -> dict[str, Any]:
    bca = _bca_bound(inputs, side, config.alpha)
    studentized = _studentized_bound(inputs, side, config.alpha)
    combined = combine_interval_bounds(
        bca.get("bound"),
        studentized.get("bound"),
        side=side,
        disagreement_tolerance=config.interval_disagreement_tolerance,
    )
    bca_probability = bca.get("adjusted_probability")
    student_probability = studentized.get("t_probability")
    monte_carlo = {
        "replicates": len(inputs.bootstrap_estimates),
        "bca_probability_mc_se": (
            math.sqrt(bca_probability * (1.0 - bca_probability) / len(inputs.bootstrap_estimates))
            if isinstance(bca_probability, int | float)
            else None
        ),
        "bca_bound_mc_se": (
            _bound_mc_se(inputs.bootstrap_estimates, bca_probability)
            if isinstance(bca_probability, int | float)
            else None
        ),
        "studentized_bound_mc_se": None,
    }
    if isinstance(student_probability, int | float) and studentized.get("defined"):
        differences = inputs.bootstrap_estimates - inputs.point
        valid = np.isfinite(inputs.bootstrap_ses) & (inputs.bootstrap_ses > 0.0) & np.isfinite(differences)
        zero_consistent = (inputs.bootstrap_ses == 0.0) & (differences == 0.0)
        t_values = np.concatenate(
            (differences[valid] / inputs.bootstrap_ses[valid], np.zeros(int(np.sum(zero_consistent))))
        )
        t_mc_se = _bound_mc_se(t_values, student_probability)
        monte_carlo["studentized_bound_mc_se"] = (
            abs(float(studentized["se_hat"])) * t_mc_se if t_mc_se is not None else None
        )
    return {
        "side": side,
        "alpha": config.alpha,
        "bca": bca,
        "studentized": studentized,
        **combined,
        "bootstrap": {
            **_distribution_diagnostics(inputs.bootstrap_estimates, inputs.point),
            "recomputed_from_aggregate_counts": recomputed_f1,
        },
        "monte_carlo": monte_carlo,
    }


def _interval_passes(interval: dict[str, Any], threshold: float) -> bool:
    bound = interval["decision_bound"]
    if bound is None or interval["interval_unstable"]:
        return False
    return bound <= threshold if interval["side"] == "upper" else bound >= threshold


def _near_boundary(interval: dict[str, Any], threshold: float, tolerance: float) -> bool:
    bound = interval["decision_bound"]
    return (
        isinstance(bound, int | float)
        and not interval["interval_unstable"]
        and abs(float(bound) - threshold) <= tolerance
    )


def _permutation_test(
    cluster_edit_deltas: np.ndarray,
    reference_words: int,
    observed: float,
    rng: np.random.Generator,
    samples: int,
) -> dict[str, Any]:
    cluster_count = len(cluster_edit_deltas)
    if cluster_count <= _EXACT_PERMUTATION_MAX_CLUSTERS:
        total = 1 << cluster_count
        favorable = 0
        batch_size = 65_536
        bit_positions = np.arange(cluster_count, dtype=np.uint64)
        for start in range(0, total, batch_size):
            masks = np.arange(start, min(start + batch_size, total), dtype=np.uint64)[:, np.newaxis]
            swapped = ((masks >> bit_positions) & 1).astype(np.int8)
            signs = 1.0 - 2.0 * swapped
            deltas = signs @ cluster_edit_deltas / reference_words
            favorable += int(np.sum(deltas <= observed))
        return {
            "method": "exact_whole_cluster_sign_swap",
            "clusters": cluster_count,
            "permutations": total,
            "p_value": favorable / total,
            "monte_carlo_se": 0.0,
            "favorable": favorable,
        }

    favorable = 0
    batch_size = min(8192, max(128, 4_000_000 // cluster_count))
    remaining = samples
    while remaining:
        size = min(batch_size, remaining)
        swapped = rng.integers(0, 2, size=(size, cluster_count), dtype=np.int8)
        signs = 1.0 - 2.0 * swapped
        deltas = signs @ cluster_edit_deltas / reference_words
        favorable += int(np.sum(deltas <= observed))
        remaining -= size
    p_value = (1.0 + favorable) / (samples + 1.0)
    return {
        "method": "monte_carlo_whole_cluster_sign_swap",
        "clusters": cluster_count,
        "permutations": samples,
        "p_value": p_value,
        "monte_carlo_se": math.sqrt(p_value * (1.0 - p_value) / (samples + 1.0)),
        "favorable": favorable,
    }


def _report_provenance(report: _Report) -> dict[str, Any]:
    return {
        "path": str(report.path),
        "sha256": report.sha256,
        "meta": report.meta,
        "manifest_sha256_pin": report.manifest_pin,
        "audio_manifest_sha256_pin": report.audio_manifest_pin,
    }


def _early_result(
    manifest: Path,
    manifest_sha256: str,
    audio_manifest_sha256: str,
    manifest_rows: list[dict[str, Any]],
    incumbent: _Report,
    candidate: _Report,
    config: GateConfig,
    validation: dict[str, Any],
    reasons: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "analysis": {
            "scope": config.claim_scope,
            "population_claim_permitted": False,
        },
        "provenance": {
            "manifest": {
                "path": str(manifest),
                "sha256": manifest_sha256,
                "audio_manifest_sha256": audio_manifest_sha256,
            },
            "incumbent": _report_provenance(incumbent),
            "candidate": _report_provenance(candidate),
        },
        "config": _config_output(config),
        "counts": {"manifest_rows": len(manifest_rows)},
        "validation": validation,
        "warnings": [],
        "decision": {"status": "reject", "reasons": reasons, "gates": {}},
    }


def _config_output(config: GateConfig) -> dict[str, Any]:
    return {
        "cluster_fields": list(config.cluster_fields),
        "stratum_fields": list(config.stratum_fields),
        "seed": config.seed,
        "rng": "numpy.PCG64",
        "bootstrap_samples_requested": config.bootstrap_samples,
        "permutation_samples": config.permutation_samples or config.bootstrap_samples,
        "alpha": config.alpha,
        "ni_margin": config.ni_margin,
        "benefit_margin": config.benefit_margin,
        "format_margin": config.format_margin,
        "incumbent_text_field": config.incumbent_text_field,
        "candidate_text_field": config.candidate_text_field,
        "interval_disagreement_tolerance": config.interval_disagreement_tolerance,
        "monte_carlo_boundary_tolerance": config.monte_carlo_boundary_tolerance,
    }


def evaluate_files(
    manifest_path: Path,
    incumbent_report_path: Path,
    candidate_report_path: Path,
    *,
    config: GateConfig,
) -> dict[str, Any]:
    """Evaluate one frozen candidate against one incumbent on identical rows."""

    manifest_path = Path(manifest_path)
    incumbent_report_path = Path(incumbent_report_path)
    candidate_report_path = Path(candidate_report_path)
    manifest_rows = _read_jsonl(manifest_path)
    manifest_ids = _validated_ids(manifest_rows, str(manifest_path))
    manifest_sha256 = _sha256(manifest_path)
    audio_manifest_sha256 = _audio_manifest_sha256(manifest_rows, str(manifest_path))
    incumbent = _load_report(incumbent_report_path)
    candidate = _load_report(candidate_report_path)
    incumbent_ids = _validated_ids(incumbent.rows, str(incumbent.path))
    candidate_ids = _validated_ids(candidate.rows, str(candidate.path))
    manifest_set = set(manifest_ids)
    incumbent_set = set(incumbent_ids)
    candidate_set = set(candidate_ids)
    incumbent_by_id = dict(zip(incumbent_ids, incumbent.rows, strict=True))
    candidate_by_id = dict(zip(candidate_ids, candidate.rows, strict=True))
    incumbent_errors = {row_id for row_id, row in incumbent_by_id.items() if _is_error_row(row)}
    candidate_errors = {row_id for row_id, row in candidate_by_id.items() if _is_error_row(row)}
    validation: dict[str, Any] = {
        "row_sets_equal": manifest_set == incumbent_set == candidate_set,
        "incumbent_missing_ids": _format_ids(manifest_set - incumbent_set),
        "incumbent_extra_ids": _format_ids(incumbent_set - manifest_set),
        "candidate_missing_ids": _format_ids(manifest_set - candidate_set),
        "candidate_extra_ids": _format_ids(candidate_set - manifest_set),
        "incumbent_error_ids": sorted(incumbent_errors),
        "candidate_error_ids": sorted(candidate_errors),
        "error_sets_equal": incumbent_errors == candidate_errors,
        "zero_error_rows": not incumbent_errors and not candidate_errors,
        "manifest_pins_present": all(
            isinstance(pin, str) and bool(pin)
            for pin in (incumbent.manifest_pin, candidate.manifest_pin)
        ),
        "manifest_pins_match": all(
            pin == manifest_sha256 for pin in (incumbent.manifest_pin, candidate.manifest_pin)
        ),
        "audio_manifest_pins_present": all(
            isinstance(pin, str) and bool(pin)
            for pin in (incumbent.audio_manifest_pin, candidate.audio_manifest_pin)
        ),
        "audio_manifest_pins_match": all(
            pin == audio_manifest_sha256
            for pin in (incumbent.audio_manifest_pin, candidate.audio_manifest_pin)
        ),
    }
    reasons: list[dict[str, Any]] = []
    if not validation["row_sets_equal"]:
        reasons.append(_reason("ROWSET_FAIL", "manifest, incumbent, and candidate row-id sets differ"))
    if incumbent.successful_evidence is not None and incumbent.error_evidence is not None:
        if (
            incumbent.successful_evidence != incumbent_set - incumbent_errors
            or incumbent.error_evidence != incumbent_errors
        ):
            reasons.append(_reason("ROWSET_FAIL", "incumbent row-id evidence disagrees with its row records"))
    if candidate.successful_evidence is not None and candidate.error_evidence is not None:
        if (
            candidate.successful_evidence != candidate_set - candidate_errors
            or candidate.error_evidence != candidate_errors
        ):
            reasons.append(_reason("ROWSET_FAIL", "candidate row-id evidence disagrees with its row records"))
    if not validation["error_sets_equal"]:
        reasons.append(_reason("ERRORSET_FAIL", "incumbent and candidate runtime-error row sets differ"))
    if not validation["zero_error_rows"]:
        reasons.append(_reason("RUNTIME_FAIL", "promotion requires zero runtime, timeout, and duration-rejected rows"))
    if not validation["manifest_pins_present"]:
        reasons.append(_reason("PROVENANCE_FAIL", "both reports must pin the supplied manifest SHA-256"))
    elif not validation["manifest_pins_match"]:
        reasons.append(_reason("PROVENANCE_FAIL", "a report manifest digest pin does not match the supplied manifest"))
    if not validation["audio_manifest_pins_present"]:
        reasons.append(_reason("PROVENANCE_FAIL", "both reports must pin the declared audio-manifest SHA-256"))
    elif not validation["audio_manifest_pins_match"]:
        reasons.append(_reason("PROVENANCE_FAIL", "a report audio-manifest digest pin does not match the manifest"))
    incumbent_mode = incumbent.meta.get("mode")
    candidate_mode = candidate.meta.get("mode")
    validation["report_modes_equal"] = incumbent_mode == candidate_mode
    validation["report_modes_present"] = all(
        isinstance(mode, str) and bool(mode) for mode in (incumbent_mode, candidate_mode)
    )
    if not validation["report_modes_present"]:
        reasons.append(_reason("PROVENANCE_FAIL", "both reports must record a non-empty execution mode"))
    elif not validation["report_modes_equal"]:
        reasons.append(_reason("PROVENANCE_FAIL", "incumbent and candidate report modes differ"))
    if reasons:
        return _early_result(
            manifest_path,
            manifest_sha256,
            audio_manifest_sha256,
            manifest_rows,
            incumbent,
            candidate,
            config,
            validation,
            reasons,
        )

    layout = _cluster_layout(manifest_rows, config)
    cluster_count = len(layout.labels)
    underreplicated = [
        layout.stratum_labels[index]
        for index, indices in enumerate(layout.strata)
        if len(indices) < 2
    ]
    if underreplicated:
        raise GateInputError(
            "CLUSTER_STRATUM_UNDERREPLICATED",
            f"each resampling stratum requires at least two clusters: {underreplicated[:10]}",
        )
    wer_features = np.zeros((cluster_count, 3), dtype=np.float64)
    case_features = np.zeros((cluster_count, 6), dtype=np.float64)
    punct_features = np.zeros((cluster_count, 6), dtype=np.float64)
    formatted_rows = 0
    deletion_hazards: list[dict[str, Any]] = []
    edit_signs = {"candidate_better": 0, "tie": 0, "candidate_worse": 0}
    exact_discordance = {
        "incumbent_exact_candidate_wrong": 0,
        "incumbent_wrong_candidate_exact": 0,
    }

    for manifest_row, cluster_index in zip(manifest_rows, layout.row_cluster_indices, strict=True):
        row_id = manifest_row["id"]
        reference = manifest_row.get("reference")
        if not isinstance(reference, str):
            raise GateInputError("INPUT_FORMAT_FAIL", f"manifest row {row_id!r} has no string reference")
        incumbent_row = incumbent_by_id[row_id]
        candidate_row = candidate_by_id[row_id]
        incumbent_text = incumbent_row.get(config.incumbent_text_field)
        candidate_text = candidate_row.get(config.candidate_text_field)
        if not isinstance(incumbent_text, str):
            raise GateInputError(
                "INPUT_FORMAT_FAIL",
                f"incumbent row {row_id!r} has no string {config.incumbent_text_field!r}",
            )
        if not isinstance(candidate_text, str):
            raise GateInputError(
                "INPUT_FORMAT_FAIL",
                f"candidate row {row_id!r} has no string {config.candidate_text_field!r}",
            )
        reference_words, incumbent_edits, incumbent_exact = _edit_counts(reference, incumbent_text)
        candidate_reference_words, candidate_edits, candidate_exact = _edit_counts(reference, candidate_text)
        if reference_words != candidate_reference_words:
            raise AssertionError(f"reference word count changed for {row_id}")
        wer_features[cluster_index] += (reference_words, incumbent_edits, candidate_edits)
        edit_delta = candidate_edits - incumbent_edits
        edit_signs[
            "candidate_better" if edit_delta < 0 else "candidate_worse" if edit_delta > 0 else "tie"
        ] += 1
        exact_discordance["incumbent_exact_candidate_wrong"] += int(incumbent_exact and not candidate_exact)
        exact_discordance["incumbent_wrong_candidate_exact"] += int(not incumbent_exact and candidate_exact)
        deletion_hazards.extend(
            _candidate_deletion_hazards(row_id, reference, incumbent_text, candidate_text)
        )

        formatted_reference = manifest_row.get("formatted_reference")
        if isinstance(formatted_reference, str):
            formatted_rows += 1
            incumbent_case = _f1_counts(case_f1([formatted_reference], [incumbent_text]), "overall")
            candidate_case = _f1_counts(case_f1([formatted_reference], [candidate_text]), "overall")
            incumbent_punct = _f1_counts(punct_f1([formatted_reference], [incumbent_text]), "micro")
            candidate_punct = _f1_counts(punct_f1([formatted_reference], [candidate_text]), "micro")
            case_features[cluster_index] += (*incumbent_case, *candidate_case)
            punct_features[cluster_index] += (*incumbent_punct, *candidate_punct)

    total_words = int(np.sum(wer_features[:, 0]))
    if total_words <= 0:
        raise GateInputError("INPUT_FORMAT_FAIL", "manifest has zero normalized reference words")
    metrics = [_MetricData("uwer", wer_features, "wer")]
    if formatted_rows:
        metrics.extend(
            (
                _MetricData("case_f1", case_features, "f1"),
                _MetricData("punctuation_micro_f1", punct_features, "f1"),
            )
        )

    point_counts = np.ones(cluster_count, dtype=np.float64)
    points: dict[str, float] = {}
    jackknives: dict[str, np.ndarray] = {}
    for metric in metrics:
        estimate, _, deleted = _estimate_and_jackknife(point_counts, metric, layout)
        points[metric.name] = float(estimate[0])
        if deleted is None:
            jackknives[metric.name] = np.asarray([], dtype=np.float64)
        else:
            jackknives[metric.name] = np.asarray(deleted[0], dtype=np.float64)

    seed_sequence = np.random.SeedSequence(config.seed)
    bootstrap_seed, permutation_seed = seed_sequence.spawn(2)
    bootstrap_rng = np.random.Generator(np.random.PCG64(bootstrap_seed))
    permutation_rng = np.random.Generator(np.random.PCG64(permutation_seed))
    bootstrap = _bootstrap_metrics(bootstrap_rng, config.bootstrap_samples, layout, metrics)

    def make_intervals(current: dict[str, tuple[np.ndarray, np.ndarray]]) -> dict[str, dict[str, Any]]:
        summaries: dict[str, dict[str, Any]] = {}
        for metric in metrics:
            estimates, ses = current[metric.name]
            summaries[metric.name] = _interval_summary(
                _IntervalInputs(points[metric.name], estimates, ses, jackknives[metric.name], layout.strata),
                "upper" if metric.name == "uwer" else "lower",
                config,
                recomputed_f1=metric.kind == "f1",
            )
        return summaries

    preliminary_intervals = make_intervals(bootstrap)
    point_incumbent_uwer = float(np.sum(wer_features[:, 1]) / total_words)
    point_candidate_uwer = float(np.sum(wer_features[:, 2]) / total_words)
    point_rejects = points["uwer"] > config.ni_margin or points["uwer"] > -config.benefit_margin
    if formatted_rows:
        point_rejects |= points["case_f1"] < -config.format_margin
        point_rejects |= points["punctuation_micro_f1"] < -config.format_margin
    interval_already_unstable = any(summary["interval_unstable"] for summary in preliminary_intervals.values())
    thresholds = {"uwer": config.ni_margin}
    if formatted_rows:
        thresholds.update({"case_f1": -config.format_margin, "punctuation_micro_f1": -config.format_margin})
    near_boundary = (
        not point_rejects
        and not interval_already_unstable
        and (
            _near_boundary(preliminary_intervals["uwer"], config.ni_margin, config.monte_carlo_boundary_tolerance)
            or _near_boundary(preliminary_intervals["uwer"], 0.0, config.monte_carlo_boundary_tolerance)
            or any(
                _near_boundary(preliminary_intervals[name], threshold, config.monte_carlo_boundary_tolerance)
                for name, threshold in thresholds.items()
                if name != "uwer"
            )
        )
    )
    extended = near_boundary and config.bootstrap_samples < config.monte_carlo_extension_samples
    preliminary_passes = {
        name: _interval_passes(summary, thresholds[name])
        for name, summary in preliminary_intervals.items()
        if name in thresholds
    }
    preliminary_passes["benefit_upper"] = (
        preliminary_intervals["uwer"]["decision_bound"] is not None
        and preliminary_intervals["uwer"]["decision_bound"] < 0.0
        and not preliminary_intervals["uwer"]["interval_unstable"]
    )
    if extended:
        extra = _bootstrap_metrics(
            bootstrap_rng,
            config.monte_carlo_extension_samples - config.bootstrap_samples,
            layout,
            metrics,
        )
        bootstrap = {
            name: (
                np.concatenate((bootstrap[name][0], extra[name][0])),
                np.concatenate((bootstrap[name][1], extra[name][1])),
            )
            for name in bootstrap
        }
    intervals = make_intervals(bootstrap)
    final_passes = {
        name: _interval_passes(summary, thresholds[name])
        for name, summary in intervals.items()
        if name in thresholds
    }
    final_passes["benefit_upper"] = (
        intervals["uwer"]["decision_bound"] is not None
        and intervals["uwer"]["decision_bound"] < 0.0
        and not intervals["uwer"]["interval_unstable"]
    )
    monte_carlo_changed_decision = extended and preliminary_passes != final_passes

    permutation = _permutation_test(
        wer_features[:, 2] - wer_features[:, 1],
        total_words,
        points["uwer"],
        permutation_rng,
        config.permutation_samples or config.bootstrap_samples,
    )

    incumbent_case = candidate_case = incumbent_punct = candidate_punct = None
    if formatted_rows:
        case_totals = np.sum(case_features, axis=0)
        punct_totals = np.sum(punct_features, axis=0)
        incumbent_case = float(_metric_value(np.asarray([*case_totals[:3], 0, 0, 0]), "f1") * -1.0)
        candidate_case = float(_metric_value(np.asarray([0, 0, 0, *case_totals[3:]]), "f1"))
        incumbent_punct = float(_metric_value(np.asarray([*punct_totals[:3], 0, 0, 0]), "f1") * -1.0)
        candidate_punct = float(_metric_value(np.asarray([0, 0, 0, *punct_totals[3:]]), "f1"))

    uwer_jackknife = jackknives["uwer"]
    finite_influences = np.isfinite(uwer_jackknife)
    if np.any(finite_influences):
        influence_values = np.where(finite_influences, np.abs(uwer_jackknife - points["uwer"]), -np.inf)
        largest_index = int(np.argmax(influence_values))
        largest_influence = {
            "cluster": layout.labels[largest_index],
            "absolute_delta_change": float(influence_values[largest_index]),
            "delete_one_delta": float(uwer_jackknife[largest_index]),
        }
    else:
        largest_influence = {"cluster": None, "absolute_delta_change": None, "delete_one_delta": None}

    warnings: list[str] = []
    if config.claim_scope == "frozen_row_conditional" and not config.cluster_fields:
        warnings.append("CLUSTER_METADATA_MISSING")
    discordant_rows = sum(exact_discordance.values())
    diagnostic_flags: list[str] = []
    if discordant_rows == 0:
        diagnostic_flags.append("LOW_DISCORDANCE")
    influence = largest_influence["absolute_delta_change"]
    if isinstance(influence, float) and influence > config.ni_margin:
        diagnostic_flags.append("HIGH_LEVERAGE")
    if any(interval["interval_unstable"] for interval in intervals.values()):
        diagnostic_flags.append("INTERVAL_UNSTABLE")
    if monte_carlo_changed_decision:
        diagnostic_flags.append("MONTE_CARLO_UNSTABLE")

    accuracy_interval = intervals["uwer"]
    case_interval = intervals.get("case_f1")
    punct_interval = intervals.get("punctuation_micro_f1")
    gates: dict[str, Any] = {
        "row_set": "pass",
        "errors": "pass",
        "deletion_hazard": "fail" if deletion_hazards else "pass",
        "uwer_non_inferiority_point": "pass" if points["uwer"] <= config.ni_margin else "fail",
        "uwer_non_inferiority_bound": (
            "pass" if _interval_passes(accuracy_interval, config.ni_margin) else "inconclusive"
        ),
        "benefit_point": "pass" if points["uwer"] <= -config.benefit_margin else "fail",
        "benefit_bound": (
            "pass"
            if accuracy_interval["decision_bound"] is not None
            and accuracy_interval["decision_bound"] < 0.0
            and not accuracy_interval["interval_unstable"]
            else "inconclusive"
        ),
        "benefit_permutation": "pass" if permutation["p_value"] <= config.alpha else "inconclusive",
        "case_f1": "not_applicable",
        "punctuation_micro_f1": "not_applicable",
    }
    if formatted_rows and case_interval is not None and punct_interval is not None:
        gates["case_f1"] = (
            "fail"
            if points["case_f1"] < -config.format_margin
            else "pass"
            if _interval_passes(case_interval, -config.format_margin)
            else "inconclusive"
        )
        gates["punctuation_micro_f1"] = (
            "fail"
            if points["punctuation_micro_f1"] < -config.format_margin
            else "pass"
            if _interval_passes(punct_interval, -config.format_margin)
            else "inconclusive"
        )

    reject_reasons: list[dict[str, Any]] = []
    inconclusive_reasons: list[dict[str, Any]] = []
    if deletion_hazards:
        reject_reasons.append(
            _reason(
                "DELETION_HAZARD",
                "candidate introduces contiguous multiword deletions",
                rows=len(deletion_hazards),
            )
        )
    if points["uwer"] > config.ni_margin:
        reject_reasons.append(
            _reason(
                "UWER_POINT_INFERIOR",
                "candidate point U-WER delta exceeds the non-inferiority margin",
                delta=points["uwer"],
                margin=config.ni_margin,
            )
        )
    if points["uwer"] > -config.benefit_margin:
        reject_reasons.append(
            _reason(
                "BENEFIT_POINT_MISS",
                "candidate point U-WER improvement misses the preregistered benefit margin",
                delta=points["uwer"],
                required_maximum=-config.benefit_margin,
            )
        )
    for name, label in (("case_f1", "case F1"), ("punctuation_micro_f1", "punctuation micro-F1")):
        if formatted_rows and points[name] < -config.format_margin:
            reject_reasons.append(
                _reason(
                    "FORMAT_POINT_INFERIOR",
                    f"candidate point {label} delta exceeds the formatting loss margin",
                    metric=name,
                    delta=points[name],
                    required_minimum=-config.format_margin,
                )
            )
    if not reject_reasons:
        if len(bootstrap["uwer"][0]) < MINIMUM_BOOTSTRAP_SAMPLES:
            inconclusive_reasons.append(
                _reason(
                    "INSUFFICIENT_MONTE_CARLO_SAMPLES",
                    "promotion inference requires at least 10,000 bootstrap replicates",
                    used=len(bootstrap["uwer"][0]),
                    required=MINIMUM_BOOTSTRAP_SAMPLES,
                )
            )
        if (
            permutation["method"] == "monte_carlo_whole_cluster_sign_swap"
            and permutation["permutations"] < MINIMUM_MONTE_CARLO_PERMUTATIONS
        ):
            inconclusive_reasons.append(
                _reason(
                    "INSUFFICIENT_MONTE_CARLO_SAMPLES",
                    "Monte Carlo benefit testing requires at least 100,000 whole-cluster swaps",
                    used=permutation["permutations"],
                    required=MINIMUM_MONTE_CARLO_PERMUTATIONS,
                )
            )
        if any(interval["interval_unstable"] for interval in intervals.values()):
            inconclusive_reasons.append(
                _reason(
                    "INTERVAL_UNSTABLE",
                    "BCa and studentized methods disagree beyond tolerance or a method is undefined",
                    tolerance=config.interval_disagreement_tolerance,
                )
            )
        if monte_carlo_changed_decision:
            inconclusive_reasons.append(
                _reason(
                    "MONTE_CARLO_UNSTABLE",
                    "extending the predetermined bootstrap stream changed a bound decision",
                    preliminary_samples=config.bootstrap_samples,
                    final_samples=len(bootstrap["uwer"][0]),
                )
            )
        if gates["uwer_non_inferiority_bound"] != "pass":
            inconclusive_reasons.append(
                _reason("UNDERPOWERED", "U-WER non-inferiority bound does not pass the fixed margin")
            )
        if gates["benefit_bound"] != "pass" or gates["benefit_permutation"] != "pass":
            inconclusive_reasons.append(
                _reason(
                    "BENEFIT_INCONCLUSIVE",
                    "accuracy benefit bound or paired cluster permutation test does not pass",
                    p_value=permutation["p_value"],
                )
            )
        for gate_name in ("case_f1", "punctuation_micro_f1"):
            if gates[gate_name] == "inconclusive":
                inconclusive_reasons.append(
                    _reason("UNDERPOWERED", "formatting lower bound does not pass", metric=gate_name)
                )
    decision_status = "reject" if reject_reasons else "inconclusive" if inconclusive_reasons else "pass"
    decision_reasons = reject_reasons or inconclusive_reasons

    formatting: dict[str, Any] = {"eligible_rows": formatted_rows}
    if formatted_rows and case_interval is not None and punct_interval is not None:
        formatting.update(
            {
                "case_f1": {
                    "incumbent": incumbent_case,
                    "candidate": candidate_case,
                    "delta_candidate_minus_incumbent": points["case_f1"],
                    "lower_interval": case_interval,
                },
                "punctuation_micro_f1": {
                    "incumbent": incumbent_punct,
                    "candidate": candidate_punct,
                    "delta_candidate_minus_incumbent": points["punctuation_micro_f1"],
                    "lower_interval": punct_interval,
                },
            }
        )
    else:
        formatting["status"] = "not_applicable"

    return {
        "schema_version": 1,
        "analysis": {
            "scope": config.claim_scope,
            "population_claim_permitted": False,
            "estimand": "pooled paired normalized word errors divided by pooled normalized reference words",
            "resampling_unit": "cluster" if config.cluster_fields else "frozen row",
        },
        "provenance": {
            "manifest": {
                "path": str(manifest_path),
                "sha256": manifest_sha256,
                "audio_manifest_sha256": audio_manifest_sha256,
            },
            "incumbent": _report_provenance(incumbent),
            "candidate": _report_provenance(candidate),
        },
        "config": {
            **_config_output(config),
            "bootstrap_samples_used": len(bootstrap["uwer"][0]),
            "bootstrap_extended_for_near_boundary": extended,
        },
        "counts": {
            "manifest_rows": len(manifest_rows),
            "reference_words": total_words,
            "clusters": cluster_count,
            "strata": [
                {"stratum": label, "clusters": len(indices)}
                for label, indices in zip(layout.stratum_labels, layout.strata, strict=True)
            ],
            "formatted_reference_rows": formatted_rows,
        },
        "validation": validation,
        "accuracy": {
            "incumbent_uwer": point_incumbent_uwer,
            "candidate_uwer": point_candidate_uwer,
            "delta_candidate_minus_incumbent": points["uwer"],
            "upper_interval": accuracy_interval,
            "benefit_permutation": permutation,
        },
        "formatting": formatting,
        "diagnostics": {
            "utterance_edit_delta_sign": edit_signs,
            "exact_match_discordance": exact_discordance,
            "discordant_rows": discordant_rows,
            "largest_cluster_influence": largest_influence,
            "deletion_hazards": deletion_hazards,
            "preliminary_bound_decisions": preliminary_passes,
            "final_bound_decisions": final_passes,
            "flags": diagnostic_flags,
        },
        "warnings": warnings,
        "decision": {"status": decision_status, "reasons": decision_reasons, "gates": gates},
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run a deterministic paired fixed-corpus ASR promotion robustness gate."
    )
    parser.add_argument("manifest", type=Path)
    parser.add_argument("incumbent", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cluster-field", action="append", default=[], metavar="FIELD")
    parser.add_argument("--stratum-field", action="append", default=[], metavar="FIELD")
    parser.add_argument(
        "--frozen-row-conditional",
        action="store_true",
        required=True,
        help="acknowledge that the decision applies only to the supplied frozen rows",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("-B", "--bootstrap-samples", type=int, default=DEFAULT_BOOTSTRAP_SAMPLES)
    parser.add_argument("--permutation-samples", type=int)
    parser.add_argument("--alpha", type=float, default=DEFAULT_ALPHA)
    parser.add_argument("--ni-margin", type=float, default=DEFAULT_NI_MARGIN)
    parser.add_argument("--benefit-margin", type=float, default=DEFAULT_BENEFIT_MARGIN)
    parser.add_argument("--format-margin", type=float, default=DEFAULT_FORMAT_MARGIN)
    parser.add_argument("--incumbent-text-field", default="final_text")
    parser.add_argument("--candidate-text-field", default="final_text")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        config = GateConfig(
            cluster_fields=tuple(args.cluster_field),
            stratum_fields=tuple(args.stratum_field),
            claim_scope="frozen_row_conditional",
            seed=args.seed,
            bootstrap_samples=args.bootstrap_samples,
            permutation_samples=args.permutation_samples,
            alpha=args.alpha,
            ni_margin=args.ni_margin,
            benefit_margin=args.benefit_margin,
            format_margin=args.format_margin,
            incumbent_text_field=args.incumbent_text_field,
            candidate_text_field=args.candidate_text_field,
        )
        result = evaluate_files(args.manifest, args.incumbent, args.candidate, config=config)
    except (GateInputError, OSError) as error:
        if isinstance(error, GateInputError):
            code = error.code
            message = error.message
        else:
            code = "INPUT_IO_FAIL"
            message = str(error)
        refusal = {"schema_version": 1, "decision": {"status": "refuse", "reasons": [_reason(code, message)]}}
        print(json.dumps(refusal, ensure_ascii=False, sort_keys=True), file=sys.stderr)
        return 2

    output = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output is None:
        print(output, end="")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
        print(json.dumps({"output": str(args.output), "status": result["decision"]["status"]}, sort_keys=True))
    return 0 if result["decision"]["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
