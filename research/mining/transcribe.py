"""Stage 4 — batched NeMo parakeet-tdt-0.6b-v3 transcription on the GPU.

NeMo 3.0's `EncDecRNNTBPEModel.transcribe(...)` accepts `timestamps: bool` and
`return_hypotheses: bool`, so word-level timestamps and the TDT hypothesis score
are both available (verified by signature probe before writing this stage).

The model revision is pinned by recording the HF commit sha of
`nvidia/parakeet-tdt-0.6b-v3` plus the sha256 of the resolved local .nemo file.
Peak VRAM is measured both by torch's allocator counters and by an nvidia-smi
sampler thread (which also catches the cuDNN/cuBLAS workspace outside torch).

Batches are duration-bucketed (deterministic sort by duration then id) to cut
padding waste; output rows are re-emitted in the original segment order. An OOM
halves the batch size and retries, recording every retry in the manifest.
"""

from __future__ import annotations

import argparse
import json
import threading
import time
from pathlib import Path

from common import (
    Timer,
    file_digest_record,
    gpu_snapshot,
    sha256_file,
    unk_stats,
    write_jsonl,
    write_manifest,
)

MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"


class SmiSampler(threading.Thread):
    """Samples nvidia-smi memory.used so the reported peak includes non-torch VRAM."""

    def __init__(self, interval: float = 0.5) -> None:
        super().__init__(daemon=True)
        self.interval = interval
        self.peak_mib = 0
        self.samples = 0
        # NB: not `self._stop` — that shadows Thread._stop(), which threading's
        # _after_fork() calls in forked dataloader workers, spewing TypeErrors.
        self._halt = threading.Event()

    def run(self) -> None:
        import subprocess

        while not self._halt.is_set():
            try:
                out = subprocess.run(
                    ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                    capture_output=True,
                    text=True,
                    timeout=10,
                ).stdout.strip()
                self.peak_mib = max(self.peak_mib, int(out.splitlines()[0]))
                self.samples += 1
            except Exception:
                pass
            self._halt.wait(self.interval)

    def stop(self) -> None:
        self._halt.set()


