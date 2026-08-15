"""Voiceour benchmark orchestrator."""

from __future__ import annotations

import argparse
import os
import subprocess
from datetime import UTC, datetime
from pathlib import Path

from .datasets_prep import prepare_tier, repo_root
from .report import build_report, markdown_table

# Mirrors `ASRBackendRegistry.builtIn` in Sources/VoiceMac/ASRBackendRegistry.swift.
# The Swift runner validates the id against the registry itself; this list only
# exists so a typo fails here instead of after a release build.
ASR_BACKENDS = ("fake", "parakeet")


def _run(args: list[str], cwd: Path, env: dict[str, str] | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True, env=env)


def _build_swift_runner(root: Path) -> Path:
    # The ASR sidecar is a sibling of the runner in .build/release, and that is how the
    # runner finds it, so both products must be built before the benchmark starts.
    _run(["swift", "build", "-c", "release", "--product", "voiceour-bench"], cwd=root)
    _run(["swift", "build", "-c", "release", "--product", "voiceour-asr"], cwd=root)
    runner = root / ".build" / "release" / "voiceour-bench"
    if not runner.exists():
        raise FileNotFoundError(f"Swift benchmark runner was not produced at {runner}")
    return runner


def _results_jsonl_path(root: Path, tier: str, mode: str, backend: str | None) -> Path:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    output_dir = root / "benchmarks" / "results"
    output_dir.mkdir(parents=True, exist_ok=True)
    # An A/B sweep runs the same tier and mode once per backend, so without the
    # backend in the name the runs are told apart only by their timestamps.
    parts = [stamp, tier, backend, mode] if backend else [stamp, tier, mode]
    return output_dir / f"{'-'.join(parts)}.results.jsonl"


def _invoke_runner(runner: Path, args: argparse.Namespace, manifest: Path, output: Path, root: Path) -> None:
    command = [
        str(runner),
        "pipeline",
        "--input",
        str(manifest),
        "--output",
        str(output),
        "--backend",
        args.backend,
        "--timeout-ms",
        str(args.timeout_ms),
    ]
    _run(command, cwd=root, env={**os.environ})


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run Voiceour production-path benchmarks.")
    parser.add_argument("--tier", choices=("smoke", "librispeech", "fleurs", "techterms"), required=True)
    parser.add_argument("--mode", choices=("stt", "e2e"), required=True)
    parser.add_argument("--n", type=int, default=None, help="first-N rows for HF-backed tiers")
    parser.add_argument("--backend", choices=ASR_BACKENDS, default="parakeet")
    parser.add_argument("--timeout-ms", type=int, default=120000)
    args = parser.parse_args(argv)

    root = repo_root()
    runner = _build_swift_runner(root)
    manifest = prepare_tier(args.tier, args.n, root=root)
    if not manifest.exists():
        raise FileNotFoundError(f"benchmark input does not exist: {manifest}")
    with manifest.open(encoding="utf-8") as manifest_file:
        rows = sum(1 for _ in manifest_file)
    print(
        f"[bench] manifest {manifest.name}: {rows} rows "
        "(librispeech counts test.clean+test.other; --n is per split)"
    )

    results_jsonl = _results_jsonl_path(root, args.tier, args.mode, args.backend)
    _invoke_runner(runner, args, manifest, results_jsonl, root)
    report, report_path = build_report(results_jsonl, manifest, args.tier, args.mode)
    print(markdown_table(report))
    print(f"\nResults JSONL: {results_jsonl}")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
