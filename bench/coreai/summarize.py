"""Offline summary of one paired Core AI encoder corpus; no ML dependencies."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import sys
from datetime import UTC, datetime
from pathlib import Path


def load_run(path: Path, *, requires_metadata: bool = True) -> dict:
    run = {"path": str(path), "bench_meta": None, "encoder_meta": None, "rows": {}}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        record = json.loads(line)
        kind = record.get("type")
        if kind in ("bench_meta", "encoder_meta"):
            if run[kind] is not None:
                raise ValueError(f"{path}:{number}: duplicate {kind}")
            run[kind] = record
        elif kind == "row":
            identifier = record["id"]
            if identifier in run["rows"]:
                raise ValueError(f"{path}:{number}: duplicate row {identifier}")
            run["rows"][identifier] = record
        else:
            raise ValueError(f"{path}:{number}: unexpected record type {kind!r}")
    if requires_metadata and run["bench_meta"] is None:
        raise ValueError(f"{path}: missing bench_meta")
    return run


def percentiles(values) -> dict:
    """Same finite-value linear interpolation as voiceour_bench.metrics."""
    values = sorted(float(value) for value in values if value is not None and math.isfinite(float(value)))
    result = {"n": len(values)}
    for percentile in (50, 95):
        rank = percentile / 100 * (len(values) - 1)
        lower, upper = math.floor(rank), math.ceil(rank)
        result[f"p{percentile}"] = values[lower] + (values[upper] - values[lower]) * (rank - lower) if values else None
    return result


def summarize_engine(run: dict) -> dict:
    errors = {key: row["error"] for key, row in run["rows"].items() if row.get("error")}
    successful = [row for row in run["rows"].values() if not row.get("error")]
    return {
        "results_jsonl": run["path"],
        "rows": len(run["rows"]),
        "error_rows": errors,
        "error_count": len(errors),
        "asr_inference_ms": percentiles(row["timings_ms"].get("asr_inference") for row in successful),
        "encoder": {
            stage: percentiles((row.get("encoder") or {}).get(stage) for row in successful)
            for stage in ("mel_ms", "encode_ms", "tail_ms")
        },
        "bench_meta": run["bench_meta"],
        "encoder_meta": run["encoder_meta"],
    }


def compare_transcripts(left: dict, right: dict) -> dict:
    left_ids, right_ids = set(left["rows"]), set(right["rows"])
    compared, equal = 0, 0
    different, errors = [], []
    for identifier in sorted(left_ids & right_ids):
        a, b = left["rows"][identifier], right["rows"][identifier]
        if a.get("error") or b.get("error"):
            errors.append(identifier)
            continue
        compared += 1
        if a["raw_transcript"].encode("utf-8") == b["raw_transcript"].encode("utf-8"):
            equal += 1
        else:
            different.append(identifier)
    return {
        "compared": compared,
        "byte_identical": equal,
        "different_ids": different,
        "error_ids": errors,
        "only_left": sorted(left_ids - right_ids),
        "only_right": sorted(right_ids - left_ids),
    }


def same_configuration(left: dict, right: dict) -> bool:
    keys = ("engine", "compute", "cache_policy", "model_tree_sha256")
    return all(left["encoder_meta"].get(key) == right["encoder_meta"].get(key) for key in keys)


def determinism(primary: dict, repeats: list[dict]) -> dict:
    witnesses = []
    for repeat in repeats:
        identity = compare_transcripts(primary, repeat)
        different, missing = [], []
        for identifier in sorted(primary["rows"].keys() & repeat["rows"].keys()):
            a = (primary["rows"][identifier].get("encoder") or {}).get("states_sha256")
            b = (repeat["rows"][identifier].get("encoder") or {}).get("states_sha256")
            if a is None or b is None:
                missing.append(identifier)
            elif a != b:
                different.append(identifier)
        passed = same_configuration(primary, repeat) and not any(
            (
                identity["different_ids"],
                identity["error_ids"],
                identity["only_left"],
                identity["only_right"],
                different,
                missing,
            )
        )
        witnesses.append(
            {
                "path": repeat["path"],
                "passed": passed,
                "transcripts": identity,
                "different_state_ids": different,
                "missing_state_ids": missing,
            }
        )
    return {
        "status": "not measured" if not witnesses else ("pass" if all(w["passed"] for w in witnesses) else "fail"),
        "witnesses": witnesses,
    }


def load_gate(specification: str) -> tuple[str, dict]:
    label, separator, filename = specification.partition("=")
    if not separator or not label or not filename:
        raise ValueError("--gate expects LABEL=PATH")
    path = Path(filename)
    data = path.read_bytes()
    decision = json.loads(data)["decision"]
    return label, {"path": str(path), "sha256": hashlib.sha256(data).hexdigest(), "decision": decision}


def build_report(args: argparse.Namespace) -> dict:
    runs = {
        name: load_run(getattr(args, name), requires_metadata=name != "native")
        for name in ("native", "coreml", "coreai")
    }
    if args.coreai_neural_engine:
        runs["coreai-neural-engine"] = load_run(args.coreai_neural_engine)
    repeats = [load_run(path) for path in args.coreai_repeat]
    warm = load_run(args.coreai_warm) if args.coreai_warm else None
    for name, run in list(runs.items()) + [("repeat", r) for r in repeats] + ([] if warm is None else [("warm", warm)]):
        if name != "native" and run["encoder_meta"] is None:
            raise ValueError(f"{run['path']}: missing encoder_meta")
    native_ids = set(runs["native"]["rows"])
    if args.retained_rows is not None and args.retained_rows != len(native_ids):
        raise ValueError("--retained-rows differs from the native run's row count")
    if args.corpus_manifest:
        expected = {json.loads(line)["id"] for line in args.corpus_manifest.read_text().splitlines() if line.strip()}
        if expected != native_ids:
            raise ValueError("corpus manifest and native result row ids differ")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if manifest.get("status") != "ok":
        raise ValueError(f"{args.manifest}: conversion was not successful")
    pairs = {f"{a}-vs-{b}": compare_transcripts(runs[a], runs[b]) for a, b in itertools.combinations(runs, 2)}
    findings = []
    for name, pair in pairs.items():
        if pair["only_left"] or pair["only_right"]:
            findings.append(f"{name}: row sets differ")
    for key in ("manifest_sha256", "audio_manifest_sha256", "model_file"):
        if len({run["bench_meta"].get(key) for run in runs.values() if run["bench_meta"] is not None}) != 1:
            findings.append(f"runs disagree on {key}")
    if runs["coreai"]["encoder_meta"]["model_tree_sha256"] != manifest["artifact"]["tree_sha256"]:
        findings.append("CoreAI run and conversion manifest tree digests differ")
    if warm is not None and not same_configuration(runs["coreai"], warm):
        findings.append("warm and cold CoreAI configurations differ")
    deterministic = determinism(runs["coreai"], repeats)
    if deterministic["status"] == "fail":
        findings.append("CoreAI determinism failed")
    return {
        "schema_version": 1,
        "kind": "coreai-encoder-experiment-corpus-summary",
        "created_at": datetime.now(UTC).isoformat(),
        "status": "failed" if findings else "measured",
        "corpus": {"name": args.corpus, "retained": len(native_ids), "dropped": args.dropped_rows},
        "engines": {name: summarize_engine(run) for name, run in runs.items()},
        "transcript_identity": pairs,
        "specialization": {
            "cold": runs["coreai"]["encoder_meta"],
            "warm": None if warm is None else warm["encoder_meta"],
        },
        "determinism": deterministic,
        "paired_gates": dict(load_gate(specification) for specification in args.gate),
        "artifact": manifest,
        "findings": findings,
        "notes": [
            "Benchmark-only, one static 15 s encoder; no product recognizer change.",
            "CoreAI weights are unquantized; the CoreML comparator is the 6-bit palettized standard tier.",
            "CoreAI tail_ms includes the native tail's additional mel recomputation; CoreML tail_ms does not.",
            "CoreML encode_ms includes native mel time; CoreAI reports mel_ms separately.",
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for engine in ("native", "coreml", "coreai"):
        parser.add_argument(engine, type=Path, help=f"{engine} results.jsonl")
    parser.add_argument("--manifest", type=Path, required=True, help="conversion artifact manifest JSON")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--corpus")
    parser.add_argument("--retained-rows", type=int)
    parser.add_argument("--dropped-rows", type=int)
    parser.add_argument("--corpus-manifest", type=Path, help="filtered corpus JSONL")
    parser.add_argument("--coreai-neural-engine", type=Path)
    parser.add_argument("--coreai-warm", type=Path)
    parser.add_argument("--coreai-repeat", type=Path, action="append", default=[])
    parser.add_argument("--gate", action="append", default=[], metavar="LABEL=PATH")
    args = parser.parse_args(argv)
    try:
        report = build_report(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n", encoding="utf-8"
        )
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"summarize.py: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"output": str(args.output), "status": report["status"]}))
    return 1 if report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