def model_revision(model_id: str) -> dict:
    info: dict = {"model_id": model_id}
    try:
        from huggingface_hub import HfApi

        mi = HfApi().model_info(model_id)
        info["hf_commit_sha"] = mi.sha
        info["hf_last_modified"] = str(getattr(mi, "lastModified", None))
        info["hf_siblings"] = sorted(s.rfilename for s in (mi.siblings or []))[:20]
    except Exception as exc:
        info["hf_lookup_error"] = repr(exc)
    return info


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--segments", required=True, help="segments.jsonl from stage 3")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--model", default=MODEL_ID)
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--num-workers", type=int, default=2)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--timestamps", default="auto", choices=["auto", "on", "off"])
    ap.add_argument("--sort-by-duration", type=int, default=1)
    ap.add_argument("--limit", type=int, default=0, help="transcribe only the first N segments (0 = all)")
    ap.add_argument("--hash-model-file", type=int, default=1)
    args = ap.parse_args()

    import torch
    from common import read_jsonl

    torch.manual_seed(0)
    segs = read_jsonl(args.segments)
    if args.limit:
        segs = segs[: args.limit]
    if not segs:
        raise SystemExit("no segments to transcribe")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    order = list(range(len(segs)))
    if args.sort_by_duration:
        order.sort(key=lambda i: (segs[i]["duration_s"], segs[i]["segment_id"]))
    paths = [segs[i]["wav_path"] for i in order]
    audio_s = sum(s["duration_s"] for s in segs)

    gpu_before = gpu_snapshot()
    timer = Timer()

    from nemo.collections.asr.models import ASRModel

    t_load = Timer()
    model = ASRModel.from_pretrained(model_name=args.model, map_location=args.device)
    model.eval()
    load_s = t_load.lap()

    model_file = None
    try:
        # NeMo records the restored .nemo path on the instance config/registry.
        cand = getattr(model, "_cfg", None)
        model_file = getattr(model, "model_guid", None)
        del cand
    except Exception:
        pass
    nemo_cache = sorted(Path.home().joinpath(".cache").glob("**/parakeet-tdt-0.6b-v3*.nemo"))
    hf_home_cache = sorted(Path("/srv/devbox/cache/hf").glob("**/*parakeet-tdt-0.6b-v3*/**/*.nemo"))
    resolved = (hf_home_cache + nemo_cache)[:1]
    model_file_record = None
    if resolved and args.hash_model_file:
        model_file_record = file_digest_record(resolved[0])
    elif resolved:
        p = resolved[0]
        model_file_record = {"path": str(p), "bytes": p.stat().st_size}

    if args.device.startswith("cuda"):
        torch.cuda.reset_peak_memory_stats()
    sampler = SmiSampler()
    sampler.start()

    want_ts = args.timestamps in ("auto", "on")
    attempts: list[dict] = []
    hyps = None
    batch = args.batch_size
    t_tr = Timer()
    while hyps is None:
        try:
            kwargs = dict(
                batch_size=batch,
                return_hypotheses=True,
                num_workers=args.num_workers,
                verbose=False,
            )
            if want_ts:
                kwargs["timestamps"] = True
            with torch.inference_mode():
                hyps = model.transcribe(paths, **kwargs)
            attempts.append({"batch_size": batch, "timestamps": want_ts, "result": "ok"})
        except torch.cuda.OutOfMemoryError as exc:
            attempts.append({"batch_size": batch, "timestamps": want_ts, "result": "cuda_oom", "error": str(exc)[:300]})
            torch.cuda.empty_cache()
            if batch <= 1:
                raise
            batch //= 2
        except TypeError as exc:
            if want_ts and args.timestamps == "auto":
                attempts.append(
                    {"batch_size": batch, "timestamps": True, "result": "timestamps_unsupported", "error": str(exc)[:300]}
                )
                want_ts = False
            else:
                raise
    transcribe_s = t_tr.lap()
    sampler.stop()
    time.sleep(0.6)

    if isinstance(hyps, tuple):
        hyps = hyps[0]

    def hyp_fields(h) -> dict:
        text = getattr(h, "text", h if isinstance(h, str) else None)
        row: dict = {"text": text}
        score = getattr(h, "score", None)
        if score is not None:
            try:
                row["score"] = float(score)
            except Exception:
                row["score"] = None
        ts = getattr(h, "timestamp", None)
        if isinstance(ts, dict):
            words = ts.get("word") or []
            row["words"] = [
                {
                    "word": w.get("word") if isinstance(w, dict) else str(w),
                    "start": round(float(w["start"]), 3) if isinstance(w, dict) and w.get("start") is not None else None,
                    "end": round(float(w["end"]), 3) if isinstance(w, dict) and w.get("end") is not None else None,
                }
                for w in words
            ]
            segs_ts = ts.get("segment") or []
            row["segment_timestamps"] = [
                {
                    "segment": s.get("segment") if isinstance(s, dict) else str(s),
                    "start": round(float(s["start"]), 3) if isinstance(s, dict) and s.get("start") is not None else None,
                    "end": round(float(s["end"]), 3) if isinstance(s, dict) and s.get("end") is not None else None,
                }
                for s in segs_ts
            ]
        return row

    by_index: dict[int, dict] = {}
    for pos, seg_index in enumerate(order):
        by_index[seg_index] = hyp_fields(hyps[pos])

    rows = []
    max_ts_overrun = 0.0
    for i, seg in enumerate(segs):
        h = by_index[i]
        words = h.get("words")
        # Order check: with duration-bucketed batching a mis-remap would be
        # silent, so assert word timestamps fall inside the segment they were
        # mapped to (they are segment-relative).
        if words:
            last_end = max((w["end"] or 0.0) for w in words)
            max_ts_overrun = max(max_ts_overrun, last_end - seg["duration_s"])
        rows.append(
            {
                "segment_id": seg["segment_id"],
                "talk_id": seg["talk_id"],
                "start_s": seg["start_s"],
                "end_s": seg["end_s"],
                "duration_s": seg["duration_s"],
                "wav_path": seg["wav_path"],
                "text": h.get("text"),
                "score": h.get("score"),
                "n_words": len(words or []) or (len((h.get("text") or "").split())),
                **unk_stats(h.get("text")),
                "words": words,
            }
        )

    hyp_path = out_dir / "hypotheses.jsonl"
    hyp_digest = write_jsonl(hyp_path, rows)

    peak_alloc = peak_reserved = None
    if args.device.startswith("cuda"):
        peak_alloc = round(torch.cuda.max_memory_allocated() / 2**20, 1)
        peak_reserved = round(torch.cuda.max_memory_reserved() / 2**20, 1)

    n_words = sum(r["n_words"] for r in rows)
    payload = {
        "inputs": [
            {
                "path": str(args.segments),
                "bytes": Path(args.segments).stat().st_size,
                "sha256": sha256_file(args.segments),
                "segments": len(segs),
                "audio_s": round(audio_s, 3),
            }
        ],
        "model": {
            **model_revision(args.model),
            "device": args.device,
            "precision": "fp32",
            "batch_size_final": batch,
            "batch_size_requested": args.batch_size,
            "num_workers": args.num_workers,
            "timestamps_enabled": want_ts,
            "sort_by_duration": bool(args.sort_by_duration),
            "attempts": attempts,
            "local_model_file": model_file_record,
            "model_guid": model_file,
        },
        "gpu": {
            "before": gpu_before,
            "after": gpu_snapshot(),
            "torch_peak_allocated_MiB": peak_alloc,
            "torch_peak_reserved_MiB": peak_reserved,
            "nvidia_smi_peak_used_MiB": sampler.peak_mib,
            "nvidia_smi_samples": sampler.samples,
        },
        "throughput": {
            "audio_s": round(audio_s, 3),
            "transcribe_s": transcribe_s,
            "rtfx": round(audio_s / transcribe_s, 2) if transcribe_s > 0 else None,
            "model_load_s": load_s,
            "segments_per_s": round(len(segs) / transcribe_s, 2) if transcribe_s > 0 else None,
            "words": n_words,
        },
        "quality": {
            "degenerate_utterances": sum(1 for r in rows if r["degenerate"]),
            "unk_tokens": sum(r["unk_tokens"] for r in rows),
            "real_tokens": sum(r["tokens"] - r["unk_tokens"] for r in rows),
            "max_word_timestamp_overrun_s": round(max_ts_overrun, 3),
            "order_check": "word timestamps are segment-relative; a positive overrun means the duration-bucketed remap is wrong",
        },
        "timings": {"stage_total_s": timer.lap()},
        "outputs": [hyp_digest],
    }
    write_manifest(out_dir, "transcribe", payload)
    print(
        json.dumps(
            {
                "segments": len(segs),
                "audio_s": round(audio_s, 1),
                "transcribe_s": transcribe_s,
                "rtfx": payload["throughput"]["rtfx"],
                "peak_vram_MiB": sampler.peak_mib,
                "timestamps": want_ts,
                "words": n_words,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
