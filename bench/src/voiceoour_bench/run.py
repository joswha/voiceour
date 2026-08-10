"""VoiceOour benchmark orchestrator."""

from __future__ import annotations

import argparse
import os
import subprocess
from datetime import UTC, datetime
from pathlib import Path

from .datasets_prep import fleurs_manifest_to_refine_cases, prepare_tier, repo_root
from .report import build_report, markdown_table


def _run(args: list[str], cwd: Path, env: dict[str, str] | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True, env=env)


def _build_swift_runner(root: Path) -> Path:
    _run(["swift", "build", "-c", "release", "--product", "voiceoour-bench"], cwd=root)
    runner = root / ".build" / "release" / "voiceoour-bench"
    if not runner.exists():
        raise FileNotFoundError(f"Swift benchmark runner was not produced at {runner}")
    return runner


def _results_jsonl_path(root: Path, tier: str, mode: str) -> Path:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    output_dir = root / "benchmarks" / "results"
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir / f"{stamp}-{tier}-{mode}.results.jsonl"


def _runner_refine_mode(mode: str, refine: str | None) -> str:
    if mode == "stt":
        return "off"
    if mode == "e2e":
        return refine or "deterministic"
    if mode == "refine":
        return refine or "deterministic"
    raise ValueError(f"unknown mode: {mode}")


def _append_refiner_flags(command: list[str], args: argparse.Namespace) -> None:
    if args.refiner_base_url:
        command.extend(["--refiner-base-url", args.refiner_base_url])
    if args.refiner_model:
        command.extend(["--refiner-model", args.refiner_model])
    if args.refiner_api_key_env:
        command.extend(["--refiner-api-key-env", args.refiner_api_key_env])


def _invoke_runner(runner: Path, args: argparse.Namespace, manifest: Path, output: Path, root: Path) -> None:
    refine_mode = _runner_refine_mode(args.mode, args.refine)
    if args.mode == "refine":
        command = [str(runner), "refine", "--input", str(manifest), "--output", str(output), "--refine", refine_mode]
        _append_refiner_flags(command, args)
    else:
        command = [
            str(runner),
            "pipeline",
            "--input",
            str(manifest),
            "--output",
            str(output),
            "--asr-dir",
            args.asr_dir,
            "--backend",
            args.backend,
            "--timeout-ms",
            str(args.timeout_ms),
            "--refine",
            refine_mode,
        ]
        _append_refiner_flags(command, args)
    env = {**os.environ, "VOICEOOUR_ASR_DECODING": args.decoding}
    _run(command, cwd=root, env=env)


def _refine_manifest(args: argparse.Namespace, root: Path) -> Path:
    if args.tier == "fleurs":
        fleurs_manifest = prepare_tier("fleurs", args.n, root=root)
        return fleurs_manifest_to_refine_cases(fleurs_manifest, root=root)
    return root / "fixtures" / "bench" / "refine_cases.jsonl"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run VoiceOour production-path benchmarks.")
    parser.add_argument("--tier", choices=("smoke", "librispeech", "fleurs", "techterms"), required=True)
    parser.add_argument("--mode", choices=("stt", "refine", "e2e"), required=True)
    parser.add_argument("--n", type=int, default=None, help="first-N rows for HF-backed tiers")
    parser.add_argument("--backend", choices=("fake", "mlx"), default="mlx")
    parser.add_argument(
        "--decoding",
        choices=("greedy", "beam"),
        default="greedy",
        help="ASR decoding mode for the sidecar (sets VOICEOOUR_ASR_DECODING)",
    )
    parser.add_argument("--refine", choices=("deterministic", "llm", "omp"), default=None)
    parser.add_argument("--timeout-ms", type=int, default=120000)
    parser.add_argument("--asr-dir", default="asr")
    parser.add_argument("--refiner-base-url", default=None)
    parser.add_argument("--refiner-model", default=None)
    parser.add_argument("--refiner-api-key-env", default=None)
    args = parser.parse_args(argv)

    root = repo_root()
    runner = _build_swift_runner(root)
    if args.mode == "refine":
        manifest = _refine_manifest(args, root)
    else:
        manifest = prepare_tier(args.tier, args.n, root=root)
    if not manifest.exists():
        raise FileNotFoundError(f"benchmark input does not exist: {manifest}")

    results_jsonl = _results_jsonl_path(root, args.tier, args.mode)
    _invoke_runner(runner, args, manifest, results_jsonl, root)
    report, report_path = build_report(results_jsonl, manifest, args.tier, args.mode)
    print(markdown_table(report))
    print(f"\nResults JSONL: {results_jsonl}")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
