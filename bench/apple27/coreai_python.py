"""Offline, one-owner CoreAI benchmark for single-graph Whisper and wav2vec2."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

from coreai_common import (
    audio,
    check_environment,
    ctc_text,
    digest,
    offline,
    read_json,
    verify_tree,
    versions,
    whisper_features,
    whisper_prefix,
)


def milliseconds(start: float) -> float:
    return (time.perf_counter() - start) * 1000


class Recognizer:
    def __init__(self, args, metadata):
        self.args = args
        self.metadata = metadata
        self.details = metadata["details"]
        self.processor = None
        self.owner = None
        self.function = None
        self.seen_shapes = set()
        self.row_new_shapes = 0
        self.row_new_shape_ms = 0.0

    async def load(self) -> dict:
        check_environment(self.args.engine, exporting=False)
        from coreai.runtime import AIModel, ComputeUnitKind, SpecializationOptions

        metadata = self.metadata
        if metadata["schema"] != "voiceour.apple27.coreai/1" or metadata["engine"] != self.args.engine:
            raise ValueError("Wrong export metadata engine/schema")
        if metadata["dtype"] not in ("float16", "float32") or metadata["sample_rate"] != 16000:
            raise ValueError("Unsupported export dtype/sample rate")
        verify_tree(self.args.model, metadata["artifacts"]["main"]["artifact"])
        preparation = time.perf_counter()
        if self.args.engine == "whisper":
            from transformers import AutoProcessor

            processor_path = self.args.processor or self.args.metadata.parent / self.details["processor"]
            verify_tree(processor_path, self.details["processor_artifact"])
            self.processor = AutoProcessor.from_pretrained(processor_path, local_files_only=True)
            prefix = whisper_prefix(self.processor, {"decoder_start_token_id": self.details["prefix_tokens"][0]})
            if prefix != self.details["prefix_tokens"]:
                raise ValueError("Processor prefix differs from export")
            if self.processor.tokenizer.eos_token_id != self.details["eos_token_id"]:
                raise ValueError("Processor EOT differs from export")
            if self.args.max_tokens > self.details["maximum_decoder_input_tokens"] - len(prefix) + 1:
                raise ValueError("--max-tokens exceeds exported decoder length bound")
        processor_ms = milliseconds(preparation)
        options = None
        if self.args.compute == "gpu":
            options = SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu())
        elif self.args.compute == "cpu":
            options = SpecializationOptions.cpu_only()
        start = time.perf_counter()
        self.owner = await AIModel.load(self.args.model, specialization_options=options)
        specialize_ms = milliseconds(start)
        start = time.perf_counter()
        self.function = self.owner.load_function("main")
        names = ["input_features", "decoder_input_ids"] if self.args.engine == "whisper" else ["waveform"]
        outputs = ["logits"] if self.args.engine == "whisper" else ["emission"]
        if list(self.function.desc.input_names) != names or list(self.function.desc.output_names) != outputs:
            raise ValueError(f"Wrong CoreAI graph signature: {self.function.desc}")
        return {
            "processor_load_ms": processor_ms,
            "specialization_ms": specialize_ms,
            "load_function_ms": milliseconds(start),
            "prewarm_ms": None,
            "prewarm": "none",
            "function_descriptor": str(self.function.desc),
            "requested_compute": self.args.compute,
            "allowed_compute_units": [str(kind) for kind in options.allowed_compute_unit_kinds]
            if options
            else "default",
            "preferred_compute": str(options.preferred_compute_unit_kind) if options else "default",
        }

    async def call(self, inputs, shape):
        unseen = shape not in self.seen_shapes
        if unseen:
            print(f"CoreAI first-seen shape {shape}", file=sys.stderr, flush=True)
        start = time.perf_counter()
        output = await self.function(inputs)
        elapsed = milliseconds(start)
        if unseen:
            self.row_new_shapes += 1
            self.row_new_shape_ms += elapsed
        self.seen_shapes.add(shape)
        return output

    def shape_timing(self):
        return {
            "first_seen_shape_calls": self.row_new_shapes,
            "first_seen_shape_call_ms": self.row_new_shape_ms,
            "shape_timing_note": (
                "First-seen dimensions in this process; includes inference and any "
                "specialization, not compiler time alone."
            ),
        }

    async def transcribe(self, samples) -> tuple[str, dict]:
        import numpy as np
        from coreai.runtime import NDArray

        detail = self.details
        self.row_new_shapes = 0
        self.row_new_shape_ms = 0.0
        if self.args.engine == "wav2vec2":
            values = samples
            if not detail["dynamic_audio"]:
                size = detail["fixed_samples"]
                if len(values) > size:
                    raise ValueError("Audio exceeds static waveform bound; truncation forbidden")
                values = np.pad(values, (0, size - len(values)))
            waveform = np.ascontiguousarray(values[None, :], dtype=self.metadata["dtype"])
            output = await self.call({"waveform": NDArray(waveform)}, tuple(waveform.shape))
            emission = output["emission"].numpy()
            if emission.ndim != 3 or emission.shape[0] != 1 or emission.shape[2] != len(detail["labels"]):
                raise ValueError(f"Wrong CTC emission shape: {emission.shape}")
            if emission.shape[1] == 0 or not np.isfinite(emission).all():
                raise ValueError("Empty/non-finite CTC emissions")
            # Static graphs emit padding too. Keep only frames whose convolutional
            # receptive fields lie in real audio (torchaudio base's seven layers).
            frames = len(samples)
            for kernel, stride in ((10, 5), (3, 2), (3, 2), (3, 2), (3, 2), (2, 2), (2, 2)):
                frames = (frames - kernel) // stride + 1
            if frames <= 0 or frames > emission.shape[1]:
                raise ValueError("CTC output length disagrees with real audio")
            ids = emission[0, :frames].argmax(axis=-1)
            return ctc_text(ids, detail["labels"], detail["blank_token_id"]), {
                "emission_frames": frames,
                "graph_emission_frames": emission.shape[1],
                "graph_calls": 1,
                "decoder": "greedy_ctc_collapse_then_remove_blank",
                **self.shape_timing(),
            }

        features = NDArray(whisper_features(self.processor, samples, self.metadata["dtype"]))
        tokens = list(detail["prefix_tokens"])
        prefix_count = len(tokens)
        eos = int(detail["eos_token_id"])
        for step in range(self.args.max_tokens):
            if len(tokens) > detail["maximum_decoder_input_tokens"]:
                raise ValueError("Whisper decoder input exceeds exported token bound")
            capacity = detail.get("fixed_decoder_input_tokens") or len(tokens)
            decoder_ids = np.full((1, capacity), detail.get("decoder_padding_token_id", eos), dtype=np.int32)
            decoder_ids[0, : len(tokens)] = tokens
            outputs = await self.call(
                {
                    "input_features": features,
                    "decoder_input_ids": NDArray(decoder_ids),
                },
                (1, capacity),
            )
            logits = outputs["logits"].numpy()
            if logits.ndim != 3 or logits.shape[:2] != (1, capacity):
                raise ValueError(f"Wrong Whisper logits shape: {logits.shape}")
            scores = logits[0, len(tokens) - 1].astype(np.float32, copy=True)
            if not np.isfinite(scores).all():
                raise ValueError("Non-finite Whisper logits")
            # English/transcribe/no-timestamps task tokens are the initial prefix;
            # suppression is the checkpoint's generation policy, not reference text.
            suppress = list(detail["suppress_tokens"])
            if step == 0:
                suppress.extend(detail["begin_suppress_tokens"])
            if any(token < 0 or token >= len(scores) for token in suppress):
                raise ValueError("Invalid checkpoint suppression token")
            scores[suppress] = -np.inf
            timestamp_begin = int(detail["timestamp_begin"])
            if not 0 <= timestamp_begin < len(scores):
                raise ValueError("Invalid timestamp token boundary")
            scores[timestamp_begin:] = -np.inf
            if not np.isfinite(scores).any():
                raise ValueError("All Whisper tokens suppressed")
            token = int(scores.argmax())
            if token == eos:
                raw = self.processor.tokenizer.decode(tokens[prefix_count:], skip_special_tokens=True).strip()
                return raw, {
                    "generated_tokens": len(tokens) - prefix_count,
                    "graph_calls": step + 1,
                    "decoder": "greedy_english_transcribe_no_timestamps",
                    "ended_on_eot": True,
                    "encoder_recomputed_per_token": True,
                    "kv_cache": False,
                    **self.shape_timing(),
                }
            tokens.append(token)
        raise ValueError(
            f"Whisper exhausted max_tokens={self.args.max_tokens} without EOT; partial transcript rejected"
        )


def inputs(path: Path) -> list[dict]:
    rows = []
    seen = set()
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        obj = json.loads(line)
        # Whitelist fields: ground truth is discarded at the manifest boundary.
        row = {key: obj[key] for key in ("id", "audio_path", "audio_bytes", "audio_sha256")}
        row["audio_s"] = obj.get("audio_s")
        if not isinstance(row["id"], str) or row["id"] in seen:
            raise ValueError(f"Invalid/duplicate id: {row['id']}")
        seen.add(row["id"])
        rows.append(row)
    if not rows:
        raise ValueError("Empty input manifest")
    return rows


def write_row(stream, value: dict) -> None:
    stream.write(json.dumps(value, allow_nan=False) + "\n")
    stream.flush()


async def run(args) -> None:
    offline()
    rows = inputs(args.input)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as stream:
        setup_start = time.perf_counter()
        metadata = None
        recognizer = None
        blocked = None
        try:
            metadata = read_json(args.metadata)
            recognizer = Recognizer(args, metadata)
            load = await recognizer.load()
            write_row(
                stream,
                {
                    "type": "bench_meta",
                    "mode": "apple27-coreai-python",
                    "backend": args.engine,
                    "model_family": args.engine,
                    "model": metadata["model"],
                    "revision": metadata["revision"],
                    "dtype": metadata["dtype"],
                    "manifest_sha256": digest(args.input),
                    "export_manifest_sha256": digest(args.metadata),
                    "provenance": metadata,
                    "runtime_dependencies": versions(),
                    "setup_ms": milliseconds(setup_start),
                    "load": load,
                    "cleanup_applied": False,
                    "locale": "en-US",
                    "max_tokens": args.max_tokens if args.engine == "whisper" else None,
                    "compute_selection": args.compute,
                    "first_request": "process-first; OS cache/model coldness not guaranteed",
                    "audio_preprocessing": "soundfile float32 mono channel average; scipy resample_poly to 16kHz",
                    "asr_timing": (
                        "feature preprocessing + all CoreAI calls + greedy decode; "
                        "includes Whisper encoder recomputation"
                    ),
                },
            )
        except Exception as error:
            blocked = f"{type(error).__name__}: {error}"
            write_row(
                stream,
                {
                    "type": "blocked",
                    "backend": args.engine,
                    "error": blocked,
                    "setup_ms": milliseconds(setup_start),
                    "runtime_dependencies": versions(),
                },
            )
        for index, row in enumerate(rows):
            started = time.perf_counter()
            raw = ""
            error_text = blocked
            asr_ms = None
            io_ms = None
            duration = row["audio_s"]
            details = {
                "cleanup_applied": False,
                "request_index": index,
                "model_family": args.engine,
                "process_first_request": index == 0,
            }
            if metadata is not None:
                details.update(
                    {
                        "model": metadata.get("model"),
                        "revision": metadata.get("revision"),
                        "dtype": metadata.get("dtype"),
                    }
                )
            if blocked is None:
                inference_start = None
                try:
                    path = Path(row["audio_path"])
                    if not path.is_absolute():
                        raise ValueError("Manifest audio paths must be absolute")
                    if path.stat().st_size != row["audio_bytes"] or digest(path) != row["audio_sha256"]:
                        raise ValueError(f"Audio pin mismatch: {row['id']}")
                    samples, duration = audio(
                        path, recognizer.details["maximum_audio_seconds"], recognizer.details.get("minimum_samples", 1)
                    )
                    io_ms = milliseconds(started)
                    inference_start = time.perf_counter()
                    raw, decode_detail = await recognizer.transcribe(samples)
                    asr_ms = milliseconds(inference_start)
                    details.update(decode_detail)
                    error_text = None
                except Exception as error:
                    if inference_start is not None:
                        asr_ms = milliseconds(inference_start)
                    error_text = f"{type(error).__name__}: {error}"
                    raw = ""
            write_row(
                stream,
                {
                    "type": "row",
                    "id": row["id"],
                    "raw_transcript": raw,
                    "cleaned_text": raw,
                    "final_text": raw,
                    "audio_s": duration,
                    "timings_ms": {
                        "asr": asr_ms,
                        "asr_inference": asr_ms,
                        "asr_load": None,
                        "audio_io": io_ms,
                        "cleanup": None,
                        "total": milliseconds(started),
                    },
                    "error": error_text,
                    "details": details,
                },
            )


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Real offline CoreAI speech inference; no Torch inference fallback. Ordered NDJSON, one model owner."
        ),
        epilog="Whisper executes its full encoder+decoder graph every token (no KV cache). "
        "EOT required; token exhaustion and audio outside the recorded export bounds are errors. "
        "No cleanup or vocabulary repair is applied; score raw_transcript. Existing outputs are refused.",
    )
    parser.add_argument("--engine", choices=("whisper", "wav2vec2"), required=True)
    parser.add_argument("--model", type=Path, required=True, help="Exported .aimodel path")
    parser.add_argument("--metadata", type=Path, required=True, help="Matching export.json from coreai_export.py")
    parser.add_argument(
        "--processor",
        type=Path,
        help="Whisper-only local processor (must match export digest); defaults to export location",
    )
    parser.add_argument("--input", type=Path, required=True, help="Pipeline manifest, pinned public audio only")
    parser.add_argument("--output", type=Path, required=True, help="New NDJSON results file")
    parser.add_argument(
        "--max-tokens", type=int, default=444, help="Whisper generated tokens including EOT; exhaustion is an error"
    )
    parser.add_argument("--compute", choices=("default", "gpu", "cpu"), default="default")
    args = parser.parse_args()
    if not 1 <= args.max_tokens <= 445:
        parser.error("--max-tokens must be 1...445")
    if args.engine != "whisper" and args.processor is not None:
        parser.error("--processor only applies to Whisper")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
