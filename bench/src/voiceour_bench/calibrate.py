"""Threshold calibration for automatic term correction.

Reads a benchmark report's ``metrics.confidence_by_mode`` (reliability bins plus
risk/coverage points) and, per confidence mode, recommends the operating
threshold that accepts the most decisions (maximum coverage/recall) while keeping
the accepted region's observed error at or below a safety bound.

The default safety bound encodes a deliberately small false-activation policy and
is anchored to the +0.35pp U-WER gate that governs the production path. It is a
provisional proxy: the report's per-mode ``risk`` is an utterance-level
not-perfect rate over whatever data produced it, not a measured production
false-activation cost. Any profile derived from TTS speakers, from an
unverified speaker source, or from a small opportunity count is therefore flagged
``provisional`` so it is never mistaken for a production-ready threshold. Real
operating thresholds require real-speaker calibration data.

Everything here is pure and deterministic.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

from .compare import UWER_MAX_DELTA

# +0.35pp U-WER acceptance gate expressed as a fraction (matches compare.UWER_MAX_DELTA).
UWER_BUDGET_FRACTION = UWER_MAX_DELTA
# Small false-activation policy: at most this fraction of accepted decisions may be wrong.
FALSE_ACTIVATION_POLICY = 0.01
# Governing safety bound on the accepted region's observed error.
DEFAULT_ACCEPTED_ERROR_BOUND = FALSE_ACTIVATION_POLICY
# Below this many scored opportunities a per-mode recommendation is treated as provisional.
DEFAULT_MIN_COUNT = 30

_CLOSE_KWARGS = {"rel_tol": 1e-9, "abs_tol": 1e-12}


def _is_number(value: Any) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool)


def _risk_coverage_points(entry: dict[str, Any]) -> list[dict[str, Any]]:
    points = entry.get("risk_coverage")
    if not isinstance(points, list):
        points = entry.get("risk_coverage_points")
    return points if isinstance(points, list) else []


def _opportunity_count(entry: dict[str, Any]) -> int:
    reliability = entry.get("reliability")
    if isinstance(reliability, dict) and isinstance(reliability.get("count"), int):
        return reliability["count"]
    covered = [point.get("covered") for point in _risk_coverage_points(entry) if isinstance(point.get("covered"), int)]
    if covered:
        return max(covered)
    count = entry.get("count")
    return count if isinstance(count, int) else 0


def select_operating_point(
    risk_coverage_points: list[dict[str, Any]],
    accepted_error_bound: float,
) -> dict[str, Any] | None:
    """Return the max-coverage point whose accepted-region risk is within the bound.

    Points are the report's risk/coverage curve, each with a cumulative ``risk``
    over all decisions at or above its ``threshold``. Selecting the eligible point
    with the largest ``coverage`` yields the lowest threshold whose *own*
    cumulative risk still satisfies the bound, so the recommendation never accepts
    a region that violates the safety bound. Returns ``None`` when no threshold is
    safe.
    """

    eligible: list[dict[str, Any]] = []
    for point in risk_coverage_points:
        threshold = point.get("threshold")
        risk = point.get("risk")
        if not _is_number(threshold) or not _is_number(risk):
            continue
        if risk <= accepted_error_bound or math.isclose(risk, accepted_error_bound, **_CLOSE_KWARGS):
            eligible.append(point)
    if not eligible:
        return None

    best = max(eligible, key=lambda point: (point.get("coverage") or 0.0, point["threshold"]))
    covered = best.get("covered")
    coverage = best.get("coverage")
    return {
        "threshold": float(best["threshold"]),
        "coverage": float(coverage) if _is_number(coverage) else None,
        "risk": float(best["risk"]),
        "covered": int(covered) if isinstance(covered, int) else None,
    }


def _report_speaker_kind(report: dict[str, Any]) -> str | None:
    for source in (report.get("meta"), report):
        if isinstance(source, dict):
            kind = source.get("speaker_kind")
            if isinstance(kind, str) and kind:
                return kind
    return None


def calibrate_profile(
    report: dict[str, Any],
    *,
    accepted_error_bound: float = DEFAULT_ACCEPTED_ERROR_BOUND,
    speaker_kind: str | None = None,
    min_count: int = DEFAULT_MIN_COUNT,
) -> dict[str, Any]:
    """Build a per-mode calibration profile from a benchmark report.

    ``speaker_kind`` overrides the report's own label. Anything other than
    ``"real"`` (including an unverified/unknown source) marks the profile
    provisional, as does a small opportunity count or a mode with no safe
    threshold. A recommended threshold is emitted only when the accepted region's
    risk is within ``accepted_error_bound``.
    """

    if not 0.0 <= accepted_error_bound <= 1.0:
        raise ValueError("accepted_error_bound must be between 0 and 1")

    metrics = report.get("metrics")
    by_mode = metrics.get("confidence_by_mode") if isinstance(metrics, dict) else None
    if not isinstance(by_mode, dict) or not by_mode:
        raise ValueError("report has no metrics.confidence_by_mode to calibrate")

    resolved_speaker = speaker_kind if speaker_kind is not None else _report_speaker_kind(report)

    mode_profiles: dict[str, Any] = {}
    for mode, entry in sorted(by_mode.items()):
        if not isinstance(entry, dict):
            continue
        count = _opportunity_count(entry)
        operating = select_operating_point(_risk_coverage_points(entry), accepted_error_bound)

        reasons: list[str] = []
        if resolved_speaker == "tts":
            reasons.append("speaker_kind=tts")
        elif resolved_speaker != "real":
            reasons.append("speaker_kind_unverified")
        if count < min_count:
            reasons.append(f"low_n(<{min_count})")
        if operating is None:
            reasons.append("no_threshold_satisfies_bound")

        mode_profiles[mode] = {
            "count": count,
            "recommended_threshold": operating["threshold"] if operating else None,
            "coverage": operating["coverage"] if operating else None,
            "risk": operating["risk"] if operating else None,
            "covered": operating["covered"] if operating else None,
            "provisional": bool(reasons),
            "provisional_reasons": reasons,
        }

    profile_reasons = sorted(
        {reason for profile in mode_profiles.values() for reason in profile["provisional_reasons"]}
    )
    return {
        "source": {
            "tier": report.get("tier"),
            "mode": report.get("mode"),
            "speaker_kind": resolved_speaker or "unknown",
            "generated_at": report.get("generated_at"),
        },
        "policy": {
            "accepted_error_bound": accepted_error_bound,
            "uwer_budget_fraction": UWER_BUDGET_FRACTION,
            "false_activation_policy": FALSE_ACTIVATION_POLICY,
            "min_count": min_count,
        },
        "provisional": bool(profile_reasons),
        "provisional_reasons": profile_reasons,
        "modes": mode_profiles,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Recommend automatic-correction operating thresholds from a benchmark "
            "report's confidence calibration."
        ),
    )
    parser.add_argument("report", type=Path, help="benchmark report JSON produced by report.build_report")
    parser.add_argument(
        "--accepted-error-bound",
        type=float,
        default=DEFAULT_ACCEPTED_ERROR_BOUND,
        help=(
            f"max accepted-region error (default {DEFAULT_ACCEPTED_ERROR_BOUND}; "
            f"anchored to the {UWER_BUDGET_FRACTION} U-WER gate)"
        ),
    )
    parser.add_argument(
        "--speaker-kind",
        choices=["real", "tts", "unknown"],
        default=None,
        help="override the report speaker source; anything but 'real' is provisional",
    )
    parser.add_argument(
        "--min-count", type=int, default=DEFAULT_MIN_COUNT, help="opportunity count below which a mode is provisional"
    )
    parser.add_argument("--out", type=Path, default=None, help="write the calibration profile here instead of stdout")
    args = parser.parse_args(argv)

    if not 0.0 <= args.accepted_error_bound <= 1.0:
        parser.error("--accepted-error-bound must be between 0 and 1")

    report = json.loads(args.report.read_text(encoding="utf-8"))
    profile = calibrate_profile(
        report,
        accepted_error_bound=args.accepted_error_bound,
        speaker_kind=args.speaker_kind,
        min_count=args.min_count,
    )

    text = json.dumps(profile, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    if args.out is not None:
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
