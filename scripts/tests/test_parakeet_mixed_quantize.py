#!/usr/bin/env python3

import hashlib
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
CONVERTER = Path(
    os.environ.get(
        "PARAKEET_MIXED_QUANTIZE_BIN",
        ROOT / ".build" / "debug" / "parakeet-mixed-quantize",
    )
)
GENERATOR = ROOT / "scripts" / "generate_parakeet_mixed_plan.py"
GENERATOR_MODULE_NAME = "_voiceour_parakeet_mixed_plan_test"
GENERATOR_SPEC = importlib.util.spec_from_file_location(
    GENERATOR_MODULE_NAME, GENERATOR
)
if GENERATOR_SPEC is None or GENERATOR_SPEC.loader is None:
    raise RuntimeError(f"cannot load generator module: {GENERATOR}")
GENERATOR_MODULE = importlib.util.module_from_spec(GENERATOR_SPEC)
sys.modules[GENERATOR_MODULE_NAME] = GENERATOR_MODULE
GENERATOR_SPEC.loader.exec_module(GENERATOR_MODULE)
MAGIC = 0x67676D6C
TYPE_LAYOUTS = {
    0: ("f32", 1, 4),
    1: ("f16", 1, 2),
    8: ("q8_0", 32, 34),
    12: ("q4_K", 256, 144),
    14: ("q6_K", 256, 210),
}

MIXED_V1_ALLOWED_NAMES = (
    "encoder.pre_encode.out.weight",
    "encoder.layers.0.feed_forward1.linear1.weight",
    "encoder.layers.0.feed_forward1.linear2.weight",
    "encoder.layers.0.conv.pointwise_conv1.weight",
    "encoder.layers.0.conv.pointwise_conv2.weight",
    "encoder.layers.0.self_attn.linear_q.weight",
    "encoder.layers.0.self_attn.linear_k.weight",
    "encoder.layers.0.self_attn.linear_v.weight",
    "encoder.layers.0.self_attn.linear_out.weight",
    "encoder.layers.0.self_attn.linear_pos.weight",
    "encoder.layers.0.feed_forward2.linear1.weight",
    "encoder.layers.0.feed_forward2.linear2.weight",
    "decoder.prediction.embed.weight",
    "decoder.prediction.dec_rnn.lstm.weight_ih_l0",
    "decoder.prediction.dec_rnn.lstm.weight_hh_l0",
    "joint.pred.weight",
    "joint.enc.weight",
    "joint.joint_net.2.weight",
)


def payload_bytes(type_id, dims):
    _, block, size = TYPE_LAYOUTS[type_id]
    physical = dims or [1]
    if physical[0] % block:
        raise ValueError("invalid fixture block shape")
    elements = 1
    for dimension in physical:
        elements *= dimension
    return elements // block * size


def encoded_values(type_id, dims, seed):
    count = 1
    for dimension in dims or [1]:
        count *= dimension
    values = [((index + seed) % 29 - 14) / 7 for index in range(count)]
    if type_id == 0:
        return struct.pack(f"<{count}f", *values)
    if type_id == 1:
        return struct.pack(f"<{count}e", *values)
    return bytes((index + seed) % 251 for index in range(payload_bytes(type_id, dims)))


def write_model(
    path, records, *, audio_layers=1, pred_layers=2, ftype=1
):
    hparams = [
        0,
        1,
        1024,
        8,
        audio_layers,
        1,
        ftype,
        2,
        8,
        1,
        9,
        640,
        pred_layers,
        0,
        10,
    ]
    with path.open("wb") as output:
        output.write(struct.pack("<I", MAGIC))
        output.write(struct.pack("<15i", *hparams))
        output.write(struct.pack("<ii", 1, 1))
        output.write(struct.pack("<f", 0.25))
        output.write(struct.pack("<i", 1))
        output.write(struct.pack("<f", 0.5))
        output.write(struct.pack("<i", 0))
        for name, dims, type_id, seed in records:
            encoded_name = name.encode("utf-8")
            output.write(struct.pack("<iii", len(dims), len(encoded_name), type_id))
            if dims:
                output.write(struct.pack(f"<{len(dims)}i", *dims))
            output.write(encoded_name)
            output.write(encoded_values(type_id, dims, seed))


def parse_model(path):
    data = path.read_bytes()
    offset = 0

    def take(fmt):
        nonlocal offset
        size = struct.calcsize(fmt)
        values = struct.unpack_from(fmt, data, offset)
        offset += size
        return values

    (magic,) = take("<I")
    if magic != MAGIC:
        raise ValueError("bad magic")
    hparams = list(take("<15i"))
    n_mel, n_fb = take("<ii")
    offset += n_mel * n_fb * 4
    (n_window,) = take("<i")
    offset += n_window * 4
    offset += hparams[13] * 4
    (n_tokens,) = take("<i")
    for _ in range(n_tokens):
        (length,) = take("<I")
        offset += length

    records = []
    while offset < len(data):
        record_offset = offset
        n_dims, name_length, type_id = take("<iii")
        dims = list(take(f"<{n_dims}i")) if n_dims else []
        name = data[offset : offset + name_length].decode("utf-8")
        offset += name_length
        size = payload_bytes(type_id, dims)
        payload = data[offset : offset + size]
        offset += size
        records.append(
            {
                "name": name,
                "n_dims": n_dims,
                "dims": dims,
                "type_id": type_id,
                "payload": payload,
                "raw": data[record_offset:offset],
            }
        )
    if offset != len(data):
        raise ValueError("parser did not end at EOF")
    return hparams, records


