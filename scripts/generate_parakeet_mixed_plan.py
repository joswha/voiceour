#!/usr/bin/env python3

"""Inventory aligned F16/F32 Parakeet streams and emit an exact dual-source plan."""

import argparse
import csv
import hashlib
import io
import json
import math
import os
import struct
import tempfile
from dataclasses import dataclass
from pathlib import Path


MAGIC = 0x67676D6C
PLAN_MAGIC = "# voiceour-parakeet-mixed-plan-v2"
HPARAM_NAMES = (
    "n_vocab",
    "n_audio_ctx",
    "n_audio_state",
    "n_audio_head",
    "n_audio_layer",
    "n_mels",
    "ftype",
    "n_fft",
    "subsampling_factor",
    "n_subsampling_channels",
    "n_conv_kernel",
    "n_pred_dim",
    "n_pred_layers",
    "n_tdt_durations",
    "n_max_tokens",
)
TYPE_LAYOUTS = {
    0: ("f32", 1, 4),
    1: ("f16", 1, 2),
    8: ("q8_0", 32, 34),
    12: ("q4_K", 256, 144),
    14: ("q6_K", 256, 210),
}
COPY_CHUNK_BYTES = 1024 * 1024
# Mirrors the vendored loader's GGML_MAX_NAME bound (64 including the terminator).
MAXIMUM_NAME_BYTES = 63
MAXIMUM_AUDIO_LAYERS = 24
MAXIMUM_PREDICTION_LAYERS = 2
ELEMENT_CHUNK = 262144
FTYPE_OFFSET = 28
GGML_FTYPE_ALL_F32 = 0
GGML_FTYPE_MOSTLY_F16 = 1

# Mechanically mirrors parakeet_tensor_uses_record_type plus the layer loops in
# parakeet_expected_tensor_names and the C++ producer's concrete-name set.
MIXED_V1_FIXED_NAMES = frozenset(
    (
        "encoder.pre_encode.out.weight",
        "decoder.prediction.embed.weight",
        "joint.pred.weight",
        "joint.enc.weight",
        "joint.joint_net.2.weight",
    )
)
MIXED_V1_ENCODER_SUFFIXES = (
    ".feed_forward1.linear1.weight",
    ".feed_forward1.linear2.weight",
    ".conv.pointwise_conv1.weight",
    ".conv.pointwise_conv2.weight",
    ".self_attn.linear_q.weight",
    ".self_attn.linear_k.weight",
    ".self_attn.linear_v.weight",
    ".self_attn.linear_out.weight",
    ".self_attn.linear_pos.weight",
    ".feed_forward2.linear1.weight",
    ".feed_forward2.linear2.weight",
)


def mixed_v1_loader_allowed_names(hparams: dict[str, int]) -> frozenset[str]:
    audio_layers = hparams["n_audio_layer"]
    prediction_layers = hparams["n_pred_layers"]
    if not 0 < audio_layers <= MAXIMUM_AUDIO_LAYERS:
        raise ModelError(f"invalid n_audio_layer {audio_layers}")
    if not 0 < prediction_layers <= MAXIMUM_PREDICTION_LAYERS:
        raise ModelError(f"invalid n_pred_layers {prediction_layers}")

    names = set(MIXED_V1_FIXED_NAMES)
    for layer in range(audio_layers):
        prefix = f"encoder.layers.{layer}"
        names.update(prefix + suffix for suffix in MIXED_V1_ENCODER_SUFFIXES)
    for layer in range(prediction_layers):
        names.add(f"decoder.prediction.dec_rnn.lstm.weight_ih_l{layer}")
        names.add(f"decoder.prediction.dec_rnn.lstm.weight_hh_l{layer}")
    return frozenset(names)


@dataclass(frozen=True)
class TensorRecord:
    index: int
    name: str
    n_dims: int
    dims: tuple[int, ...]
    type_id: int
    type_name: str
    payload_offset: int
    payload_bytes: int

    @property
    def shape(self) -> str:
        return "x".join(str(dimension) for dimension in self.dims) if self.dims else "-"


class ModelError(ValueError):
    pass


def read_exact(stream, size: int, description: str) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        raise ModelError(
            f"truncated {description} at offset {stream.tell() - len(data)}: "
            f"wanted {size}, got {len(data)}"
        )
    return data


def read_i32(stream, description: str) -> int:
    return struct.unpack("<i", read_exact(stream, 4, description))[0]


def read_u32(stream, description: str) -> int:
    return struct.unpack("<I", read_exact(stream, 4, description))[0]


