"""Deterministic planning, collection, and reporting for paired capture runs."""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import Any

CAPTURE_MODES = (
    "standard",
    "native",
    "voice-processing",
    "voice-processing-no-agc",
    "sound-isolation",
    "sound-isolation-high-quality",
)
CONDITIONS = (
    "quiet",
    "fan-keyboard",
    "echo",
    "distance",
    "clipping",
    "bluetooth",
    "route-change",
)
DEFAULT_PRE_ROLL_MS = (100, 200)
DEFAULT_POST_ROLL_MS = (300, 500)
HARDWARE_DEPENDENT_CONDITIONS = frozenset({"bluetooth", "route-change"})
CONDITION_INSTRUCTIONS = {
    "quiet": "Quiet room; keep microphone, angle, gain, and speaking position fixed.",
    "fan-keyboard": "Use the documented fan and keyboard setup without changing gain or position.",
    "echo": "Play the documented loudspeaker echo source at a fixed level and position.",
    "distance": "Use the documented far-field distance and angle markers.",
    "clipping": "Use the documented high-level setup; do not change gain between paired modes.",
    "bluetooth": "Select and verify the documented Bluetooth HFP input before every paired take.",
    "route-change": "Perform the documented input-route transition during every paired take.",
}


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number}: expected a JSON object")
            rows.append(value)
    return rows


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            handle.write("\n")


