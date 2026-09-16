"""Explicit preparation, offline CoreAI export, and opt-in PyTorch parity traces.

No inference performed by this CLI is a benchmark result. See coreai_python.py.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from coreai_common import (
    MODELS,
    WAV2VEC2_URL,
    audio,
    check_environment,
    digest,
    offline,
    read_json,
    tree,
    verify_tree,
    versions,
    whisper_features,
    whisper_prefix,
    write_json,
)

ROOT = Path(__file__).resolve().parents[2]


def verify_requested_pin(args) -> None:
    pins = read_json(ROOT / "bench/apple27/dependencies.json")["model_pins"]
    if args.model not in pins or pins[args.model]["revision"] != args.revision:
        raise ValueError("Model/revision differs from the recorded experiment pin")


def prepare(args) -> None:
    """Only this command is allowed to access model download services."""
    verify_requested_pin(args)
    if args.engine == "wav2vec2":
        if args.revision != "torchaudio-2.11.0":
            raise ValueError("wav2vec2 revision must be torchaudio-2.11.0; source bytes are SHA-pinned in source.json")
    elif not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        raise ValueError("HF --revision must be a full lowercase 40-hex commit, never main or a tag")
    if not args.download and args.local_source is None:
        raise ValueError("prepare needs --download (explicit network consent) or --local-source")
    if args.download and args.local_source is not None:
        raise ValueError("Choose --download or --local-source, not both")
    args.output.mkdir(parents=True, exist_ok=False)
    if args.engine == "wav2vec2":
        source = args.output / "weights.pth"
        if args.local_source:
            shutil.copyfile(args.local_source, source)
        else:
            import urllib.request

            with urllib.request.urlopen(WAV2VEC2_URL) as response, source.open("xb") as stream:
                shutil.copyfileobj(response, stream)
        # The torchaudio label is not a content address; the recorded bytes are.
        pin = read_json(ROOT / "bench/apple27/dependencies.json")["model_pins"][args.model]
        actual = digest(source)
        if actual != pin["sha256"] or source.stat().st_size != pin["size_bytes"]:
            source.unlink()
            raise ValueError(
                f"wav2vec2 checkpoint differs from the pinned bytes: sha256 {actual}, "
                f"expected {pin['sha256']} ({pin['size_bytes']} bytes)"
            )
        origin = WAV2VEC2_URL
    else:
        source = args.output / "snapshot"
        if args.local_source:
            shutil.copytree(args.local_source, source, ignore=shutil.ignore_patterns(".cache", ".git"))
        else:
            from huggingface_hub import snapshot_download

            snapshot_download(
                repo_id=args.model,
                revision=args.revision,
                local_dir=source,
                token=False,
                allow_patterns=[
                    "*.json",
                    "model.safetensors",
                    "model-*.safetensors",
                    "*.model",
                    "*.txt",
                    "*.tiktoken",
                ],
            )
        origin = f"https://huggingface.co/{args.model}/tree/{args.revision}"
    record = {
        "schema": "voiceour.apple27.source/1",
        "engine": args.engine,
        "model": args.model,
        "revision": args.revision,
        "origin": origin,
        "source": source.name,
        "source_artifact": tree(source),
        "local_source_asserted_revision": args.local_source is not None,
        "preparation_versions": versions(),
    }
    write_json(args.output / "source.json", record)
    print(json.dumps({"source": str(args.output.resolve()), "provenance": record}))


def source_record(args) -> tuple[dict, Path]:
    verify_requested_pin(args)
    record = read_json(args.source / "source.json")
    for field in ("engine", "model", "revision"):
        if record[field] != getattr(args, field):
            raise ValueError(f"Prepared source {field} mismatch")
    source = args.source / record["source"]
    verify_tree(source, record["source_artifact"])
    return record, source


def upstream(engine: str, checkout: Path):
    pin = read_json(ROOT / "bench/apple27/dependencies.json")["coreai_models"]["revision"]
    actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if actual != pin:
        raise ValueError(f"coreai-models checkout {actual} differs from pin {pin}")
    # The exporter imports sibling modules and the Swift package compiles CoreAISpeech
    # from this same checkout, so the whole tree must be the pinned revision untouched.
    dirty = subprocess.check_output(
        ["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"], text=True
    ).strip()
    if dirty:
        raise ValueError(f"coreai-models checkout has local modifications:\n{dirty}")
    path = checkout / "models" / engine / "export.py"
    name = f"voiceour_upstream_{engine}"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module, {"revision": pin, "exporter": str(path.resolve()), "exporter_sha256": digest(path)}


def load_wav2vec2(module, source: Path, dtype):
    import torch
    import torchaudio

    class LocalWav2Vec2(module.Wav2Vec2Module):
        def __init__(self):
            # Reuse upstream forward, but source weights without a downloader.
            torch.nn.Module.__init__(self)
            self._model = torchaudio.models.wav2vec2_base(aux_num_out=29)
            state = torch.load(source, map_location="cpu", weights_only=True)
            # Torchaudio 2.11's ASR bundle removes fairseq dictionary axes 1,2,3.
            # Require the original 32-class checkpoint; never guess its layout.
            for key in ("aux.weight", "aux.bias"):
                if state[key].shape[0] != 32:
                    raise ValueError(f"Expected original 32-class torchaudio checkpoint: {key}")
                keep = [0, *range(4, 32)]
                state[key] = state[key][keep]
            self._model.load_state_dict(state, strict=True)

    return LocalWav2Vec2().eval().to(dtype)


def export(args) -> None:
    offline()
    check_environment(args.engine, exporting=True)
    record, source = source_record(args)
    module, upstream_pin = upstream(args.engine, args.upstream)
    import torch

    dtype = getattr(torch, args.dtype)
    args.output.mkdir(parents=True, exist_ok=False)
    start = time.perf_counter()
    if args.engine == "parakeet":
        # Upstream owns the full three-graph bundle and its Swift metadata schema.
        module.create_parakeet(
            output_dir=str(args.output),
            model_name=str(source.resolve()),
            dtype=dtype,
            overwrite=False,
            dynamic=not args.static,
            audio_seconds=15.0,
            include_debug_info=False,
        )
        bundle, assets = module._bundle_paths(str(args.output), str(source.resolve()), dtype, not args.static)
        exported_artifacts = {
            name: {"path": str(path.relative_to(args.output)), "artifact": tree(path)} for name, path in assets.items()
        }
        from transformers import AutoProcessor

        processor = AutoProcessor.from_pretrained(bundle / "processor", local_files_only=True)
        feature_shape = list(module._audio_features(processor, dtype, 15.0).shape)
        config = read_json(bundle / "metadata.json")["config"]
        details = {
            "bundle": str(bundle.relative_to(args.output)),
            "processor": str((bundle / "processor").relative_to(args.output)),
            "processor_artifact": tree(bundle / "processor"),
            "bundle_metadata_sha256": digest(bundle / "metadata.json"),
            "architecture": "three_graph_tdt",
            "dynamic_audio": not args.static,
            "input_layout": "[1,mel_frames,128]",
            "maximum_audio_seconds": 15.0,
        }
        details["shape_bounds"] = {
            "input_features_at_15_seconds": feature_shape,
            "attention_mask_at_15_seconds": feature_shape[:2],
            "decoder_input_ids": [1, 1],
            "decoder_hidden_and_cell": [config["num_decoder_layers"], 1, config["decoder_hidden_size"]],
            "joint_encoder_and_decoder": [1, 1, config["decoder_hidden_size"]],
            "maximum_waveform_samples": 240000,
        }
    else:
        from coreai_torch import TorchConverter, get_decomp_table

        if args.engine == "whisper":
            from transformers import AutoProcessor

            model = module.WhisperModule(str(source.resolve()), dtype).eval()
            model._model.config.use_cache = False
            processor = AutoProcessor.from_pretrained(source, local_files_only=True)
            processor.save_pretrained(args.output / "processor")
            config = model._model.config.to_dict()
            prefix = whisper_prefix(processor, config)
            features = whisper_features(processor, torch.zeros(80000).numpy(), args.dtype)
            decoder_ids = torch.tensor([prefix], dtype=torch.int32)
            if args.static:
                decoder_ids = torch.full((1, 448), config["pad_token_id"], dtype=torch.int32)
                decoder_ids[0, : len(prefix)] = torch.tensor(prefix, dtype=torch.int32)
            inputs = {"input_features": torch.from_numpy(features), "decoder_input_ids": decoder_ids}
            dynamic = (
                None
                if args.static
                else {
                    "input_features": {},
                    "decoder_input_ids": {1: torch.export.Dim("decoder_tokens", min=1, max=448)},
                }
            )
            output_names = ["logits"]
            generation = model._model.generation_config.to_dict()
            details = {
                "architecture": "single_encoder_decoder_forward",
                "encoder_recomputed_per_token": True,
                "kv_cache": False,
                "maximum_decoder_input_tokens": 448,
                "fixed_decoder_input_tokens": 448 if args.static else None,
                "decoder_padding_token_id": config["pad_token_id"],
                "decoder_padding_policy": (
                    "Causal attention: select logits at the last real prefix token, never padded positions."
                ),
                "maximum_audio_seconds": 30.0,
                "feature_padding_seconds": 30,
                "input_features_shape": [1, 128, 3000],
                "decoder_input_dtype": "int32",
                "prefix_tokens": prefix,
                "eos_token_id": config["eos_token_id"],
                "suppress_tokens": generation.get("suppress_tokens") or [],
                "begin_suppress_tokens": generation.get("begin_suppress_tokens") or [],
                "timestamp_begin": processor.tokenizer.convert_tokens_to_ids("<|0.00|>"),
                "processor": "processor",
                "processor_artifact": tree(args.output / "processor"),
            }
        else:
            import torchaudio

            model = load_wav2vec2(module, source, dtype)
            inputs = {"waveform": torch.zeros(1, 240000 if args.static else 80000, dtype=dtype)}
            dynamic = None if args.static else {"waveform": {1: torch.export.Dim.DYNAMIC}}
            output_names = ["emission"]
            details = {
                "architecture": "waveform_ctc",
                "dynamic_audio": not args.static,
                "fixed_samples": 240000 if args.static else None,
                "minimum_samples": 400,
                "maximum_audio_seconds": 15.0 if args.static else 60.0,
                "labels": list(torchaudio.pipelines.WAV2VEC2_ASR_BASE_960H.get_labels()),
                "blank_token_id": 0,
                "word_delimiter": "|",
                "waveform_normalization": "none",
                "padding_note": "static zero padding changes group-normalization context" if args.static else "none",
            }
        with torch.inference_mode():
            program = torch.export.export(model, args=(), kwargs=inputs, dynamic_shapes=dynamic)
        details["export_range_constraints"] = str(program.range_constraints)
        program = program.run_decompositions(get_decomp_table())
        converted = (
            TorchConverter(mode=TorchConverter.Mode.RELEASE)
            .add_exported_program(
                exported_program=program,
                input_names=list(inputs),
                output_names=output_names,
            )
            .to_coreai()
        )
        converted.optimize()
        asset = args.output / "model.aimodel"
        module._save_asset(converted, asset, False)
        exported_artifacts = {"main": {"path": asset.name, "artifact": tree(asset)}}
    manifest = {
        "schema": "voiceour.apple27.coreai/1",
        "engine": args.engine,
        "model": args.model,
        "revision": args.revision,
        "dtype": args.dtype,
        "sample_rate": 16000,
        "source": record,
        "prepared_source": str(args.source.resolve()),
        "upstream": upstream_pin,
        "dependencies": versions(),
        "artifacts": exported_artifacts,
        "export_ms": (time.perf_counter() - start) * 1000,
        "compression": "none",
        "details": details,
    }
    write_json(args.output / "export.json", manifest)
    print(
        json.dumps(
            {
                "metadata": str((args.output / "export.json").resolve()),
                "bundle": details.get("bundle"),
                "export_ms": manifest["export_ms"],
            }
        )
    )


def trace(args) -> None:
    """Save real public-audio graph inputs and PyTorch outputs, not ground truth."""
    offline()
    check_environment(args.engine, exporting=True)
    record, source = source_record(args)
    module, upstream_pin = upstream(args.engine, args.upstream)
    import numpy as np
    import torch

    dtype = getattr(torch, args.dtype)
    samples, duration = audio(args.public_audio, 15.0, 400 if args.engine == "wav2vec2" else 1)
    if args.engine == "whisper":
        from transformers import AutoProcessor

        processor = AutoProcessor.from_pretrained(source, local_files_only=True)
        model = module.WhisperModule(str(source.resolve()), dtype).eval()
        model._model.config.use_cache = False
        prefix = whisper_prefix(processor, model._model.config.to_dict())
        inputs = {
            "input_features": torch.from_numpy(whisper_features(processor, samples, args.dtype)),
            "decoder_input_ids": torch.tensor([prefix], dtype=torch.int32),
        }
        with torch.inference_mode():
            output = model(**inputs)
        tensors = {**inputs, "logits": output}
    elif args.engine == "wav2vec2":
        model = load_wav2vec2(module, source, dtype)
        waveform = torch.from_numpy(samples).to(dtype).unsqueeze(0)
        if args.static:
            waveform = torch.nn.functional.pad(waveform, (0, 240000 - waveform.shape[1]))
        with torch.inference_mode():
            output = model(waveform)
        tensors = {"waveform": waveform, "emission": output}
    else:
        from transformers import AutoModelForTDT, AutoProcessor

        processor = AutoProcessor.from_pretrained(source, local_files_only=True)
        model = AutoModelForTDT.from_pretrained(source, dtype=dtype, local_files_only=True).eval()
        features = processor(samples, sampling_rate=16000, return_tensors="pt")["input_features"].to(dtype)
        feature_frames = features.shape[1]
        valid_frames = len(samples) // processor.feature_extractor.hop_length
        if args.static:
            capacity = module._audio_features(processor, dtype, 15.0).shape[1]
            if feature_frames > capacity:
                raise ValueError("Features exceed static export bound")
            features = torch.nn.functional.pad(features, (0, 0, 0, capacity - feature_frames))
        inputs = module._encoder_inputs(features)
        inputs["attention_mask"][:, valid_frames:] = False
        decoder_inputs = module._decoder_step_inputs(model.config, dtype)
        with torch.inference_mode():
            encoder = module.ParakeetEncoderModule(model).eval()(**inputs)
            decoder, hidden, cell = module.ParakeetDecoderStepModule(model).eval()(**decoder_inputs)
            joint_inputs = {"decoder_hidden_states": decoder, "encoder_hidden_states": encoder[:, :1, :]}
            logits = module.ParakeetJointModule(model).eval()(**joint_inputs)
        tensors = {
            **inputs,
            "encoder_hidden_states": encoder,
            **{f"decoder_{key}": value for key, value in decoder_inputs.items()},
            "decoder_output": decoder,
            "new_hidden_state": hidden,
            "new_cell_state": cell,
            **{f"joint_{key}": value for key, value in joint_inputs.items()},
            "logits": logits,
        }
    if args.output.exists() or args.output.with_suffix(".json").exists():
        raise FileExistsError(args.output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("xb") as stream:
        np.savez(stream, **{key: value.detach().cpu().numpy() for key, value in tensors.items()})
    write_json(
        args.output.with_suffix(".json"),
        {
            "kind": "pytorch_reference_graph_trace_not_benchmark",
            "source": record,
            "upstream": upstream_pin,
            "dependencies": versions(),
            "dtype": args.dtype,
            "static": args.static,
            "audio_path": str(args.public_audio.resolve()),
            "audio_sha256": digest(args.public_audio),
            "audio_s": duration,
            "trace_sha256": digest(args.output),
            "shapes": {key: list(value.shape) for key, value in tensors.items()},
        },
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="One-candidate pinned preparation/export; preparation is the only network operation.",
        epilog="Separate envs: Parakeet transformers[audio]==5.9.0; Whisper transformers==4.57.3; "
        "wav2vec2 torchaudio==2.11.0. Export needs torch==2.11.0, coreai-core==1.0.0b2, "
        "coreai-torch==0.4.2, numpy, scipy, soundfile. Output paths refuse overwrite.",
    )
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("prepare", "export", "trace"):
        sub = commands.add_parser(
            name,
            help={
                "prepare": "Explicitly download or copy and pin sources",
                "export": "Offline conversion, no measured inference",
                "trace": "Offline PyTorch graph parity trace from explicit public audio",
            }[name],
        )
        sub.add_argument("--engine", choices=MODELS, required=True)
        sub.add_argument("--model", required=True, help="HF model id, or wav2vec2_asr_base_960h")
        sub.add_argument("--revision", required=True, help="HF full commit SHA; wav2vec2 uses torchaudio-2.11.0")
        sub.add_argument("--output", type=Path, required=True, help="New directory; trace: new .npz file")
        if name == "prepare":
            sub.add_argument(
                "--download", action="store_true", help="Explicit permission to download selected pinned source"
            )
            sub.add_argument(
                "--local-source",
                type=Path,
                help="Local HF snapshot directory or wav2vec2 checkpoint; asserted revision recorded",
            )
        else:
            sub.add_argument("--source", type=Path, required=True, help="Prepared directory containing source.json")
            sub.add_argument("--upstream", type=Path, default=ROOT / ".build/apple27/upstream/coreai-models")
            sub.add_argument("--dtype", choices=("float16", "float32"), default="float16")
            sub.add_argument(
                "--static",
                action="store_true",
                help="Static 15s Parakeet/CTC export; default dynamic. Whisper always fixed 30s features.",
            )
            if name == "trace":
                sub.add_argument(
                    "--public-audio",
                    type=Path,
                    required=True,
                    help="Public fixture only; no microphone and no reference-text argument",
                )
    return result


def main() -> None:
    args = parser().parse_args()
    if args.model not in MODELS[args.engine]:
        raise ValueError(f"Unsupported {args.engine} model: {args.model}")
    {"prepare": prepare, "export": export, "trace": trace}[args.command](args)


if __name__ == "__main__":
    main()