def payload_size(type_id: int, dims: tuple[int, ...], name: str) -> int:
    try:
        _, block_size, type_size = TYPE_LAYOUTS[type_id]
    except KeyError as error:
        raise ModelError(f"unsupported source tensor type {type_id} for {name}") from error
    physical_dims = dims or (1,)
    if physical_dims[0] <= 0 or physical_dims[0] % block_size:
        raise ModelError(
            f"tensor {name} ne[0]={physical_dims[0]} is not divisible by block size "
            f"{block_size}"
        )
    return math.prod(physical_dims) // block_size * type_size


def checked_seek(stream, count: int, file_size: int, description: str) -> None:
    if count < 0 or stream.tell() + count > file_size:
        raise ModelError(f"truncated {description} at offset {stream.tell()}")
    stream.seek(count, os.SEEK_CUR)


def parse_model(
    path: Path, stream, file_size: int
) -> tuple[dict[str, int], list[TensorRecord], int]:
    stream.seek(0)
    if True:
        if read_u32(stream, "model magic") != MAGIC:
            raise ModelError(f"bad model magic in {path}")
        hparams = {
            name: read_i32(stream, "model hyperparameters") for name in HPARAM_NAMES
        }

        n_mel = read_i32(stream, "mel-filter dimensions")
        n_filter_bank = read_i32(stream, "mel-filter dimensions")
        if n_mel <= 0 or n_filter_bank <= 0:
            raise ModelError(f"invalid mel-filter dimensions {n_mel}x{n_filter_bank}")
        checked_seek(stream, n_mel * n_filter_bank * 4, file_size, "mel-filter payload")

        n_window = read_i32(stream, "window length")
        if n_window <= 0:
            raise ModelError(f"invalid window length {n_window}")
        checked_seek(stream, n_window * 4, file_size, "window payload")

        duration_count = hparams["n_tdt_durations"]
        if duration_count < 0:
            raise ModelError(f"invalid duration count {duration_count}")
        checked_seek(stream, duration_count * 4, file_size, "duration payload")

        token_count = read_i32(stream, "token count")
        if token_count < 0:
            raise ModelError(f"invalid token count {token_count}")
        for _ in range(token_count):
            length = read_u32(stream, "token length")
            checked_seek(stream, length, file_size, "token bytes")

        tensor_offset = stream.tell()
        records = []
        names = set()
        while stream.tell() < file_size:
            record_offset = stream.tell()
            if file_size - record_offset < 12:
                raise ModelError(f"truncated tensor header at offset {record_offset}")
            n_dims, name_length, type_id = struct.unpack(
                "<iii", read_exact(stream, 12, "tensor header")
            )
            if not 0 <= n_dims <= 4 or not 0 < name_length <= MAXIMUM_NAME_BYTES:
                raise ModelError(f"invalid tensor header at offset {record_offset}")
            dims = tuple(read_i32(stream, "tensor dimensions") for _ in range(n_dims))
            if any(dimension <= 0 for dimension in dims):
                raise ModelError(f"invalid tensor dimensions at offset {record_offset}: {dims}")
            raw_name = read_exact(stream, name_length, "tensor name")
            try:
                name = raw_name.decode("utf-8")
            except UnicodeDecodeError as error:
                raise ModelError(f"invalid UTF-8 tensor name at offset {record_offset}") from error
            if not name or "\x00" in name or any(character in name for character in "\t\r\n"):
                raise ModelError(f"tensor name cannot be represented in exact TSV: {name!r}")
            if name in names:
                raise ModelError(f"duplicate source tensor {name}")
            names.add(name)
            type_name = TYPE_LAYOUTS.get(type_id, (None, None, None))[0]
            if type_name is None:
                raise ModelError(f"unsupported source tensor type {type_id} for {name}")
            encoded_bytes = payload_size(type_id, dims, name)
            payload_offset = stream.tell()
            checked_seek(stream, encoded_bytes, file_size, f"tensor {name} payload")
            records.append(
                TensorRecord(
                    index=len(records),
                    name=name,
                    n_dims=n_dims,
                    dims=dims,
                    type_id=type_id,
                    type_name=type_name,
                    payload_offset=payload_offset,
                    payload_bytes=encoded_bytes,
                )
            )
        if stream.tell() != file_size:
            raise ModelError(f"tensor parser ended at {stream.tell()}, expected {file_size}")
    return hparams, records, tensor_offset


def sha256_stream(stream, size: int, description: str) -> str:
    stream.seek(0)
    digest = hashlib.sha256()
    remaining = size
    while remaining:
        chunk = stream.read(min(remaining, COPY_CHUNK_BYTES))
        if not chunk:
            raise ModelError(f"truncated {description} while hashing")
        digest.update(chunk)
        remaining -= len(chunk)
    return digest.hexdigest()