def _require_nonempty_string(row: dict[str, Any], key: str, context: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{context}: {key} must be a non-empty string")
    return value


def _prompt_fields(row: dict[str, Any], index: int) -> tuple[str, str]:
    prompt_id = row.get("prompt_id", row.get("id"))
    prompt = row.get("prompt", row.get("reference"))
    context = f"prompt row {index}"
    if not isinstance(prompt_id, str) or not prompt_id:
        raise ValueError(f"{context}: prompt_id or id must be a non-empty string")
    if any(
        character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for character in prompt_id
    ):
        raise ValueError(f"{context}: prompt id must contain only letters, digits, '.', '_', or '-'")
    if not isinstance(prompt, str) or not prompt:
        raise ValueError(f"{context}: prompt or reference must be a non-empty string")
    return prompt_id, prompt


def _validate_matrix_axis(name: str, values: Sequence[Any]) -> None:
    if not values:
        raise ValueError(f"{name} must not be empty")
    if len(values) != len(set(values)):
        raise ValueError(f"{name} contains duplicate values")


def capture_command(row: dict[str, Any], executable: str | Path | None = None) -> list[str]:
    program = str(executable) if executable is not None else _require_nonempty_string(row, "executable", "capture row")
    return [
        program,
        "--mode",
        _require_nonempty_string(row, "mode", "capture row"),
        "--duration-ms",
        str(row["duration_ms"]),
        "--pre-roll-ms",
        str(row["pre_roll_ms"]),
        "--post-roll-ms",
        str(row["post_roll_ms"]),
        "--output",
        _require_nonempty_string(row, "output_path", "capture row"),
    ]


def plan_matrix(
    prompts: Sequence[dict[str, Any]],
    output_dir: Path,
    *,
    executable: str | Path = "voiceoour-capture-bench",
    modes: Sequence[str] = CAPTURE_MODES,
    conditions: Sequence[str] = CONDITIONS,
    pre_roll_ms: Sequence[int] = DEFAULT_PRE_ROLL_MS,
    post_roll_ms: Sequence[int] = DEFAULT_POST_ROLL_MS,
    takes: int = 2,
    duration_ms: int = 8_000,
    speaker_id: str,
    speaker_kind: str,
) -> list[dict[str, Any]]:
    """Return a stable row-per-capture matrix; no audio APIs or subprocesses are used."""
    _validate_matrix_axis("modes", modes)
    _validate_matrix_axis("conditions", conditions)
    _validate_matrix_axis("pre_roll_ms", pre_roll_ms)
    _validate_matrix_axis("post_roll_ms", post_roll_ms)
    unknown_modes = sorted(set(modes) - set(CAPTURE_MODES))
    unknown_conditions = sorted(set(conditions) - set(CONDITIONS))
    if unknown_modes:
        raise ValueError(f"unknown capture modes: {', '.join(unknown_modes)}")
    if unknown_conditions:
        raise ValueError(f"unknown conditions: {', '.join(unknown_conditions)}")
    if any(
        not isinstance(value, int) or isinstance(value, bool) or value < 0 for value in (*pre_roll_ms, *post_roll_ms)
    ):
        raise ValueError("pre/post-roll values must be non-negative integers")
    if not isinstance(takes, int) or isinstance(takes, bool) or takes < 1:
        raise ValueError("takes must be a positive integer")
    if not isinstance(duration_ms, int) or isinstance(duration_ms, bool) or duration_ms < 1:
        raise ValueError("duration_ms must be a positive integer")
    if not speaker_id:
        raise ValueError("speaker_id must not be empty")
    if speaker_kind not in {"real", "tts"}:
        raise ValueError("speaker_kind must be 'real' or 'tts'")

    normalized_prompts: list[tuple[str, str]] = []
    seen_prompt_ids: set[str] = set()
    for index, prompt_row in enumerate(prompts, start=1):
        prompt_id, prompt = _prompt_fields(prompt_row, index)
        if prompt_id in seen_prompt_ids:
            raise ValueError(f"duplicate prompt id: {prompt_id}")
        seen_prompt_ids.add(prompt_id)
        normalized_prompts.append((prompt_id, prompt))
    if not normalized_prompts:
        raise ValueError("prompts must not be empty")

    rows: list[dict[str, Any]] = []
    for prompt_id, prompt in normalized_prompts:
        for take_number in range(1, takes + 1):
            take_id = f"take-{take_number:02d}"
            for condition in conditions:
                for pre_roll in pre_roll_ms:
                    for post_roll in post_roll_ms:
                        pair_id = f"{prompt_id}__{take_id}__{condition}__pre-{pre_roll}__post-{post_roll}"
                        for mode in modes:
                            capture_id = f"{pair_id}__{mode}"
                            output_path = output_dir / condition / prompt_id / f"{capture_id}.wav"
                            row: dict[str, Any] = {
                                "type": "capture_plan",
                                "id": capture_id,
                                "pair_id": pair_id,
                                "prompt_id": prompt_id,
                                "prompt": prompt,
                                "take_id": take_id,
                                "speaker_id": speaker_id,
                                "speaker_kind": speaker_kind,
                                "evidence_scope": "primary" if speaker_kind == "real" else "smoke-only",
                                "condition": condition,
                                "condition_instruction": CONDITION_INSTRUCTIONS[condition],
                                "manual_required": True,
                                "hardware_dependent": condition in HARDWARE_DEPENDENT_CONDITIONS,
                                "mode": mode,
                                "duration_ms": duration_ms,
                                "pre_roll_ms": pre_roll,
                                "post_roll_ms": post_roll,
                                "output_path": str(output_path),
                                "executable": str(executable),
                            }
                            row["command"] = capture_command(row)
                            rows.append(row)
    return rows


def dry_run_commands(rows: Sequence[dict[str, Any]], executable: str | Path | None = None) -> list[list[str]]:
    """Build commands without touching the microphone or starting the executable."""
    return [capture_command(row, executable) for row in rows]


def _parse_capture_stdout(stdout: str) -> dict[str, Any]:
    lines = [line for line in stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError(f"capture executable must print exactly one non-empty JSON line, got {len(lines)}")
    value = json.loads(lines[0])
    if not isinstance(value, dict):
        raise ValueError("capture executable result must be a JSON object")
    return value


def _reported_output_path(result: dict[str, Any]) -> str:
    for key in ("output_path", "output"):
        value = result.get(key)
        if isinstance(value, str) and value:
            return value
    raise ValueError("capture executable result is missing output_path")


def _paths_match(planned: str, reported: str) -> bool:
    return Path(planned).expanduser().resolve(strict=False) == Path(reported).expanduser().resolve(strict=False)


def _validated_telemetry(row: dict[str, Any], capture: dict[str, Any]) -> dict[str, Any]:
    expected_fields = {
        "mode": row["mode"],
        "requested_duration_ms": row["duration_ms"],
        "pre_roll_ms": row["pre_roll_ms"],
        "post_roll_ms": row["post_roll_ms"],
    }
    for field, expected in expected_fields.items():
        actual = capture.get(field)
        if actual != expected:
            raise ValueError(
                f"capture {row.get('id')}: executable {field} mismatch; expected {expected!r}, got {actual!r}"
            )
    captured_duration = capture.get("captured_duration_ms")
    if not isinstance(captured_duration, int | float) or isinstance(captured_duration, bool) or captured_duration < 0:
        raise ValueError(f"capture {row.get('id')}: executable captured_duration_ms must be non-negative")
    telemetry = capture.get("telemetry")
    if not isinstance(telemetry, dict):
        raise ValueError(f"capture {row.get('id')}: executable telemetry must be a JSON object")
    return telemetry


def run_matrix(
    rows: Sequence[dict[str, Any]],
    results_path: Path,
    *,
    executable: str | Path | None = None,
    consent_confirmed: bool = False,
) -> list[dict[str, Any]]:
    """Run the capture CLI serially and persist decorated JSONL results."""
    if any(row.get("speaker_kind") == "real" for row in rows) and not consent_confirmed:
        raise ValueError("real-speaker collection requires consent_confirmed=True")

    result_rows: list[dict[str, Any]] = []
    results_path.parent.mkdir(parents=True, exist_ok=True)
    with results_path.open("w", encoding="utf-8") as results_handle:
        for row in rows:
            planned_output = _require_nonempty_string(row, "output_path", "capture row")
            Path(planned_output).expanduser().parent.mkdir(parents=True, exist_ok=True)
            command = capture_command(row, executable)
            completed = subprocess.run(command, check=True, capture_output=True, text=True)
            capture = _parse_capture_stdout(completed.stdout)
            reported_output = _reported_output_path(capture)
            if not _paths_match(planned_output, reported_output):
                raise ValueError(
                    f"capture {row.get('id')}: executable reported output {reported_output!r}, "
                    f"expected {planned_output!r}"
                )
            result_row = {
                "type": "capture_result",
                "id": row["id"],
                "pair_id": row["pair_id"],
                "prompt_id": row["prompt_id"],
                "prompt": row["prompt"],
                "take_id": row["take_id"],
                "mode": row["mode"],
                "condition": row["condition"],
                "output_path": reported_output,
                "requested_duration_ms": capture["requested_duration_ms"],
                "captured_duration_ms": capture["captured_duration_ms"],
                "pre_roll_ms": capture["pre_roll_ms"],
                "post_roll_ms": capture["post_roll_ms"],
                "telemetry": _validated_telemetry(row, capture),
            }
            for provenance_field in ("implementation", "endpoint_bounding_applied"):
                if provenance_field in capture:
                    result_row[provenance_field] = capture[provenance_field]
            result_rows.append(result_row)
            results_handle.write(
                json.dumps(
                    result_row,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
            results_handle.write("\n")
            results_handle.flush()
    return result_rows


def ingest_results(
    manifest_rows: Sequence[dict[str, Any]], result_rows: Sequence[dict[str, Any]]
) -> dict[str, dict[str, Any]]:
    """Validate result identity and return results keyed by capture id."""
    manifest_by_id: dict[str, dict[str, Any]] = {}
    for row in manifest_rows:
        capture_id = _require_nonempty_string(row, "id", "manifest row")
        if capture_id in manifest_by_id:
            raise ValueError(f"duplicate manifest capture id: {capture_id}")
        manifest_by_id[capture_id] = row

    results_by_id: dict[str, dict[str, Any]] = {}
    identity_fields = ("prompt_id", "prompt", "take_id", "pair_id", "mode", "condition")
    for result in result_rows:
        capture_id = _require_nonempty_string(result, "id", "result row")
        if capture_id in results_by_id:
            raise ValueError(f"duplicate result capture id: {capture_id}")
        manifest = manifest_by_id.get(capture_id)
        if manifest is None:
            raise ValueError(f"result references unknown capture id: {capture_id}")
        for field in identity_fields:
            expected = manifest.get(field)
            actual = result.get(field)
            if actual != expected:
                raise ValueError(f"capture {capture_id}: {field} mismatch; expected {expected!r}, got {actual!r}")
        results_by_id[capture_id] = result
    return results_by_id


def build_report(manifest_rows: Sequence[dict[str, Any]], result_rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """Build an explicit collection report; it makes no audio-quality pass claim."""
    results_by_id = ingest_results(manifest_rows, result_rows)
    rows: list[dict[str, Any]] = []
    captured = 0
    errors = 0
    missing_manual = 0
    missing_hardware = 0
    for plan in manifest_rows:
        capture_id = str(plan["id"])
        result = results_by_id.get(capture_id)
        if result is None:
            status = "missing-manual" if plan.get("manual_required") else "missing"
            if plan.get("manual_required"):
                missing_manual += 1
            if plan.get("hardware_dependent"):
                missing_hardware += 1
        elif result.get("error"):
            status = "capture-error"
            errors += 1
        else:
            status = "captured"
            captured += 1
        rows.append(
            {
                "id": capture_id,
                "pair_id": plan.get("pair_id"),
                "prompt_id": plan.get("prompt_id"),
                "prompt": plan.get("prompt"),
                "take_id": plan.get("take_id"),
                "speaker_id": plan.get("speaker_id"),
                "speaker_kind": plan.get("speaker_kind"),
                "evidence_scope": plan.get("evidence_scope"),
                "condition": plan.get("condition"),
                "mode": plan.get("mode"),
                "condition_instruction": plan.get("condition_instruction"),
                "duration_ms": plan.get("duration_ms"),
                "pre_roll_ms": plan.get("pre_roll_ms"),
                "post_roll_ms": plan.get("post_roll_ms"),
                "output_path": plan.get("output_path"),
                "manual_required": bool(plan.get("manual_required")),
                "hardware_dependent": bool(plan.get("hardware_dependent")),
                "collection_status": status,
                "result": result,
            }
        )

    missing = len(manifest_rows) - captured - errors
    return {
        "type": "capture_matrix_report",
        "collection_status": "complete" if missing == 0 and errors == 0 else "incomplete",
        "quality_verdict": "not-evaluated",
        "counts": {
            "planned": len(manifest_rows),
            "captured": captured,
            "capture_errors": errors,
            "missing": missing,
            "missing_manual": missing_manual,
            "missing_hardware_dependent": missing_hardware,
        },
        "rows": rows,
    }


def _split_csv(values: Sequence[str]) -> tuple[str, ...]:
    return tuple(item for value in values for item in value.split(",") if item)


def _add_plan_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--prompts", type=Path, required=True, help="JSONL rows with prompt_id/id and prompt/reference")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--speaker-id", required=True, help="stable pseudonymous speaker id")
    parser.add_argument("--speaker-kind", choices=("real", "tts"), required=True)
    parser.add_argument("--executable", default="voiceoour-capture-bench")
    parser.add_argument("--modes", nargs="+", default=list(CAPTURE_MODES))
    parser.add_argument("--conditions", nargs="+", default=list(CONDITIONS))
    parser.add_argument("--pre-roll-ms", nargs="+", type=int, default=list(DEFAULT_PRE_ROLL_MS))
    parser.add_argument("--post-roll-ms", nargs="+", type=int, default=list(DEFAULT_POST_ROLL_MS))
    parser.add_argument("--takes", type=int, default=2)
    parser.add_argument("--duration-ms", type=int, default=8_000)
    parser.add_argument("--dry-run", action="store_true", help="print stable commands; planning never accesses audio")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Plan and collect the VoiceOour paired capture matrix.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan_parser = subparsers.add_parser("plan", help="write a deterministic capture manifest")
    _add_plan_arguments(plan_parser)

    run_parser = subparsers.add_parser("run", help="run or dry-run a planned manifest")
    run_parser.add_argument("--manifest", type=Path, required=True)
    run_parser.add_argument("--results", type=Path, required=True)
    run_parser.add_argument("--executable", default=None)
    run_parser.add_argument("--dry-run", action="store_true")
    run_parser.add_argument("--consent-confirmed", action="store_true")

    report_parser = subparsers.add_parser("report", help="ingest JSONL and write a complete collection report")
    report_parser.add_argument("--manifest", type=Path, required=True)
    report_parser.add_argument("--results", type=Path, required=True)
    report_parser.add_argument("--output", type=Path, required=True)

    args = parser.parse_args(argv)
    if args.command == "plan":
        modes = _split_csv(args.modes)
        conditions = _split_csv(args.conditions)
        rows = plan_matrix(
            read_jsonl(args.prompts),
            args.output_dir,
            executable=args.executable,
            modes=modes,
            conditions=conditions,
            pre_roll_ms=tuple(args.pre_roll_ms),
            post_roll_ms=tuple(args.post_roll_ms),
            takes=args.takes,
            duration_ms=args.duration_ms,
            speaker_id=args.speaker_id,
            speaker_kind=args.speaker_kind,
        )
        write_jsonl(args.manifest, rows)
        if args.dry_run:
            for command in dry_run_commands(rows):
                print(shlex.join(command))
        print(f"Manifest: {args.manifest}")
        print(f"Planned captures: {len(rows)}")
        return 0

    manifest_rows = read_jsonl(args.manifest)
    if args.command == "run":
        if args.dry_run:
            for command in dry_run_commands(manifest_rows, args.executable):
                print(shlex.join(command))
            return 0
        result_rows = run_matrix(
            manifest_rows,
            args.results,
            executable=args.executable,
            consent_confirmed=args.consent_confirmed,
        )
        print(f"Results: {args.results}")
        print(f"Captured: {len(result_rows)}")
        return 0

    result_rows = read_jsonl(args.results)
    report = build_report(manifest_rows, result_rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Report: {args.output}")
    print(json.dumps(report["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
