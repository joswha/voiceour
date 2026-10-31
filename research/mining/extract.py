"""Stage 2 — decode the talk media to 16 kHz mono PCM16 wav with static-ffmpeg.

static-ffmpeg ships its own ffmpeg/ffprobe binaries, so the pipeline never
depends on a system package (devbox rule: no apt). Both binary paths and the
ffmpeg banner version are recorded in the manifest.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from common import Timer, file_digest_record, sha256_file, write_manifest


def ffmpeg_paths() -> tuple[str, str]:
    from static_ffmpeg import run as sfr

    ffmpeg, ffprobe = sfr.get_or_fetch_platform_executables_else_raise()
    return ffmpeg, ffprobe


def probe(ffprobe: str, path: str | Path) -> dict:
    out = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=300,
        check=True,
    ).stdout
    return json.loads(out)


def summarize(info: dict) -> dict:
    fmt = info.get("format", {})
    streams = [
        {
            "index": s.get("index"),
            "codec_type": s.get("codec_type"),
            "codec_name": s.get("codec_name"),
            "sample_rate": s.get("sample_rate"),
            "channels": s.get("channels"),
            "duration": s.get("duration"),
        }
        for s in info.get("streams", [])
    ]
    return {
        "format_name": fmt.get("format_name"),
        "duration_s": float(fmt.get("duration")) if fmt.get("duration") else None,
        "bit_rate": fmt.get("bit_rate"),
        "streams": streams,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, help="media file from stage 1")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--talk-id", required=True)
    ap.add_argument("--sample-rate", type=int, default=16000)
    ap.add_argument("--timeout", type=float, default=3600.0)
    args = ap.parse_args()

    src = Path(args.input)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / f"{args.talk_id}.16k.mono.wav"

    ffmpeg, ffprobe = ffmpeg_paths()
    ver = subprocess.run([ffmpeg, "-version"], capture_output=True, text=True, timeout=120).stdout
    ffmpeg_version = ver.splitlines()[0] if ver else None

    src_info = summarize(probe(ffprobe, src))

    cmd = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(src),
        "-vn",
        "-map",
        "0:a:0",
        "-ac",
        "1",
        "-ar",
        str(args.sample_rate),
        "-c:a",
        "pcm_s16le",
        "-f",
        "wav",
        str(dest),
    ]
    timer = Timer()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout)
    decode_s = timer.lap()
    if proc.returncode != 0:
        print(proc.stderr[-4000:])
        return proc.returncode

    out_info = summarize(probe(ffprobe, dest))
    digest = file_digest_record(dest)
    dur = out_info["duration_s"] or 0.0
    payload = {
        "inputs": [{"path": str(src), "bytes": src.stat().st_size, "sha256": sha256_file(src)}],
        "tools": {"ffmpeg": ffmpeg, "ffprobe": ffprobe, "ffmpeg_version": ffmpeg_version},
        "ffmpeg_cmd": cmd,
        "source_media": src_info,
        "output_audio": out_info,
        "audio_s": dur,
        "timings": {
            "decode_s": decode_s,
            "decode_xrealtime": round(dur / decode_s, 2) if decode_s > 0 else None,
            "stage_total_s": timer.lap(),
        },
        "outputs": [digest],
    }
    write_manifest(out_dir, "extract", payload)
    print(json.dumps({"wav": str(dest), "audio_s": dur, "decode_s": decode_s, "sha256": digest["sha256"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