def file_identity(descriptor: int) -> tuple[int, int, int, int]:
    status = os.fstat(descriptor)
    return (status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns)


def verify_source_unchanged(path: Path, stream, identity) -> None:
    if file_identity(stream.fileno()) != identity:
        raise ModelError(f"source changed while generating the plan: {path}")
    status = os.stat(path)
    if (status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns) != identity:
        raise ModelError(f"source changed while generating the plan: {path}")


def validate_preambles(
    input_stream,
    quant_stream,
    input_hparams: dict[str, int],
    quant_hparams: dict[str, int],
    input_tensor_offset: int,
    quant_tensor_offset: int,
) -> None:
    if input_hparams["ftype"] != GGML_FTYPE_MOSTLY_F16:
        raise ModelError(
            f"input global ftype must be f16, got {input_hparams['ftype']}"
        )
    if quant_hparams["ftype"] != GGML_FTYPE_ALL_F32:
        raise ModelError(
            f"quant source global ftype must be f32, got {quant_hparams['ftype']}"
        )
    if input_tensor_offset != quant_tensor_offset:
        raise ModelError(
            f"quant source preamble size mismatch: input={input_tensor_offset} "
            f"quant_source={quant_tensor_offset}"
        )
    input_stream.seek(0)
    quant_stream.seek(0)
    input_preamble = bytearray(
        read_exact(input_stream, input_tensor_offset, "input preamble")
    )
    quant_preamble = bytearray(
        read_exact(quant_stream, quant_tensor_offset, "quant source preamble")
    )
    input_preamble[FTYPE_OFFSET : FTYPE_OFFSET + 4] = b"\x00\x00\x00\x00"
    quant_preamble[FTYPE_OFFSET : FTYPE_OFFSET + 4] = b"\x00\x00\x00\x00"
    if input_preamble != quant_preamble:
        raise ModelError("quant source preamble does not match input")


def verify_selected_f16_equivalence(
    f16_stream,
    f32_stream,
    input_by_name: dict[str, TensorRecord],
    quant_by_name: dict[str, TensorRecord],
    selected_names: list[str],
) -> None:
    if True:
        for name in selected_names:
            input_record = input_by_name[name]
            quant_record = quant_by_name[name]
            if input_record.type_id != 1 or quant_record.type_id != 0:
                raise ModelError(
                    f"selected pair {name} must be f16 input over f32 quant source"
                )
            f16_stream.seek(input_record.payload_offset)
            f32_stream.seek(quant_record.payload_offset)
            remaining = input_record.payload_bytes // 2
            while remaining:
                count = min(remaining, ELEMENT_CHUNK)
                f32_bytes = read_exact(
                    f32_stream, count * 4, f"quant source payload for {name}"
                )
                f16_bytes = read_exact(
                    f16_stream, count * 2, f"input payload for {name}"
                )
                values = struct.unpack(f"<{count}f", f32_bytes)
                try:
                    rounded = struct.pack(f"<{count}e", *values)
                except (OverflowError, ValueError) as error:
                    raise ModelError(
                        f"selected quant source tensor {name} does not round "
                        f"exactly to input f16"
                    ) from error
                if rounded != f16_bytes:
                    raise ModelError(
                        f"selected quant source tensor {name} does not round "
                        f"exactly to input f16"
                    )
                remaining -= count

def validate_quant_source(
    input_hparams: dict[str, int],
    input_records: list[TensorRecord],
    quant_hparams: dict[str, int],
    quant_records: list[TensorRecord],
) -> None:
    for name in HPARAM_NAMES:
        if name == "ftype":
            continue
        if input_hparams[name] != quant_hparams[name]:
            raise ModelError(
                f"quant source hyperparameter mismatch for {name}: "
                f"input={input_hparams[name]} quant_source={quant_hparams[name]}"
            )
    if len(input_records) != len(quant_records):
        raise ModelError(
            f"quant source tensor count mismatch: "
            f"input={len(input_records)} quant_source={len(quant_records)}"
        )
    for input_record, quant_record in zip(input_records, quant_records):
        if input_record.name != quant_record.name:
            raise ModelError(
                f"quant source tensor name mismatch at index {input_record.index}: "
                f"input={input_record.name} quant_source={quant_record.name}"
            )
        if (
            input_record.n_dims != quant_record.n_dims
            or input_record.dims != quant_record.dims
        ):
            raise ModelError(
                f"quant source tensor shape mismatch for {input_record.name}: "
                f"input={input_record.shape} quant_source={quant_record.shape}"
            )


