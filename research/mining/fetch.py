"""Stage 1 — fetch one conference talk media file by direct URL.

FOSDEM archive layout: https://video.fosdem.org/<year>/<room>/<slug>.av1.webm
(`.mp4` also exists but is the ~10x larger stream mezzanine; prefer `.av1.webm`).
Direct URLs 302-redirect to a mirror; redirects are followed and the final URL
is recorded. Downloads are byte-capped so a smoke run cannot run away.

Records url, resolved url, http status, bytes, sha256, throughput, licence note.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

from common import Timer, file_digest_record, sha256_bytes, write_manifest

FOSDEM_LICENCE = (
    "FOSDEM recordings are published under the Creative Commons Attribution 2.0 "
    "Belgium Licence (CC BY 2.0 BE), http://creativecommons.org/licenses/by/2.0/be/deed.en "
    "(stated on the https://video.fosdem.org/ index page). Attribution: FOSDEM + the "
    "speaker(s) of the talk. Redistribution of derived audio/transcripts must keep the "
    "attribution and licence notice."
)
UA = "voiceour-asr-research/0.1 (mining smoke; contact: local research use)"


def http_get(url: str, timeout: float) -> tuple[int, dict[str, str], str, urllib.request.addinfourl]:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    resp = urllib.request.urlopen(req, timeout=timeout)
    return resp.status, dict(resp.headers), resp.geturl(), resp


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", required=True, help="direct media URL")
    ap.add_argument("--talk-id", required=True, help="stable id, e.g. fosdem2025-4189-k8s-controller-rust")
    ap.add_argument("--out-dir", required=True, help="destination directory for the media file + manifest")
    ap.add_argument("--index-url", default=None, help="directory index URL recorded for provenance")
    ap.add_argument("--max-bytes", type=int, default=600_000_000, help="hard cap; abort past this")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--licence-note", default=FOSDEM_LICENCE)
    ap.add_argument("--talk-title", default=None)
    ap.add_argument("--speaker-note", default=None, help="free-text speaker attribution if known")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    suffix = "".join(Path(args.url.split("?")[0]).suffixes[-2:]) or ".bin"
    dest = out_dir / f"{args.talk_id}{suffix}"

    index_record = None
    if args.index_url:
        status, headers, final, resp = http_get(args.index_url, args.timeout)
        body = resp.read()
        index_record = {
            "url": args.index_url,
            "status": status,
            "bytes": len(body),
            "sha256": sha256_bytes(body),
        }

    timer = Timer()
    status, headers, final_url, resp = http_get(args.url, args.timeout)
    declared = headers.get("Content-Length")
    declared_int = int(declared) if declared and declared.isdigit() else None
    if declared_int is not None and declared_int > args.max_bytes:
        print(f"ABORT: content-length {declared_int} exceeds --max-bytes {args.max_bytes}", file=sys.stderr)
        return 2

    total = 0
    t_start = time.perf_counter()
    with open(dest, "wb") as fh:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > args.max_bytes:
                fh.close()
                dest.unlink(missing_ok=True)
                print(f"ABORT: stream exceeded --max-bytes {args.max_bytes}", file=sys.stderr)
                return 2
            fh.write(chunk)
    elapsed = time.perf_counter() - t_start

    digest = file_digest_record(dest)
    mbps = round((total / 1e6) / elapsed, 2) if elapsed > 0 else None
    payload = {
        "talk": {
            "talk_id": args.talk_id,
            "title": args.talk_title,
            "speaker_note": args.speaker_note,
            "requested_url": args.url,
            "resolved_url": final_url,
            "http_status": status,
            "content_type": headers.get("Content-Type"),
            "last_modified": headers.get("Last-Modified"),
            "content_length_declared": declared_int,
        },
        "download": {
            "bytes": total,
            "sha256": digest["sha256"],
            "dest": str(dest),
            "elapsed_s": round(elapsed, 3),
            "throughput_MB_s": mbps,
            "max_bytes": args.max_bytes,
        },
        "index_page": index_record,
        "licence": args.licence_note,
        "timings": {"stage_total_s": timer.lap()},
        "outputs": [digest],
    }
    write_manifest(out_dir, "fetch", payload)
    print(json.dumps({"dest": str(dest), "bytes": total, "MB_s": mbps, "sha256": digest["sha256"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