def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def build_fsync_fault_library(directory):
    source = directory / "fail-fsync.c"
    library = directory / "libfail-fsync.dylib"
    source.write_text(
        r"""
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static int replacement_fsync(int descriptor) {
    static unsigned long directory_call_count = 0;
    struct stat status;
    if (fstat(descriptor, &status) == 0 && S_ISDIR(status.st_mode)) {
        ++directory_call_count;
        const char * raw_failure_call =
            getenv("VOICEOUR_TEST_FAIL_DIRECTORY_FSYNC_CALL");
        if (raw_failure_call != NULL &&
                strtoul(raw_failure_call, NULL, 10) ==
                    directory_call_count) {
            errno = EIO;
            return -1;
        }
    }
    return (int)syscall(SYS_fsync, descriptor);
}

#define DYLD_INTERPOSE(replacement, replacee)                              \
    __attribute__((used)) static struct {                                  \
        const void * replacement;                                          \
        const void * replacee;                                             \
    } interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement,                              \
        (const void *)(uintptr_t)&replacee                                  \
    }

DYLD_INTERPOSE(replacement_fsync, fsync);
""".lstrip(),
        encoding="utf-8",
    )
    compiled = subprocess.run(
        ["cc", "-dynamiclib", str(source), "-o", str(library)],
        text=True,
        capture_output=True,
    )
    if compiled.returncode != 0:
        raise AssertionError(compiled.stderr)
    return library