def select_all_q8(records: list[TensorRecord]) -> list[tuple[str, str]]:
    selected = []
    for record in records:
        if record.type_id != 1:
            continue
        if record.n_dims != 2:
            raise ModelError(
                f"all-q8 source F16 tensor is not 2-D: {record.name} ({record.shape})"
            )
        if record.dims[0] % TYPE_LAYOUTS[8][1]:
            raise ModelError(
                f"all-q8 source F16 tensor is not Q8_0 block-compatible: "
                f"{record.name} ({record.shape})"
            )
        selected.append((record.name, "q8_0"))
    if not selected:
        raise ModelError("all-q8 found no F16 matrix records")
    return selected


def select_encoder_ffn_q6(
    hparams: dict[str, int], records: list[TensorRecord]
) -> list[tuple[str, str]]:
    layer_count = hparams["n_audio_layer"]
    if layer_count <= 0:
        raise ModelError(f"invalid n_audio_layer {layer_count}")
    by_name = {record.name: record for record in records}
    selected = []
    for layer in range(layer_count):
        for feed_forward in (1, 2):
            for linear, expected_dims in ((1, (1024, 4096)), (2, (4096, 1024))):
                name = (
                    f"encoder.layers.{layer}.feed_forward{feed_forward}."
                    f"linear{linear}.weight"
                )
                record = by_name.get(name)
                if record is None:
                    raise ModelError(f"encoder-ffn-q6 tensor is missing: {name}")
                if record.type_id != 1:
                    raise ModelError(
                        f"encoder-ffn-q6 tensor must be f16, got {record.type_name}: {name}"
                    )
                if record.n_dims != 2 or record.dims != expected_dims:
                    raise ModelError(
                        f"encoder-ffn-q6 tensor has shape {record.shape}, expected "
                        f"{'x'.join(map(str, expected_dims))}: {name}"
                    )
                if record.dims[0] % TYPE_LAYOUTS[14][1]:
                    raise ModelError(
                        f"encoder-ffn-q6 tensor is not Q6_K block-compatible: {name}"
                    )
                selected.append((name, "q6_K"))
    expected_count = layer_count * 4
    if len(selected) != expected_count:
        raise ModelError(
            f"encoder-ffn-q6 resolved {len(selected)} tensors, expected {expected_count}"
        )
    return selected


def render_inventory(
    input_records: list[TensorRecord],
    quant_records: list[TensorRecord],
) -> str:
    output = io.StringIO(newline="")
    writer = csv.writer(output, delimiter="\t", lineterminator="\n")
    writer.writerow(
        (
            "index",
            "name",
            "n_dims",
            "shape",
            "input_type_id",
            "input_type",
            "input_payload_offset",
            "input_payload_bytes",
            "quant_source_type_id",
            "quant_source_type",
            "quant_source_payload_offset",
            "quant_source_payload_bytes",
        )
    )
    for input_record, quant_record in zip(input_records, quant_records):
        writer.writerow(
            (
                input_record.index,
                input_record.name,
                input_record.n_dims,
                input_record.shape,
                input_record.type_id,
                input_record.type_name,
                input_record.payload_offset,
                input_record.payload_bytes,
                quant_record.type_id,
                quant_record.type_name,
                quant_record.payload_offset,
                quant_record.payload_bytes,
            )
        )
    return output.getvalue()


def render_plan(
    input_size: int,
    input_sha256: str,
    quant_source_size: int,
    quant_source_sha256: str,
    nominal_type: str,
    entries: list[tuple[str, str]],
) -> str:
    lines = [
        PLAN_MAGIC,
        f"# input_size_bytes={input_size}",
        f"# input_sha256={input_sha256}",
        f"# quant_source_size_bytes={quant_source_size}",
        f"# quant_source_sha256={quant_source_sha256}",
        f"# nominal_type={nominal_type}",
    ]
    lines.extend(f"{name}\t{target}" for name, target in entries)
    return "\n".join(lines) + "\n"


