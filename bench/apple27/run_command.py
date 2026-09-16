"""Run one prototype command with an explicit environment, watchdog, logs and client RSS."""

from __future__ import annotations

import argparse
import json
import math
import os
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path


def run(command: list[str], prefix: Path, timeout: float, extra_env: dict[str, str], minimum_free_gib: float) -> dict:
    prefix.parent.mkdir(parents=True, exist_ok=True)
    floor_bytes = int(minimum_free_gib * 1024**3)
    if shutil.disk_usage(prefix.parent).free < floor_bytes:
        raise RuntimeError(f"Insufficient free disk space for an experiment; require {minimum_free_gib:g} GiB")
    scratch = Path(tempfile.mkdtemp(prefix=prefix.name + "-", dir=prefix.parent)).resolve()
    system_temporary = Path(tempfile.gettempdir())
    environment = {key: os.environ[key] for key in ("PATH", "HOME") if key in os.environ}
    environment.update(
        {
            "VOICEOUR_MODEL_VARIANT": "f16",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "DO_NOT_TRACK": "1",
            "TOKENIZERS_PARALLELISM": "false",
            **extra_env,
            "TMPDIR": str(scratch) + "/",
        }
    )
    started = datetime.now(UTC).isoformat()
    start = time.monotonic()
    started_wall = time.time()
    process = None
    removed_compiler_scratch = []
    stop_reason = None
    minimum_observed_free = shutil.disk_usage(prefix.parent).free
    try:
        with (
            prefix.with_suffix(".stdout.log").open("x") as stdout,
            prefix.with_suffix(".stderr.log").open("x") as stderr,
        ):
            process = subprocess.Popen(command, env=environment, stdout=stdout, stderr=stderr, start_new_session=True)
            while process.poll() is None:
                free = shutil.disk_usage(prefix.parent).free
                minimum_observed_free = min(minimum_observed_free, free)
                if free < floor_bytes:
                    stop_reason = "free_disk_floor"
                    break
                if time.monotonic() - start >= timeout:
                    stop_reason = "timeout"
                    break
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
            if stop_reason is not None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            code = process.returncode
    finally:
        shutil.rmtree(scratch)
        if process is not None and process.poll() is not None:
            # MPSGraph ignores TMPDIR on this SDK. Reclaim only directories born
            # during this run and bearing the exact child pid we just waited for.
            compiler_root = system_temporary / "com.apple.MetalPerformanceShadersGraph"
            if compiler_root.is_dir():
                for directory in compiler_root.glob(f"mpsgraph-{process.pid}-*"):
                    created = getattr(directory.stat(), "st_birthtime", directory.stat().st_ctime)
                    if directory.is_dir() and created >= started_wall:
                        shutil.rmtree(directory)
                        removed_compiler_scratch.append(str(directory))
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    result = {
        "command": command,
        "started_at": started,
        "pid": process.pid,
        "removed_compiler_scratch": removed_compiler_scratch,
        "exit_code": code,
        "timed_out": stop_reason == "timeout",
        "stop_reason": stop_reason,
        "minimum_free_disk_gib": minimum_free_gib,
        "minimum_observed_free_bytes": minimum_observed_free,
        "isolated_temporary_directory": str(scratch),
        "temporary_directory_removed": True,
        "wall_seconds": time.monotonic() - start,
        "maximum_client_rss_bytes": usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024),
        "user_cpu_seconds": usage.ru_utime,
        "system_cpu_seconds": usage.ru_stime,
        "memory_scope": (
            "Child-process maximum RSS, not simultaneous process-tree total; Apple system model servers excluded."
        ),
        "environment": {key: value for key, value in environment.items() if key not in ("PATH", "HOME", "TMPDIR")},
        "stdout": str(prefix.with_suffix(".stdout.log")),
        "stderr": str(prefix.with_suffix(".stderr.log")),
    }
    with prefix.with_suffix(".run.json").open("x") as handle:
        json.dump(result, handle, indent=2)
        handle.write("\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--minimum-free-gib", type=float, default=8.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if not math.isfinite(arguments.timeout) or arguments.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    if not math.isfinite(arguments.minimum_free_gib) or arguments.minimum_free_gib <= 0:
        parser.error("--minimum-free-gib must be finite and positive")
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("Provide a command after --")
    environment = dict(item.split("=", 1) for item in arguments.env)
    result = run(command, arguments.prefix, arguments.timeout, environment, arguments.minimum_free_gib)
    print(json.dumps(result, indent=2))
    sys.exit(1 if result["stop_reason"] else result["exit_code"] if result["exit_code"] >= 0 else 1)


if __name__ == "__main__":
    main()
