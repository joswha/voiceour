#!/usr/bin/env python3
from __future__ import annotations

import argparse
import resource
import statistics
import sys
import time
from pathlib import Path

from voiceoour_asr import cache


def transcribe_once(path: Path) -> tuple[str, float, float, int]:
    start = time.perf_counter()
    cache.ensure_model(cache.PARAKEET)
    from parakeet_mlx import from_pretrained
    model = from_pretrained(cache.MODEL_ID, cache_dir=str(cache.PARAKEET.cache_dir))
    loaded = time.perf_counter()
    result = model.transcribe(str(path))
    done = time.perf_counter()
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return getattr(result, "text", ""), (loaded - start) * 1000, (done - loaded) * 1000, rss


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--bench", action="store_true")
    args = parser.parse_args()
    if args.bench:
        samples = []
        for _ in range(3):
            _, _, inference, _ = transcribe_once(args.audio)
            samples.append(inference)
        print(f"bench p50_ms={statistics.median(samples):.0f} p95_ms={max(samples):.0f}")
        return 0
    text, load_ms, inference_ms, rss = transcribe_once(args.audio)
    print(f"transcript={text}")
    print(f"cold_load_ms={load_ms:.0f} warm_inference_ms={inference_ms:.0f} rss_bytes={rss}")
    lowered = text.lower()
    if not text.strip() or ("hello" not in lowered and "world" not in lowered):
        print("expected non-empty transcript containing hello/world", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