def fsync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_new_atomic(
    path: Path,
    content: str,
    linked_paths: list[Path],
    temporary_paths: list[Path],
) -> None:
    descriptor, raw_temporary = tempfile.mkstemp(
        prefix=f"{path.name}.tmp.", dir=path.parent
    )
    temporary = Path(raw_temporary)
    temporary_paths.append(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise FileExistsError(f"output already exists: {path}") from error
        linked_paths.append(path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            temporary_paths.remove(temporary)
        else:
            temporary_paths.remove(temporary)


def publish_pair(
    inventory_path: Path,
    inventory_text: str,
    plan_path: Path,
    plan_text: str,
) -> None:
    inventory_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.parent.mkdir(parents=True, exist_ok=True)
    resolved_inventory = inventory_path.parent.resolve() / inventory_path.name
    resolved_plan = plan_path.parent.resolve() / plan_path.name
    if resolved_inventory == resolved_plan:
        raise ModelError("plan and inventory paths must differ")
    # Preflight both destinations before publishing either, so a rejected pair never
    # leaves a half-result behind.
    for path in (inventory_path, plan_path):
        if os.path.lexists(path):
            raise FileExistsError(f"output already exists: {path}")

    publication_directories = list(
        dict.fromkeys(
            (
                inventory_path.parent.resolve(),
                plan_path.parent.resolve(),
            )
        )
    )
    linked_paths: list[Path] = []
    temporary_paths: list[Path] = []
    try:
        write_new_atomic(
            inventory_path,
            inventory_text,
            linked_paths,
            temporary_paths,
        )
        write_new_atomic(
            plan_path,
            plan_text,
            linked_paths,
            temporary_paths,
        )
        for directory in publication_directories:
            fsync_directory(directory)
    except BaseException:
        for path in reversed(linked_paths):
            try:
                os.unlink(path)
            except OSError:
                pass
        for path in temporary_paths:
            try:
                os.unlink(path)
            except OSError:
                pass
        for directory in publication_directories:
            try:
                fsync_directory(directory)
            except OSError:
                pass
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--quant-source", required=True, type=Path)
    parser.add_argument(
        "--family", required=True, choices=("all-q8", "encoder-ffn-q6")
    )
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    arguments = parser.parse_args()

    with arguments.input.open("rb") as input_stream, \
            arguments.quant_source.open("rb") as quant_stream:
        input_identity = file_identity(input_stream.fileno())
        quant_identity = file_identity(quant_stream.fileno())
        input_size = input_identity[2]
        quant_source_size = quant_identity[2]
        input_sha256 = sha256_stream(input_stream, input_size, "input")
        quant_source_sha256 = sha256_stream(
            quant_stream, quant_source_size, "quant source"
        )
        input_hparams, input_records, input_tensor_offset = parse_model(
            arguments.input, input_stream, input_size
        )
        quant_hparams, quant_records, quant_tensor_offset = parse_model(
            arguments.quant_source, quant_stream, quant_source_size
        )
        validate_preambles(
            input_stream,
            quant_stream,
            input_hparams,
            quant_hparams,
            input_tensor_offset,
            quant_tensor_offset,
        )
        validate_quant_source(
            input_hparams,
            input_records,
            quant_hparams,
            quant_records,
        )
        allowed_names = mixed_v1_loader_allowed_names(input_hparams)
        if arguments.family == "all-q8":
            nominal_type = "q8_0"
            entries = select_all_q8(input_records)
        else:
            nominal_type = "q6_K"
            entries = select_encoder_ffn_q6(input_hparams, input_records)

        input_by_name = {record.name: record for record in input_records}
        quant_by_name = {record.name: record for record in quant_records}
        selected_names = [name for name, _ in entries]
        for name in selected_names:
            if name not in allowed_names:
                raise ModelError(
                    f"plan selects tensor outside the mixed-v1 loader allowlist: {name}"
                )
            if quant_by_name[name].type_id != 0:
                raise ModelError(
                    f"selected quant source tensor {name} must be f32, "
                    f"got {quant_by_name[name].type_name}"
                )
        verify_selected_f16_equivalence(
            input_stream,
            quant_stream,
            input_by_name,
            quant_by_name,
            selected_names,
        )
        verify_source_unchanged(arguments.input, input_stream, input_identity)
        verify_source_unchanged(
            arguments.quant_source, quant_stream, quant_identity
        )

    inventory = render_inventory(input_records, quant_records)
    plan = render_plan(
        input_size,
        input_sha256,
        quant_source_size,
        quant_source_sha256,
        nominal_type,
        entries,
    )
    publish_pair(arguments.inventory, inventory, arguments.plan, plan)
    print(
        json.dumps(
            {
                "family": arguments.family,
                "input_size_bytes": input_size,
                "input_sha256": input_sha256,
                "quant_source_size_bytes": quant_source_size,
                "quant_source_sha256": quant_source_sha256,
                "record_count": len(input_records),
                "selected_count": len(entries),
                "inventory": str(arguments.inventory),
                "plan": str(arguments.plan),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
