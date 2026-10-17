#!/usr/bin/env python3
"""Paired timing statistics for the Voiceour Rust proof program (Python standard library only).

Reads the program's `timing` and `stage_profile` JSONL rows and reports per-arm latency distributions, paired
candidate/base ratios with bootstrap percentile and BCa intervals, Wilcoxon signed-rank and sign tests, absolute
savings, output equivalence, A/A noise floors, execution-order drift, and offline stage profiles. Every reported number
is deterministic for fixed inputs, flags and seed. Metric definitions and exact formulas: bench/rust/analysis/README.md.

Before any statistic it checks each run's declared grid and completion footer and refuses an incomplete run; runtime
errors are counted and excluded, never turned into time.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import sys
from bisect import bisect_left, bisect_right
from collections import Counter
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from operator import itemgetter
from pathlib import Path
from statistics import NormalDist
from typing import Any

SCHEMA_VERSION = 1
TOOL = "bench/rust/analysis/paired_stats.py"
DEFAULT_SEED = 20261016
DEFAULT_BOOTSTRAP = 10_000
DEFAULT_STAGE_TOLERANCE = 0.01
ALPHA = 0.05
EXACT_WILCOXON_MAX_N = 25
DRIFT_RHO_THRESHOLD = 0.3
ID_LIST_LIMIT = 20
SMALL_N_WARNING = 10
MIN_RECOMMENDED_BOOTSTRAP = 1_000
AUDIO_S_RELATIVE_TOLERANCE = 1e-6
AGGREGATES = ("median", "min")
AA_SUFFIX = "@aa"
FULL_STAGE = "full"
UNATTRIBUTED_STAGE = "(unattributed)"
INVALID_RUN_STATUSES = frozenset({"aborted", "invalid", "failed", "error", "incomplete", "cancelled", "canceled"})
FAULT_MESSAGE_LIMIT = 160
INTEGRITY_PROBLEM_LIMIT = 12
GRID_EXAMPLES = 3
_NORMAL = NormalDist()
_DIGIT_RUNS = re.compile(r"([0-9]+)")


def _normal_cdf(x: float) -> float:
    """Standard normal CDF through erfc: accurate in both tails and identical across Python versions
    (statistics.NormalDist.cdf changed its formula between releases)."""
    return 0.5 * math.erfc(-x / math.sqrt(2.0))


class InputError(ValueError):
    """The inputs or flags cannot support the requested analysis."""


@dataclass
class TimingSample:
    source: int
    where: str
    arm: str
    row_id: str
    corpus: str | None
    pass_index: int
    seq: float | None
    elapsed_us: float
    output_sha256: str | None
    equal_ref: bool | None
    audio_s: float | None
    err_max_abs: float | None
    err_rel_l2: float | None
    row: str = ""
    runtime_error: str | None = None


@dataclass
class StageSample:
    source: int
    where: str
    group: str
    row_id: str
    corpus: str | None
    pass_index: int
    audio_s: float | None
    stages_us: dict[str, float]
    counts: dict[str, float]
    row: str = ""


@dataclass
class InputFile:
    path: str
    sha256: str
    lines: int = 0
    timing_rows: int = 0
    stage_profile_rows: int = 0
    ignored_types: dict[str, int] = field(default_factory=dict)
    run_meta: list[dict[str, Any]] = field(default_factory=list)
    run_end: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class RunSegment:
    """The records of one run inside one input file: its run_meta (if any), the keys of every timing and
    stage_profile row it wrote, and its run_end footer (if any)."""

    source: int
    path: str
    meta: dict[str, Any] | None = None
    meta_line: int | None = None
    timing_keys: list[tuple[str, str, int]] = field(default_factory=list)
    stage_keys: list[tuple[str, str, int]] = field(default_factory=list)
    run_ends: list[dict[str, Any]] = field(default_factory=list)
    rows_after_end: int = 0
    runtime_error_rows: int = 0

    def is_empty(self) -> bool:
        return self.meta is None and not self.timing_keys and not self.stage_keys and not self.run_ends


@dataclass
class Dataset:
    inputs: list[InputFile]
    timing: list[TimingSample]
    stages: list[StageSample]
    invalid_timing: list[dict[str, Any]]
    timing_rows: dict[str, Any]
    stage_rows: dict[str, Any]
    segments: list[RunSegment]
    runtime_errors: list[TimingSample]


@dataclass(frozen=True)
class ArmRow:
    """One (arm, row) after aggregating its timed passes; equivalence fields cover every pass."""

    value: float
    samples: int
    hashes: frozenset[str]
    equal_ref: bool | None
    err_max_abs: tuple[float, ...]
    err_rel_l2: tuple[float, ...]


class _Warnings:
    def __init__(self) -> None:
        self.items: list[dict[str, str]] = []

    def add(self, code: str, message: str) -> None:
        self.items.append({"code": code, "message": message})


# ---------------------------------------------------------------------------------------------------------------------
# Order statistics, ranks and correlation


def natural_key(text: str) -> tuple[tuple[Any, ...], str]:
    """Sort key that orders digit runs numerically ("row2" < "row10"); the raw text breaks ties."""
    parts = _DIGIT_RUNS.split(text)
    return tuple(int(part) if index % 2 else part for index, part in enumerate(parts)), text


def quantile(ordered: Sequence[float], probability: float) -> float:
    """Type-7 quantile (linear interpolation between closest ranks) of an ascending sequence."""
    count = len(ordered)
    if count == 0:
        raise ValueError("quantile of an empty sample")
    position = (count - 1) * min(1.0, max(0.0, probability))
    lower = math.floor(position)
    upper = min(lower + 1, count - 1)
    return ordered[lower] + (position - lower) * (ordered[upper] - ordered[lower])


def describe(values: Iterable[float]) -> dict[str, Any]:
    ordered = sorted(values)
    count = len(ordered)
    if count == 0:
        return {"n": 0}
    total = math.fsum(ordered)
    return {
        "n": count,
        "sum": total,
        "mean": total / count,
        "p50": quantile(ordered, 0.50),
        "p90": quantile(ordered, 0.90),
        "p95": quantile(ordered, 0.95),
        "p99": quantile(ordered, 0.99),
        "min": ordered[0],
        "max": ordered[-1],
    }


def _aggregate(values: Sequence[float], how: str) -> float:
    return min(values) if how == "min" else quantile(sorted(values), 0.5)


def _stdev(values: Sequence[float]) -> float | None:
    count = len(values)
    if count < 2:
        return None
    mean = math.fsum(values) / count
    return math.sqrt(math.fsum((value - mean) ** 2 for value in values) / (count - 1))


def average_ranks(values: Sequence[float]) -> list[float]:
    """1-based ranks; tied values share the mean of the ranks they span (mid-ranks)."""
    order = sorted(range(len(values)), key=values.__getitem__)
    ranks = [0.0] * len(values)
    start = 0
    while start < len(order):
        end = start
        while end + 1 < len(order) and values[order[end + 1]] == values[order[start]]:
            end += 1
        rank = (start + end + 2) / 2
        for position in range(start, end + 1):
            ranks[order[position]] = rank
        start = end + 1
    return ranks


def _tie_sizes(values: Iterable[float]) -> list[int]:
    return [size for size in Counter(values).values() if size > 1]


def pearson(x: Sequence[float], y: Sequence[float]) -> float | None:
    count = len(x)
    if count < 2:
        return None
    mean_x = math.fsum(x) / count
    mean_y = math.fsum(y) / count
    sxx = math.fsum((value - mean_x) ** 2 for value in x)
    syy = math.fsum((value - mean_y) ** 2 for value in y)
    if sxx == 0.0 or syy == 0.0:
        return None
    sxy = math.fsum((a - mean_x) * (b - mean_y) for a, b in zip(x, y, strict=True))
    return max(-1.0, min(1.0, sxy / math.sqrt(sxx * syy)))


def spearman(x: Sequence[float], y: Sequence[float]) -> float | None:
    """Spearman rho: Pearson correlation of mid-ranks. None below 3 points or for a constant series."""
    if len(x) < 3:
        return None
    return pearson(average_ranks(x), average_ranks(y))


# ---------------------------------------------------------------------------------------------------------------------
# Tests and intervals


def wilcoxon_signed_rank(differences: Sequence[float], exact_max_n: int = EXACT_WILCOXON_MAX_N) -> dict[str, Any]:
    """Two-sided Wilcoxon signed-rank test with Pratt zero handling.

    Exact conditional null distribution (all 2^m sign assignments of the observed nonzero mid-ranks) when n <= 25,
    otherwise the normal approximation with Cureton's zero correction and the tie correction; no continuity correction.
    """
    count = len(differences)
    ranks = average_ranks([abs(value) for value in differences])
    nonzero = [(rank, value) for rank, value in zip(ranks, differences, strict=True) if value != 0.0]
    zeros = count - len(nonzero)
    w_plus = math.fsum(rank for rank, value in nonzero if value > 0.0)
    w_minus = math.fsum(rank for rank, value in nonzero if value < 0.0)
    result: dict[str, Any] = {
        "n": count,
        "n_zero": zeros,
        "n_nonzero": len(nonzero),
        "w_plus": w_plus,
        "w_minus": w_minus,
        "zero_method": "pratt",
        "continuity_correction": False,
        "method": None,
        "z": None,
        "p_two_sided": 1.0,
    }
    if not nonzero:
        result["method"] = "degenerate"
        return result
    if count <= exact_max_n:
        # Mid-ranks are multiples of 1/2, so doubled ranks are integers and the null distribution is a subset-sum count.
        doubled = [round(2.0 * rank) for rank, _ in nonzero]
        counts = [0] * (sum(doubled) + 1)
        counts[0] = 1
        reach = 0
        for rank in doubled:
            for total in range(reach, -1, -1):
                if counts[total]:
                    counts[total + rank] += counts[total]
            reach += rank
        observed = round(2.0 * w_plus)
        lower = sum(counts[: observed + 1])
        upper = sum(counts[observed:])
        result["method"] = "exact"
        result["p_two_sided"] = min(1.0, 2 * min(lower, upper) / (1 << len(nonzero)))
        return result
    mean = (count * (count + 1) - zeros * (zeros + 1)) / 4.0
    ties = sum(size**3 - size for size in _tie_sizes(abs(value) for _, value in nonzero))
    variance = (count * (count + 1) * (2 * count + 1) - zeros * (zeros + 1) * (2 * zeros + 1)) / 24.0 - ties / 48.0
    result["method"] = "normal"
    result["mean"] = mean
    result["variance"] = variance
    if variance <= 0.0:
        return result
    z = (w_plus - mean) / math.sqrt(variance)
    result["z"] = z
    result["p_two_sided"] = min(1.0, math.erfc(abs(z) / math.sqrt(2.0)))
    return result


def sign_test(faster: int, slower: int) -> dict[str, Any]:
    """Exact two-sided binomial sign test (p = 1/2) over rows that are not tied."""
    trials = faster + slower
    result: dict[str, Any] = {"n": trials, "faster": faster, "slower": slower, "p_two_sided": 1.0}
    if trials == 0:
        return result
    smaller = min(faster, slower)
    term = 1
    tail = 1
    for index in range(1, smaller + 1):
        term = term * (trials - index + 1) // index
        tail += term
    result["p_two_sided"] = min(1.0, 2 * tail / (1 << trials))
    return result


def jackknife_acceleration(values: Sequence[float]) -> float | None:
    """BCa acceleration a = sum(d^3) / (6 * sum(d^2)^1.5) with d_i = mean(theta_(.)) - theta_(i)."""
    count = len(values)
    if count < 2:
        return None
    mean = math.fsum(values) / count
    deltas = [mean - value for value in values]
    squares = math.fsum(delta * delta for delta in deltas)
    if squares == 0.0:
        return 0.0
    return math.fsum(delta * delta * delta for delta in deltas) / (6.0 * squares**1.5)


def bca_bounds(
    point: float, ordered: Sequence[float], jackknife: Sequence[float], alpha: float = ALPHA
) -> dict[str, Any]:
    """Bias-corrected and accelerated bootstrap bounds from ascending replicates and jackknife values."""
    count = len(ordered)
    if count == 0:
        return {"defined": False, "reason": "no bootstrap replicates"}
    acceleration = jackknife_acceleration(jackknife)
    if acceleration is None:
        return {"defined": False, "reason": "the jackknife needs at least 2 rows"}
    less = bisect_left(ordered, point)
    ties = bisect_right(ordered, point) - less
    proportion = min(1.0 - 0.5 / count, max(0.5 / count, (less + 0.5 * ties) / count))
    z0 = _NORMAL.inv_cdf(proportion)
    adjusted: list[float] = []
    for tail in (alpha / 2.0, 1.0 - alpha / 2.0):
        shifted = z0 + _NORMAL.inv_cdf(tail)
        denominator = 1.0 - acceleration * shifted
        if denominator <= 0.0:
            return {
                "defined": False,
                "reason": "BCa transform is singular: 1 - a*(z0 + z) <= 0",
                "z0": z0,
                "acceleration": acceleration,
            }
        adjusted.append(_normal_cdf(z0 + shifted / denominator))
    return {
        "defined": True,
        "low": quantile(ordered, adjusted[0]),
        "high": quantile(ordered, adjusted[1]),
        "z0": z0,
        "acceleration": acceleration,
        "adjusted_probabilities": adjusted,
        "reason": None,
    }


def bootstrap_interval(
    point: float,
    replicates: Sequence[float],
    jackknife: Sequence[float],
    *,
    null: float,
    exponentiate: bool = False,
) -> dict[str, Any]:
    """Percentile and BCa intervals; BCa is primary when defined. `exponentiate` maps log-scale bounds to ratios."""
    ordered = sorted(replicates)
    bca = bca_bounds(point, ordered, jackknife)
    scale = math.exp if exponentiate else float
    percentile = [scale(quantile(ordered, ALPHA / 2.0)), scale(quantile(ordered, 1.0 - ALPHA / 2.0))]
    bca_pair = [scale(bca["low"]), scale(bca["high"])] if bca["defined"] else None
    low, high = bca_pair if bca_pair is not None else percentile
    return {
        "method": "bca" if bca_pair is not None else "percentile",
        "low": low,
        "high": high,
        "null": null,
        "excludes_null": not low <= null <= high,
        "percentile": percentile,
        "bca": bca_pair,
        "bca_z0": bca.get("z0"),
        "bca_acceleration": bca.get("acceleration"),
        "bca_adjusted_probabilities": bca.get("adjusted_probabilities"),
        "bca_reason": bca.get("reason"),
        "resamples": len(ordered),
        "statistic_scale": "log" if exponentiate else "linear",
        "bootstrap_se": _stdev(ordered),
    }


def _pair_seed(seed: int, base: str, cand: str) -> int:
    digest = hashlib.sha256(f"paired_stats\0{seed}\0{base}\0{cand}".encode()).digest()
    return int.from_bytes(digest[:8], "big")


def paired_bootstrap(
    base: Sequence[float], cand: Sequence[float], logs: Sequence[float], resamples: int, rng_seed: int
) -> tuple[list[float], list[float], list[float]]:
    """Row bootstrap: each replicate draws n row indices floor(U * n) from random.Random(rng_seed).random()."""
    count = len(base)
    draw = random.Random(rng_seed).random
    fsum = math.fsum
    positions = range(count)
    ratios = [0.0] * resamples
    log_means = [0.0] * resamples
    savings = [0.0] * resamples
    for replicate in range(resamples):
        pick = itemgetter(*[int(draw() * count) for _ in positions])
        base_sum = fsum(pick(base))
        cand_sum = fsum(pick(cand))
        ratios[replicate] = cand_sum / base_sum
        log_means[replicate] = fsum(pick(logs)) / count
        savings[replicate] = (base_sum - cand_sum) / count
    return ratios, log_means, savings


# ---------------------------------------------------------------------------------------------------------------------
# Input


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    try:
        return float(value)
    except OverflowError:
        return math.inf if value > 0 else -math.inf


def _finite(value: Any) -> float | None:
    number = _number(value)
    return number if number is not None and math.isfinite(number) else None


def _integer(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def _label(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _row_id(value: Any, where: str) -> str:
    if isinstance(value, bool) or not isinstance(value, str | int) or value == "":
        raise InputError(f"{where}: 'row_id' must be a non-empty string or an integer")
    return str(value)


def _pass_index(value: Any, where: str) -> int:
    number = _integer(value)
    if number is None or number < 0:
        raise InputError(f"{where}: 'pass' must be a non-negative integer")
    return number


def _positive_audio(value: Any) -> float | None:
    number = _finite(value)
    return number if number is not None and number > 0.0 else None


def _runtime_fault(work: Any) -> str | None:
    """Why the timed call failed at run time (`work.error`, or `work.non_finite` > 0), else None. Such a row is not a
    timing: whatever `elapsed_us` it carries measured a call that did not produce a valid output."""
    if not isinstance(work, dict):
        return None
    error = work.get("error")
    if error:
        text = error if isinstance(error, str) else json.dumps(error, sort_keys=True, ensure_ascii=False)
        return "error: " + " ".join(text.split())[:FAULT_MESSAGE_LIMIT]
    flagged = work.get("non_finite")
    if flagged is True:
        return "non_finite: true"
    count = _number(flagged)
    if count is not None and (count > 0.0 or math.isnan(count)):
        return f"non_finite: {count:g}"
    return None


def _invalid_reason(raw: Any, elapsed: float | None) -> str:
    if raw is None:
        return "missing"
    if elapsed is None:
        return "non_numeric"
    if not math.isfinite(elapsed):
        return "non_finite"
    return "zero" if elapsed == 0.0 else "negative"


def _parse_timing(
    obj: dict[str, Any],
    where: str,
    source: int,
    corpus: str | None,
    bet: str | None,
    bets_by_arm: dict[str, set[str]],
    invalid: list[dict[str, Any]],
) -> tuple[tuple[str, str, int], TimingSample | None]:
    """The row's grid key and its sample. The sample is None when `elapsed_us` is unusable (recorded in `invalid`),
    and carries `runtime_error` (with a NaN elapsed) when the call failed at run time."""
    arm = obj.get("arm")
    if not isinstance(arm, str) or not arm:
        raise InputError(f"{where}: timing row needs a non-empty string 'arm'")
    row_id = _row_id(obj.get("row_id"), where)
    pass_index = _pass_index(obj.get("pass"), where)
    row_bet = _label(obj.get("bet"))
    row_bet = bet if row_bet is None else row_bet
    if row_bet is not None:
        bets_by_arm.setdefault(arm, set()).add(row_bet)
    if obj.get("corpus") is not None:
        corpus = _label(obj.get("corpus"))
    digest = obj.get("output_sha256")
    if digest is not None and not isinstance(digest, str):
        raise InputError(f"{where}: 'output_sha256' must be a string or null")
    equal_ref = obj.get("equal_ref")
    if equal_ref is not None and not isinstance(equal_ref, bool):
        raise InputError(f"{where}: 'equal_ref' must be true, false or null")
    err = obj.get("err")
    if err is not None and not isinstance(err, dict):
        raise InputError(f"{where}: 'err' must be an object or null")
    key = (arm, row_id, pass_index)
    raw_elapsed = obj.get("elapsed_us")
    elapsed = _number(raw_elapsed)
    fault = _runtime_fault(obj.get("work"))
    if fault is None and (elapsed is None or not math.isfinite(elapsed) or elapsed <= 0.0):
        invalid.append(
            {
                "where": where,
                "arm": arm,
                "row_id": row_id,
                "pass": pass_index,
                "elapsed_us": str(raw_elapsed),
                "reason": _invalid_reason(raw_elapsed, elapsed),
            }
        )
        return key, None
    return key, TimingSample(
        source=source,
        where=where,
        arm=arm,
        row_id=row_id,
        corpus=corpus,
        pass_index=pass_index,
        seq=_finite(obj.get("seq")),
        elapsed_us=math.nan if fault is not None or elapsed is None else elapsed,
        output_sha256=digest,
        equal_ref=equal_ref,
        audio_s=_positive_audio(obj.get("audio_s")),
        err_max_abs=None if err is None else _number(err.get("max_abs")),
        err_rel_l2=None if err is None else _number(err.get("rel_l2")),
        runtime_error=fault,
    )


def _parse_stage(obj: dict[str, Any], where: str, source: int, corpus: str | None) -> StageSample:
    row_id = _row_id(obj.get("row_id"), where)
    pass_index = _pass_index(obj.get("pass"), where)
    raw_stages = obj.get("stages_us")
    if not isinstance(raw_stages, dict) or not raw_stages:
        raise InputError(f"{where}: stage_profile row needs a non-empty object 'stages_us'")
    stages: dict[str, float] = {}
    for name, value in raw_stages.items():
        if name == UNATTRIBUTED_STAGE:
            raise InputError(f"{where}: stage name {UNATTRIBUTED_STAGE!r} is reserved for the analyzer")
        number = _finite(value)
        if number is None or number < 0.0:
            raise InputError(f"{where}: stages_us[{name!r}] must be a finite number >= 0")
        stages[name] = number
    raw_counts = obj.get("counts")
    if raw_counts is not None and not isinstance(raw_counts, dict):
        raise InputError(f"{where}: 'counts' must be an object or null")
    counts = {}
    for name, value in (raw_counts or {}).items():
        number = _finite(value)
        if number is not None:
            counts[name] = number
    arm = obj.get("arm")
    if obj.get("corpus") is not None:
        corpus = _label(obj.get("corpus"))
    return StageSample(
        source=source,
        where=where,
        group=arm if isinstance(arm, str) and arm else "all",
        row_id=row_id,
        corpus=corpus,
        pass_index=pass_index,
        audio_s=_positive_audio(obj.get("audio_s")),
        stages_us=stages,
        counts=counts,
    )


def _assign_rows(samples: Sequence[TimingSample | StageSample]) -> dict[str, Any]:
    """Row identity is row_id; it becomes "<corpus>/<row_id>" when the inputs mix corpora (ids may collide)."""
    corpora = sorted({sample.corpus for sample in samples}, key=lambda value: (value is None, value or ""))
    namespaced = len(corpora) > 1
    for sample in samples:
        corpus = sample.corpus if sample.corpus is not None else "?"
        sample.row = f"{corpus}/{sample.row_id}" if namespaced else sample.row_id
    return {"key": "corpus/row_id" if namespaced else "row_id", "corpora": corpora}


def load_inputs(paths: Sequence[str]) -> Dataset:
    inputs: list[InputFile] = []
    timing: list[TimingSample] = []
    stages: list[StageSample] = []
    invalid: list[dict[str, Any]] = []
    runtime_errors: list[TimingSample] = []
    segments: list[RunSegment] = []
    bets_by_arm: dict[str, set[str]] = {}
    for source, path in enumerate(paths):
        try:
            data = Path(path).read_bytes()
        except OSError as error:
            raise InputError(f"{path}: cannot read ({error.strerror or error})") from error
        info = InputFile(path=path, sha256=hashlib.sha256(data).hexdigest())
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError as error:
            raise InputError(f"{path}: not valid UTF-8 ({error.reason} at byte {error.start})") from error
        corpus: str | None = None
        bet: str | None = None
        segment = RunSegment(source=source, path=path)
        file_segments = [segment]
        for line_number, raw_line in enumerate(text.split("\n"), start=1):
            line = raw_line.strip()
            if not line:
                continue
            info.lines += 1
            where = f"{path}:{line_number}"
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as error:
                raise InputError(f"{where}: invalid JSON ({error.msg})") from error
            if not isinstance(obj, dict):
                raise InputError(f"{where}: expected a JSON object")
            kind = obj.get("type")
            if kind == "run_meta":
                info.run_meta.append(obj)
                if not segment.is_empty():
                    segment = RunSegment(source=source, path=path)
                    file_segments.append(segment)
                segment.meta = obj
                segment.meta_line = line_number
                corpus = _label(obj.get("corpus"))
                bet = _label(obj.get("bet"))
            elif kind == "run_end":
                info.run_end.append(obj)
                segment.run_ends.append(obj)
            elif kind == "timing":
                info.timing_rows += 1
                key, sample = _parse_timing(obj, where, source, corpus, bet, bets_by_arm, invalid)
                segment.timing_keys.append(key)
                segment.rows_after_end += 1 if segment.run_ends else 0
                if sample is None:
                    continue
                if sample.runtime_error is not None:
                    runtime_errors.append(sample)
                    segment.runtime_error_rows += 1
                else:
                    timing.append(sample)
            elif kind == "stage_profile":
                info.stage_profile_rows += 1
                stage = _parse_stage(obj, where, source, corpus)
                stages.append(stage)
                segment.stage_keys.append((stage.group, stage.row_id, stage.pass_index))
                segment.rows_after_end += 1 if segment.run_ends else 0
            else:
                name = "<missing>" if kind is None else str(kind)
                info.ignored_types[name] = info.ignored_types.get(name, 0) + 1
        segments.extend(item for item in file_segments if not item.is_empty())
        inputs.append(info)
    collisions = {arm: sorted(bets) for arm, bets in bets_by_arm.items() if len(bets) > 1}
    if collisions:
        detail = "; ".join(f"{arm}: {', '.join(bets)}" for arm, bets in sorted(collisions.items()))
        raise InputError(f"arm names repeat across bets ({detail}); analyze one bet per invocation")
    return Dataset(
        inputs=inputs,
        timing=timing,
        stages=stages,
        invalid_timing=invalid,
        timing_rows=_assign_rows([*timing, *runtime_errors]),
        stage_rows=_assign_rows(stages),
        segments=segments,
        runtime_errors=runtime_errors,
    )


# ---------------------------------------------------------------------------------------------------------------------
# Run integrity: declared grid, completion footer, provenance


def _cells(keys: Sequence[tuple[str, str, int]]) -> str:
    return ", ".join("(" + ", ".join(str(part) for part in key) + ")" for key in keys[:GRID_EXAMPLES])


def _check_grid(
    keys: Sequence[tuple[str, str, int]], declared_groups: Sequence[str] | None, passes: int, kind: str
) -> tuple[dict[str, Any], list[str]]:
    """Every declared (group, row_id, pass) cell exactly once.

    Rows are the ids that appear anywhere in the file (a row missing from every arm cannot be seen from the file
    alone), groups are the declared arms (timing) or the observed groups (stage_profile), passes are 0..passes."""
    counts = Counter(keys)
    duplicates = [key for key, count in counts.items() if count > 1]
    observed = _first_seen(key[0] for key in keys)
    groups = list(declared_groups) if declared_groups is not None else observed
    rows = sorted({key[1] for key in keys}, key=natural_key)
    name = "arm" if kind == "timing" else "group"
    problems: list[str] = []
    if duplicates:
        problems.append(f"{len(duplicates)} duplicate ({name}, row_id, pass) keys (first: {_cells(duplicates)})")
    if declared_groups is not None:
        seen_groups = set(observed)
        declared_set = set(groups)
        never_written = [group for group in groups if group not in seen_groups]
        undeclared = [group for group in observed if group not in declared_set]
        if never_written or undeclared:
            problems.append(
                f"the arms written differ from run_meta.arms: declared but never written {never_written or 'none'}; "
                f"written but not declared {undeclared or 'none'}"
            )
    beyond = sorted({key[2] for key in keys if key[2] > passes})
    if beyond:
        problems.append(f"pass indices {beyond[:5]} exceed run_meta.passes={passes} (a run writes passes 0..{passes})")
    expected = len(groups) * len(rows) * (passes + 1)
    missing = [
        (group, row, index)
        for group in groups
        for row in rows
        for index in range(passes + 1)
        if (group, row, index) not in counts
    ]
    if missing:
        problems.append(
            f"incomplete grid: {expected - len(missing)} of {expected} declared cells written "
            f"({len(groups)} {name}(s) x {len(rows)} rows x {passes + 1} passes; {len(missing)} missing, "
            f"first: {_cells(missing)})"
        )
    report = {
        "groups": len(groups),
        "rows": len(rows),
        "passes": passes,
        "expected_cells": expected,
        "written_keys": len(keys),
        "missing_cells": len(missing),
        "duplicate_keys": len(duplicates),
        "complete": not problems,
    }
    return report, problems


def _check_run_end(
    end: dict[str, Any],
    counted: int,
    grid_cells: int | None,
    runtime_error_rows: int,
    completion_required: bool,
    strict: bool,
    where: str,
    warnings: _Warnings,
) -> list[str]:
    problems: list[str] = []
    expected = _integer(end.get("expected_timing_rows"))
    written = _integer(end.get("written_timing_rows"))
    if written is None:
        written = _integer(end.get("timing_rows"))
    if expected is None or expected < 0:
        problems.append("run_end has no non-negative integer expected_timing_rows")
    if written is None or written < 0:
        problems.append("run_end has no non-negative integer written_timing_rows")
    if expected is not None and expected >= 0 and written is not None and written >= 0:
        if written != counted:
            problems.append(f"run_end.written_timing_rows={written} but the file holds {counted} timing rows")
        if expected != written:
            problems.append(f"run_end reports {written} of {expected} expected timing rows written")
        if grid_cells is not None and expected != grid_cells:
            problems.append(
                f"run_end.expected_timing_rows={expected} but run_meta's arms x rows x (passes + 1) = {grid_cells}"
            )
    status = end.get("status")
    if isinstance(status, str) and status.strip().lower() in INVALID_RUN_STATUSES:
        problems.append(f"run_end.status is {status!r}")
    raw_failures = end.get("failures", end.get("failed_calls"))
    failures = _integer(raw_failures)
    if raw_failures is None:
        if completion_required:
            problems.append("run_end has no failures count")
    elif failures is None or failures < 0:
        problems.append("run_end.failures must be a non-negative integer")
    else:
        if failures > 0:
            message = f"{where}: run_end reports {failures} failed calls"
            if strict:
                problems.append(f"run_end reports {failures} failed calls")
            else:
                warnings.add("run_reported_failures", message)
        if failures != runtime_error_rows:
            warnings.add(
                "run_failures_mismatch",
                f"{where}: run_end reports {failures} failures but {runtime_error_rows} timing rows carry a "
                "runtime error (work.error / work.non_finite)",
            )
    return problems


def _check_provenance(meta: dict[str, Any], where: str, warnings: _Warnings) -> None:
    host = meta.get("host")
    power = host.get("power") if isinstance(host, dict) else None
    if not isinstance(power, str) or not power.strip():
        warnings.add("non_ac_power", f"{where}: run_meta.host.power is missing; AC power cannot be confirmed")
    else:
        lowered = power.strip().lower()
        if lowered != "ac" and not lowered.startswith("ac "):
            warnings.add(
                "non_ac_power",
                f"{where}: run_meta.host.power is {power!r}, not AC; battery runs can be throttled or power-capped, "
                "so absolute times and ratios are not comparable with AC runs",
            )
    digest = meta.get("executable_sha256")
    if not (isinstance(digest, str) and len(digest) == 64 and all(char in "0123456789abcdefABCDEF" for char in digest)):
        warnings.add(
            "no_executable_fingerprint",
            f"{where}: run_meta has no executable_sha256, so the binary that produced these rows is not identified",
        )


def _check_segment(segment: RunSegment, warnings: _Warnings, strict: bool) -> tuple[dict[str, Any], list[str]]:
    meta = segment.meta
    where = segment.path if segment.meta_line is None else f"{segment.path}:{segment.meta_line}"
    timing_rows = len(segment.timing_keys)
    stage_rows = len(segment.stage_keys)
    passes: int | None = None
    arms: list[str] | None = None
    completion_required = False
    if meta is not None:
        _check_provenance(meta, where, warnings)
        passes = _integer(meta.get("passes"))
        if passes is not None and passes < 0:
            passes = None
        raw_arms = meta.get("arms")
        if (
            isinstance(raw_arms, list)
            and raw_arms
            and all(isinstance(arm, str) and arm for arm in raw_arms)
            and len(set(raw_arms)) == len(raw_arms)
        ):
            arms = list(raw_arms)
        completion_required = meta.get("completion_required") is True
    problems: list[str] = []
    grid: dict[str, Any] | None = None
    unchecked: str | None = None
    if meta is None:
        if timing_rows or stage_rows:
            unchecked = "the file has no run_meta line"
    elif timing_rows:
        if passes is None or arms is None:
            unchecked = "run_meta declares no integer passes and non-empty arms list"
        else:
            grid, found = _check_grid(segment.timing_keys, arms, passes, "timing")
            problems.extend(found)
    elif stage_rows:
        if passes is None:
            unchecked = "run_meta declares no integer passes"
        else:
            grid, found = _check_grid(segment.stage_keys, None, passes, "stage_profile")
            problems.extend(found)
    if unchecked is not None:
        if completion_required:
            problems.append(f"completion_required is true but the declared grid cannot be checked: {unchecked}")
        else:
            warnings.add(
                "incomplete_provenance",
                f"{where}: the declared grid cannot be checked ({unchecked}); a truncated or partial run would pass",
            )
    footer = "missing"
    if segment.run_ends:
        if len(segment.run_ends) > 1:
            problems.append(f"{len(segment.run_ends)} run_end footers in one run")
        if segment.rows_after_end:
            problems.append(f"{segment.rows_after_end} timing/stage_profile rows follow the run_end footer")
        found = _check_run_end(
            segment.run_ends[-1],
            timing_rows or stage_rows,
            grid["expected_cells"] if grid is not None and timing_rows else None,
            segment.runtime_error_rows,
            completion_required,
            strict,
            where,
            warnings,
        )
        problems.extend(found)
        footer = "invalid" if found or len(segment.run_ends) > 1 or segment.rows_after_end else "valid"
    elif completion_required:
        problems.append("run_meta.completion_required is true but the file has no run_end footer (interrupted run)")
    if strict and segment.runtime_error_rows:
        problems.append(
            f"{segment.runtime_error_rows} timing rows report a runtime error or non-finite output "
            "(work.error / work.non_finite)"
        )
    if footer == "valid" and grid is not None and not problems:
        status = "verified"
    elif footer == "missing" and grid is not None and not problems:
        status = "grid_only"
        warnings.add(
            "incomplete_provenance",
            f"{where}: the declared grid is complete, but the run wrote no run_end footer (a legacy harness), so "
            "nothing proves that whole rows or arms were not left out: the grid is checked only against the rows "
            "and arms that appear",
        )
    elif problems:
        status = "failed"
    else:
        status = "footer_only" if footer == "valid" else "unchecked"
    report = {
        "path": segment.path,
        "run_meta_line": segment.meta_line,
        "completion_required": completion_required,
        "timing_rows": timing_rows,
        "stage_profile_rows": stage_rows,
        "grid": grid,
        "footer": footer,
        "runtime_error_rows": segment.runtime_error_rows,
        "status": status,
    }
    return report, problems


def check_integrity(dataset: Dataset, warnings: _Warnings, strict: bool) -> list[dict[str, Any]]:
    """Refuse an incomplete or inconsistent run (InputError); warn about weak provenance. One report per run."""
    reports: list[dict[str, Any]] = []
    problems: list[str] = []
    for segment in dataset.segments:
        report, found = _check_segment(segment, warnings, strict)
        reports.append(report)
        problems.extend(f"{segment.path}: {item}" for item in found)
    if problems:
        shown = "; ".join(problems[:INTEGRITY_PROBLEM_LIMIT])
        more = len(problems) - INTEGRITY_PROBLEM_LIMIT
        raise InputError(
            "run integrity check failed, refusing to analyze an incomplete or invalid run: "
            + shown
            + (f"; (+{more} more)" if more > 0 else "")
        )
    return reports


# ---------------------------------------------------------------------------------------------------------------------
# Timing analysis


def _id_list(ids: Sequence[str]) -> dict[str, Any]:
    return {"count": len(ids), "row_ids": list(ids[:ID_LIST_LIMIT])}


def _arm_rows(rows: dict[str, list[TimingSample]], aggregate: str, include_warmup: bool) -> dict[str, ArmRow]:
    built: dict[str, ArmRow] = {}
    for row, samples in rows.items():
        timed = [sample.elapsed_us for sample in samples if include_warmup or sample.pass_index != 0]
        if not timed:
            continue
        refs = [sample.equal_ref for sample in samples if sample.equal_ref is not None]
        built[row] = ArmRow(
            value=_aggregate(timed, aggregate),
            samples=len(timed),
            hashes=frozenset(sample.output_sha256 for sample in samples if sample.output_sha256 is not None),
            equal_ref=all(refs) if refs else None,
            err_max_abs=tuple(sample.err_max_abs for sample in samples if sample.err_max_abs is not None),
            err_rel_l2=tuple(sample.err_rel_l2 for sample in samples if sample.err_rel_l2 is not None),
        )
    return built


def _audio_by_row(samples: Sequence[TimingSample], warnings: _Warnings) -> dict[str, float]:
    audio: dict[str, float] = {}
    conflicts: list[str] = []
    for sample in samples:
        if sample.audio_s is None:
            continue
        known = audio.setdefault(sample.row, sample.audio_s)
        if abs(known - sample.audio_s) > AUDIO_S_RELATIVE_TOLERANCE * max(known, sample.audio_s):
            conflicts.append(sample.row)
    if conflicts:
        rows = sorted(set(conflicts), key=natural_key)
        warnings.add(
            "audio_s_inconsistent",
            f"audio_s differs between samples of {len(rows)} rows (first: {', '.join(rows[:5])}); "
            "the first value in input order is used",
        )
    return audio


def _value_stats(rows: Sequence[str], values: Sequence[float], audio: dict[str, float]) -> dict[str, Any]:
    with_audio = [(value, audio[row]) for row, value in zip(rows, values, strict=True) if row in audio]
    stats: dict[str, Any] = {"elapsed_us": describe(values), "audio_rows": len(with_audio)}
    if with_audio:
        audio_total = math.fsum(seconds for _, seconds in with_audio)
        stats["audio_s_total"] = audio_total
        stats["us_per_audio_s"] = describe(value / seconds for value, seconds in with_audio)
        stats["total_us_per_audio_s"] = math.fsum(value for value, _ in with_audio) / audio_total
    else:
        stats["audio_s_total"] = None
        stats["us_per_audio_s"] = None
        stats["total_us_per_audio_s"] = None
    return stats


def _err_max(rows: Sequence[str], built: dict[str, ArmRow], attribute: str) -> dict[str, Any] | None:
    best: float | None = None
    best_row: str | None = None
    samples = 0
    nonfinite = 0
    for row in rows:
        for value in getattr(built[row], attribute):
            samples += 1
            if not math.isfinite(value):
                nonfinite += 1
            elif best is None or value > best:
                best, best_row = value, row
    if samples == 0:
        return None
    return {"samples": samples, "max": best, "row_id": best_row, "nonfinite_samples": nonfinite}


def _arm_equivalence(rows: Sequence[str], built: dict[str, ArmRow]) -> dict[str, Any]:
    true_rows = [row for row in rows if built[row].equal_ref is True]
    false_rows = [row for row in rows if built[row].equal_ref is False]
    judged = len(true_rows) + len(false_rows)
    return {
        "rows": len(rows),
        "hash_rows": sum(1 for row in rows if built[row].hashes),
        "nondeterministic_rows": _id_list([row for row in rows if len(built[row].hashes) > 1]),
        "equal_ref": {
            "true": len(true_rows),
            "false": len(false_rows),
            "null": len(rows) - judged,
            "rate": len(true_rows) / judged if judged else None,
            "false_rows": _id_list(false_rows),
        },
        "err": {"max_abs": _err_max(rows, built, "err_max_abs"), "rel_l2": _err_max(rows, built, "err_rel_l2")},
    }


def _pair_equivalence(
    rows: Sequence[str], base_rows: dict[str, ArmRow], cand_rows: dict[str, ArmRow]
) -> dict[str, Any]:
    identical = 0
    missing: list[str] = []
    mismatched: list[str] = []
    for row in rows:
        base_hashes = base_rows[row].hashes
        cand_hashes = cand_rows[row].hashes
        if not base_hashes or not cand_hashes:
            missing.append(row)
        elif len(base_hashes) == 1 and base_hashes == cand_hashes:
            identical += 1
        else:
            mismatched.append(row)
    compared = len(rows) - len(missing)
    return {
        "rows": len(rows),
        "compared": compared,
        "identical": identical,
        "identical_rate": identical / compared if compared else None,
        "hash_missing": _id_list(missing),
        "mismatched": _id_list(mismatched),
        "base": _arm_equivalence(rows, base_rows),
        "cand": _arm_equivalence(rows, cand_rows),
    }


def _saving_per_audio(rows: Sequence[str], savings: Sequence[float], audio: dict[str, float]) -> dict[str, Any] | None:
    with_audio = [(saving, audio[row]) for row, saving in zip(rows, savings, strict=True) if row in audio]
    if not with_audio:
        return None
    per_second = sorted(saving / seconds for saving, seconds in with_audio)
    return {
        "rows": len(with_audio),
        "mean": math.fsum(per_second) / len(per_second),
        "p50": quantile(per_second, 0.5),
        "total": math.fsum(saving for saving, _ in with_audio) / math.fsum(seconds for _, seconds in with_audio),
    }


def _speed(
    rows: Sequence[str], base: list[float], cand: list[float], audio: dict[str, float], rng_seed: int, resamples: int
) -> dict[str, Any]:
    count = len(base)
    base_sum = math.fsum(base)
    cand_sum = math.fsum(cand)
    ratios = [c / b for b, c in zip(base, cand, strict=True)]
    logs = [math.log(ratio) for ratio in ratios]
    savings = [b - c for b, c in zip(base, cand, strict=True)]
    faster = sum(1 for b, c in zip(base, cand, strict=True) if c < b)
    slower = sum(1 for b, c in zip(base, cand, strict=True) if c > b)
    log_sum = math.fsum(logs)
    total_ratio = cand_sum / base_sum
    mean_log = log_sum / count
    mean_saving = (base_sum - cand_sum) / count
    ratio_ci = geomean_ci = saving_ci = None
    if count >= 2:
        boot_ratio, boot_log, boot_saving = paired_bootstrap(base, cand, logs, resamples, rng_seed)
        jack_ratio = [(cand_sum - c) / (base_sum - b) for b, c in zip(base, cand, strict=True)]
        jack_log = [(log_sum - value) / (count - 1) for value in logs]
        jack_saving = [((base_sum - b) - (cand_sum - c)) / (count - 1) for b, c in zip(base, cand, strict=True)]
        ratio_ci = bootstrap_interval(total_ratio, boot_ratio, jack_ratio, null=1.0)
        geomean_ci = bootstrap_interval(mean_log, boot_log, jack_log, null=1.0, exponentiate=True)
        saving_ci = bootstrap_interval(mean_saving, boot_saving, jack_saving, null=0.0)
    return {
        "base_total_us": base_sum,
        "cand_total_us": cand_sum,
        "total_ratio": {"point": total_ratio, "ci95": ratio_ci},
        "geomean_ratio": {"point": math.exp(mean_log), "mean_log_ratio": mean_log, "ci95": geomean_ci},
        "median_ratio": quantile(sorted(ratios), 0.5),
        "rows_faster": faster,
        "rows_slower": slower,
        "rows_tied": count - faster - slower,
        "fraction_faster": faster / count,
        "wilcoxon": wilcoxon_signed_rank(logs),
        "sign_test": sign_test(faster, slower),
        "saving_us": {
            "mean": mean_saving,
            "p50": quantile(sorted(savings), 0.5),
            "total": base_sum - cand_sum,
            "ci95_mean": saving_ci,
        },
        "saving_us_per_audio_s": _saving_per_audio(rows, savings, audio),
    }


def _is_aa(base: str, cand: str) -> bool:
    return cand == base + AA_SUFFIX or base == cand + AA_SUFFIX


def _split_pair(spec: str, known: set[str]) -> tuple[str, str]:
    splits = [(spec[:index], spec[index + 1 :]) for index, char in enumerate(spec) if char == ":"]
    if not splits:
        raise InputError(f"--pair {spec!r}: expected BASE_ARM:CAND_ARM")
    matches = [(base, cand) for base, cand in splits if base in known and cand in known]
    if len(matches) > 1:
        raise InputError(f"--pair {spec!r} is ambiguous: it splits into known arms in {len(matches)} ways")
    if not matches:
        available = ", ".join(sorted(known, key=natural_key))
        raise InputError(f"--pair {spec!r}: unknown arm; arms in the inputs: {available}")
    base, cand = matches[0]
    if base == cand:
        raise InputError(f"--pair {spec!r}: base and candidate are the same arm")
    return base, cand


def resolve_pairs(specs: Sequence[str], all_vs: str | None, arms: Sequence[str]) -> list[tuple[str, str, str]]:
    """Requested pairs in flag order, then every automatic X vs X@aa pair; duplicates keep their first position."""
    known = set(arms)
    wanted: list[tuple[str, str]] = []
    if all_vs is not None:
        if all_vs not in known:
            raise InputError(f"--all-vs {all_vs!r}: unknown arm; arms in the inputs: {', '.join(arms)}")
        wanted.extend((all_vs, arm) for arm in arms if arm != all_vs and not arm.endswith(AA_SUFFIX))
        if not wanted:
            raise InputError(f"--all-vs {all_vs!r}: the inputs contain no other non-A/A arm")
    wanted.extend(_split_pair(spec, known) for spec in specs)
    wanted.extend(
        (arm[: -len(AA_SUFFIX)], arm) for arm in arms if arm.endswith(AA_SUFFIX) and arm[: -len(AA_SUFFIX)] in known
    )
    seen: set[tuple[str, str]] = set()
    resolved: list[tuple[str, str, str]] = []
    for base, cand in wanted:
        if (base, cand) not in seen:
            seen.add((base, cand))
            resolved.append((base, cand, "aa" if _is_aa(base, cand) else "comparison"))
    return resolved


def analyze_pair(
    base: str,
    cand: str,
    kind: str,
    arm_rows: dict[str, dict[str, ArmRow]],
    audio: dict[str, float],
    seed: int,
    resamples: int,
    warnings: _Warnings,
) -> dict[str, Any]:
    base_rows = arm_rows[base]
    cand_rows = arm_rows[cand]
    common = sorted(base_rows.keys() & cand_rows.keys(), key=natural_key)
    base_only = sorted(base_rows.keys() - cand_rows.keys(), key=natural_key)
    cand_only = sorted(cand_rows.keys() - base_rows.keys(), key=natural_key)
    label = f"{base} vs {cand}"
    result: dict[str, Any] = {
        "label": label,
        "base": base,
        "cand": cand,
        "kind": kind,
        "n": len(common),
        "dropped_rows": {"base_only": _id_list(base_only), "cand_only": _id_list(cand_only)},
        "noise_floor": None,
    }
    if base_only or cand_only:
        warnings.add(
            "dropped_rows",
            f"{label}: compared {len(common)} common rows; dropped {len(base_only)} rows only in {base} "
            f"and {len(cand_only)} rows only in {cand}",
        )
    if not common:
        result["error"] = "no common rows"
        warnings.add("no_common_rows", f"{label}: the arms share no row_id; nothing to compare")
        return result
    if len(common) < SMALL_N_WARNING:
        warnings.add("small_n", f"{label}: only {len(common)} common rows; bootstrap intervals are unreliable")
    base_values = [base_rows[row].value for row in common]
    cand_values = [cand_rows[row].value for row in common]
    result["seed"] = _pair_seed(seed, base, cand)
    result["speed"] = _speed(common, base_values, cand_values, audio, result["seed"], resamples)
    result["base_stats"] = _value_stats(common, base_values, audio)
    result["cand_stats"] = _value_stats(common, cand_values, audio)
    equivalence = _pair_equivalence(common, base_rows, cand_rows)
    result["equivalence"] = equivalence
    if equivalence["compared"] and equivalence["hash_missing"]["count"]:
        warnings.add(
            "hash_missing",
            f"{label}: {equivalence['hash_missing']['count']} common rows lack output_sha256 in one arm; "
            "they are excluded from the identity rate",
        )
    if kind == "aa" and equivalence["mismatched"]["count"]:
        warnings.add(
            "aa_output_mismatch",
            f"{label}: A/A replicate outputs differ on {equivalence['mismatched']['count']} rows (nondeterminism)",
        )
    return result


def _interval_pair(interval: dict[str, Any] | None) -> list[float] | None:
    return None if interval is None else [interval["low"], interval["high"]]


def _attach_noise_floor(results: list[dict[str, Any]], warnings: _Warnings) -> None:
    aa_by_arm: dict[str, dict[str, Any]] = {}
    for pair in results:
        if pair["kind"] != "aa" or "speed" not in pair or pair["cand"] != pair["base"] + AA_SUFFIX:
            continue
        aa_by_arm[pair["base"]] = pair
        interval = pair["speed"]["total_ratio"]["ci95"]
        if interval is not None and interval["excludes_null"]:
            warnings.add(
                "aa_bias",
                f"A/A {pair['label']}: total-ratio CI [{interval['low']:.4f}, {interval['high']:.4f}] excludes 1.0; "
                "identical implementations differ, so order, position or thermal bias is present",
            )
    comparisons = [pair for pair in results if pair["kind"] != "aa" and "speed" in pair]
    if comparisons and not aa_by_arm:
        warnings.add("no_aa", "no X@aa replicate arm in the inputs: the A/A noise floor is unknown")
    for pair in comparisons:
        references = [aa_by_arm[arm] for arm in (pair["base"], pair["cand"]) if arm in aa_by_arm]
        proxy = not references and bool(aa_by_arm)
        if proxy:
            references = [aa_by_arm[arm] for arm in sorted(aa_by_arm, key=natural_key)]
        if not references:
            continue
        checks = []
        for reference in references:
            for metric in ("total_ratio", "geomean_ratio"):
                mine = _interval_pair(pair["speed"][metric]["ci95"])
                theirs = _interval_pair(reference["speed"][metric]["ci95"])
                overlaps = None if mine is None or theirs is None else mine[0] <= theirs[1] and theirs[0] <= mine[1]
                checks.append(
                    {
                        "aa_pair": reference["label"],
                        "metric": metric,
                        "pair_ci": mine,
                        "aa_ci": theirs,
                        "overlaps": overlaps,
                    }
                )
        within = any(check["overlaps"] for check in checks)
        pair["noise_floor"] = {"proxy": proxy, "within_noise_floor": within, "checks": checks}
        if within:
            hits = sorted({f"{check['metric']} vs {check['aa_pair']}" for check in checks if check["overlaps"]})
            warnings.add(
                "within_noise_floor",
                f"{pair['label']}: 95% CI overlaps the A/A noise floor ({'; '.join(hits)})"
                + (" [proxy A/A arm]" if proxy else ""),
            )


def _drift(
    samples: Sequence[TimingSample],
    arm_rows: dict[str, dict[str, ArmRow]],
    include_warmup: bool,
    paths: Sequence[str],
    warnings: _Warnings,
) -> list[dict[str, Any]]:
    groups: dict[tuple[int, str], list[TimingSample]] = {}
    missing_seq = 0
    for sample in samples:
        if not include_warmup and sample.pass_index == 0:
            continue
        if sample.seq is None:
            missing_seq += 1
            continue
        groups.setdefault((sample.source, sample.arm), []).append(sample)
    if missing_seq:
        warnings.add("seq_missing", f"{missing_seq} timed samples have no numeric seq and are left out of drift")
    results = []
    for source, arm in sorted(groups, key=lambda key: (key[0], natural_key(key[1]))):
        members = groups[(source, arm)]
        order = [sample.seq for sample in members]
        rho = spearman(order, [sample.elapsed_us for sample in members])
        normalized = spearman(order, [sample.elapsed_us / arm_rows[arm][sample.row].value for sample in members])
        warn = any(value is not None and abs(value) > DRIFT_RHO_THRESHOLD for value in (rho, normalized))
        results.append(
            {
                "source": paths[source],
                "arm": arm,
                "n": len(members),
                "rho": rho,
                "rho_row_normalized": normalized,
                "warn": warn,
            }
        )
        if warn:
            warnings.add(
                "drift",
                f"{paths[source]} {arm}: Spearman rho vs seq = {_format_optional(rho)} "
                f"(row-normalized {_format_optional(normalized)}) exceeds |{DRIFT_RHO_THRESHOLD}|",
            )
    return results


def _format_optional(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.3f}"


def _refuse_pooled_arms(dataset: Dataset) -> None:
    """The same (arm, row_id, pass) in two input files is two runs of one arm; pooling them would merge replicates of a
    baseline or A/A arm taken in different processes."""
    owner: dict[tuple[str, str, int], int] = {}
    clashes: dict[str, set[int]] = {}
    example: dict[str, tuple[str, int]] = {}
    for sample in (*dataset.timing, *dataset.runtime_errors):
        key = (sample.arm, sample.row, sample.pass_index)
        first = owner.setdefault(key, sample.source)
        if first != sample.source:
            clashes.setdefault(sample.arm, {first}).add(sample.source)
            example.setdefault(sample.arm, (sample.row, sample.pass_index))
    if clashes:
        paths = [info.path for info in dataset.inputs]
        detail = "; ".join(
            f"{arm} in {', '.join(paths[index] for index in sorted(sources))} "
            f"(e.g. row {example[arm][0]}, pass {example[arm][1]})"
            for arm, sources in sorted(clashes.items(), key=lambda item: natural_key(item[0]))
        )
        raise InputError(
            f"the same (arm, row_id, pass) appears in more than one input file: {detail}; rows of one arm from "
            "different runs are never pooled (that would merge replicates of a baseline or A/A arm taken in "
            "different processes): analyze each run's file separately"
        )


def _runtime_error_summary(errors: Sequence[TimingSample], include_warmup: bool) -> dict[str, Any]:
    by_arm: dict[str, dict[str, Any]] = {}
    for sample in errors:
        entry = by_arm.setdefault(
            sample.arm,
            {
                "samples": 0,
                "rows": set(),
                "dropped_rows": set(),
                "passes": set(),
                "kinds": {},
                "first": sample.runtime_error,
            },
        )
        entry["samples"] += 1
        entry["rows"].add(sample.row)
        entry["passes"].add(sample.pass_index)
        if include_warmup or sample.pass_index != 0:
            entry["dropped_rows"].add(sample.row)
        kind = (sample.runtime_error or "").split(":", 1)[0]
        entry["kinds"][kind] = entry["kinds"].get(kind, 0) + 1
    return {
        "count": len(errors),
        "by_arm": {
            arm: {
                "samples": entry["samples"],
                "rows": len(entry["rows"]),
                "dropped_rows": len(entry["dropped_rows"]),
                "passes": sorted(entry["passes"]),
                "kinds": dict(sorted(entry["kinds"].items())),
                "first": entry["first"],
            }
            for arm, entry in sorted(by_arm.items(), key=lambda item: natural_key(item[0]))
        },
        "examples": [
            {"where": s.where, "arm": s.arm, "row_id": s.row, "pass": s.pass_index, "runtime_error": s.runtime_error}
            for s in errors[:ID_LIST_LIMIT]
        ],
    }


def analyze_timing(
    dataset: Dataset,
    pair_specs: Sequence[str],
    all_vs: str | None,
    aggregate: str,
    include_warmup: bool,
    seed: int,
    resamples: int,
    warnings: _Warnings,
) -> dict[str, Any]:
    runtime_errors = dataset.runtime_errors
    if not dataset.timing:
        detail = f" ({len(runtime_errors)} runtime-error rows excluded)" if runtime_errors else ""
        raise InputError("the inputs contain no valid timing rows" + detail)
    _refuse_pooled_arms(dataset)
    # A row whose call failed in a timed pass is dropped for that arm: its other passes would be survivors of a
    # failing implementation, and the pair would silently compare only the rows where the candidate happened to run.
    failed = {(s.arm, s.row) for s in runtime_errors if include_warmup or s.pass_index != 0}
    samples = [sample for sample in dataset.timing if (sample.arm, sample.row) not in failed]
    if not samples:
        raise InputError(
            f"no usable timing rows remain: {len(runtime_errors)} timing rows report a runtime error "
            "(work.error / work.non_finite) and every row is dropped"
        )
    arm_names = sorted(
        {sample.arm for sample in dataset.timing}
        | {sample.arm for sample in runtime_errors}
        | {str(item["arm"]) for item in dataset.invalid_timing},
        key=natural_key,
    )
    grouped: dict[str, dict[str, list[TimingSample]]] = {arm: {} for arm in arm_names}
    for sample in samples:
        grouped[sample.arm].setdefault(sample.row, []).append(sample)
    arm_rows = {arm: _arm_rows(grouped[arm], aggregate, include_warmup) for arm in arm_names}
    if not any(arm_rows.values()):
        raise InputError("every valid timing row is warmup pass 0; pass --include-warmup to analyze warmups")
    audio = _audio_by_row(samples, warnings)
    duplicates = sum(size - 1 for size in Counter((s.arm, s.row, s.pass_index) for s in samples).values() if size > 1)
    if duplicates:
        warnings.add(
            "duplicate_samples",
            f"{duplicates} timing samples repeat an (arm, row_id, pass) key; every sample enters the aggregate",
        )
    error_summary = _runtime_error_summary(runtime_errors, include_warmup)
    if runtime_errors:
        detail = "; ".join(
            f"{arm}: {item['samples']} samples on {item['rows']} rows ({item['dropped_rows']} rows dropped)"
            for arm, item in error_summary["by_arm"].items()
        )
        warnings.add(
            "runtime_errors",
            f"{len(runtime_errors)} timing rows report a runtime error or non-finite output (work.error / "
            f"work.non_finite) and enter no statistic; they are counted here, never as zero time. {detail}. Rows with "
            "such a timed sample are dropped for that arm, so its pairs cover only rows where it ran cleanly",
        )
    zero_elapsed = sum(1 for item in dataset.invalid_timing if item.get("reason") == "zero")
    timed_by_arm: dict[str, list[TimingSample]] = {arm: [] for arm in arm_names}
    for sample in samples:
        if include_warmup or sample.pass_index != 0:
            timed_by_arm[sample.arm].append(sample)
    arms: dict[str, dict[str, Any]] = {}
    for arm in arm_names:
        built = arm_rows[arm]
        rows = sorted(built, key=natural_key)
        summary: dict[str, Any] = {
            "rows": len(rows),
            "samples": len(timed_by_arm[arm]),
            "passes": sorted({sample.pass_index for sample in timed_by_arm[arm]}),
            "runtime_error_samples": error_summary["by_arm"].get(arm, {}).get("samples", 0),
        }
        summary.update(_value_stats(rows, [built[row].value for row in rows], audio))
        summary["equivalence"] = _arm_equivalence(rows, built)
        arms[arm] = summary
        if not rows:
            warnings.add(
                "arm_without_rows",
                f"{arm}: no timing samples remain (warmup pass 0, runtime errors and invalid samples are excluded)",
            )
        nondeterministic = summary["equivalence"]["nondeterministic_rows"]["count"]
        if nondeterministic:
            warnings.add(
                "nondeterministic_output", f"{arm}: output_sha256 varies across passes on {nondeterministic} rows"
            )
        for name, err in summary["equivalence"]["err"].items():
            if err is not None and err["nonfinite_samples"]:
                warnings.add(
                    "err_nonfinite", f"{arm}: {err['nonfinite_samples']} samples report a non-finite err.{name}"
                )
        if arm.endswith(AA_SUFFIX) and arm[: -len(AA_SUFFIX)] not in arm_rows:
            warnings.add("orphan_aa", f"{arm}: A/A replicate without its base arm {arm[: -len(AA_SUFFIX)]!r}")
    pairs = [
        analyze_pair(base, cand, kind, arm_rows, audio, seed, resamples, warnings)
        for base, cand, kind in resolve_pairs(pair_specs, all_vs, arm_names)
    ]
    _attach_noise_floor(pairs, warnings)
    drift = _drift(samples, arm_rows, include_warmup, [info.path for info in dataset.inputs], warnings)
    by_reason = dict(sorted(Counter(str(item.get("reason")) for item in dataset.invalid_timing).items()))
    return {
        "row_identity": dataset.timing_rows,
        "invalid_samples": {
            "count": len(dataset.invalid_timing),
            "zero_elapsed": zero_elapsed,
            "by_reason": by_reason,
            "examples": dataset.invalid_timing[:ID_LIST_LIMIT],
        },
        "runtime_errors": error_summary,
        "arms": arms,
        "pairs": pairs,
        "drift": drift,
    }


# ---------------------------------------------------------------------------------------------------------------------
# Stage profile


def _first_seen(names: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(names))


def _stage_stats(
    stage: str,
    rows: Sequence[str],
    aggregated: dict[str, dict[str, float]],
    audio: dict[str, float],
    scope: str,
) -> dict[str, Any]:
    present = [row for row in rows if stage in aggregated[row]]
    values = sorted(aggregated[row][stage] for row in present)
    # A stage outside `full` has no share of it: the ratio would compare time spent on different sides of the call.
    shared = [] if scope == "outside_full" else [row for row in present if aggregated[row].get(FULL_STAGE, 0.0) > 0.0]
    shares = sorted(aggregated[row][stage] / aggregated[row][FULL_STAGE] for row in shared)
    per_audio = sorted(aggregated[row][stage] / audio[row] for row in present if row in audio)
    mean = math.fsum(values) / len(values)
    p50 = quantile(values, 0.5)
    return {
        "stage": stage,
        "scope": scope,
        "rows": len(present),
        "p50_us": p50,
        "p95_us": quantile(values, 0.95),
        "mean_us": mean,
        "p50_ms": p50 / 1000.0,
        "mean_ms": mean / 1000.0,
        "total_ms": math.fsum(values) / 1000.0,
        "share_rows": len(shared),
        "share_of_full_p50": quantile(shares, 0.5) if shares else None,
        "share_of_total_full": (
            math.fsum(aggregated[row][stage] for row in shared)
            / math.fsum(aggregated[row][FULL_STAGE] for row in shared)
            if shared
            else None
        ),
        "us_per_audio_s_p50": quantile(per_audio, 0.5) if per_audio else None,
    }


def _stage_group(
    name: str,
    samples: Sequence[StageSample],
    aggregate: str,
    tolerance: float,
    warnings: _Warnings,
    selected: Sequence[str] | None = None,
) -> dict[str, Any]:
    order = _first_seen(stage for sample in samples for stage in sample.stages_us)
    has_full = FULL_STAGE in order
    if selected is None:
        parts = [stage for stage in order if stage != FULL_STAGE]
        outside: list[str] = []
    else:
        if not has_full:
            raise InputError(f"--stage-parts: stage profile {name} has no '{FULL_STAGE}' stage to scope the parts to")
        absent = [stage for stage in selected if stage not in order]
        if absent:
            raise InputError(
                f"--stage-parts: stage profile {name} has no stage {', '.join(absent)}; its stages: {', '.join(order)}"
            )
        parts = list(selected)
        outside = [stage for stage in order if stage != FULL_STAGE and stage not in selected]
    part_set = set(parts)
    by_row: dict[str, list[StageSample]] = {}
    audio: dict[str, float] = {}
    for sample in samples:
        by_row.setdefault(sample.row, []).append(sample)
        if sample.audio_s is not None:
            audio.setdefault(sample.row, sample.audio_s)
    rows = sorted(by_row, key=natural_key)
    coverage: list[float] = []
    over: list[dict[str, Any]] = []
    missing_full = 0
    missing_part = 0
    zero_full = 0
    unattributed: dict[str, list[float]] = {}
    for row in rows:
        for sample in by_row[row]:
            full = sample.stages_us.get(FULL_STAGE)
            if full is None:
                missing_full += 1
                continue
            if selected is not None and any(part not in sample.stages_us for part in parts):
                missing_part += 1
            parts_sum = math.fsum(value for stage, value in sample.stages_us.items() if stage in part_set)
            unattributed.setdefault(row, []).append(full - parts_sum)
            if full <= 0.0:
                zero_full += 1
                continue
            ratio = parts_sum / full
            coverage.append(ratio)
            if ratio > 1.0 + tolerance:
                over.append({"row_id": row, "pass": sample.pass_index, "coverage": ratio})
    aggregated: dict[str, dict[str, float]] = {}
    for row in rows:
        values: dict[str, list[float]] = {}
        for sample in by_row[row]:
            for stage, value in sample.stages_us.items():
                values.setdefault(stage, []).append(value)
        aggregated[row] = {stage: _aggregate(stage_values, aggregate) for stage, stage_values in values.items()}
        if parts and row in unattributed:
            aggregated[row][UNATTRIBUTED_STAGE] = _aggregate(unattributed[row], aggregate)
    table = parts + ([UNATTRIBUTED_STAGE] if has_full and parts else []) + ([FULL_STAGE] if has_full else [])
    counts: dict[str, dict[str, Any]] = {}
    for key in _first_seen(key for sample in samples for key in sample.counts):
        per_row = sorted(
            _aggregate([sample.counts[key] for sample in by_row[row] if key in sample.counts], "median")
            for row in rows
            if any(key in sample.counts for sample in by_row[row])
        )
        counts[key] = {
            "rows": len(per_row),
            "mean": math.fsum(per_row) / len(per_row),
            "p50": quantile(per_row, 0.5),
            "min": per_row[0],
            "max": per_row[-1],
            "total": math.fsum(per_row),
        }
    ordered_coverage = sorted(coverage)
    if not has_full:
        warnings.add(
            "stage_no_full", f"stage profile {name}: no '{FULL_STAGE}' stage; shares and the sum check are undefined"
        )
    elif missing_full:
        warnings.add(
            "stage_missing_full", f"stage profile {name}: {missing_full} samples lack the '{FULL_STAGE}' stage"
        )
    if missing_part:
        warnings.add(
            "stage_missing_part",
            f"stage profile {name}: {missing_part} samples lack at least one of the selected parts "
            f"({', '.join(parts)}); their sum understates {FULL_STAGE}",
        )
    if over:
        hint = (
            f"overlapping or nested selected parts, or a mis-measured {FULL_STAGE}"
            if selected is not None
            else f"overlapping or nested stages, stages measured outside {FULL_STAGE} (select the ones inside it "
            f"with --stage-parts), or a mis-measured {FULL_STAGE}"
        )
        warnings.add(
            "stage_overcount",
            f"stage profile {name}: on {len(over)} samples the stages sum to more than "
            f"{FULL_STAGE} x {1.0 + tolerance:g} ({hint})",
        )

    def scope_of(stage: str) -> str:
        return {FULL_STAGE: "full", UNATTRIBUTED_STAGE: "unattributed"}.get(stage, "part")

    return {
        "group": name,
        "rows": len(rows),
        "samples": len(samples),
        "passes": sorted({sample.pass_index for sample in samples}),
        "audio_rows": len(audio),
        "scope": {
            "mode": "selected_parts" if selected is not None else "all_non_full",
            "parts": parts,
            "outside_full": outside,
        },
        "stages": [_stage_stats(stage, rows, aggregated, audio, scope_of(stage)) for stage in table],
        "outside_full": [_stage_stats(stage, rows, aggregated, audio, "outside_full") for stage in outside],
        "consistency": {
            "tolerance": tolerance,
            "samples_checked": len(coverage),
            "samples_missing_full": missing_full,
            "samples_missing_part": missing_part,
            "samples_zero_full": zero_full,
            "coverage": (
                {
                    "min": ordered_coverage[0],
                    "p50": quantile(ordered_coverage, 0.5),
                    "max": ordered_coverage[-1],
                }
                if ordered_coverage
                else None
            ),
            "over_full": {"count": len(over), "examples": over[:ID_LIST_LIMIT]},
            "consistent": has_full and not over and missing_full == 0 and missing_part == 0,
        },
        "counts": counts,
    }


def analyze_stage_profile(
    dataset: Dataset,
    aggregate: str,
    include_warmup: bool,
    tolerance: float,
    warnings: _Warnings,
    selected: Sequence[str] | None = None,
) -> dict[str, Any]:
    if not dataset.stages:
        raise InputError("--stage-profile: the inputs contain no stage_profile rows")
    used = [sample for sample in dataset.stages if include_warmup or sample.pass_index != 0]
    if not used:
        raise InputError("--stage-profile: every stage_profile row is warmup pass 0; pass --include-warmup")
    groups: dict[str, list[StageSample]] = {}
    for sample in used:
        groups.setdefault(sample.group, []).append(sample)
    return {
        "row_identity": dataset.stage_rows,
        "groups": [
            _stage_group(name, groups[name], aggregate, tolerance, warnings, selected)
            for name in sorted(groups, key=natural_key)
        ],
    }


# ---------------------------------------------------------------------------------------------------------------------
# Entry points


def _validate_stage_parts(parts: Sequence[str] | None, stage_profile: bool) -> list[str] | None:
    if parts is None:
        return None
    if not stage_profile:
        raise InputError("--stage-parts needs --stage-profile")
    selected = list(parts)
    if not selected or any(not isinstance(part, str) or not part.strip() for part in selected):
        raise InputError("--stage-parts: expected a comma-separated list of non-empty stage names")
    if len(set(selected)) != len(selected):
        raise InputError("--stage-parts: a stage is listed twice")
    for reserved in (FULL_STAGE, UNATTRIBUTED_STAGE):
        if reserved in selected:
            raise InputError(f"--stage-parts: {reserved!r} is not a part; parts are the stages inside {FULL_STAGE!r}")
    return selected


def analyze(
    paths: Sequence[str],
    *,
    pairs: Sequence[str] = (),
    all_vs: str | None = None,
    aggregate: str = "median",
    include_warmup: bool = False,
    seed: int = DEFAULT_SEED,
    bootstrap: int = DEFAULT_BOOTSTRAP,
    stage_profile: bool = False,
    stage_tolerance: float = DEFAULT_STAGE_TOLERANCE,
    stage_parts: Sequence[str] | None = None,
    check: bool = False,
) -> dict[str, Any]:
    """Run the requested analyses and return the full report (the JSON document).

    A run whose declared grid or completion footer does not hold is refused (InputError). `check` is the strict gate
    for a run that must be clean: it also refuses runtime errors and reported failures, and it needs no analysis."""
    pair_specs = list(pairs)
    if aggregate not in AGGREGATES:
        raise InputError(f"--aggregate must be one of {', '.join(AGGREGATES)}")
    if bootstrap < 1:
        raise InputError("--bootstrap must be at least 1")
    if not math.isfinite(stage_tolerance) or stage_tolerance < 0.0:
        raise InputError("--stage-tolerance must be a finite number >= 0")
    if pair_specs and all_vs is not None:
        raise InputError("--pair and --all-vs are mutually exclusive")
    timing_requested = bool(pair_specs) or all_vs is not None
    if not timing_requested and not stage_profile and not check:
        raise InputError(
            "nothing to analyze: pass --pair BASE_ARM:CAND_ARM, --all-vs BASE_ARM, --stage-profile and/or --check"
        )
    selected_parts = _validate_stage_parts(stage_parts, stage_profile)
    dataset = load_inputs(paths)
    warnings = _Warnings()
    integrity = check_integrity(dataset, warnings, check)
    if timing_requested and bootstrap < MIN_RECOMMENDED_BOOTSTRAP:
        warnings.add(
            "bootstrap_small",
            f"--bootstrap {bootstrap} is below {MIN_RECOMMENDED_BOOTSTRAP}; tail quantiles are noisy",
        )
    for info in dataset.inputs:
        for kind, count in info.ignored_types.items():
            warnings.add("ignored_rows", f"{info.path}: ignored {count} rows of type {kind!r}")
    if dataset.invalid_timing:
        first = dataset.invalid_timing[0]
        zero = sum(1 for item in dataset.invalid_timing if item.get("reason") == "zero")
        warnings.add(
            "invalid_samples",
            f"{len(dataset.invalid_timing)} timing rows have a missing, non-finite, zero or negative elapsed_us and "
            f"are excluded ({zero} are exactly 0, a timer read below its resolution: left out, not replaced by an "
            f"epsilon; first: {first['where']})",
        )
    timing = (
        analyze_timing(dataset, pair_specs, all_vs, aggregate, include_warmup, seed, bootstrap, warnings)
        if timing_requested
        else None
    )
    profile = (
        analyze_stage_profile(dataset, aggregate, include_warmup, stage_tolerance, warnings, selected_parts)
        if stage_profile
        else None
    )
    return {
        "tool": TOOL,
        "schema_version": SCHEMA_VERSION,
        "settings": {
            "aggregate": aggregate,
            "include_warmup": include_warmup,
            "seed": seed,
            "bootstrap": bootstrap,
            "alpha": ALPHA,
            "quantile_method": "type-7 linear interpolation",
            "exact_wilcoxon_max_n": EXACT_WILCOXON_MAX_N,
            "wilcoxon_zero_method": "pratt",
            "drift_rho_threshold": DRIFT_RHO_THRESHOLD,
            "id_list_limit": ID_LIST_LIMIT,
            "stage_tolerance": stage_tolerance,
            "stage_parts": selected_parts,
            "check": check,
        },
        "inputs": [
            {
                "path": info.path,
                "sha256": info.sha256,
                "lines": info.lines,
                "timing_rows": info.timing_rows,
                "stage_profile_rows": info.stage_profile_rows,
                "ignored_types": info.ignored_types,
                "run_meta": info.run_meta,
                "run_end": info.run_end,
            }
            for info in dataset.inputs
        ],
        "warnings": warnings.items,
        "integrity": integrity,
        "timing": timing,
        "stage_profile": profile,
    }


def _json_safe(value: Any) -> Any:
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, list | tuple):
        return [_json_safe(item) for item in value]
    return value


def to_json(report: dict[str, Any]) -> str:
    return json.dumps(_json_safe(report), indent=2, ensure_ascii=False, allow_nan=False) + "\n"


# ---------------------------------------------------------------------------------------------------------------------
# Markdown


def _md(text: Any) -> str:
    return str(text).replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ")


def _table(headers: Sequence[str], rows: Iterable[Sequence[str]]) -> list[str]:
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    lines.append("")
    return lines


def _num(value: float | None, digits: int = 1) -> str:
    return "—" if value is None else f"{value:.{digits}f}"


def _pct(value: float | None) -> str:
    return "—" if value is None else f"{100.0 * value:.1f}%"


def _pvalue(value: float | None) -> str:
    if value is None:
        return "—"
    if value == 0.0:
        return "0"
    return f"{value:.2e}" if value < 1e-4 else f"{value:.4f}"


def _bounds(bounds: Sequence[float] | None, digits: int = 4) -> str:
    return "undefined" if bounds is None else f"[{bounds[0]:.{digits}f}, {bounds[1]:.{digits}f}]"


def _interval_cell(interval: dict[str, Any] | None, key: str, digits: int = 4) -> str:
    return "—" if interval is None else _bounds(interval[key], digits)


def _primary_cell(interval: dict[str, Any] | None, digits: int = 4) -> str:
    return "—" if interval is None else _bounds([interval["low"], interval["high"]], digits)


def _err_cell(err: dict[str, Any]) -> str:
    cells = []
    for name in ("max_abs", "rel_l2"):
        item = err[name]
        cells.append("—" if item is None or item["max"] is None else f"{item['max']:.3g}")
    return " / ".join(cells)


def _meta_summary(meta: dict[str, Any]) -> str:
    parts = []
    for key in ("bet", "harness", "git_sha", "started_at", "corpus", "passes", "order", "arms", "notes"):
        if meta.get(key) is not None:
            value = meta[key]
            parts.append(f"{key}={value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)}")
    host = meta.get("host")
    if isinstance(host, dict):
        host_parts = [
            f"{key}={host[key] if isinstance(host[key], str) else json.dumps(host[key])}"
            for key in ("chip", "os", "os_build", "power", "load_avg", "cpu_threads", "perf_cores", "eff_cores")
            if host.get(key) is not None
        ]
        if host_parts:
            parts.append("host: " + ", ".join(host_parts))
    return _md("; ".join(parts) or "(empty)")


def _noise_cell(pair: dict[str, Any]) -> str:
    if pair["kind"] == "aa":
        return "A/A pair"
    floor = pair.get("noise_floor")
    if floor is None:
        return "no A/A arm"
    suffix = " (proxy)" if floor["proxy"] else ""
    if floor["within_noise_floor"]:
        labels = sorted({check["aa_pair"] for check in floor["checks"] if check["overlaps"]})
        return _md("WITHIN noise: overlaps " + ", ".join(labels) + suffix)
    labels = sorted({check["aa_pair"] for check in floor["checks"]})
    return _md("clear of " + ", ".join(labels) + suffix)


def _render_timing(out: list[str], timing: dict[str, Any]) -> None:
    identity = timing["row_identity"]
    out.append("## Arms")
    out.append("")
    out.append(
        f"Per-row aggregated elapsed µs (row key: {identity['key']}). µs/audio-s divides each row by its audio_s; "
        "Σµs/Σaudio-s is the time-weighted rate."
    )
    out.append("")
    headers = [
        "arm",
        "rows",
        "samples",
        "mean µs",
        "p50",
        "p90",
        "p95",
        "p99",
        "min",
        "max",
        "p50 µs/audio-s",
        "Σµs/Σaudio-s",
    ]
    rows = []
    for name, arm in timing["arms"].items():
        elapsed = arm["elapsed_us"]
        per_audio = arm["us_per_audio_s"] or {}
        rows.append(
            [_md(name), str(arm["rows"]), str(arm["samples"])]
            + [_num(elapsed.get(key)) for key in ("mean", "p50", "p90", "p95", "p99", "min", "max")]
            + [_num(per_audio.get("p50")), _num(arm["total_us_per_audio_s"])]
        )
    out.extend(_table(headers, rows))
    errors = timing.get("runtime_errors") or {"count": 0}
    if errors["count"]:
        out.append("## Runtime errors")
        out.append("")
        out.append(
            "Rows whose call failed (work.error, or work.non_finite > 0) enter no statistic and never count as zero "
            "time. A row with such a timed sample is dropped for that arm, so its pairs cover only the rows where "
            "it ran cleanly."
        )
        out.append("")
        out.extend(
            _table(
                ["arm", "error samples", "rows", "rows dropped", "kinds", "first"],
                [
                    [
                        _md(arm),
                        str(item["samples"]),
                        str(item["rows"]),
                        str(item["dropped_rows"]),
                        _md(", ".join(f"{kind}: {count}" for kind, count in item["kinds"].items())),
                        _md(item["first"] or "—"),
                    ]
                    for arm, item in errors["by_arm"].items()
                ],
            )
        )
    invalid = timing["invalid_samples"]
    if invalid["count"]:
        reasons = ", ".join(f"{reason}: {count}" for reason, count in invalid.get("by_reason", {}).items())
        out.append(
            f"Samples without a usable elapsed_us are excluded, never replaced by an epsilon: {invalid['count']} "
            f"({reasons or 'reasons not recorded'}); {invalid.get('zero_elapsed', 0)} read exactly 0, below the timer "
            "resolution."
        )
        out.append("")
    pairs = [pair for pair in timing["pairs"] if "speed" in pair]
    if pairs:
        out.append("## Pairs: speed")
        out.append("")
        out.append("Ratios are candidate/base over common rows: below 1 means the candidate is faster.")
        out.append("")
        headers = [
            "base",
            "cand",
            "n",
            "Σcand/Σbase",
            "95% CI BCa",
            "95% CI pct",
            "geomean ratio",
            "95% CI BCa",
            "95% CI pct",
            "median ratio",
            "cand faster",
            "A/A noise floor",
        ]
        rows = []
        for pair in pairs:
            speed = pair["speed"]
            total = speed["total_ratio"]
            geomean = speed["geomean_ratio"]
            rows.append(
                [
                    _md(pair["base"]),
                    _md(pair["cand"]),
                    str(pair["n"]),
                    _num(total["point"], 4),
                    _interval_cell(total["ci95"], "bca"),
                    _interval_cell(total["ci95"], "percentile"),
                    _num(geomean["point"], 4),
                    _interval_cell(geomean["ci95"], "bca"),
                    _interval_cell(geomean["ci95"], "percentile"),
                    _num(speed["median_ratio"], 4),
                    f"{speed['rows_faster']}/{pair['n']} ({_pct(speed['fraction_faster'])})",
                    _noise_cell(pair),
                ]
            )
        out.extend(_table(headers, rows))
        out.append("## Pairs: tests and savings")
        out.append("")
        out.append(
            "Saving = base − cand (positive: candidate saves time). Wilcoxon runs on log(cand/base); "
            "the sign test on faster vs slower rows."
        )
        out.append("")
        headers = [
            "base",
            "cand",
            "Wilcoxon p",
            "method",
            "sign p",
            "faster/slower/tied",
            "mean saving µs",
            "95% CI (mean)",
            "p50 saving µs",
            "mean saving µs/audio-s",
            "p50 saving µs/audio-s",
            "Σsaving/Σaudio-s",
        ]
        rows = []
        for pair in pairs:
            speed = pair["speed"]
            saving = speed["saving_us"]
            per_audio = speed["saving_us_per_audio_s"] or {}
            rows.append(
                [
                    _md(pair["base"]),
                    _md(pair["cand"]),
                    _pvalue(speed["wilcoxon"]["p_two_sided"]),
                    speed["wilcoxon"]["method"],
                    _pvalue(speed["sign_test"]["p_two_sided"]),
                    f"{speed['rows_faster']}/{speed['rows_slower']}/{speed['rows_tied']}",
                    _num(saving["mean"]),
                    _primary_cell(saving["ci95_mean"], 1),
                    _num(saving["p50"]),
                    _num(per_audio.get("mean")),
                    _num(per_audio.get("p50")),
                    _num(per_audio.get("total")),
                ]
            )
        out.extend(_table(headers, rows))
        out.append("## Equivalence")
        out.append("")
        out.append(
            "Identical = both arms produced one output_sha256 over every pass and it is the same; rows lacking a "
            "hash in either arm are not compared. equal_ref is judged per row over every pass."
        )
        out.append("")
        headers = [
            "base",
            "cand",
            "compared",
            "identical sha256",
            "hash missing",
            "mismatching row_ids",
            "base equal_ref",
            "cand equal_ref",
            "base max err abs / rel_l2",
            "cand max err abs / rel_l2",
        ]
        rows = []
        for pair in pairs:
            equivalence = pair["equivalence"]
            mismatched = equivalence["mismatched"]
            listed = ", ".join(mismatched["row_ids"])
            more = mismatched["count"] - len(mismatched["row_ids"])
            rows.append(
                [
                    _md(pair["base"]),
                    _md(pair["cand"]),
                    str(equivalence["compared"]),
                    f"{equivalence['identical']} ({_pct(equivalence['identical_rate'])})",
                    str(equivalence["hash_missing"]["count"]),
                    _md((listed + (f" (+{more} more)" if more else "")) or "—"),
                    _equal_ref_cell(equivalence["base"]["equal_ref"]),
                    _equal_ref_cell(equivalence["cand"]["equal_ref"]),
                    _err_cell(equivalence["base"]["err"]),
                    _err_cell(equivalence["cand"]["err"]),
                ]
            )
        out.extend(_table(headers, rows))
    failed = [pair for pair in timing["pairs"] if "speed" not in pair]
    if failed:
        out.append("Pairs without common rows: " + ", ".join(_md(pair["label"]) for pair in failed))
        out.append("")
    out.append("## Arms: equivalence")
    out.append("")
    headers = [
        "arm",
        "rows",
        "equal_ref true",
        "false",
        "null",
        "rate",
        "false row_ids",
        "nondeterministic rows",
        "max err abs / rel_l2",
    ]
    rows = []
    for name, arm in timing["arms"].items():
        equivalence = arm["equivalence"]
        ref = equivalence["equal_ref"]
        rows.append(
            [
                _md(name),
                str(arm["rows"]),
                str(ref["true"]),
                str(ref["false"]),
                str(ref["null"]),
                _pct(ref["rate"]),
                _md(", ".join(ref["false_rows"]["row_ids"]) or "—"),
                str(equivalence["nondeterministic_rows"]["count"]),
                _err_cell(equivalence["err"]),
            ]
        )
    out.extend(_table(headers, rows))
    if timing["drift"]:
        out.append("## Drift")
        out.append("")
        out.append(
            "Spearman rho of elapsed_us vs seq per input file and arm; row-normalized divides each sample by its "
            f"row's aggregate. Warn when |rho| > {DRIFT_RHO_THRESHOLD}."
        )
        out.append("")
        rows = [
            [
                _md(item["source"]),
                _md(item["arm"]),
                str(item["n"]),
                _num(item["rho"], 3),
                _num(item["rho_row_normalized"], 3),
                "WARN" if item["warn"] else "ok",
            ]
            for item in timing["drift"]
        ]
        out.extend(_table(["source", "arm", "n", "rho", "rho row-normalized", "status"], rows))
    dropped = [
        pair
        for pair in timing["pairs"]
        if pair["dropped_rows"]["base_only"]["count"] or pair["dropped_rows"]["cand_only"]["count"]
    ]
    if dropped:
        out.append("## Dropped rows")
        out.append("")
        for pair in dropped:
            for side, arm in (("base_only", pair["base"]), ("cand_only", pair["cand"])):
                info = pair["dropped_rows"][side]
                if info["count"]:
                    more = info["count"] - len(info["row_ids"])
                    out.append(
                        f"- {_md(pair['label'])}: {info['count']} rows only in {_md(arm)}: "
                        + _md(", ".join(info["row_ids"]) + (f" (+{more} more)" if more else ""))
                    )
        out.append("")


def _equal_ref_cell(ref: dict[str, Any]) -> str:
    judged = ref["true"] + ref["false"]
    if judged == 0:
        return "—"
    return f"{ref['true']}/{judged} ({_pct(ref['rate'])})"


def _render_stage_profile(out: list[str], profile: dict[str, Any]) -> None:
    for group in profile["groups"]:
        out.append(f"## Stage profile: {_md(group['group'])}")
        out.append("")
        scope = group.get("scope") or {}
        selected = scope.get("mode") == "selected_parts"
        out.append(
            f"{group['rows']} rows, {group['samples']} samples, passes {group['passes']}. Shares divide each row's "
            f"aggregated stage by its aggregated {FULL_STAGE}; Σ share is Σstage/Σ{FULL_STAGE}."
        )
        out.append("")
        if selected:
            outside_names = ", ".join(scope["outside_full"]) or "none"
            out.append(
                f"Parts inside {FULL_STAGE} (--stage-parts): {', '.join(scope['parts'])}. (unattributed) is "
                f"{FULL_STAGE} minus their sum. Stages outside {FULL_STAGE}: {outside_names}; they are listed "
                f"separately and are never added to or subtracted from {FULL_STAGE}."
            )
            out.append("")
        headers = [
            "stage",
            "rows",
            "p50 µs",
            "p95 µs",
            "mean µs",
            "p50 ms",
            "mean ms",
            "share of full p50",
            "Σ share",
            "p50 µs/audio-s",
        ]
        rows = [
            [
                _md(stage["stage"]),
                str(stage["rows"]),
                _num(stage["p50_us"]),
                _num(stage["p95_us"]),
                _num(stage["mean_us"]),
                _num(stage["p50_ms"], 3),
                _num(stage["mean_ms"], 3),
                _pct(stage["share_of_full_p50"]),
                _pct(stage["share_of_total_full"]),
                _num(stage["us_per_audio_s_p50"]),
            ]
            for stage in group["stages"]
        ]
        out.extend(_table(headers, rows))
        consistency = group["consistency"]
        coverage = consistency["coverage"]
        coverage_text = (
            "no sample has full"
            if coverage is None
            else f"min {coverage['min']:.4f}, p50 {coverage['p50']:.4f}, max {coverage['max']:.4f}"
        )
        parts_label = "selected parts" if selected else f"stages except {FULL_STAGE}"
        missing_part = consistency.get("samples_missing_part", 0)
        out.append(
            f"Consistency (Σ {parts_label}, per sample, divided by {FULL_STAGE}): {coverage_text}; "
            f"{consistency['over_full']['count']} of {consistency['samples_checked']} samples exceed "
            f"1 + {consistency['tolerance']:g}; {consistency['samples_missing_full']} samples lack {FULL_STAGE}"
            + (f"; {missing_part} samples lack a selected part." if missing_part else ".")
        )
        out.append("")
        if group.get("outside_full"):
            out.append(f"### Outside {FULL_STAGE} (not part of it; no share of it)")
            out.append("")
            out.extend(
                _table(
                    ["stage", "rows", "p50 µs", "p95 µs", "mean µs", "p50 ms", "mean ms", "p50 µs/audio-s"],
                    [
                        [
                            _md(stage["stage"]),
                            str(stage["rows"]),
                            _num(stage["p50_us"]),
                            _num(stage["p95_us"]),
                            _num(stage["mean_us"]),
                            _num(stage["p50_ms"], 3),
                            _num(stage["mean_ms"], 3),
                            _num(stage["us_per_audio_s_p50"]),
                        ]
                        for stage in group["outside_full"]
                    ],
                )
            )
        if group["counts"]:
            rows = [
                [_md(key), str(item["rows"])] + [_num(item[name], 2) for name in ("mean", "p50", "min", "max", "total")]
                for key, item in group["counts"].items()
            ]
            out.extend(_table(["count", "rows", "mean", "p50", "min", "max", "total"], rows))


def render_markdown(report: dict[str, Any]) -> str:
    settings = report["settings"]
    out = ["# Paired timing analysis", ""]
    summary = (
        f"Aggregate per (arm, row_id): {settings['aggregate']} over passes; warmup pass 0 "
        f"{'included' if settings['include_warmup'] else 'excluded'}."
    )
    if report["timing"] is not None:
        summary += (
            f" {settings['bootstrap']} row-bootstrap resamples, seed {settings['seed']}; "
            f"{round(100 * (1 - settings['alpha']))}% intervals (BCa primary, percentile shown)."
        )
    out.append(summary)
    out.append("")
    out.append("## Inputs")
    out.append("")
    out.extend(
        _table(
            ["file", "sha256", "lines", "timing", "stage_profile", "ignored"],
            [
                [
                    _md(info["path"]),
                    info["sha256"][:16],
                    str(info["lines"]),
                    str(info["timing_rows"]),
                    str(info["stage_profile_rows"]),
                    _md(", ".join(f"{kind}: {count}" for kind, count in info["ignored_types"].items()) or "—"),
                ]
                for info in report["inputs"]
            ],
        )
    )
    metas = [(info["path"], meta) for info in report["inputs"] for meta in info["run_meta"]]
    for path, meta in metas:
        out.append(f"- run_meta {_md(path)}: {_meta_summary(meta)}")
    if metas:
        out.append("")
    integrity = report.get("integrity") or []
    if integrity:
        out.append("## Run integrity")
        out.append("")
        out.append(
            "The declared grid (run_meta.arms × the row_ids written × passes 0..passes) and the run_end footer are "
            "checked before any statistic. verified: grid and footer hold. grid_only: a legacy run with no footer, "
            "which cannot prove that whole rows or arms were not left out."
        )
        out.append("")
        table_rows = []
        for item in integrity:
            grid = item["grid"]
            grid_text = (
                "—"
                if grid is None
                else f"{grid['written_keys']}/{grid['expected_cells']} "
                f"({grid['groups']}×{grid['rows']}×{grid['passes'] + 1})"
            )
            table_rows.append(
                [
                    _md(item["path"]),
                    str(item["run_meta_line"] or "—"),
                    str(item["timing_rows"] or item["stage_profile_rows"]),
                    grid_text,
                    item["footer"],
                    str(item["runtime_error_rows"]),
                    item["status"],
                ]
            )
        out.extend(
            _table(
                ["file", "run_meta line", "rows", "grid written/expected", "footer", "runtime errors", "status"],
                table_rows,
            )
        )
    out.append("## Warnings")
    out.append("")
    if report["warnings"]:
        out.extend(f"- `{item['code']}`: {_md(item['message'])}" for item in report["warnings"])
    else:
        out.append("None.")
    out.append("")
    if report["timing"] is not None:
        _render_timing(out, report["timing"])
    if report["stage_profile"] is not None:
        _render_stage_profile(out, report["stage_profile"])
    return "\n".join(out).rstrip("\n") + "\n"


# ---------------------------------------------------------------------------------------------------------------------
# CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="paired_stats.py",
        description="Paired timing statistics for bench/rust timing and stage_profile JSONL rows.",
    )
    parser.add_argument("results", nargs="+", metavar="RESULTS.jsonl", help="timing / stage_profile JSONL files")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--pair",
        action="append",
        default=[],
        metavar="BASE_ARM:CAND_ARM",
        help="compare CAND against BASE (repeatable)",
    )
    selection.add_argument("--all-vs", metavar="BASE_ARM", help="compare every non-@aa arm against BASE_ARM")
    parser.add_argument("--aggregate", choices=AGGREGATES, default="median", help="per-row reduction over passes")
    parser.add_argument("--include-warmup", action="store_true", help="keep pass 0 (excluded by default)")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help=f"bootstrap seed (default {DEFAULT_SEED})")
    parser.add_argument(
        "--bootstrap", type=int, default=DEFAULT_BOOTSTRAP, help=f"bootstrap resamples (default {DEFAULT_BOOTSTRAP})"
    )
    parser.add_argument("--json", metavar="OUT.json", help="write the full JSON report")
    parser.add_argument("--md", metavar="OUT.md", help="write the Markdown report (default: stdout)")
    parser.add_argument("--stage-profile", action="store_true", help="analyze stage_profile rows")
    parser.add_argument(
        "--stage-tolerance",
        type=float,
        default=DEFAULT_STAGE_TOLERANCE,
        help=f"allowed relative excess of summed stages over full (default {DEFAULT_STAGE_TOLERANCE})",
    )
    parser.add_argument(
        "--stage-parts",
        metavar="STAGE,STAGE,...",
        help="with --stage-profile: the stages inside `full` (for example mel,encode,tail); every other stage is "
        "listed as outside full and is never added to or subtracted from it",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="strict gate: also refuse runtime errors and reported failures; needs no --pair, --all-vs or "
        "--stage-profile (then only the integrity summary is printed)",
    )
    return parser


def _write(path: str, text: str) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def render_check_summary(report: dict[str, Any]) -> str:
    lines = []
    for item in report["integrity"]:
        grid = item["grid"]
        cells = "no declared grid" if grid is None else f"{grid['written_keys']}/{grid['expected_cells']} cells"
        lines.append(
            f"{item['path']}: {item['status']} ({cells}; footer {item['footer']}; "
            f"runtime errors {item['runtime_error_rows']})"
        )
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_intermixed_args(argv)
    stage_parts = None if args.stage_parts is None else [part.strip() for part in args.stage_parts.split(",")]
    try:
        report = analyze(
            args.results,
            pairs=args.pair,
            all_vs=args.all_vs,
            aggregate=args.aggregate,
            include_warmup=args.include_warmup,
            seed=args.seed,
            bootstrap=args.bootstrap,
            stage_profile=args.stage_profile,
            stage_tolerance=args.stage_tolerance,
            stage_parts=stage_parts,
            check=args.check,
        )
    except InputError as error:
        print(f"paired_stats.py: error: {error}", file=sys.stderr)
        return 2
    check_only = args.check and report["timing"] is None and report["stage_profile"] is None
    markdown = render_markdown(report)
    if args.json:
        _write(args.json, to_json(report))
    if args.md:
        _write(args.md, markdown)
    elif check_only and not args.json:
        sys.stdout.write(render_check_summary(report))
    elif not check_only:
        sys.stdout.write(markdown)
    for item in report["warnings"]:
        print(f"paired_stats.py: warning [{item['code']}]: {item['message']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