def write_plan(
    path,
    input_model,
    quant_source,
    entries,
    *,
    nominal_type="q8_0",
    input_sha=None,
    input_size=None,
    quant_sha=None,
    quant_size=None,
):
    lines = [
        "# voiceour-parakeet-mixed-plan-v2",
        f"# input_size_bytes={input_size if input_size is not None else input_model.stat().st_size}",
        f"# input_sha256={input_sha if input_sha is not None else sha256_file(input_model)}",
        f"# quant_source_size_bytes={quant_size if quant_size is not None else quant_source.stat().st_size}",
        f"# quant_source_sha256={quant_sha if quant_sha is not None else sha256_file(quant_source)}",
        f"# nominal_type={nominal_type}",
    ]
    lines.extend(f"{name}\t{target}" for name, target in entries)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class MixedQuantizeTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CONVERTER.is_file(), f"missing converter executable: {CONVERTER}")
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)
        self.source = self.directory / "source-f16.bin"
        self.quant_source = self.directory / "source-f32.bin"
        records = [
            ("encoder.pre_encode.out.weight", [256, 2], 1, 1),
            ("joint.enc.weight", [256, 1], 0, 2),
            ("legacy_scalar", [], 0, 3),
        ]
        quant_records = [
            ("encoder.pre_encode.out.weight", [256, 2], 0, 101),
            ("joint.enc.weight", [256, 1], 0, 102),
            ("legacy_scalar", [], 0, 3),
        ]
        write_model(self.source, records, ftype=1)
        write_model(self.quant_source, quant_records, ftype=0)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def run_converter(
        self,
        plan,
        output=None,
        report=None,
        *,
        quant_source=None,
        include_quant_source=True,
        env=None,
        timeout=None,
    ):
        if output is None:
            output = self.directory / "output.bin"
        command = [str(CONVERTER), "--input", str(self.source)]
        if include_quant_source:
            command.extend(
                ["--quant-source", str(quant_source or self.quant_source)]
            )
        command.extend(["--plan", str(plan), "--output", str(output)])
        if report is not None:
            command.extend(["--report", str(report)])
        return (
            subprocess.run(
                command,
                text=True,
                capture_output=True,
                env=env,
                timeout=timeout,
            ),
            output,
        )

    def run_generator(
        self,
        source,
        quant_source,
        family,
        plan,
        inventory,
    ):
        return subprocess.run(
            [
                "python3",
                str(GENERATOR),
                "--input",
                str(source),
                "--quant-source",
                str(quant_source),
                "--family",
                family,
                "--plan",
                str(plan),
                "--inventory",
                str(inventory),
            ],
            text=True,
            capture_output=True,
        )

    def test_deterministic_double_conversion_and_record_preservation(self):
        plan = self.directory / "plan.tsv"
        write_plan(
            plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q6_K"), ("joint.enc.weight", "q6_K")],
            nominal_type="q6_K",
        )
        report_a = self.directory / "report-a.tsv"
        result_a, output_a = self.run_converter(
            plan, self.directory / "output-a.bin", report_a
        )
        result_b, output_b = self.run_converter(
            plan, self.directory / "output-b.bin"
        )
        self.assertEqual(result_a.returncode, 0, result_a.stderr)
        self.assertEqual(result_b.returncode, 0, result_b.stderr)
        self.assertEqual(output_a.read_bytes(), output_b.read_bytes())
        self.assertIn("# voiceour-parakeet-mixed-report-v2", result_b.stdout)

        source_hparams, source_records = parse_model(self.source)
        output_hparams, output_records = parse_model(output_a)
        self.assertEqual(output_hparams[6], 2014)
        self.assertEqual(
            [record["name"] for record in output_records],
            [record["name"] for record in source_records],
        )
        self.assertEqual([record["type_id"] for record in output_records], [14, 14, 0])
        self.assertEqual(len(output_records[0]["payload"]), 420)
        self.assertEqual(len(output_records[1]["payload"]), 210)
        self.assertEqual(output_records[2]["n_dims"], 0)
        self.assertEqual(output_records[2]["raw"], source_records[2]["raw"])
        self.assertNotEqual(source_hparams[6], output_hparams[6])

        report = report_a.read_text(encoding="utf-8")
        self.assertIn(f"# input_sha256={sha256_file(self.source)}", report)
        self.assertIn(
            f"# quant_source_sha256={sha256_file(self.quant_source)}", report
        )
        self.assertIn(f"# output_size_bytes={output_a.stat().st_size}", report)
        self.assertIn(f"# output_sha256={sha256_file(output_a)}", report)
        self.assertIn("legacy_scalar\t0\t-\tf32\tf32\tf32\t4\t4\t4", report)

    def test_selected_payload_comes_from_f32_quant_source(self):
        plan_a = self.directory / "source-a.tsv"
        write_plan(
            plan_a,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q8_0")],
        )
        result_a, output_a = self.run_converter(
            plan_a, self.directory / "source-a.bin"
        )
        self.assertEqual(result_a.returncode, 0, result_a.stderr)

        alternate = self.directory / "alternate-f32.bin"
        write_model(
            alternate,
            [
                ("encoder.pre_encode.out.weight", [256, 2], 0, 116),
                ("joint.enc.weight", [256, 1], 0, 102),
                ("legacy_scalar", [], 0, 3),
            ],
            ftype=0,
        )
        plan_b = self.directory / "source-b.tsv"
        write_plan(plan_b, self.source, alternate, [("encoder.pre_encode.out.weight", "q8_0")])
        result_b, output_b = self.run_converter(
            plan_b,
            self.directory / "source-b.bin",
            quant_source=alternate,
        )
        self.assertEqual(result_b.returncode, 0, result_b.stderr)
        self.assertNotEqual(
            parse_model(output_a)[1][0]["payload"],
            parse_model(output_b)[1][0]["payload"],
        )

    def test_noop_is_byte_identical_to_input(self):
        plan = self.directory / "noop.tsv"
        write_plan(
            plan,
            self.source,
            self.quant_source,
            [],
            nominal_type="f16",
        )
        result, output = self.run_converter(plan, self.directory / "noop.bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), self.source.read_bytes())

    def test_missing_bad_and_mismatched_quant_source_rejection(self):
        plan = self.directory / "plan.tsv"
        write_plan(plan, self.source, self.quant_source, [("encoder.pre_encode.out.weight", "q6_K")])

        result, output = self.run_converter(
            plan,
            self.directory / "missing-argument.bin",
            include_quant_source=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--quant-source", result.stderr)
        self.assertFalse(output.exists())

        bad_pin = self.directory / "bad-pin.tsv"
        write_plan(
            bad_pin,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q6_K")],
            quant_sha="0" * 64,
        )
        result, output = self.run_converter(
            bad_pin, self.directory / "bad-pin.bin"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("quant source SHA-256 mismatch", result.stderr)
        self.assertFalse(output.exists())

        wrong_shape = self.directory / "wrong-shape.bin"
        write_model(
            wrong_shape,
            [
                ("encoder.pre_encode.out.weight", [256, 3], 0, 101),
                ("joint.enc.weight", [256, 1], 0, 102),
                ("legacy_scalar", [], 0, 3),
            ],
            ftype=0,
        )
        wrong_shape_plan = self.directory / "wrong-shape.tsv"
        write_plan(
            wrong_shape_plan,
            self.source,
            wrong_shape,
            [("encoder.pre_encode.out.weight", "q6_K")],
        )
        result, output = self.run_converter(
            wrong_shape_plan,
            self.directory / "wrong-shape-out.bin",
            quant_source=wrong_shape,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("quant source tensor shape mismatch", result.stderr)
        self.assertFalse(output.exists())

        f16_quant_source = self.directory / "selected-f16.bin"
        write_model(
            f16_quant_source,
            [
                ("encoder.pre_encode.out.weight", [256, 2], 1, 101),
                ("joint.enc.weight", [256, 1], 0, 102),
                ("legacy_scalar", [], 0, 3),
            ],
            ftype=0,
        )
        f16_plan = self.directory / "selected-f16.tsv"
        write_plan(
            f16_plan,
            self.source,
            f16_quant_source,
            [("encoder.pre_encode.out.weight", "q6_K")],
        )
        result, output = self.run_converter(
            f16_plan,
            self.directory / "selected-f16-out.bin",
            quant_source=f16_quant_source,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
                    "selected quant source tensor encoder.pre_encode.out.weight must be f32",
                    result.stderr,
                )
        self.assertFalse(output.exists())

    def test_duplicate_missing_unknown_and_bad_input_pin_rejection(self):
        duplicate = self.directory / "duplicate.tsv"
        write_plan(
            duplicate,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q6_K"), ("encoder.pre_encode.out.weight", "q6_K")],
            nominal_type="q6_K",
        )
        result, output = self.run_converter(duplicate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate plan tensor", result.stderr)
        self.assertFalse(output.exists())

        missing = self.directory / "missing.tsv"
        missing.write_text(
            "# voiceour-parakeet-mixed-plan-v2\n"
            f"# input_size_bytes={self.source.stat().st_size}\n"
            f"# input_sha256={sha256_file(self.source)}\n"
            f"# quant_source_size_bytes={self.quant_source.stat().st_size}\n"
            "# nominal_type=q6_K\n"
            "matrix_f16\tq6_K\n",
            encoding="utf-8",
        )
        result, output = self.run_converter(missing, self.directory / "missing.bin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing quant_source_sha256", result.stderr)
        self.assertFalse(output.exists())

        unknown = self.directory / "unknown.tsv"
        write_plan(
            unknown,
            self.source,
            self.quant_source,
            [("joint.joint_net.2.weight", "q6_K")],
            nominal_type="q6_K",
        )
        result, output = self.run_converter(
            unknown, self.directory / "unknown.bin"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plan tensor not found", result.stderr)
        self.assertFalse(output.exists())
        self.assertEqual(list(self.directory.glob("unknown.bin.tmp.*")), [])

        bad_input = self.directory / "bad-input.tsv"
        write_plan(
            bad_input,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q6_K")],
            input_sha="0" * 64,
        )
        result, output = self.run_converter(
            bad_input, self.directory / "bad-input.bin"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("input SHA-256 mismatch", result.stderr)
        self.assertFalse(output.exists())

    def test_unsupported_target_illegal_width_and_non_2d_rejection(self):
        unsupported = self.directory / "unsupported.tsv"
        write_plan(
            unsupported,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q5_0")],
            nominal_type="q6_K",
        )
        result, _ = self.run_converter(
            unsupported, self.directory / "unsupported.bin"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported target type q5_0", result.stderr)

        illegal_input = self.directory / "illegal-width-f16.bin"
        illegal_quant = self.directory / "illegal-width-f32.bin"
        write_model(illegal_input, [("joint.pred.weight", [640, 1], 1, 1)], ftype=1)
        write_model(illegal_quant, [("joint.pred.weight", [640, 1], 0, 1)], ftype=0)
        self.source = illegal_input
        self.quant_source = illegal_quant
        width_plan = self.directory / "illegal-width.tsv"
        write_plan(
            width_plan,
            self.source,
            self.quant_source,
            [("joint.pred.weight", "q6_K")],
            nominal_type="q6_K",
        )
        result, _ = self.run_converter(
            width_plan, self.directory / "illegal-width-out.bin"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ne[0]=640 is not divisible by q6_K block size 256", result.stderr)

        non_2d_input = self.directory / "non-2d-f16.bin"
        non_2d_quant = self.directory / "non-2d-f32.bin"
        write_model(non_2d_input, [("encoder.pre_encode.out.weight", [256], 1, 1)], ftype=1)
        write_model(non_2d_quant, [("encoder.pre_encode.out.weight", [256], 0, 1)], ftype=0)
        self.source = non_2d_input
        self.quant_source = non_2d_quant
        non_2d_plan = self.directory / "non-2d.tsv"
        write_plan(
            non_2d_plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q6_K")],
            nominal_type="q6_K",
        )
        result, _ = self.run_converter(
            non_2d_plan, self.directory / "non-2d-out.bin"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "selected tensor encoder.pre_encode.out.weight is not 2-D",
            result.stderr,
        )

    def test_duplicate_source_and_existing_output_rejection(self):
        duplicate_source = self.directory / "duplicate-source.bin"
        duplicate_quant = self.directory / "duplicate-quant.bin"
        write_model(
            duplicate_source,
            [("joint.enc.weight", [32, 1], 1, 1), ("joint.enc.weight", [32, 1], 1, 2)],
            ftype=1,
        )
        write_model(
            duplicate_quant,
            [("joint.enc.weight", [32, 1], 0, 1), ("joint.enc.weight", [32, 1], 0, 2)],
            ftype=0,
        )
        self.source = duplicate_source
        self.quant_source = duplicate_quant
        plan = self.directory / "duplicate-source.tsv"
        write_plan(plan, self.source, self.quant_source, [("joint.enc.weight", "q8_0")])
        result, output = self.run_converter(
            plan, self.directory / "duplicate-source-out.bin"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate input tensor joint.enc.weight", result.stderr)
        self.assertFalse(output.exists())

        self.source = self.directory / "source-f16.bin"
        self.quant_source = self.directory / "source-f32.bin"
        existing_plan = self.directory / "existing.tsv"
        write_plan(
            existing_plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q8_0")],
        )
        existing_output = self.directory / "existing.bin"
        existing_output.write_bytes(b"sentinel")
        result, _ = self.run_converter(existing_plan, existing_output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output already exists", result.stderr)
        self.assertEqual(existing_output.read_bytes(), b"sentinel")

    def test_mixed_v1_allowlist_parity_and_forbidden_selection(self):
        allowed_source = self.directory / "allowed-f16.bin"
        allowed_quant = self.directory / "allowed-f32.bin"
        write_model(
            allowed_source,
            [
                (name, [256, 1], 1, index)
                for index, name in enumerate(MIXED_V1_ALLOWED_NAMES)
            ],
            ftype=1,
        )
        write_model(
            allowed_quant,
            [
                (name, [256, 1], 0, index + 100)
                for index, name in enumerate(MIXED_V1_ALLOWED_NAMES)
            ],
            ftype=0,
        )
        self.source = allowed_source
        self.quant_source = allowed_quant
        allowed_plan = self.directory / "allowed.tsv"
        write_plan(
            allowed_plan,
            allowed_source,
            allowed_quant,
            [(name, "q8_0") for name in MIXED_V1_ALLOWED_NAMES],
        )
        accepted, allowed_output = self.run_converter(
            allowed_plan,
            self.directory / "allowed.bin",
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(
            [record["type_id"] for record in parse_model(allowed_output)[1]],
            [8] * len(MIXED_V1_ALLOWED_NAMES),
        )

        forbidden_name = "encoder.layers.0.self_attn.pos_bias_u"
        forbidden_source = self.directory / "forbidden-f16.bin"
        forbidden_quant = self.directory / "forbidden-f32.bin"
        write_model(
            forbidden_source,
            [(forbidden_name, [256, 1], 1, 1)],
            ftype=1,
        )
        write_model(
            forbidden_quant,
            [(forbidden_name, [256, 1], 0, 1)],
            ftype=0,
        )
        self.source = forbidden_source
        self.quant_source = forbidden_quant
        forbidden_plan = self.directory / "forbidden.tsv"
        write_plan(
            forbidden_plan,
            forbidden_source,
            forbidden_quant,
            [(forbidden_name, "q8_0")],
        )
        rejected, forbidden_output = self.run_converter(
            forbidden_plan,
            self.directory / "forbidden.bin",
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("outside the mixed-v1 loader allowlist", rejected.stderr)
        self.assertFalse(forbidden_output.exists())

    def test_long_tensor_names_are_rejected_before_conversion(self):
        long_name = "x" * 64
        long_source = self.directory / "long-name-f16.bin"
        long_quant = self.directory / "long-name-f32.bin"
        write_model(long_source, [(long_name, [32, 1], 1, 1)], ftype=1)
        write_model(long_quant, [(long_name, [32, 1], 0, 1)], ftype=0)
        self.source = long_source
        self.quant_source = long_quant
        plan = self.directory / "long-name.tsv"
        write_plan(plan, long_source, long_quant, [], nominal_type="f16")
        rejected, output = self.run_converter(
            plan,
            self.directory / "long-name-output.bin",
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("invalid input tensor header", rejected.stderr)
        self.assertFalse(output.exists())

    def test_publication_alias_rejection_and_matching_output_resume(self):
        plan = self.directory / "publication.tsv"
        write_plan(
            plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q8_0")],
        )

        real_parent = self.directory / "real-parent"
        real_parent.mkdir()
        alias_parent = self.directory / "alias-parent"
        alias_parent.symlink_to(real_parent, target_is_directory=True)
        aliased_output = real_parent / "same.bin"
        aliased_report = alias_parent / "same.bin"
        rejected, _ = self.run_converter(
            plan,
            aliased_output,
            aliased_report,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("report path must differ", rejected.stderr)
        self.assertFalse(aliased_output.exists())

        resumable_output = self.directory / "resumable.bin"
        first, _ = self.run_converter(plan, resumable_output)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_hash = sha256_file(resumable_output)
        resumed_report = self.directory / "resumable.report.tsv"
        resumed, _ = self.run_converter(
            plan,
            resumable_output,
            resumed_report,
        )
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(sha256_file(resumable_output), first_hash)
        self.assertIn(
            f"# output_sha256={first_hash}",
            resumed_report.read_text(encoding="utf-8"),
        )

    def test_named_plan_generator_emits_dual_pins_and_exact_resolved_names(self):
        ffn_records = []
        for feed_forward in (1, 2):
            for linear, dims in ((1, [1024, 4096]), (2, [4096, 1024])):
                ffn_records.append(
                    (
                        f"encoder.layers.0.feed_forward{feed_forward}.linear{linear}.weight",
                        dims,
                        1,
                        feed_forward * 10 + linear,
                    )
                )
        ffn_records.append(("other.weight", [32, 1], 0, 99))
        generator_source = self.directory / "generator-f16.bin"
        generator_quant = self.directory / "generator-f32.bin"
        write_model(generator_source, ffn_records, audio_layers=1, ftype=1)
        write_model(
            generator_quant,
            [(name, dims, 0, seed) for name, dims, _, seed in ffn_records],
            audio_layers=1,
            ftype=0,
        )

        all_q8_plan = self.directory / "all-q8.tsv"
        all_q8_inventory = self.directory / "all-q8.inventory.tsv"
        result = self.run_generator(
            generator_source,
            generator_quant,
            "all-q8",
            all_q8_plan,
            all_q8_inventory,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        all_q8 = all_q8_plan.read_text(encoding="utf-8")
        self.assertIn(f"# input_sha256={sha256_file(generator_source)}", all_q8)
        self.assertIn(
            f"# quant_source_sha256={sha256_file(generator_quant)}", all_q8
        )
        self.assertEqual(all_q8.count("\tq8_0\n"), 4)
        inventory_header = all_q8_inventory.read_text(encoding="utf-8").splitlines()[0]
        self.assertIn("input_type", inventory_header)
        self.assertIn("quant_source_type", inventory_header)

        ffn_plan = self.directory / "ffn-q6.tsv"
        ffn_inventory = self.directory / "ffn-q6.inventory.tsv"
        result = self.run_generator(
            generator_source,
            generator_quant,
            "encoder-ffn-q6",
            ffn_plan,
            ffn_inventory,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        resolved = [
            line
            for line in ffn_plan.read_text(encoding="utf-8").splitlines()
            if not line.startswith("#")
        ]
        self.assertEqual(
            resolved,
            [
                "encoder.layers.0.feed_forward1.linear1.weight\tq6_K",
                "encoder.layers.0.feed_forward1.linear2.weight\tq6_K",
                "encoder.layers.0.feed_forward2.linear1.weight\tq6_K",
                "encoder.layers.0.feed_forward2.linear2.weight\tq6_K",
            ],
        )

        mismatched = self.directory / "mismatched-f32.bin"
        write_model(
            mismatched,
            [(name, [256, 1] if index == 0 else dims, 0, seed)
             for index, (name, dims, _, seed) in enumerate(ffn_records)],
            audio_layers=1,
            ftype=0,
        )
        rejected = self.run_generator(
            generator_source,
            mismatched,
            "all-q8",
            self.directory / "rejected.tsv",
            self.directory / "rejected.inventory.tsv",
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("quant source tensor shape mismatch", rejected.stderr)


    def test_generator_rejects_ftype_preamble_and_selected_payload_mismatch(self):
        name = "encoder.pre_encode.out.weight"
        source = self.directory / "validated-f16.bin"
        quant = self.directory / "validated-f32.bin"
        write_model(source, [(name, [256, 1], 1, 7)], ftype=1)
        write_model(quant, [(name, [256, 1], 0, 7)], ftype=0)

        wrong_ftype = self.directory / "wrong-ftype.bin"
        write_model(wrong_ftype, [(name, [256, 1], 0, 7)], ftype=1)
        plan = self.directory / "wrong-ftype.tsv"
        inventory = self.directory / "wrong-ftype.inventory.tsv"
        rejected = self.run_generator(
            source,
            wrong_ftype,
            "all-q8",
            plan,
            inventory,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("quant source global ftype must be f32", rejected.stderr)
        self.assertFalse(plan.exists())
        self.assertFalse(inventory.exists())

        wrong_preamble = self.directory / "wrong-preamble.bin"
        write_model(wrong_preamble, [(name, [256, 1], 0, 7)], ftype=0)
        with wrong_preamble.open("r+b") as stream:
            stream.seek(72)
            stream.write(struct.pack("<f", 0.75))
        plan = self.directory / "wrong-preamble.tsv"
        inventory = self.directory / "wrong-preamble.inventory.tsv"
        rejected = self.run_generator(
            source,
            wrong_preamble,
            "all-q8",
            plan,
            inventory,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("quant source preamble does not match input", rejected.stderr)
        self.assertFalse(plan.exists())
        self.assertFalse(inventory.exists())

        wrong_payload = self.directory / "wrong-payload.bin"
        write_model(wrong_payload, [(name, [256, 1], 0, 8)], ftype=0)
        plan = self.directory / "wrong-payload.tsv"
        inventory = self.directory / "wrong-payload.inventory.tsv"
        rejected = self.run_generator(
            source,
            wrong_payload,
            "all-q8",
            plan,
            inventory,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not round exactly to input f16", rejected.stderr)
        self.assertFalse(plan.exists())
        self.assertFalse(inventory.exists())

    def test_generator_publishes_plan_inventory_as_one_failure_consistent_pair(self):
        name = "encoder.pre_encode.out.weight"
        source = self.directory / "pair-f16.bin"
        quant = self.directory / "pair-f32.bin"
        write_model(source, [(name, [256, 1], 1, 4)], ftype=1)
        write_model(quant, [(name, [256, 1], 0, 4)], ftype=0)

        existing_plan = self.directory / "existing-plan.tsv"
        existing_plan.write_text("sentinel", encoding="utf-8")
        inventory = self.directory / "must-not-exist.inventory.tsv"
        rejected = self.run_generator(
            source,
            quant,
            "all-q8",
            existing_plan,
            inventory,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(existing_plan.read_text(encoding="utf-8"), "sentinel")
        self.assertFalse(inventory.exists())

        aliased = self.directory / "same-output.tsv"
        rejected = self.run_generator(
            source,
            quant,
            "all-q8",
            aliased,
            aliased,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("plan and inventory paths must differ", rejected.stderr)
        self.assertFalse(aliased.exists())

    def test_generator_rejects_overlong_tensor_name(self):
        name = "x" * 64
        source = self.directory / "long-generator-f16.bin"
        quant = self.directory / "long-generator-f32.bin"
        write_model(source, [(name, [32, 1], 1, 1)], ftype=1)
        write_model(quant, [(name, [32, 1], 0, 1)], ftype=0)
        plan = self.directory / "long-generator.tsv"
        inventory = self.directory / "long-generator.inventory.tsv"
        rejected = self.run_generator(
            source,
            quant,
            "all-q8",
            plan,
            inventory,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("invalid tensor header", rejected.stderr)
        self.assertFalse(plan.exists())
        self.assertFalse(inventory.exists())

    def test_converter_rejects_noncanonical_and_out_of_range_layer_names(self):
        cases = (
            "encoder.layers.1.feed_forward1.linear1.weight",
            "encoder.layers.00.feed_forward1.linear1.weight",
            "decoder.prediction.dec_rnn.lstm.weight_ih_l2",
            "decoder.prediction.dec_rnn.lstm.weight_hh_l00",
        )
        for index, name in enumerate(cases):
            with self.subTest(name=name):
                source = self.directory / f"invalid-index-{index}-f16.bin"
                quant = self.directory / f"invalid-index-{index}-f32.bin"
                write_model(
                    source,
                    [(name, [256, 1], 1, 7)],
                    audio_layers=1,
                    pred_layers=2,
                    ftype=1,
                )
                write_model(
                    quant,
                    [(name, [256, 1], 0, 7)],
                    audio_layers=1,
                    pred_layers=2,
                    ftype=0,
                )
                plan = self.directory / f"invalid-index-{index}.tsv"
                output = self.directory / f"invalid-index-{index}.bin"
                write_plan(plan, source, quant, [(name, "q8_0")])
                self.source = source
                self.quant_source = quant

                rejected, _ = self.run_converter(plan, output)

                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    "outside the mixed-v1 loader allowlist", rejected.stderr
                )
                self.assertFalse(output.exists())

    def test_generator_rejects_noncanonical_and_out_of_range_layer_names(self):
        cases = (
            "encoder.layers.1.feed_forward1.linear1.weight",
            "encoder.layers.00.feed_forward1.linear1.weight",
            "decoder.prediction.dec_rnn.lstm.weight_ih_l2",
            "decoder.prediction.dec_rnn.lstm.weight_hh_l00",
        )
        for index, name in enumerate(cases):
            with self.subTest(name=name):
                source = self.directory / f"generator-index-{index}-f16.bin"
                quant = self.directory / f"generator-index-{index}-f32.bin"
                write_model(
                    source,
                    [(name, [256, 1], 1, 11)],
                    audio_layers=1,
                    pred_layers=2,
                    ftype=1,
                )
                write_model(
                    quant,
                    [(name, [256, 1], 0, 11)],
                    audio_layers=1,
                    pred_layers=2,
                    ftype=0,
                )
                plan = self.directory / f"generator-index-{index}.tsv"
                inventory = (
                    self.directory / f"generator-index-{index}.inventory.tsv"
                )

                rejected = self.run_generator(
                    source, quant, "all-q8", plan, inventory
                )

                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    "outside the mixed-v1 loader allowlist", rejected.stderr
                )
                self.assertFalse(plan.exists())
                self.assertFalse(inventory.exists())

    def test_existing_report_rejects_symlink_before_model_installation(self):
        plan = self.directory / "report-symlink-plan.tsv"
        output = self.directory / "report-symlink-model.bin"
        target_report = self.directory / "report-target.tsv"
        report_symlink = self.directory / "report-link.tsv"
        write_plan(
            plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q8_0")],
        )
        initial, _ = self.run_converter(plan, output, target_report)
        self.assertEqual(initial.returncode, 0, initial.stderr)
        output.unlink()
        report_symlink.symlink_to(target_report)

        rejected, _ = self.run_converter(plan, output, report_symlink)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("existing report is not a regular file", rejected.stderr)
        self.assertFalse(output.exists())

    def test_existing_report_rejects_device_and_oversize_without_model(self):
        plan = self.directory / "bounded-report-plan.tsv"
        write_plan(
            plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q8_0")],
        )

        device_output = self.directory / "device-report-model.bin"
        rejected, _ = self.run_converter(plan, device_output, Path("/dev/null"))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("existing report is not a regular file", rejected.stderr)
        self.assertFalse(device_output.exists())

        oversize_report = self.directory / "oversize-report.tsv"
        oversize_report.write_bytes(b"x" * 200_000)
        oversize_output = self.directory / "oversize-report-model.bin"
        rejected, _ = self.run_converter(
            plan, oversize_output, oversize_report
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(
            "existing report size does not match expected report",
            rejected.stderr,
        )
        self.assertFalse(oversize_output.exists())

    def test_converter_rolls_back_post_rename_directory_fsync_failures(self):
        plan = self.directory / "fsync-failure-plan.tsv"
        write_plan(
            plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q8_0")],
        )
        interposer = build_fsync_fault_library(self.directory)
        base_environment = os.environ.copy()
        inserted = str(interposer)
        if base_environment.get("DYLD_INSERT_LIBRARIES"):
            inserted += ":" + base_environment["DYLD_INSERT_LIBRARIES"]
        base_environment["DYLD_INSERT_LIBRARIES"] = inserted

        cases = (
            (1, "model-directory"),
            (2, "report-directory"),
        )
        for failure_call, label in cases:
            with self.subTest(label=label):
                environment = base_environment.copy()
                environment[
                    "VOICEOUR_TEST_FAIL_DIRECTORY_FSYNC_CALL"
                ] = str(failure_call)
                output = self.directory / f"{label}.bin"
                report = self.directory / f"{label}.report.tsv"

                rejected, _ = self.run_converter(
                    plan, output, report, env=environment
                )

                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    "cannot fsync destination directory", rejected.stderr
                )
                self.assertFalse(output.exists())
                self.assertFalse(report.exists())

    def test_report_sync_failure_never_deletes_preexisting_validated_model(self):
        plan = self.directory / "preexisting-fsync-plan.tsv"
        output = self.directory / "preexisting-fsync.bin"
        report = self.directory / "preexisting-fsync.report.tsv"
        write_plan(
            plan,
            self.source,
            self.quant_source,
            [("encoder.pre_encode.out.weight", "q8_0")],
        )
        initial, _ = self.run_converter(plan, output)
        self.assertEqual(initial.returncode, 0, initial.stderr)
        original_digest = sha256_file(output)

        interposer = build_fsync_fault_library(self.directory)
        environment = os.environ.copy()
        environment["DYLD_INSERT_LIBRARIES"] = str(interposer)
        environment["VOICEOUR_TEST_FAIL_DIRECTORY_FSYNC_CALL"] = "1"
        rejected, _ = self.run_converter(
            plan, output, report, env=environment
        )

        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(sha256_file(output), original_digest)
        self.assertFalse(report.exists())

    def test_generator_rolls_back_pair_on_either_directory_sync_failure(self):
        original_fsync_directory = GENERATOR_MODULE.fsync_directory
        for failed_output in ("inventory", "plan"):
            with self.subTest(failed_output=failed_output):
                inventory_directory = (
                    self.directory / f"{failed_output}-inventory"
                )
                plan_directory = self.directory / f"{failed_output}-plan"
                inventory_directory.mkdir()
                plan_directory.mkdir()
                inventory = inventory_directory / "inventory.tsv"
                plan = plan_directory / "plan.tsv"
                failed_directory = (
                    inventory_directory
                    if failed_output == "inventory"
                    else plan_directory
                ).resolve()

                def injected_fsync(directory):
                    if Path(directory) == failed_directory:
                        raise OSError("injected directory fsync failure")
                    original_fsync_directory(Path(directory))

                with mock.patch.object(
                    GENERATOR_MODULE,
                    "fsync_directory",
                    side_effect=injected_fsync,
                ):
                    with self.assertRaisesRegex(
                        OSError, "injected directory fsync failure"
                    ):
                        GENERATOR_MODULE.publish_pair(
                            inventory,
                            "inventory\n",
                            plan,
                            "plan\n",
                        )

                self.assertFalse(inventory.exists())
                self.assertFalse(plan.exists())

    def test_generator_rolls_back_link_when_temporary_unlink_fails(self):
        inventory = self.directory / "unlink-failure.inventory.tsv"
        plan = self.directory / "unlink-failure.plan.tsv"
        original_unlink = GENERATOR_MODULE.os.unlink
        failed_once = False

        def injected_unlink(path):
            nonlocal failed_once
            if not failed_once and ".tmp." in Path(path).name:
                failed_once = True
                raise OSError("injected temporary unlink failure")
            original_unlink(path)

        with mock.patch.object(
            GENERATOR_MODULE.os,
            "unlink",
            side_effect=injected_unlink,
        ):
            with self.assertRaisesRegex(
                OSError, "injected temporary unlink failure"
            ):
                GENERATOR_MODULE.publish_pair(
                    inventory,
                    "inventory\n",
                    plan,
                    "plan\n",
                )

        self.assertFalse(inventory.exists())
        self.assertFalse(plan.exists())

if __name__ == "__main__":
    unittest.main()
