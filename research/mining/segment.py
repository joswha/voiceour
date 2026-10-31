"""Stage 3 — silero-vad segmentation into 1-15 s utterances with 0.3 s padding.

Thresholds are explicit CLI parameters with fixed defaults and are recorded in
the manifest, so the segmentation is reproducible byte-for-byte:

  threshold=0.5, min_speech_duration_ms=1000, max_speech_duration_s=15.0,
  min_silence_duration_ms=300, speech_pad_ms=300, window_size_samples=512

silero's `max_speech_duration_s` already splits over-long speech runs at the
best internal silence, so no ad-hoc chopping is needed; any residual region
longer than the cap (silero can overshoot by the padding) is hard-cut on a
deterministic grid, and regions shorter than --min-duration are dropped.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import Timer, file_digest_record, sha256_file, write_jsonl, write_manifest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--wav", required=True, help="16 kHz mono wav from stage 2")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--talk-id", required=True)
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--min-duration", type=float, default=1.0, help="drop utterances shorter than this (s)")
    ap.add_argument("--max-duration", type=float, default=15.0, help="hard utterance cap (s)")
    ap.add_argument("--min-silence-ms", type=int, default=300)
    ap.add_argument("--speech-pad-ms", type=int, default=300)
    ap.add_argument("--window-size-samples", type=int, default=512)
    ap.add_argument("--sample-rate", type=int, default=16000)
    ap.add_argument("--limit", type=int, default=0, help="keep only the first N segments (0 = all)")
    args = ap.parse_args()

    import numpy as np
    import soundfile as sf
    import torch
    from silero_vad import get_speech_timestamps, load_silero_vad

    torch.manual_seed(0)
    torch.set_num_threads(8)

    wav_path = Path(args.wav)
    out_dir = Path(args.out_dir)
    seg_dir = out_dir / "segments"
    seg_dir.mkdir(parents=True, exist_ok=True)

    timer = Timer()
    audio, sr = sf.read(str(wav_path), dtype="float32", always_2d=False)
    if sr != args.sample_rate:
        raise SystemExit(f"expected {args.sample_rate} Hz input, got {sr}")
    if audio.ndim != 1:
        raise SystemExit(f"expected mono input, got shape {audio.shape}")
    load_s = timer.lap()
    total_audio_s = len(audio) / sr

    model = load_silero_vad()
    t_vad = Timer()
    raw = get_speech_timestamps(
        torch.from_numpy(audio),
        model,
        threshold=args.threshold,
        sampling_rate=sr,
        min_speech_duration_ms=int(args.min_duration * 1000),
        max_speech_duration_s=args.max_duration,
        min_silence_duration_ms=args.min_silence_ms,
        speech_pad_ms=args.speech_pad_ms,
        return_seconds=False,
        window_size_samples=args.window_size_samples,
    )
    vad_s = t_vad.lap()

    # Deterministic post-processing: hard-cut over-long regions, drop short ones.
    max_samples = int(args.max_duration * sr)
    min_samples = int(args.min_duration * sr)
    spans: list[tuple[int, int]] = []
    overlong = 0
    for region in raw:
        start, end = int(region["start"]), int(region["end"])
        if end - start > max_samples:
            overlong += 1
            cursor = start
            while cursor < end:
                stop = min(cursor + max_samples, end)
                if stop - cursor >= min_samples:
                    spans.append((cursor, stop))
                cursor = stop
        elif end - start >= min_samples:
            spans.append((start, end))

    t_write = Timer()
    rows = []
    kept_s = 0.0
    if args.limit:
        spans = spans[: args.limit]
    for idx, (start, end) in enumerate(spans):
        seg_id = f"{args.talk_id}-s{idx:05d}"
        seg_path = seg_dir / f"{seg_id}.wav"
        chunk = np.ascontiguousarray(audio[start:end])
        sf.write(str(seg_path), chunk, sr, subtype="PCM_16")
        dur = (end - start) / sr
        kept_s += dur
        rows.append(
            {
                "segment_id": seg_id,
                "talk_id": args.talk_id,
                "start_s": round(start / sr, 3),
                "end_s": round(end / sr, 3),
                "duration_s": round(dur, 3),
                "wav_path": str(seg_path),
                "sha256": sha256_file(seg_path),
                "bytes": seg_path.stat().st_size,
            }
        )
    write_s = t_write.lap()

    seg_jsonl = out_dir / "segments.jsonl"
    seg_digest = write_jsonl(seg_jsonl, rows)

    durs = sorted(r["duration_s"] for r in rows)

    def pct(p: float) -> float | None:
        if not durs:
            return None
        return round(durs[min(len(durs) - 1, int(p * (len(durs) - 1)))], 3)

    payload = {
        "inputs": [{"path": str(wav_path), "bytes": wav_path.stat().st_size, "sha256": sha256_file(wav_path)}],
        "vad": {
            "backend": "silero-vad (load_silero_vad, torch jit)",
            "threshold": args.threshold,
            "min_speech_duration_ms": int(args.min_duration * 1000),
            "max_speech_duration_s": args.max_duration,
            "min_silence_duration_ms": args.min_silence_ms,
            "speech_pad_ms": args.speech_pad_ms,
            "window_size_samples": args.window_size_samples,
            "torch_num_threads": 8,
            "seed": 0,
        },
        "counts": {
            "raw_regions": len(raw),
            "overlong_regions_hard_cut": overlong,
            "segments": len(rows),
            "limit_applied": args.limit or None,
        },
        "audio": {
            "total_audio_s": round(total_audio_s, 3),
            "kept_speech_s": round(kept_s, 3),
            "speech_ratio": round(kept_s / total_audio_s, 4) if total_audio_s else None,
            "duration_p05_s": pct(0.05),
            "duration_p50_s": pct(0.50),
            "duration_p95_s": pct(0.95),
            "duration_min_s": durs[0] if durs else None,
            "duration_max_s": durs[-1] if durs else None,
        },
        "timings": {
            "load_wav_s": load_s,
            "vad_s": vad_s,
            "vad_xrealtime": round(total_audio_s / vad_s, 1) if vad_s > 0 else None,
            "write_segments_s": write_s,
            "stage_total_s": timer.lap(),
        },
        "outputs": [seg_digest],
        "segments_dir": str(seg_dir),
    }
    write_manifest(out_dir, "segment", payload)
    print(
        json.dumps(
            {
                "segments": len(rows),
                "kept_speech_s": round(kept_s, 1),
                "total_audio_s": round(total_audio_s, 1),
                "vad_s": vad_s,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
