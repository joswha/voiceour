#!/usr/bin/env python3
"""Stage 2 of glossary-conditioned-decoding, Wave 1: cached CPU training and replay.

Preregistration: research/prereg/glossary-conditioned-decoding-wave1.md, frozen at
commit 898262c. Every endpoint, input rule, split, model, threshold budget, and
hyper-parameter below is copied from that file; nothing here is tunable.

No audio is decoded here and no CoreML model is loaded. The only external process
this script starts is the prebuilt tail runner:

    <tail-runner> glossary-conditioning replay-states \
        --input <manifest.jsonl> --states <states.f32> \
        --index <index.jsonl> --output <rows.jsonl> \
        --model <model.bin> --vocabulary <repair.vocabulary.json>

Third-party imports: numpy for all arithmetic, plus the pinned bench metric module
(`bench/src/voiceour_bench/metrics.py`) for `uwer` and `contains_exact_term`, which own
the frozen definitions the primary endpoint and the general guard are stated in.

Run `--describe` for the frozen constants, the located decoder-embedding tensor, the
tokenizer self-check, and the full deviation list.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import math
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Sequence

import numpy as np

# ---------------------------------------------------------------------------
# Frozen constants (preregistration; none of these is a knob)
# ---------------------------------------------------------------------------

PREREG_FREEZE_COMMIT = "898262c"
METRICS_RUN = "glossary-conditioned-decoding/wave1/1"

SEED = 20260830
TEMPERATURE = 0.07
ETA_BUDGET: tuple[float, ...] = (0.05, 0.10, 0.20)
ADAPT_HALF_WINDOW = 4
UPDATES_PER_FOLD = 256
BATCH_SIZE = 8
DISTRACTORS_PER_POSITIVE = 7
LEARNING_RATE = 1e-4
ADAM_BETAS = (0.9, 0.999)
ADAM_EPS = 1e-8
WEIGHT_DECAY = 1e-4
GRAD_CLIP = 1.0
INIT_NOISE_STD = 0.001
STATE_WIDTH = 1024
TERM_DIM = 640
GLOSSARY_LIMIT = 100
TERM_ID_PREFIX = "Voiceour/Wave1/"
RANK_SALT = "20260830|"
UNREPRESENTABLE = ("C#", "C++", "io_uring")
EXPECTED_JARGON_ROWS = 456
EXPECTED_POSITIVES = 346
EXPECTED_NEGATIVES = 110
EXPECTED_CANONICALS = 173
EXPECTED_GENERAL_ROWS = 96
MEL_SUBSAMPLING = 8
MS_PER_MEL_FRAME = 10

BOOTSTRAP_B = 10_000
PERMUTATION_FLIPS = 100_000

BAR_MEANINGFUL = 262
BAR_STRONG = 279
BAR_KILL = 254
UWER_GENERAL_CEILING = 0.034225
RUNTIME_CEILING_S = 8 * 3600

# Layer norm / L2 normalisation epsilons. The preregistration fixes the algebra but not
# these guards; both are the boring defaults and are listed under Deviations.
LN_EPS = 1e-5
L2_EPS = 1e-12

# Immutable inputs pinned by the preregistration (§Immutable source inputs) and by
# `autoresearch.sh:51-86`, which owns the manifest pin keys.
PINNED = {
    "model_sha256": "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f",
    "model_bytes": 1_255_897_319,
    "general_corpus_sha256": "885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749",
    "jargon_corpus_sha256": "576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf",
    "jargon_terms_sha256": "2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5",
    "repair_vocabulary_sha256": "650dfc3fa02ebc7e2e8754066f0f9d4336d5113444154e1a27975139812fd1c8",
    "jargon_lattice_sha256": "64980e8027867e17798800d947c446a673da7d1e3f4440b13ed098efad48cd25",
    "general_lattice_sha256": "a82adf5b5884370af25a7f3ed5ef18496498c426d31f33a4d2152904b5cf6411",
    "coreml_encoder_digest": "adffa42216599bdb01611a6e06cb8f26448cb3a66078b8fbed66dbe8b6cb544d",
    "coreml_short_digest": "1d995f0ef5a92e14f92214b93af46126a78427513be7d6ea695cae421f6a16e6",
    "coreml_tiny_digest": "e77ac4a6fc6299868fce308b652b363a3fd98d7024a225b6920f691ff66add05",
    "coreml_max_s": "15.0",
    "coreml_short_max_s": "8.0",
    "coreml_tiny_max_s": "6.0",
}

# The declared prediction embedding (`parakeet-arch.h:177`), verified byte-for-byte.
EMBED_TENSOR_NAME = "decoder.prediction.embed.weight"
EMBED_EXPECTED = {
    "n_dims": 2,
    "ne": [640, 8193],
    "ggml_type": 1,  # GGML_TYPE_F16
    "payload_offset": 1_219_620_741,
    "payload_bytes": 10_487_040,
    "payload_sha256": "3173388aaf6b5b4ae292d8777940bb8fb5c7c02e30adf708b9dde4d909c2000f",
}

GGML_FILE_MAGIC = 0x67676D6C
# (block elements, bytes per block) for every ggml type this container can hold.
GGML_TYPE_LAYOUT = {0: (1, 4), 1: (1, 2), 2: (32, 18), 3: (32, 20), 6: (32, 22), 7: (32, 24), 8: (32, 34)}
GGML_TYPE_NAMES = {0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q5_1", 8: "Q8_0"}

SPM_SPACE = "\u2581"
SPM_SPACE_BYTES = SPM_SPACE.encode("utf-8")
CONTROL_PIECES = frozenset({"<unk>", "<s>", "</s>", "[BLANK]"})
# `std::isspace` in the C locale, which is what sentencepiece_normalize applies.
C_SPACE_BYTES = frozenset(b" \t\n\v\f\r")

# Acoustic classes the preregistration names for unsupported activations. Presence is
# reported, never synthesised.
NAMED_ACTIVATION_CLASSES = ("IAM", "Redis", "runc", "Swift", "CALayer", "C++", "kqueue", "QUIC", "CUDA")

# A replaced span damages a code, identifier, number, or operator span when its residue
# still carries one of these after the inserted canonical's own characters are removed.
SYNTAX_CHARS = re.compile(r"[0-9_+#=<>/\\{}()\[\]@$%&*|~^]")

DEVIATIONS: tuple[str, ...] = (
    "Scoring domain, decided before the run and consistent with the frozen bars. The "
    "preregistration's bars (>=262 / >=279 / <254) are declared relative to the shipped strict "
    ".95 repair's 246, so M0 must be the SHIPPED path, not bare-ASR cleanup. Stage 1 was "
    "therefore dumped with `--vocabulary`, M0 is the index's `baseline_final_text` exactly as "
    "dumped, every replay invocation passes "
    "`--vocabulary bench/autoresearch/repair.vocabulary.json`, and the primary endpoint is "
    "scored on the post-renderer `final_text`. The renderer's frame->character map is a "
    "raw-domain object (replay `tokens` carry `start_ms`), so each token span is carried from "
    "`raw_text` into `final_text` through one deterministic difflib alignment per row before "
    "the whole-word span is chosen; on rows where cleanup and repair changed nothing the two "
    "texts are identical and the alignment is the identity. The same endpoint recomputed in "
    "the raw domain is reported as `recall_hits_raw_domain` with "
    "`replay_domain_disagreements` as the cross-check, and "
    "`baseline_domain_disagreements` reports raw-vs-final canonical containment disagreement "
    "on the Stage 1 index itself.",
    "General96 final texts come from the cached harness results file (`--general-results`, "
    "default .build/autoresearch/general.results.jsonl), keyed by row id, because the "
    "structural empty-glossary branch is an exact identity and that file is the frozen "
    "cleanup/repair output for those rows. Its sha256 is pinned in the manifest, all four "
    "cached passes are required to agree byte-for-byte, and `general_lattice_raw_agreement` "
    "reports how many of the 96 cached lattice raw transcripts match that run (the lattice is "
    "a different instrument run and disagrees on some rows).",
    "Layer-norm epsilon 1e-5 and L2-normalisation epsilon 1e-12; the preregistration fixes "
    "`LN` and `norm` but not their guards.",
    "`norm(...)` is L2 normalisation over the 1024 output channels, and `a(x) * g(t)` inside "
    "`tanh` is the elementwise product (the frame score is the dot product, but the state "
    "delta must be a 1024-vector).",
    "PCG64(20260830) draw order is Wa1, Wa2, Wg1, Wg2 for model A then the same four for "
    "model B; biases are zeros and consume no randomness.",
    "Batch composition is a deterministic cycle over the fold's fit examples sorted by row id, "
    "batches of 8, wrapping for exactly 256 updates. No shuffling, so the seed is consumed "
    "entirely by initialisation.",
    "The seven snapshot distractors are the seven highest hash-ranked non-target terms of the "
    "row's own 100-term active glossary; a negative row's eight candidates are the eight "
    "highest hash-ranked terms of its glossary. The preregistration fixes the counts, not the "
    "choice rule.",
    "`low bit of sha256(row_id)` is the low bit of the digest read as a big-endian integer "
    "(equivalently `digest[-1] & 1`).",
    "The three cached fit replays per fold adapt every row at its argmax candidate and `tau` is "
    "applied afterwards as the accept/abstain filter, an abstaining row falling back to its "
    "Stage 1 baseline bytes. That is what makes three replays per fold sufficient, as the "
    "preregistration requires. The I1 identity control instead gates the pack writer on "
    "`probability >= 2.0`, so the block is evaluated and its pack is byte-identical to Stage 1.",
    "Localization label spans are resolved against the cached jargon456 lattice in this fixed "
    "order: (1) earliest exact canonical occurrence in the lattice transcript; (2) the "
    "contrastive `emitted_start/emitted_end` when the contrastive row's `raw_transcript` equals "
    "the lattice transcript; (3) the unique occurrence of `emitted_surface` in the lattice "
    "transcript; (4) a deterministic difflib character alignment of the contrastive raw "
    "transcript onto the lattice transcript. A row that still fails to map is excluded from the "
    "fit set and counted in `unmappable_localization_rows` (it is still scored out of fold); "
    "`--strict-span-map` turns that exclusion into a hard stop.",
    "The renderer's frame->character map for the adapted decode is taken from the replay row's "
    "`tokens` array (`start_ms / 10 / 8` is the encoder frame); if a replay row carries no "
    "usable tokens the Stage 1 `baseline-rows.jsonl` tokens are used, and failing that the "
    "cached lattice step spans are aligned onto the replay text with difflib. The source is "
    "recorded per row as `token_map_source`; only the first is exact.",
    "`the minimal contiguous token span overlapping the frame window` is operationalised as "
    "the minimal contiguous run of WHOLE SentencePiece words anchored at the localization "
    "frame: the word whose token frame range contains that frame, extended forward over "
    "following words whose first token starts at or before the window's upper edge. Three "
    "reasons. (a) Exact rendering of a canonical cannot land inside a word; replacing the raw "
    "token union of a nine-frame (720 ms) window turns `Please run Quebecal against` into "
    "`Pkubectlal against`, which no bounded renderer can be meant to emit. (b) `minimal` is "
    "read as smallest, and the smallest span that can carry an exact canonical is one word. "
    "(c) The localization frame is by definition the EARLIEST frame at the candidate's maximum "
    "score, so the term's acoustics begin there and the span may only grow forward; never "
    "backward over already-decoded words. A multi-word emitted surface whose later words start "
    "beyond the window is therefore under-covered rather than silently over-covered, and the "
    "resulting change is counted as incorrect. If no word contains the frame the nearest word "
    "by frame midpoint is used, earliest index on tie, and the row records "
    "`render_mode = nearest`. Leading and trailing whitespace stays outside the replacement.",
    "A changed span is correct when the accepted canonical equals the annotated canonical, the "
    "rendered text contains that canonical exactly, and the replaced character span is exactly "
    "the `target_span`: the annotated label character span carried into the replay text and "
    "snapped through the same whole-word rule. Equality, not overlap, is required, because "
    "`changed_span_precision = 1.0` is a hard gate on the change being the RIGHT change and a "
    "+/-4 frame window is wide enough to reach neighbouring words. The looser frame-range test "
    "is still recorded per row as `changed_span_frame_overlap` for diagnosis.",
    "The localization label's CHARACTER span is resolved against the cached jargon456 lattice "
    "as the preregistration fixes, but its FRAME is taken from Stage 1's own "
    "`baseline-rows.jsonl` token timings when those exist (`label_source` then ends in "
    "`+stage1_frame`), falling back to the cached lattice's step frames only when they do not. "
    "The cached lattice is a different instrument run, so its step frame axis is offset from "
    "the dumped states' axis by a couple of frames on some rows; training a +/-4-frame "
    "localization against the wrong axis would bake that offset into the label.",
    "`adapter_pair_rank_accuracy` compares the out-of-fold row score of the annotated canonical "
    "on the positive row against its out-of-fold row score on the paired negative counterpart "
    "row. Pairs whose counterpart lives in general96 have no cached encoder state, and are "
    "excluded and counted, never synthesised.",
    "`candidate_id_accuracy` counts a row correct only when the accepted (post-tau) id equals "
    "the annotated canonical; abstention counts as incorrect.",
    "`unsupported_activations` counts a taught surface that this run's accepted change "
    "introduced: a surface already present in the Stage 1 baseline of a negative row is not an "
    "activation by this adapter. The harness-shaped `jargon_false_terms` is reported "
    "separately with the unconditional `score_v5.py:46-72` definition.",
    "`critical_syntax_corruption` counts an accepted change whose replaced span, after removing "
    "the inserted canonical's own characters, still contains a digit, `_`, or an "
    "operator/bracket character, or which swallows a different taught canonical.",
    "Adapted state packs are deleted after their replay unless `--keep-packs` is passed; the "
    "replay `rows.jsonl` files are always retained under `<output>/replay/`.",
)


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------


def fail(message: str) -> None:
    print(f"glossary_conditioned_replay.py: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def log(message: str) -> None:
    print(f"[gcd] {message}", flush=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_jsonl(path: Path) -> list[dict]:
    out: list[dict] = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as error:
                fail(f"{path}:{number} is not JSON: {error}")
    return out


def write_jsonl(path: Path, records: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n")


def refuse_overwrite(path: Path) -> None:
    if path.exists():
        fail(f"{path} already exists; the preregistration forbids overwriting a run artifact")


def finite(value: float) -> float | int:
    """metrics.jsonl carries JSON numbers only; -1 marks an undefined measurement."""

    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return -1
    if isinstance(value, int):
        return value
    if not math.isfinite(float(value)):
        return -1
    return float(value)


def term_id(canonical: str) -> str:
    return hashlib.sha256((TERM_ID_PREFIX + canonical).encode("utf-8")).hexdigest()[:16]


def rank_key(row_id: str, tid: str) -> str:
    return hashlib.sha256((RANK_SALT + row_id + "|" + tid).encode("utf-8")).hexdigest()


def row_ordinal(row_id: str) -> int:
    match = re.match(r"^jg_(\d+)_", row_id)
    if not match:
        fail(f"row id {row_id!r} has no numeric ordinal")
        raise AssertionError
    return int(match.group(1))


def digest_low_bit(row_id: str) -> int:
    return hashlib.sha256(row_id.encode("utf-8")).digest()[-1] & 1


def contains_exact(text: str | None, canonical: str | None) -> bool:
    """Mirror of `bench/src/voiceour_bench/metrics.py:382-389`."""

    if not text or not canonical:
        return False
    prefix = r"(?<!\w)" if canonical[0].isalnum() or canonical[0] == "_" else ""
    suffix = r"(?!\w)" if canonical[-1].isalnum() or canonical[-1] == "_" else ""
    return re.search(f"{prefix}{re.escape(canonical)}{suffix}", text, re.UNICODE) is not None


def find_exact(text: str, canonical: str) -> tuple[int, int] | None:
    if not text or not canonical:
        return None
    prefix = r"(?<!\w)" if canonical[0].isalnum() or canonical[0] == "_" else ""
    suffix = r"(?!\w)" if canonical[-1].isalnum() or canonical[-1] == "_" else ""
    match = re.search(f"{prefix}{re.escape(canonical)}{suffix}", text, re.UNICODE)
    return (match.start(), match.end()) if match else None


# ---------------------------------------------------------------------------
# GGML container reader (legacy magic 0x67676d6c, not GGUF)
# ---------------------------------------------------------------------------

HPARAM_ORDER = (
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


@dataclass(frozen=True)
class TensorRecord:
    name: str
    n_dims: int
    ggml_type: int
    ne: tuple[int, ...]
    payload_offset: int
    payload_bytes: int


@dataclass
class GGMLModel:
    path: Path
    hparams: dict[str, int]
    tdt_durations: tuple[int, ...]
    id_to_token: list[str]
    records: dict[str, TensorRecord]


def read_ggml(path: Path) -> GGMLModel:
    """Read the pinned container's header, vocab, and tensor directory.

    Layout is the checked record layout at `Vendor/parakeet/src/parakeet.cpp:2193-2338`
    (magic, 15 int32 hparams, mel filters, window, TDT durations, vocab) followed by the
    tensor records of `parakeet.cpp:963-1071`: n_dims/i32, name_length/i32, type_id/i32,
    ne[n_dims]/i32, name bytes, payload. Nothing is inferred and no ggml context exists.
    """

    size = path.stat().st_size
    with path.open("rb") as handle:

        def i32() -> int:
            raw = handle.read(4)
            if len(raw) != 4:
                fail(f"{path}: truncated header")
            return int(struct.unpack("<i", raw)[0])

        def u32() -> int:
            raw = handle.read(4)
            if len(raw) != 4:
                fail(f"{path}: truncated header")
            return int(struct.unpack("<I", raw)[0])

        magic = u32()
        if magic != GGML_FILE_MAGIC:
            fail(f"{path}: bad magic 0x{magic:08x}, expected 0x{GGML_FILE_MAGIC:08x}")

        hparams = {name: i32() for name in HPARAM_ORDER}

        n_mel = i32()
        n_fb = i32()
        handle.seek(n_mel * n_fb * 4, os.SEEK_CUR)

        n_window = i32()
        handle.seek(n_window * 4, os.SEEK_CUR)

        durations = struct.unpack(
            f"<{hparams['n_tdt_durations']}I", handle.read(4 * hparams["n_tdt_durations"])
        )

        n_vocab = i32()
        if n_vocab != hparams["n_vocab"]:
            fail(f"{path}: vocab section declares {n_vocab}, the header declares {hparams['n_vocab']}")
        id_to_token: list[str] = []
        for position in range(n_vocab):
            length = u32()
            raw = handle.read(length) if length else b""
            if len(raw) != length:
                fail(f"{path}: truncated vocab entry {position}")
            id_to_token.append(raw.decode("utf-8", errors="surrogateescape"))

        records: dict[str, TensorRecord] = {}
        while True:
            header = handle.read(12)
            if len(header) < 12:
                break
            n_dims, name_length, type_id = struct.unpack("<iii", header)
            if not 0 <= n_dims <= 4 or not 0 < name_length < 64:
                fail(f"{path}: invalid tensor header at byte {handle.tell() - 12}")
            ne = struct.unpack(f"<{n_dims}i", handle.read(4 * n_dims)) if n_dims else ()
            name = handle.read(name_length).decode("utf-8")
            layout = GGML_TYPE_LAYOUT.get(type_id)
            if layout is None:
                fail(f"{path}: unsupported tensor type {type_id} for {name!r}")
                raise AssertionError
            block_elements, block_bytes = layout
            elements = 1
            for dim in ne:
                if dim <= 0:
                    fail(f"{path}: invalid dimension in {name!r}")
                elements *= dim
            if elements % block_elements:
                fail(f"{path}: {name!r} has an invalid block shape for type {type_id}")
            payload_bytes = elements // block_elements * block_bytes
            offset = handle.tell()
            if offset + payload_bytes > size:
                fail(f"{path}: {name!r} payload exceeds model bounds")
            if name in records:
                fail(f"{path}: duplicate tensor record {name!r}")
            records[name] = TensorRecord(name, n_dims, type_id, tuple(ne), offset, payload_bytes)
            handle.seek(payload_bytes, os.SEEK_CUR)

    return GGMLModel(path, hparams, tuple(int(value) for value in durations), id_to_token, records)


def read_embedding(model: GGMLModel) -> np.ndarray:
    """Return the decoder prediction embedding as F32 `[8193, 640]`, one row per token id."""

    record = model.records.get(EMBED_TENSOR_NAME)
    if record is None:
        fail(f"{model.path}: {EMBED_TENSOR_NAME} is absent")
        raise AssertionError
    observed = {
        "n_dims": record.n_dims,
        "ne": list(record.ne),
        "ggml_type": record.ggml_type,
        "payload_offset": record.payload_offset,
        "payload_bytes": record.payload_bytes,
    }
    for key, expected in EMBED_EXPECTED.items():
        if key == "payload_sha256":
            continue
        if observed[key] != expected:
            fail(f"{EMBED_TENSOR_NAME}: {key} is {observed[key]!r}, the preregistration pins {expected!r}")
    if record.ne[0] != model.hparams["n_pred_dim"]:
        fail(
            f"{EMBED_TENSOR_NAME}: row width {record.ne[0]} disagrees with the hparam "
            f"n_pred_dim={model.hparams['n_pred_dim']}"
        )
    if record.ne[1] != model.hparams["n_vocab"] + 1:
        fail(
            f"{EMBED_TENSOR_NAME}: {record.ne[1]} rows, the hparams expect n_vocab+1="
            f"{model.hparams['n_vocab'] + 1} (the transducer blank shares the table)"
        )
    with model.path.open("rb") as handle:
        handle.seek(record.payload_offset)
        payload = handle.read(record.payload_bytes)
    if len(payload) != record.payload_bytes:
        fail(f"{EMBED_TENSOR_NAME}: truncated payload")
    observed_sha = hashlib.sha256(payload).hexdigest()
    if observed_sha != EMBED_EXPECTED["payload_sha256"]:
        fail(
            f"{EMBED_TENSOR_NAME}: payload sha256 {observed_sha} != pinned "
            f"{EMBED_EXPECTED['payload_sha256']}; the pilot stops"
        )
    table = np.frombuffer(payload, dtype="<f2").astype(np.float32, copy=True)
    return table.reshape(record.ne[1], record.ne[0])


# ---------------------------------------------------------------------------
# tokenizer: sentencepiece_normalize + greedy longest match
# (Vendor/parakeet/src/parakeet.cpp:608-635, 5223-5253)
# ---------------------------------------------------------------------------


class Tokenizer:
    def __init__(self, id_to_token: Sequence[str]) -> None:
        self.id_to_token = list(id_to_token)
        self.blank_id = len(self.id_to_token)
        self.byte_to_id: dict[bytes, int] = {}
        for index, token in enumerate(self.id_to_token):
            # `vocab.token_to_id[word] = i` in file order: a later duplicate wins.
            self.byte_to_id[token.encode("utf-8", errors="surrogateescape")] = index
        self.control_bytes = {piece.encode("utf-8") for piece in CONTROL_PIECES}
        self.max_token_bytes = max(len(key) for key in self.byte_to_id)
        self.unk_id = self.byte_to_id.get(b"<unk>", 0)

    def piece(self, token_id: int) -> str:
        if token_id == self.blank_id:
            return "[BLANK]"
        if 0 <= token_id < len(self.id_to_token):
            return self.id_to_token[token_id]
        fail(f"token id {token_id} is outside the pinned vocabulary")
        raise AssertionError

    @staticmethod
    def normalize(text: str) -> bytes:
        out = bytearray(SPM_SPACE_BYTES)  # SentencePiece dummy prefix
        for byte in text.encode("utf-8"):
            if byte in C_SPACE_BYTES:
                out += SPM_SPACE_BYTES
            else:
                out.append(byte)
        return bytes(out)

    @staticmethod
    def _codepoint_len(byte: int) -> int:
        if byte & 0x80 == 0x00:
            return 1
        if byte & 0xE0 == 0xC0:
            return 2
        if byte & 0xF0 == 0xE0:
            return 3
        if byte & 0xF8 == 0xF0:
            return 4
        return 1

    def tokenize(self, text: str) -> list[int]:
        normalized = self.normalize(text)
        tokens: list[int] = []
        index = 0
        total = len(normalized)
        while index < total:
            longest = min(self.max_token_bytes, total - index)
            found = False
            for length in range(longest, 0, -1):
                candidate = normalized[index : index + length]
                token = self.byte_to_id.get(candidate)
                if token is not None and candidate not in self.control_bytes:
                    tokens.append(token)
                    index += length
                    found = True
                    break
            if not found:
                tokens.append(self.unk_id)
                index += self._codepoint_len(normalized[index])
        return tokens

    def is_control(self, token_id: int) -> bool:
        return self.piece(token_id) in CONTROL_PIECES

    @staticmethod
    def piece_to_text(piece: str, is_first_piece: bool) -> str:
        if piece in CONTROL_PIECES:
            return ""
        out: list[str] = []
        for char in piece:
            if char == SPM_SPACE:
                if not is_first_piece or out:
                    out.append(" ")
            else:
                out.append(char)
        return "".join(out)

    def detokenize(self, token_ids: Sequence[int]) -> str:
        text = ""
        for token_id in token_ids:
            text += self.piece_to_text(self.piece(token_id), text == "")
        return text

    def representable(self, surface: str) -> bool:
        return self.unk_id not in self.tokenize(surface)


def tokenizer_lattice_check(tokenizer: Tokenizer, lattices: Sequence[dict]) -> dict:
    """Every (id, piece) the cached lattices recorded must round-trip; 100% required."""

    checked = 0
    mismatches: list[dict] = []
    render_mismatches: list[str] = []
    round_trip = 0
    round_trip_failures: list[str] = []
    for row in lattices:
        for step in row["steps"]:
            token = step["chosen_token"]
            checked += 1
            if tokenizer.piece(int(token["id"])) != token["piece"]:
                mismatches.append({"id": int(token["id"]), "lattice": token["piece"]})
        text, _ = render_lattice_text(row["steps"])
        if text != row["transcript"]:
            render_mismatches.append(row["id"])
        # Greedy longest match must also reproduce the transcript it emitted.
        round_trip += 1
        if tokenizer.detokenize(tokenizer.tokenize(text)) != text:
            round_trip_failures.append(row["id"])
    return {
        "checked_tokens": checked,
        "mismatches": len(mismatches),
        "examples": mismatches[:8],
        "render_mismatch_rows": render_mismatches,
        "round_trip_rows": round_trip,
        "round_trip_failures": round_trip_failures,
        "rate": 1.0 if checked and not mismatches else 0.0,
    }


# ---------------------------------------------------------------------------
# term vectors
# ---------------------------------------------------------------------------


def term_vector(tokenizer: Tokenizer, embedding: np.ndarray, surface: str) -> np.ndarray | None:
    """F32 mean of the surface's non-control embedding rows, L2-normalised, 640 -> 1024.

    Returns None for an unrepresentable surface (any `<unk>`), which is always null.
    """

    token_ids = tokenizer.tokenize(surface)
    if tokenizer.unk_id in token_ids:
        return None
    rows = [tid for tid in token_ids if not tokenizer.is_control(tid)]
    if not rows:
        return None
    mean = embedding[rows, :].mean(axis=0, dtype=np.float32)
    norm = float(np.sqrt(float(mean @ mean) + L2_EPS))
    padded = np.zeros(STATE_WIDTH, dtype=np.float32)
    padded[:TERM_DIM] = (mean / np.float32(norm)).astype(np.float32)
    return padded


# ---------------------------------------------------------------------------
# cached lattice: nonblank step spans over the rendered transcript
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class StepSpan:
    start: int
    end: int
    frame: int
    piece: str


def render_lattice_text(steps: Sequence[dict]) -> tuple[str, list[StepSpan]]:
    """Rebuild the raw transcript and each nonblank step's character span.

    Mirrors the tail's own assembly (`parakeet.cpp:6293-6305`): `is_first` is true only
    for the first emitted piece of the segment.
    """

    text = ""
    spans: list[StepSpan] = []
    for step in steps:
        if step.get("is_blank"):
            continue
        piece = step["chosen_token"]["piece"]
        chunk = Tokenizer.piece_to_text(piece, text == "")
        spans.append(StepSpan(len(text), len(text) + len(chunk), int(step["frame_index"]), piece))
        text += chunk
    return text, spans


def align_span(source: str, target: str, start: int, end: int) -> tuple[int, int] | None:
    """Map `[start, end)` from `source` onto `target` with a deterministic char alignment."""

    matcher = difflib.SequenceMatcher(a=source, b=target, autojunk=False)
    low: int | None = None
    high: int | None = None
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if i2 <= start or i1 >= end:
            continue
        if tag == "equal":
            begin = j1 + (max(i1, start) - i1)
            stop = j1 + (min(i2, end) - i1)
        else:
            begin, stop = j1, j2
        if stop < begin:
            continue
        low = begin if low is None else min(low, begin)
        high = stop if high is None else max(high, stop)
    if low is None or high is None or high <= low:
        return None
    return (low, high)


def earliest_intersecting_frame(spans: Sequence[StepSpan], start: int, end: int) -> int | None:
    for span in spans:
        if span.end > span.start and start < span.end and span.start < end:
            return span.frame
    return None


# ---------------------------------------------------------------------------
# corpus assembly
# ---------------------------------------------------------------------------


@dataclass
class Row:
    row_id: str
    ordinal: int
    is_positive: bool
    canonical: str | None
    domain: str
    reference: str
    audio_path: str
    audio_sha256: str
    audio_s: float
    frame_count: int
    byte_offset: int
    byte_count: int
    state_sha256: str | None
    baseline_raw_text: str
    baseline_final_text: str
    transcript_sha256: str
    lattice_transcript: str
    lattice_spans: list[StepSpan]
    baseline_tokens: list[dict] | None = None
    glossary: list[str] = field(default_factory=list)
    ranked_glossary: list[str] = field(default_factory=list)
    target_term_id: str | None = None
    label_span: tuple[int, int] | None = None
    label_frame: int | None = None
    label_source: str = "none"
    fold: str = ""  # the fold this row is TESTED in
    contrastive: dict | None = None


def build_rows(
    manifest: Sequence[dict],
    terms: dict,
    index: Sequence[dict],
    jargon_lattice: dict[str, dict],
    baseline_rows: dict[str, dict],
) -> list[Row]:
    by_id = {record["id"]: record for record in index}
    if len(by_id) != len(index):
        fail("state-dump/index.jsonl contains duplicate ids")
    rows: list[Row] = []
    for record in manifest:
        row_id = record["id"]
        entry = by_id.get(row_id)
        if entry is None:
            fail(f"{row_id} is missing from the state index")
            raise AssertionError
        info = terms.get(row_id)
        if info is None:
            fail(f"{row_id} is absent from the terms file")
            raise AssertionError
        if int(entry["width"]) != STATE_WIDTH:
            fail(f"{row_id}: index width {entry['width']} != {STATE_WIDTH}")
        frame_count = int(entry["frame_count"])
        if int(entry["byte_count"]) != frame_count * STATE_WIDTH * 4:
            fail(f"{row_id}: byte_count {entry['byte_count']} disagrees with frame_count {frame_count}")
        # Stage 1 records the mel length the tail's external-state guard checks against
        # (`parakeet.cpp:6236-6254`). Trust it, never the manifest's rounded `audio_s`: the
        # decoder's own mel is shorter than `audio_s * 16000 / 160 + 1` suggests.
        mel_frames = entry.get("mel_frame_count")
        if mel_frames is not None:
            expected_frames = -(-int(mel_frames) // MEL_SUBSAMPLING)
            if frame_count != expected_frames:
                fail(
                    f"{row_id}: index frame_count {frame_count} is not ceil({mel_frames}/"
                    f"{MEL_SUBSAMPLING}) = {expected_frames}"
                )
        if entry.get("audio_sha256") and entry["audio_sha256"] != record["audio_sha256"]:
            fail(f"{row_id}: index audio_sha256 disagrees with the input manifest")
        lattice = jargon_lattice.get(row_id)
        if lattice is None:
            fail(f"{row_id} is absent from the cached jargon lattice")
            raise AssertionError
        transcript, spans = render_lattice_text(lattice["steps"])
        raw = entry["baseline_raw_text"]
        if sha256_text(raw) != entry["transcript_sha256"]:
            fail(f"{row_id}: transcript_sha256 does not match baseline_raw_text")
        rows.append(
            Row(
                row_id=row_id,
                ordinal=row_ordinal(row_id),
                is_positive="canonical" in info,
                canonical=info.get("canonical"),
                domain=info.get("domain", "?"),
                reference=record["reference"],
                audio_path=record["audio_path"],
                audio_sha256=record["audio_sha256"],
                audio_s=float(record["audio_s"]),
                frame_count=frame_count,
                byte_offset=int(entry["byte_offset"]),
                byte_count=int(entry["byte_count"]),
                state_sha256=entry.get("state_sha256"),
                baseline_raw_text=raw,
                baseline_final_text=entry.get("baseline_final_text") or raw,
                transcript_sha256=entry["transcript_sha256"],
                lattice_transcript=transcript,
                lattice_spans=spans,
                baseline_tokens=(baseline_rows.get(row_id) or {}).get("tokens"),
            )
        )
    return rows


def build_glossaries(rows: Sequence[Row], term_ids: dict[str, str]) -> None:
    """Active glossary per row, exactly per §Active glossary and tokenizer.

    All 173 canonicals are `.manualImport`, non-priority, unprotected, so
    `VocabularyCompiler.compile(limit: 100)` (`Vocabulary.swift:74-140`) selects exactly the
    first 100 of its trust ordering as a set: pass 2 admits 60 under the `.manualImport`
    quota of 60 and pass 3 backfills the next 40 from `deferred` in the same order. The
    preregistration then sorts the set by term id before indexing, so only the set matters.
    """

    all_ids = sorted(term_ids.values())
    for row in rows:
        ranked = sorted(all_ids, key=lambda tid: rank_key(row.row_id, tid))
        selected = ranked[:GLOSSARY_LIMIT]
        if row.is_positive:
            target = term_ids[row.canonical or ""]
            row.target_term_id = target
            if target not in selected:
                selected[GLOSSARY_LIMIT - 1] = target
        chosen = set(selected)
        row.glossary = sorted(chosen)
        row.ranked_glossary = [tid for tid in ranked if tid in chosen]
        if len(row.glossary) != min(GLOSSARY_LIMIT, len(all_ids)):
            fail(f"{row.row_id}: active glossary has {len(row.glossary)} terms, expected {GLOSSARY_LIMIT}")


def resolve_labels(rows: Sequence[Row], contrastive: dict[str, dict], strict: bool) -> dict:
    """Localization labels: canonical span, contrastive emitted span, or char alignment."""

    counts: dict[str, int] = {}
    unmappable: list[str] = []
    for row in rows:
        row.contrastive = contrastive.get(row.row_id)
        if not row.is_positive:
            continue
        transcript = row.lattice_transcript
        span = find_exact(transcript, row.canonical or "")
        source = "exact_canonical"
        if span is None:
            pair = row.contrastive
            if pair is None:
                source = "no_contrastive_row"
            else:
                start = int(pair["emitted_start"])
                end = int(pair["emitted_end"])
                surface = pair.get("emitted_surface") or ""
                if pair.get("raw_transcript") == transcript:
                    span, source = (start, end), "contrastive_direct"
                elif surface and transcript.count(surface) == 1:
                    begin = transcript.index(surface)
                    span, source = (begin, begin + len(surface)), "contrastive_unique_surface"
                else:
                    span = align_span(pair.get("raw_transcript") or "", transcript, start, end)
                    source = "contrastive_aligned" if span else "unmappable_alignment"
        if span is None:
            unmappable.append(row.row_id)
            row.label_source = source
            counts[source] = counts.get(source, 0) + 1
            continue
        # The label character span is resolved against the cached lattice, but its FRAME must
        # live on the same axis as the states being trained on. Stage 1's own token timings
        # are that axis, so use them when `baseline-rows.jsonl` supplied them and fall back to
        # the cached lattice's step frames only when it did not.
        frame = None
        if row.baseline_tokens:
            spans, _ = token_map(
                row, {"raw_text": row.baseline_raw_text, "tokens": row.baseline_tokens}
            )
            mapped = (
                span
                if transcript == row.baseline_raw_text
                else align_span(transcript, row.baseline_raw_text, span[0], span[1])
            )
            if mapped is not None:
                frame = next(
                    (
                        item.frame_low
                        for item in spans
                        if item.end > item.start and item.start < mapped[1] and mapped[0] < item.end
                    ),
                    None,
                )
                if frame is not None:
                    source = source + "+stage1_frame"
        if frame is None:
            frame = earliest_intersecting_frame(row.lattice_spans, span[0], span[1])
        if frame is None:
            source = "no_intersecting_step"
        elif frame >= row.frame_count:
            source = "frame_out_of_range"
        if frame is None or frame >= row.frame_count:
            unmappable.append(row.row_id)
            row.label_source = source
            counts[source] = counts.get(source, 0) + 1
            continue
        row.label_span = span
        row.label_frame = frame
        row.label_source = source
        counts[source] = counts.get(source, 0) + 1
    if unmappable and strict:
        fail(f"{len(unmappable)} positive rows failed to map a localization span uniquely: {unmappable[:8]}")
    return {"sources": counts, "unmappable": unmappable}


def assign_folds(rows: Sequence[Row]) -> None:
    """Two-fold cross-fitting, deterministic (§Split, labels, and localization).

    Model A fits the lower numeric row id of each canonical and tests the higher; model B
    reverses them. A row's `fold` names the model that TESTS it.
    """

    by_canonical: dict[str, list[Row]] = {}
    for row in rows:
        if row.is_positive:
            by_canonical.setdefault(row.canonical or "", []).append(row)
    for canonical, group in by_canonical.items():
        if len(group) != 2:
            fail(f"canonical {canonical!r} has {len(group)} rows; the corpus fixes two templates")
        low, high = sorted(group, key=lambda item: item.ordinal)
        low.fold = "B"
        high.fold = "A"
    for row in rows:
        if not row.is_positive:
            row.fold = "B" if digest_low_bit(row.row_id) == 0 else "A"


def fold_sets(rows: Sequence[Row], fold: str) -> tuple[list[Row], list[Row]]:
    test = [row for row in rows if row.fold == fold]
    fit = [row for row in rows if row.fold != fold]
    return fit, test


# ---------------------------------------------------------------------------
# state pack access
# ---------------------------------------------------------------------------


class StatePack:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.size = path.stat().st_size
        if self.size % 4:
            fail(f"{path}: {self.size} bytes is not a whole number of F32 values")
        self.data = np.memmap(path, dtype="<f4", mode="r")

    def states(self, row: Row) -> np.ndarray:
        if row.byte_offset % 4:
            fail(f"{row.row_id}: byte_offset {row.byte_offset} is not F32-aligned")
        start = row.byte_offset // 4
        count = row.frame_count * STATE_WIDTH
        if start + count > self.data.size:
            fail(f"{row.row_id}: state slice runs past the end of the pack")
        block = np.asarray(self.data[start : start + count], dtype=np.float32)
        return block.reshape(row.frame_count, STATE_WIDTH)

    def row_bytes(self, row: Row) -> bytes:
        with self.path.open("rb") as handle:
            handle.seek(row.byte_offset)
            payload = handle.read(row.byte_count)
        if len(payload) != row.byte_count:
            fail(f"{row.row_id}: truncated state payload")
        return payload


def channel_std(pack: StatePack, rows: Sequence[Row]) -> np.ndarray:
    """Per-channel standard deviation over that fold's fit states only."""

    total = 0
    accum = np.zeros(STATE_WIDTH, dtype=np.float64)
    square = np.zeros(STATE_WIDTH, dtype=np.float64)
    for row in rows:
        states = pack.states(row).astype(np.float64)
        accum += states.sum(axis=0)
        square += (states * states).sum(axis=0)
        total += states.shape[0]
    if total == 0:
        fail("channel_std has no fit frames")
    mean = accum / total
    variance = np.maximum(square / total - mean * mean, 0.0)
    return np.sqrt(variance).astype(np.float32)


# ---------------------------------------------------------------------------
# the one model (§One model and training budget)
# ---------------------------------------------------------------------------

PARAM_NAMES = ("Wa1", "ba1", "Wa2", "ba2", "Wg1", "bg1", "Wg2", "bg2")
PARAMETER_COUNT = 4 * STATE_WIDTH * STATE_WIDTH + 4 * STATE_WIDTH


def init_params(rng: np.random.Generator) -> dict[str, np.ndarray]:
    """Matrices identity + N(0, .001); biases zero. Draw order Wa1, Wa2, Wg1, Wg2."""

    identity = np.eye(STATE_WIDTH, dtype=np.float32)
    params: dict[str, np.ndarray] = {}
    for name in ("Wa1", "Wa2", "Wg1", "Wg2"):
        noise = rng.normal(0.0, INIT_NOISE_STD, size=(STATE_WIDTH, STATE_WIDTH)).astype(np.float32)
        params[name] = (identity + noise).astype(np.float32)
    for name in ("ba1", "ba2", "bg1", "bg2"):
        params[name] = np.zeros(STATE_WIDTH, dtype=np.float32)
    if sum(value.size for value in params.values()) != PARAMETER_COUNT:
        fail("parameter count is not the preregistered 4,198,400")
    return params


def layer_norm(x: np.ndarray) -> np.ndarray:
    mean = x.mean(axis=1, keepdims=True, dtype=np.float32)
    centred = (x - mean).astype(np.float32)
    inv = (1.0 / np.sqrt((centred * centred).mean(axis=1, keepdims=True) + LN_EPS)).astype(np.float32)
    return (centred * inv).astype(np.float32)


@dataclass
class BranchCache:
    inp: np.ndarray
    pre: np.ndarray
    hidden: np.ndarray
    norm: np.ndarray
    unit: np.ndarray


def branch_forward(params: dict[str, np.ndarray], x: np.ndarray, prefix: str, apply_ln: bool) -> BranchCache:
    inp = layer_norm(x) if apply_ln else x.astype(np.float32, copy=False)
    pre = (inp @ params[f"W{prefix}1"].T + params[f"b{prefix}1"]).astype(np.float32)
    hidden = np.maximum(pre, np.float32(0.0)).astype(np.float32)
    out = (hidden @ params[f"W{prefix}2"].T + params[f"b{prefix}2"]).astype(np.float32)
    norm = np.sqrt((out * out).sum(axis=1, keepdims=True) + L2_EPS).astype(np.float32)
    return BranchCache(inp, pre, hidden, norm, (out / norm).astype(np.float32))


def branch_backward(
    params: dict[str, np.ndarray],
    cache: BranchCache,
    d_unit: np.ndarray,
    prefix: str,
    grads: dict[str, np.ndarray],
) -> None:
    projection = (d_unit * cache.unit).sum(axis=1, keepdims=True)
    d_out = ((d_unit - cache.unit * projection) / cache.norm).astype(np.float32)
    grads[f"W{prefix}2"] += d_out.T @ cache.hidden
    grads[f"b{prefix}2"] += d_out.sum(axis=0)
    d_hidden = (d_out @ params[f"W{prefix}2"]).astype(np.float32)
    d_pre = (d_hidden * (cache.pre > 0.0)).astype(np.float32)
    grads[f"W{prefix}1"] += d_pre.T @ cache.inp
    grads[f"b{prefix}1"] += d_pre.sum(axis=0)


def frame_embeddings(params: dict[str, np.ndarray], states: np.ndarray) -> np.ndarray:
    return branch_forward(params, states, "a", apply_ln=True).unit


def term_embeddings(params: dict[str, np.ndarray], vectors: np.ndarray) -> np.ndarray:
    return branch_forward(params, vectors, "g", apply_ln=False).unit


class AdamW:
    def __init__(self, params: dict[str, np.ndarray]) -> None:
        self.m = {name: np.zeros_like(value) for name, value in params.items()}
        self.v = {name: np.zeros_like(value) for name, value in params.items()}
        self.step = 0

    def update(self, params: dict[str, np.ndarray], grads: dict[str, np.ndarray]) -> float:
        total = 0.0
        for name in PARAM_NAMES:
            total += float((grads[name].astype(np.float64) ** 2).sum())
        norm = math.sqrt(total)
        scale = 1.0 if norm <= GRAD_CLIP else GRAD_CLIP / norm
        self.step += 1
        beta1, beta2 = ADAM_BETAS
        bias1 = 1.0 - beta1**self.step
        bias2 = 1.0 - beta2**self.step
        for name in PARAM_NAMES:
            grad = (grads[name] * np.float32(scale)).astype(np.float32)
            self.m[name] = (beta1 * self.m[name] + (1.0 - beta1) * grad).astype(np.float32)
            self.v[name] = (beta2 * self.v[name] + (1.0 - beta2) * grad * grad).astype(np.float32)
            m_hat = (self.m[name] / np.float32(bias1)).astype(np.float32)
            v_hat = (self.v[name] / np.float32(bias2)).astype(np.float32)
            step = (m_hat / (np.sqrt(v_hat) + np.float32(ADAM_EPS))).astype(np.float32)
            params[name] -= np.float32(LEARNING_RATE) * (step + np.float32(WEIGHT_DECAY) * params[name])
        return norm


# ---------------------------------------------------------------------------
# training
# ---------------------------------------------------------------------------


@dataclass
class Example:
    row: Row
    vectors: np.ndarray  # [K, 1024]
    target_index: int  # 0 = null, 1 = the annotated target


def build_examples(
    rows: Sequence[Row],
    vectors: dict[str, np.ndarray | None],
    surface_vectors: dict[str, np.ndarray | None],
) -> tuple[list[Example], int, dict[str, int]]:
    examples: list[Example] = []
    contrastive_used = 0
    skipped: dict[str, int] = {}
    candidates = 1 + DISTRACTORS_PER_POSITIVE
    for row in sorted(rows, key=lambda item: item.row_id):
        if row.is_positive:
            if row.label_frame is None:
                skipped["no_localization_label"] = skipped.get("no_localization_label", 0) + 1
                continue
            target_vector = vectors.get(row.target_term_id or "")
            if target_vector is None:
                skipped["unrepresentable_canonical"] = skipped.get("unrepresentable_canonical", 0) + 1
                continue
            distractors = [
                vectors[tid]
                for tid in row.ranked_glossary
                if tid != row.target_term_id and vectors.get(tid) is not None
            ][:DISTRACTORS_PER_POSITIVE]
            block = [target_vector, *distractors]
            pair = row.contrastive
            if (
                pair
                and pair.get("counterpart_status") == "retained"
                and pair.get("provenance_complete")
                and pair.get("negative_surface")
                and surface_vectors.get(pair["negative_surface"]) is not None
                and len(block) >= candidates
            ):
                block[DISTRACTORS_PER_POSITIVE] = surface_vectors[pair["negative_surface"]]
                contrastive_used += 1
            while len(block) < candidates:
                block.append(np.zeros(STATE_WIDTH, dtype=np.float32))
            examples.append(Example(row, np.stack(block[:candidates]).astype(np.float32), 1))
        else:
            block = [
                vectors[tid] for tid in row.ranked_glossary if vectors.get(tid) is not None
            ][:candidates]
            while len(block) < candidates:
                block.append(np.zeros(STATE_WIDTH, dtype=np.float32))
            examples.append(Example(row, np.stack(block[:candidates]).astype(np.float32), 0))
    return examples, contrastive_used, skipped


def train_fold(pack: StatePack, examples: Sequence[Example], params: dict[str, np.ndarray], label: str) -> dict:
    if not examples:
        fail(f"fold {label} has no training examples")
    optimiser = AdamW(params)
    cached_states = {example.row.row_id: pack.states(example.row) for example in examples}
    history: list[dict] = []
    cursor = 0
    for update in range(1, UPDATES_PER_FOLD + 1):
        batch = [examples[(cursor + offset) % len(examples)] for offset in range(BATCH_SIZE)]
        cursor = (cursor + BATCH_SIZE) % len(examples)
        grads = {name: np.zeros_like(value) for name, value in params.items()}
        loss_total = 0.0
        frame_rows: list[np.ndarray] = []
        term_rows: list[np.ndarray] = []
        d_frames: list[np.ndarray] = []
        d_terms: list[np.ndarray] = []
        for example in batch:
            states = cached_states[example.row.row_id]
            frames = frame_embeddings(params, states)
            terms = term_embeddings(params, example.vectors)
            score_matrix = (frames @ terms.T).astype(np.float32)
            best = np.argmax(score_matrix, axis=0)  # earliest frame wins a tie
            scores = score_matrix[best, np.arange(score_matrix.shape[1])]
            logits = np.concatenate(([np.float32(0.0)], scores / np.float32(TEMPERATURE)))
            exponent = np.exp((logits - logits.max()).astype(np.float64))
            probabilities = exponent / exponent.sum()
            loss_total += float(-math.log(max(float(probabilities[example.target_index]), 1e-300)))
            d_logits = probabilities.copy()
            d_logits[example.target_index] -= 1.0
            d_logits /= BATCH_SIZE
            d_scores = (d_logits[1:] / TEMPERATURE).astype(np.float32)
            frame_rows.append(states[best, :])
            term_rows.append(example.vectors)
            d_frames.append((d_scores[:, None] * terms).astype(np.float32))
            d_terms.append((d_scores[:, None] * frames[best, :]).astype(np.float32))
        frame_cache = branch_forward(params, np.concatenate(frame_rows, axis=0), "a", apply_ln=True)
        term_cache = branch_forward(params, np.concatenate(term_rows, axis=0), "g", apply_ln=False)
        branch_backward(params, frame_cache, np.concatenate(d_frames, axis=0), "a", grads)
        branch_backward(params, term_cache, np.concatenate(d_terms, axis=0), "g", grads)
        grad_norm = optimiser.update(params, grads)
        if update == 1 or update % 32 == 0:
            history.append(
                {"update": update, "loss": loss_total / BATCH_SIZE, "grad_norm_before_clip": grad_norm}
            )
    return {
        "fold": label,
        "examples": len(examples),
        "updates": UPDATES_PER_FOLD,
        "batch": BATCH_SIZE,
        "parameters": PARAMETER_COUNT,
        "history": history,
    }


# ---------------------------------------------------------------------------
# inference
# ---------------------------------------------------------------------------


@dataclass
class Decision:
    row_id: str
    term_id: str | None
    canonical: str | None
    score: float
    probability: float
    frame: int
    window: tuple[int, int]
    null_probability: float
    structural_null: bool = False


def decide(
    params: dict[str, np.ndarray],
    pack: StatePack,
    row: Row,
    vectors: dict[str, np.ndarray | None],
    id_to_canonical: dict[str, str],
) -> Decision:
    """Score the row's active glossary; pick the argmax candidate and its earliest frame."""

    candidates = [tid for tid in row.glossary if vectors.get(tid) is not None]
    if not candidates:
        # Structural block skip: an empty glossary is never evaluated.
        return Decision(row.row_id, None, None, float("-inf"), 0.0, 0, (0, 0), 1.0, structural_null=True)
    frames = frame_embeddings(params, pack.states(row))
    terms = term_embeddings(params, np.stack([vectors[tid] for tid in candidates]))
    score_matrix = (frames @ terms.T).astype(np.float32)
    best_frames = np.argmax(score_matrix, axis=0)
    scores = score_matrix[best_frames, np.arange(score_matrix.shape[1])]
    logits = np.concatenate(([np.float32(0.0)], scores / np.float32(TEMPERATURE)))
    exponent = np.exp((logits - logits.max()).astype(np.float64))
    probabilities = exponent / exponent.sum()
    best = int(np.argmax(scores))
    frame = int(best_frames[best])
    term = candidates[best]
    return Decision(
        row.row_id,
        term,
        id_to_canonical[term],
        float(scores[best]),
        float(probabilities[best + 1]),
        frame,
        (max(0, frame - ADAPT_HALF_WINDOW), min(row.frame_count - 1, frame + ADAPT_HALF_WINDOW)),
        float(probabilities[0]),
    )


def row_score(params: dict[str, np.ndarray], pack: StatePack, row: Row, vector: np.ndarray) -> float:
    frames = frame_embeddings(params, pack.states(row))
    term = term_embeddings(params, vector[None, :])
    return float((frames @ term.T).max())


def adapt_states(
    params: dict[str, np.ndarray],
    states: np.ndarray,
    vector: np.ndarray,
    std: np.ndarray,
    eta: float,
    window: tuple[int, int],
) -> np.ndarray:
    """`x' = x + eta * channel_std * tanh(a(x) * g(t))` over the clipped +/-4 window."""

    low, high = window
    block = states[low : high + 1, :]
    a_block = frame_embeddings(params, block)
    g_vector = term_embeddings(params, vector[None, :])[0]
    delta = (np.float32(eta) * std * np.tanh(a_block * g_vector)).astype(np.float32)
    out = states.copy()
    out[low : high + 1, :] = (block + delta).astype(np.float32)
    return out


# ---------------------------------------------------------------------------
# adapted packs and replay
# ---------------------------------------------------------------------------


def write_pack(
    directory: Path,
    rows: Sequence[Row],
    manifest_by_id: dict[str, dict],
    state_provider: Callable[[Row], np.ndarray | None],
    pack: StatePack,
) -> tuple[Path, Path, Path]:
    """Write the `manifest.jsonl` + `states.f32` + `index.jsonl` triple for one replay."""

    directory.mkdir(parents=True, exist_ok=True)
    states_path = directory / "states.f32"
    index_path = directory / "index.jsonl"
    manifest_path = directory / "manifest.jsonl"
    offset = 0
    index: list[dict] = []
    with states_path.open("wb") as handle:
        for row in rows:
            adapted = state_provider(row)
            if adapted is None:
                payload = pack.row_bytes(row)
            else:
                if adapted.shape != (row.frame_count, STATE_WIDTH):
                    fail(
                        f"{row.row_id}: adapted states are {adapted.shape}, expected "
                        f"{(row.frame_count, STATE_WIDTH)}"
                    )
                if not np.isfinite(adapted).all():
                    fail(f"{row.row_id}: adapted states contain a non-finite value")
                payload = np.ascontiguousarray(adapted, dtype="<f4").tobytes()
            if len(payload) != row.byte_count:
                fail(f"{row.row_id}: pack payload {len(payload)} != byte_count {row.byte_count}")
            handle.write(payload)
            index.append(
                {
                    "id": row.row_id,
                    "byte_offset": offset,
                    "byte_count": len(payload),
                    "frame_count": row.frame_count,
                    "width": STATE_WIDTH,
                }
            )
            offset += len(payload)
    write_jsonl(index_path, index)
    write_jsonl(manifest_path, [manifest_by_id[row.row_id] for row in rows])
    return manifest_path, states_path, index_path


def map_spans(source: str, target: str, spans: Sequence[TokenSpan]) -> list[TokenSpan]:
    """Carry token spans from one text into another through one deterministic alignment."""

    if source == target:
        return list(spans)
    matcher = difflib.SequenceMatcher(a=source, b=target, autojunk=False)
    opcodes = matcher.get_opcodes()
    out: list[TokenSpan] = []
    for span in spans:
        low: int | None = None
        high: int | None = None
        for tag, i1, i2, j1, j2 in opcodes:
            if i2 <= span.start or i1 >= span.end:
                continue
            if tag == "equal":
                begin = j1 + (max(i1, span.start) - i1)
                stop = j1 + (min(i2, span.end) - i1)
            else:
                begin, stop = j1, j2
            if stop < begin:
                continue
            low = begin if low is None else min(low, begin)
            high = stop if high is None else max(high, stop)
        if low is None or high is None or high < low:
            continue
        out.append(TokenSpan(low, high, span.frame_low, span.frame_high, span.word_start))
    out.sort(key=lambda item: (item.start, item.end))
    return out


def run_replay(
    tail_runner: Path,
    model: Path,
    vocabulary: Path,
    manifest_path: Path,
    states_path: Path,
    index_path: Path,
    output_path: Path,
    repo_root: Path,
    stub_rows: dict[str, tuple[str, str]] | None,
) -> tuple[dict[str, dict], list[str]]:
    """Invoke `glossary-conditioning replay-states`, or stub it with the baseline text."""

    argv = [
        str(tail_runner),
        "glossary-conditioning",
        "replay-states",
        "--input",
        str(manifest_path),
        "--states",
        str(states_path),
        "--index",
        str(index_path),
        "--output",
        str(output_path),
        "--model",
        str(model),
        "--vocabulary",
        str(vocabulary),
    ]
    if stub_rows is not None:
        records = []
        for entry in read_jsonl(index_path):
            texts = stub_rows.get(entry["id"])
            if texts is None:
                fail(f"stub replay has no baseline text for {entry['id']}")
                raise AssertionError
            raw, final = texts
            records.append(
                {
                    "id": entry["id"],
                    "raw_text": raw,
                    "cleaned_text": final,
                    "final_text": final,
                    "transcript_sha256": sha256_text(raw),
                    "final_sha256": sha256_text(final),
                    "frame_count": entry["frame_count"],
                }
            )
        write_jsonl(output_path, records)
    else:
        environment = {
            key: value for key, value in os.environ.items() if not key.startswith("VOICEOUR_COREML")
        }
        started = time.time()
        completed = subprocess.run(
            argv, cwd=str(repo_root), env=environment, capture_output=True, text=True, check=False
        )
        if completed.returncode != 0:
            fail(
                f"replay-states failed with exit {completed.returncode}\nargv: {' '.join(argv)}\n"
                f"stdout tail: {completed.stdout[-2000:]}\nstderr tail: {completed.stderr[-2000:]}"
            )
        log(f"replay {output_path.name}: {time.time() - started:.1f}s")
    rows = {record["id"]: record for record in read_jsonl(output_path)}
    expected = {entry["id"] for entry in read_jsonl(index_path)}
    if set(rows) != expected:
        fail(f"replay {output_path} covered {len(rows)} of {len(expected)} requested rows")
    for row_id, record in rows.items():
        if sha256_text(record["raw_text"]) != record["transcript_sha256"]:
            fail(f"replay row {row_id}: transcript_sha256 disagrees with raw_text")
        if record.get("final_text") is None:
            fail(
                f"replay row {row_id} carries no final_text; replay-states must run with "
                "--vocabulary so the shipped cleanup+repair domain is available"
            )
        if record.get("final_sha256") and sha256_text(record["final_text"]) != record["final_sha256"]:
            fail(f"replay row {row_id}: final_sha256 disagrees with final_text")
    return rows, argv


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------


@dataclass
class TokenSpan:
    start: int
    end: int
    frame_low: int
    frame_high: int
    word_start: bool


def token_map(row: Row, replay: dict) -> tuple[list[TokenSpan], str]:
    """Encoder-frame -> character map for the adapted decode, in the fixed source order.

    `replay-states` rows carry `tokens` with `start_ms`/`end_ms` in milliseconds of mel
    frame (`ParakeetContext.msPerFrame`), so the encoder frame is `start_ms / 10 / 8`.
    """

    text_target = replay["raw_text"]
    for tokens, source in (
        (replay.get("tokens"), "replay_tokens"),
        (row.baseline_tokens, "baseline_tokens"),
    ):
        if not tokens:
            continue
        spans: list[TokenSpan] = []
        text = ""
        for token in tokens:
            chunk = token.get("text")
            if chunk is None:
                chunk = Tokenizer.piece_to_text(token.get("piece", ""), text == "")
            start_ms = int(token.get("start_ms", 0))
            end_ms = int(token.get("end_ms", start_ms))
            low = start_ms // MS_PER_MEL_FRAME // MEL_SUBSAMPLING
            high = end_ms // MS_PER_MEL_FRAME // MEL_SUBSAMPLING
            piece = token.get("piece", "")
            word_start = bool(
                token.get("is_word_start", piece.startswith(SPM_SPACE) or not spans)
            )
            spans.append(
                TokenSpan(len(text), len(text) + len(chunk), low, max(low, high), word_start)
            )
            text += chunk
        if text == text_target:
            return spans, source
    aligned: list[TokenSpan] = []
    for span in row.lattice_spans:
        if span.end <= span.start:
            continue
        mapped = align_span(row.lattice_transcript, text_target, span.start, span.end)
        if mapped is None:
            continue
        aligned.append(
            TokenSpan(
                mapped[0],
                mapped[1],
                span.frame,
                span.frame,
                span.piece.startswith(SPM_SPACE) or not aligned,
            )
        )
    aligned.sort(key=lambda item: (item.start, item.end))
    return aligned, "lattice_aligned"


@dataclass(frozen=True)
class WordSpan:
    start: int
    end: int
    frame_low: int
    frame_high: int


def word_spans(spans: Sequence[TokenSpan]) -> list[WordSpan]:
    """Group the token spans into SentencePiece words, in order."""

    groups: list[list[TokenSpan]] = []
    for span in spans:
        if not groups or (span.word_start and any(item.end > item.start for item in groups[-1])):
            groups.append([span])
        else:
            groups[-1].append(span)
    out: list[WordSpan] = []
    for group in groups:
        body = [span for span in group if span.end > span.start]
        if not body:
            continue
        out.append(
            WordSpan(
                min(span.start for span in body),
                max(span.end for span in body),
                min(span.frame_low for span in body),
                max(span.frame_high for span in body),
            )
        )
    return out


@dataclass
class Rendered:
    text: str
    span: tuple[int, int]
    frames: tuple[int, int]
    mode: str


def _trim(text: str, start: int, end: int) -> tuple[int, int]:
    core = text[start:end]
    inner_start = start + (len(core) - len(core.lstrip()))
    inner_end = end - (len(core) - len(core.rstrip()))
    return (start, end) if inner_end <= inner_start else (inner_start, inner_end)


def render(
    text: str,
    spans: Sequence[TokenSpan],
    frame: int,
    window: tuple[int, int],
    canonical: str,
) -> Rendered | None:
    """Replace the minimal contiguous whole-word token span the frame window covers.

    Anchored at the localization frame, which is by construction the earliest frame at the
    candidate's maximum score, so the term's acoustics start there and can only run
    forward: the anchor is the word containing `frame`, extended over following words that
    start inside the window. See the `render`/`changed_span` deviations.
    """

    words = word_spans(spans)
    if not words:
        return None
    _, high = window
    mode = "overlap"
    anchor = next(
        (index for index, word in enumerate(words) if word.frame_low <= frame <= word.frame_high),
        None,
    )
    if anchor is None:
        anchor = min(
            range(len(words)),
            key=lambda index: (
                abs((words[index].frame_low + words[index].frame_high) / 2.0 - frame),
                index,
            ),
        )
        mode = "nearest"
    last = anchor
    while last + 1 < len(words) and words[last + 1].frame_low <= high:
        last += 1
    start, end = _trim(text, words[anchor].start, words[last].end)
    if not 0 <= start < end <= len(text):
        return None
    return Rendered(
        text[:start] + canonical + text[end:],
        (start, end),
        (words[anchor].frame_low, words[last].frame_high),
        mode,
    )


def snap_char_span(
    text: str, spans: Sequence[TokenSpan], low: int, high: int
) -> tuple[int, int] | None:
    """The minimal contiguous whole-word token span overlapping `[low, high)`."""

    words = word_spans(spans)
    touched = [index for index, word in enumerate(words) if word.start < high and low < word.end]
    if not touched:
        return None
    return _trim(text, words[min(touched)].start, words[max(touched)].end)


def syntax_corruption(replaced: str, canonical: str, taught: Sequence[str]) -> bool:
    residue = replaced
    for char in canonical:
        residue = residue.replace(char, "", 1)
    if SYNTAX_CHARS.search(residue):
        return True
    return any(
        surface != canonical and contains_exact(replaced, surface) for surface in taught
    )


# ---------------------------------------------------------------------------
# endpoints for one (eta, tau) operating point
# ---------------------------------------------------------------------------


@dataclass
class Prepared:
    """Everything about a row that depends on the replay but not on `tau`."""

    row: Row
    decision: Decision
    m1_text: str
    m1_raw_text: str
    span: tuple[int, int] | None
    target_span: tuple[int, int] | None
    frames: tuple[int, int] | None
    frame_overlap: bool
    replaced: str
    token_map_source: str
    render_mode: str
    renderable: bool
    span_correct: bool
    corrupting: bool
    introduced: list[str]
    replay_changed: bool
    replay_final_changed: bool


def prepare(
    rows: Sequence[Row],
    decisions: dict[str, Decision],
    replays: dict[str, dict],
    taught_surfaces: Sequence[str],
    canonical_set: Sequence[str],
) -> dict[str, Prepared]:
    prepared: dict[str, Prepared] = {}
    for row in rows:
        decision = decisions[row.row_id]
        replay = replays[row.row_id]
        raw = replay["raw_text"]
        final = replay["final_text"]
        baseline = row.baseline_final_text
        result: Rendered | None = None
        raw_result: Rendered | None = None
        spans_final: list[TokenSpan] = []
        source = "none"
        if decision.term_id is not None:
            spans_raw, source = token_map(row, replay)
            spans_final = map_spans(raw, final, spans_raw)
            result = render(
                final, spans_final, decision.frame, decision.window, decision.canonical or ""
            )
            raw_result = render(
                raw, spans_raw, decision.frame, decision.window, decision.canonical or ""
            )
        if result is None:
            prepared[row.row_id] = Prepared(
                row=row,
                decision=decision,
                m1_text=baseline,
                m1_raw_text=row.baseline_raw_text,
                span=None,
                target_span=None,
                frames=None,
                frame_overlap=False,
                replaced="",
                token_map_source=source,
                render_mode="none",
                renderable=False,
                span_correct=False,
                corrupting=False,
                introduced=[],
                replay_changed=raw != row.baseline_raw_text,
                replay_final_changed=final != baseline,
            )
            continue
        replaced = final[result.span[0] : result.span[1]]
        # The span the renderer SHOULD have replaced: the annotated character span carried
        # from the cached lattice into the final text, snapped by the same whole-word rule.
        target: tuple[int, int] | None = None
        if row.is_positive and row.label_span is not None:
            mapped = (
                row.label_span
                if row.lattice_transcript == final
                else align_span(row.lattice_transcript, final, row.label_span[0], row.label_span[1])
            )
            if mapped is not None:
                target = snap_char_span(final, spans_final, mapped[0], mapped[1])
        frame_overlap = bool(
            row.label_frame is not None
            and result.frames[0] <= row.label_frame + ADAPT_HALF_WINDOW
            and result.frames[1] >= row.label_frame - ADAPT_HALF_WINDOW
        )
        correct = bool(
            row.is_positive
            and decision.canonical == row.canonical
            and target is not None
            and result.span == target
            and contains_exact(result.text, row.canonical)
        )
        introduced = [
            surface
            for surface in taught_surfaces
            if contains_exact(result.text, surface) and not contains_exact(baseline, surface)
        ]
        prepared[row.row_id] = Prepared(
            row=row,
            decision=decision,
            m1_text=result.text,
            m1_raw_text=raw_result.text if raw_result is not None else raw,
            span=result.span,
            target_span=target,
            frames=result.frames,
            frame_overlap=frame_overlap,
            replaced=replaced,
            token_map_source=source,
            render_mode=result.mode,
            renderable=True,
            span_correct=correct,
            corrupting=syntax_corruption(replaced, decision.canonical or "", canonical_set),
            introduced=introduced,
            replay_changed=raw != row.baseline_raw_text,
            replay_final_changed=final != baseline,
        )
    return prepared


@dataclass
class RowOutcome:
    row: Row
    decision: Decision
    accepted: bool
    m0_text: str
    m1_text: str
    m1_raw_text: str
    changed_span: tuple[int, int] | None
    target_span: tuple[int, int] | None
    changed_frames: tuple[int, int] | None
    frame_overlap: bool
    replaced: str
    token_map_source: str
    render_mode: str
    m0_hit: bool
    m1_hit: bool
    m1_raw_hit: bool | None
    unsupported: list[str]
    corrupting: bool
    span_correct: bool | None
    replay_changed: bool


def apply_tau(prepared: dict[str, Prepared], rows: Sequence[Row], tau: float) -> list[RowOutcome]:
    outcomes: list[RowOutcome] = []
    for row in rows:
        item = prepared[row.row_id]
        accepted = (
            item.decision.term_id is not None and item.renderable and item.decision.probability >= tau
        )
        m0_text = row.baseline_final_text
        m1_text = item.m1_text if accepted else m0_text
        raw_text = item.m1_raw_text if accepted else row.baseline_raw_text
        m0_hit = bool(row.is_positive and contains_exact(m0_text, row.canonical))
        m1_hit = bool(row.is_positive and contains_exact(m1_text, row.canonical))
        raw_hit = bool(row.is_positive and contains_exact(raw_text, row.canonical))
        unsupported: list[str] = []
        if accepted and not row.is_positive:
            reference = row.reference.casefold()
            unsupported = sorted(
                surface
                for surface in item.introduced
                if not contains_exact(reference, surface.casefold())
            )
        outcomes.append(
            RowOutcome(
                row=row,
                decision=item.decision,
                accepted=accepted,
                m0_text=m0_text,
                m1_text=m1_text,
                m1_raw_text=raw_text,
                changed_span=item.span if accepted else None,
                target_span=item.target_span,
                changed_frames=item.frames if accepted else None,
                frame_overlap=bool(accepted and item.frame_overlap),
                replaced=item.replaced if accepted else "",
                token_map_source=item.token_map_source if accepted else "none",
                render_mode=item.render_mode if accepted else "none",
                m0_hit=m0_hit,
                m1_hit=m1_hit,
                m1_raw_hit=raw_hit,
                unsupported=unsupported,
                corrupting=bool(accepted and item.corrupting),
                span_correct=item.span_correct if accepted else None,
                replay_changed=item.replay_changed,
            )
        )
    return outcomes


def summarise(outcomes: Sequence[RowOutcome]) -> dict:
    positives = [item for item in outcomes if item.row.is_positive]
    negatives = [item for item in outcomes if not item.row.is_positive]
    changed = [item for item in outcomes if item.accepted and item.changed_span is not None]
    correct = [item for item in changed if item.span_correct]
    return {
        "recall_hits": sum(1 for item in positives if item.m1_hit),
        "m0_recall_hits": sum(1 for item in positives if item.m0_hit),
        "lost_m0_hits": sum(1 for item in positives if item.m0_hit and not item.m1_hit),
        "positives": len(positives),
        "negatives": len(negatives),
        "unsupported_activations": sum(1 for item in negatives if item.unsupported),
        "changed_spans": len(changed),
        "changed_spans_correct": len(correct),
        "changed_span_precision": (len(correct) / len(changed)) if changed else 1.0,
        "critical_syntax_corruption": sum(1 for item in changed if item.corrupting),
        "accepted": sum(1 for item in outcomes if item.accepted),
        "candidate_id_correct": sum(
            1 for item in positives if item.accepted and item.decision.canonical == item.row.canonical
        ),
        "replay_changed_rows": sum(1 for item in outcomes if item.replay_changed),
    }


def tau_grid(decisions: Iterable[Decision]) -> list[float]:
    """Unique fit maximum probabilities plus the always-null sentinel."""

    # Exact float values: rounding could lift a threshold above the probability that
    # produced it, making its own row unreachable at `probability >= tau`.
    values = sorted({float(decision.probability) for decision in decisions if decision.term_id})
    return [*values, 2.0]


# ---------------------------------------------------------------------------
# uncertainty
# ---------------------------------------------------------------------------


def _cluster_draws(clusters: Sequence[np.ndarray], seed: int, draws: int) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.Generator(np.random.PCG64(seed))
    sums = np.array([float(item.sum()) for item in clusters], dtype=np.float64)
    lengths = np.array([len(item) for item in clusters], dtype=np.float64)
    picks = rng.integers(0, len(clusters), size=(draws, len(clusters)))
    return sums[picks].sum(axis=1), lengths[picks].sum(axis=1)


def bootstrap_count(clusters: Sequence[np.ndarray], seed: int, draws: int) -> tuple[float, float]:
    if not clusters:
        return (float("nan"), float("nan"))
    numerators, _ = _cluster_draws(clusters, seed, draws)
    return (float(np.percentile(numerators, 2.5)), float(np.percentile(numerators, 97.5)))


def bootstrap_rate(clusters: Sequence[np.ndarray], seed: int, draws: int) -> tuple[float, float]:
    if not clusters:
        return (float("nan"), float("nan"))
    numerators, denominators = _cluster_draws(clusters, seed, draws)
    values = np.where(denominators > 0, numerators / np.maximum(denominators, 1e-12), 0.0)
    return (float(np.percentile(values, 2.5)), float(np.percentile(values, 97.5)))


def bootstrap_ratio(
    numerators: Sequence[float], denominators: Sequence[float], seed: int, draws: int
) -> tuple[float, float]:
    """Percentile bootstrap over utterance rows for a corpus-level ratio such as U-WER."""

    if not numerators:
        return (float("nan"), float("nan"))
    rng = np.random.Generator(np.random.PCG64(seed))
    num = np.asarray(numerators, dtype=np.float64)
    den = np.asarray(denominators, dtype=np.float64)
    picks = rng.integers(0, num.size, size=(draws, num.size))
    totals = den[picks].sum(axis=1)
    values = np.where(totals > 0, num[picks].sum(axis=1) / np.maximum(totals, 1e-12), 0.0)
    return (float(np.percentile(values, 2.5)), float(np.percentile(values, 97.5)))


def paired_permutation(gains: Sequence[float], seed: int, flips: int) -> float:
    """One-sided paired permutation over gain clusters, plus-one corrected."""

    array = np.asarray(gains, dtype=np.float64)
    if array.size == 0:
        return float("nan")
    observed = float(array.mean())
    rng = np.random.Generator(np.random.PCG64(seed))
    extreme = 0
    remaining = flips
    while remaining > 0:
        take = min(2000, remaining)
        signs = rng.integers(0, 2, size=(take, array.size)) * 2 - 1
        extreme += int(((signs * array).mean(axis=1) >= observed).sum())
        remaining -= take
    return (extreme + 1) / (flips + 1)


def clopper_pearson_upper(n: int) -> float | None:
    """Exact one-sided 95% upper rate for zero observed events: 1 - .05^(1/n)."""

    return None if n <= 0 else 1.0 - 0.05 ** (1.0 / n)


# ---------------------------------------------------------------------------
# general96 guard
# ---------------------------------------------------------------------------


def general_guard(
    corpus: Sequence[dict],
    results: Sequence[dict],
    lattice: dict[str, dict],
    uwer: Callable[[Sequence[str], Sequence[str]], float],
    per_row_edits: Callable[[str, str], tuple[float, float]],
) -> dict:
    """Structural empty-glossary branch: final text is the cached frozen pipeline output."""

    rows: dict[str, dict] = {}
    for record in results:
        if record.get("type") != "row":
            continue
        base, _, pass_id = str(record["id"]).partition("#")
        rows.setdefault(base, {})[pass_id] = record
    references: list[str] = []
    hypotheses: list[str] = []
    agreement = 0
    missing: list[str] = []
    nondeterministic: list[str] = []
    for record in corpus:
        row_id = record["id"]
        passes = rows.get(row_id)
        if not passes:
            missing.append(row_id)
            continue
        if len({passes[key]["final_text"] for key in passes}) != 1:
            nondeterministic.append(row_id)
        latest = passes[sorted(passes)[-1]]
        if latest.get("error") is not None:
            fail(f"general row {row_id} carries an error in the cached results")
        references.append(record["reference"])
        hypotheses.append(latest["final_text"])
        cached = lattice.get(row_id)
        if cached is not None and cached["transcript"] == latest["raw_transcript"]:
            agreement += 1
    if missing:
        fail(f"{len(missing)} general96 rows are absent from the cached results: {missing[:6]}")
    if nondeterministic:
        fail(f"{len(nondeterministic)} general96 rows differ across cached passes: {nondeterministic[:6]}")
    value = uwer(references, hypotheses)
    edits = [per_row_edits(reference, hypothesis) for reference, hypothesis in zip(references, hypotheses)]
    numerators = [item[0] for item in edits]
    denominators = [item[1] for item in edits]
    total = sum(denominators)
    decomposed = sum(numerators) / total if total else 0.0
    return {
        "uwer_general": value,
        "rows": len(references),
        "lattice_raw_agreement": agreement,
        "numerators": numerators,
        "denominators": denominators,
        "decomposition_error": abs(decomposed - value),
    }


# ---------------------------------------------------------------------------
# dry-run fixture
# ---------------------------------------------------------------------------


def build_dry_run_fixture(
    root: Path,
    repo: Path,
    manifest: Sequence[dict],
    row_ids: Sequence[str],
    planted: dict[str, tuple[int, np.ndarray]],
) -> tuple[Path, Path]:
    """Fabricate a small state pack so the pipeline can run without a Stage 1 dump."""

    cached: dict[str, dict] = {}
    cached_path = repo / ".build/autoresearch/jargon.1.results.jsonl"
    if cached_path.exists():
        for record in read_jsonl(cached_path):
            if record.get("type") == "row":
                cached[str(record["id"]).split("#")[0]] = record
    root.mkdir(parents=True, exist_ok=True)
    states_path = root / "states.f32"
    index_path = root / "index.jsonl"
    by_id = {record["id"]: record for record in manifest}
    rng = np.random.Generator(np.random.PCG64(SEED))
    index: list[dict] = []
    offset = 0
    with states_path.open("wb") as handle:
        for row_id in row_ids:
            record = by_id[row_id]
            samples = int(round(float(record["audio_s"]) * 16000))
            mel_frames = samples // 160 + 1
            frames = -(-mel_frames // MEL_SUBSAMPLING)
            block = (rng.standard_normal((frames, STATE_WIDTH)) * 0.5).astype(np.float32)
            # Plant the target's own direction at its annotated frame so the near-identity
            # initialisation can localise it: the block is otherwise pure noise and the
            # renderer, span guard, and recall path would never be exercised at all. The
            # planted rows are synthetic by construction and are never evidence.
            plant = planted.get(row_id)
            if plant is not None:
                frame, vector = plant
                if 0 <= frame < frames:
                    block[frame, :] = (vector * np.float32(8.0) + block[frame, :] * np.float32(0.05))
            payload = np.ascontiguousarray(block, dtype="<f4").tobytes()
            handle.write(payload)
            raw = (cached.get(row_id) or {}).get("raw_transcript") or record["reference"]
            final = (cached.get(row_id) or {}).get("final_text") or raw
            index.append(
                {
                    "id": row_id,
                    "byte_offset": offset,
                    "byte_count": len(payload),
                    "frame_count": frames,
                    "width": STATE_WIDTH,
                    "audio_sha256": record["audio_sha256"],
                    "state_sha256": hashlib.sha256(payload).hexdigest(),
                    "baseline_raw_text": raw,
                    "baseline_final_text": final,
                    "transcript_sha256": sha256_text(raw),
                    "mel_frame_count": mel_frames,
                    "audio_s": record["audio_s"],
                }
            )
            offset += len(payload)
    write_jsonl(index_path, index)
    return states_path, index_path


# ---------------------------------------------------------------------------
# environment identity
# ---------------------------------------------------------------------------


def _capture(argv: Sequence[str], default: str = "none") -> str:
    try:
        out = subprocess.run(list(argv), capture_output=True, text=True, timeout=60, check=False)
        return out.stdout.strip() or default
    except Exception:
        return default


def environment_identity() -> dict[str, str]:
    swift = _capture(["swift", "--version"])
    return {
        "hw_model": _capture(["sysctl", "-n", "hw.model"], "0"),
        "hw_chip": _capture(["sysctl", "-n", "machdep.cpu.brand_string"], "0").replace(" ", "_"),
        "hw_cpu_threads": _capture(["sysctl", "-n", "hw.logicalcpu"], "0"),
        "hw_perf_cores": _capture(["sysctl", "-n", "hw.perflevel0.logicalcpu"], "0"),
        "hw_eff_cores": _capture(["sysctl", "-n", "hw.perflevel1.logicalcpu"], "0"),
        "hw_memory_bytes": _capture(["sysctl", "-n", "hw.memsize"], "0"),
        "os_version": _capture(["sw_vers", "-productVersion"]),
        "os_build": _capture(["sw_vers", "-buildVersion"]),
        "kernel": platform.release() or "none",
        "swift_version": (swift.splitlines() or ["none"])[0].replace(" ", "_"),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

REPO_ROOT = Path("/Users/vlad/Desktop/voiceoour")
REPLAY_SUBCOMMAND = ("glossary-conditioning", "replay-states")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--states", type=Path, help="state-dump/states.f32 from Stage 1")
    parser.add_argument("--index", type=Path, help="state-dump/index.jsonl from Stage 1")
    parser.add_argument("--terms", type=Path, default=REPO_ROOT / "bench/autoresearch/jargon.terms.json")
    parser.add_argument(
        "--jargon-lattice",
        type=Path,
        default=REPO_ROOT / ".build/asr-research/three-bets/margins/jargon456.lattice.jsonl",
    )
    parser.add_argument(
        "--general-lattice",
        type=Path,
        default=REPO_ROOT / ".build/asr-research/three-bets/margins/general96.lattice.jsonl",
    )
    parser.add_argument(
        "--contrastive-rows",
        type=Path,
        default=REPO_ROOT
        / ".build/asr-research/next/data-foundation/contrastive-homophone-training/wave1/run1/rows.jsonl",
    )
    parser.add_argument(
        "--model",
        type=Path,
        default=Path.home()
        / "Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin",
    )
    parser.add_argument("--tail-runner", type=Path, default=REPO_ROOT / ".build/release/voiceour-bench")
    parser.add_argument("--output", type=Path, help="the run directory (run1)")
    # Inputs the preregistration names but the frozen command leaves at their defaults.
    parser.add_argument(
        "--jargon-manifest", type=Path, default=REPO_ROOT / "benchmarks/data/jargon/manifest.jsonl"
    )
    parser.add_argument(
        "--general-corpus", type=Path, default=REPO_ROOT / "bench/autoresearch/corpus.manifest.jsonl"
    )
    parser.add_argument(
        "--general-results", type=Path, default=REPO_ROOT / ".build/autoresearch/general.results.jsonl"
    )
    parser.add_argument(
        "--repair-vocabulary", type=Path, default=REPO_ROOT / "bench/autoresearch/repair.vocabulary.json"
    )
    parser.add_argument(
        "--prereg", type=Path, default=REPO_ROOT / "research/prereg/glossary-conditioned-decoding-wave1.md"
    )
    parser.add_argument("--bench-src", type=Path, default=REPO_ROOT / "bench/src")
    parser.add_argument("--verdict", type=Path, help="default <output>/../verdict.md")
    parser.add_argument("--dry-run", action="store_true", help="fabricate a small pack and stub the replay")
    parser.add_argument("--dry-run-rows", type=int, default=2)
    parser.add_argument("--stub-replay", action="store_true", help="substitute the baseline text for the tail")
    parser.add_argument("--keep-packs", action="store_true")
    parser.add_argument("--strict-span-map", action="store_true")
    parser.add_argument("--identity-controls", action="store_true", default=True)
    parser.add_argument("--no-identity-controls", dest="identity_controls", action="store_false")
    parser.add_argument("--describe", action="store_true", help="print constants and deviations, then exit")
    return parser.parse_args(argv)


def describe(args: argparse.Namespace) -> int:
    model = read_ggml(args.model)
    record = model.records[EMBED_TENSOR_NAME]
    tokenizer = Tokenizer(model.id_to_token)
    lattices = read_jsonl(args.jargon_lattice) + read_jsonl(args.general_lattice)
    check = tokenizer_lattice_check(tokenizer, lattices)
    terms = json.loads(args.terms.read_text(encoding="utf-8"))
    canonicals = sorted({info["canonical"] for info in terms.values() if "canonical" in info})
    unrepresentable = tuple(sorted(name for name in canonicals if not tokenizer.representable(name)))
    print("glossary-conditioned-decoding wave1 run1 - Stage 2 (cached CPU training and replay)")
    print(f"preregistration freeze commit : {PREREG_FREEZE_COMMIT}")
    print(f"metrics run id                : {METRICS_RUN}")
    print()
    print("frozen constants")
    print(f"  seed={SEED} temperature={TEMPERATURE} eta_budget={list(ETA_BUDGET)}")
    print(f"  adapt_window=+/-{ADAPT_HALF_WINDOW} updates_per_fold={UPDATES_PER_FOLD} batch={BATCH_SIZE}")
    print(f"  distractors={DISTRACTORS_PER_POSITIVE} lr={LEARNING_RATE} betas={ADAM_BETAS} eps={ADAM_EPS}")
    print(f"  weight_decay={WEIGHT_DECAY} grad_clip={GRAD_CLIP} init_noise_std={INIT_NOISE_STD}")
    print(f"  glossary_limit={GLOSSARY_LIMIT} term_id=sha256({TERM_ID_PREFIX!r}+canonical)[:16]")
    print(f"  parameters={PARAMETER_COUNT} across {len(PARAM_NAMES)} tensors {list(PARAM_NAMES)}")
    print(f"  bootstrap_B={BOOTSTRAP_B} permutation_flips={PERMUTATION_FLIPS}")
    print(
        f"  bars: meaningful>={BAR_MEANINGFUL} strong>={BAR_STRONG} kill<{BAR_KILL} "
        f"uwer_general<={UWER_GENERAL_CEILING} runtime<={RUNTIME_CEILING_S / 3600:g}h"
    )
    print()
    print("model container (read without inference)")
    print(f"  path={model.path}")
    print(f"  magic=0x{GGML_FILE_MAGIC:08x} legacy ggml (NOT GGUF)")
    print(f"  hparams={json.dumps(model.hparams)}")
    print(f"  tdt_durations={list(model.tdt_durations)}")
    print(
        f"  vocab={len(model.id_to_token)} tokens; blank id {tokenizer.blank_id}; "
        f"max token {tokenizer.max_token_bytes} bytes; unk id {tokenizer.unk_id}"
    )
    print(f"  tensor records={len(model.records)}")
    print(
        f"  {EMBED_TENSOR_NAME}: n_dims={record.n_dims} ne={list(record.ne)} "
        f"type={record.ggml_type} ({GGML_TYPE_NAMES[record.ggml_type]}) "
        f"payload_offset={record.payload_offset} payload_bytes={record.payload_bytes}"
    )
    print(
        f"    -> F32 [{record.ne[1]}, {record.ne[0]}] = [n_vocab+1, n_pred_dim] = "
        f"[{model.hparams['n_vocab'] + 1}, {model.hparams['n_pred_dim']}] (row = token id)"
    )
    print()
    print("tokenizer self-check against the cached lattices")
    print(
        f"  chosen tokens checked={check['checked_tokens']} mismatches={check['mismatches']} "
        f"match_rate={check['rate']:.6f}"
    )
    print(f"  transcript re-render mismatches={len(check['render_mismatch_rows'])}")
    print(
        f"  greedy-longest-match round trip over {check['round_trip_rows']} transcripts: "
        f"{len(check['round_trip_failures'])} failures"
    )
    print(f"  unrepresentable canonicals observed={list(unrepresentable)} (frozen {list(UNREPRESENTABLE)})")
    print()
    print("replay invocation (the only external process)")
    print(
        f"  {args.tail_runner} {' '.join(REPLAY_SUBCOMMAND)} --input <manifest.jsonl> "
        "--states <states.f32> --index <index.jsonl> --output <rows.jsonl> "
        f"--model {args.model} --vocabulary {args.repair_vocabulary}"
    )
    print("  no VOICEOUR_COREML_* variable is passed; replay-states loads no CoreML model")
    print()
    print("deviations (preregistration silent or frozen semantics unreachable; also in verdict.md)")
    for number, item in enumerate(DEVIATIONS, start=1):
        print(f"  {number:2d}. {item}")
    if check["mismatches"] or check["render_mismatch_rows"] or unrepresentable != tuple(sorted(UNREPRESENTABLE)):
        return 1
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.describe:
        return describe(args)
    if args.output is None:
        fail("--output is required")
        raise AssertionError
    started = time.time()
    repo = REPO_ROOT
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(args.bench_src))
    try:
        from voiceour_bench.metrics import contains_exact_term, uwer
        from voiceour_bench.normalizer import english_normalize
        import jiwer
    except Exception as error:  # pragma: no cover - environment contract
        fail(f"cannot import the pinned bench metric module from {args.bench_src}: {error}")
        raise AssertionError
    for probe in ("kubectl now", "kubectlx", "C++ code", ""):
        for surface in ("kubectl", "C++"):
            if contains_exact_term(probe, surface) != contains_exact(probe, surface):
                fail(f"local containment mirror disagrees with the pinned metric module on {probe!r}/{surface!r}")

    def per_row_edits(reference: str, hypothesis: str) -> tuple[float, float]:
        left = english_normalize(reference)
        right = english_normalize(hypothesis)
        measures = jiwer.process_words([left], [right])
        edits = measures.substitutions + measures.deletions + measures.insertions
        return (float(edits), float(len(left.split())))

    # --- pinned inputs ----------------------------------------------------
    log("reading pinned inputs")
    model = read_ggml(args.model)
    embedding = read_embedding(model)
    tokenizer = Tokenizer(model.id_to_token)
    embed_record = model.records[EMBED_TENSOR_NAME]
    log(
        f"{EMBED_TENSOR_NAME}: ne={list(embed_record.ne)} "
        f"{GGML_TYPE_NAMES[embed_record.ggml_type]} at byte {embed_record.payload_offset} "
        f"({embed_record.payload_bytes} bytes) -> F32 {tuple(int(v) for v in embedding.shape)}"
    )

    jargon_lattice_rows = read_jsonl(args.jargon_lattice)
    general_lattice_rows = read_jsonl(args.general_lattice)
    check = tokenizer_lattice_check(tokenizer, jargon_lattice_rows + general_lattice_rows)
    if check["mismatches"] or check["render_mismatch_rows"] or check["round_trip_failures"]:
        fail(
            f"tokenizer check failed: {check['mismatches']} piece mismatches, "
            f"{len(check['render_mismatch_rows'])} re-render mismatches, "
            f"{len(check['round_trip_failures'])} round-trip failures"
        )
    log(
        f"tokenizer check: {check['checked_tokens']} cached-lattice tokens and "
        f"{check['round_trip_rows']} transcripts, 100% match"
    )

    terms = json.loads(args.terms.read_text(encoding="utf-8"))
    manifest_all = read_jsonl(args.jargon_manifest)
    manifest_by_id = {record["id"]: record for record in manifest_all}
    contrastive_all = read_jsonl(args.contrastive_rows)
    contrastive = {record["positive_id"]: record for record in contrastive_all}
    repair_vocabulary = json.loads(args.repair_vocabulary.read_text(encoding="utf-8"))
    taught_surfaces = sorted(
        set(repair_vocabulary.get("surfaces", [])) | set(repair_vocabulary.get("protected_surfaces", []))
    )

    canonicals = sorted({info["canonical"] for info in terms.values() if "canonical" in info})
    if len(canonicals) != EXPECTED_CANONICALS:
        fail(f"{len(canonicals)} canonicals, the corpus fixes {EXPECTED_CANONICALS}")
    term_ids = {canonical: term_id(canonical) for canonical in canonicals}
    if len(set(term_ids.values())) != len(term_ids):
        fail("term id collision in the 16-hex-digit namespace")
    id_to_canonical = {value: key for key, value in term_ids.items()}

    observed_unrepresentable = tuple(sorted(name for name in canonicals if not tokenizer.representable(name)))
    if observed_unrepresentable != tuple(sorted(UNREPRESENTABLE)):
        fail(
            f"unrepresentable set is {observed_unrepresentable}, the preregistration freezes "
            f"{tuple(sorted(UNREPRESENTABLE))}"
        )
    log(f"unrepresentable canonicals (always null): {list(observed_unrepresentable)}")

    vectors: dict[str, np.ndarray | None] = {
        term_ids[canonical]: term_vector(tokenizer, embedding, canonical) for canonical in canonicals
    }
    surface_vectors: dict[str, np.ndarray | None] = {}
    for record in contrastive_all:
        for key in ("emitted_surface", "negative_surface"):
            surface = record.get(key)
            if surface and surface not in surface_vectors:
                surface_vectors[surface] = term_vector(tokenizer, embedding, surface)

    usable_pairs = [
        record
        for record in contrastive_all
        if record.get("counterpart_status") == "retained"
        and record.get("provenance_complete")
        and record.get("negative_counterpart_id")
        and record.get("negative_surface")
        and record.get("negative_source_kind")
        and record.get("negative_span_start") is not None
        and record.get("negative_span_end") is not None
        and record.get("positive_id")
        and record.get("canonical")
        and record.get("emitted_surface")
        and record.get("emitted_start") is not None
        and record.get("emitted_end") is not None
        and record.get("positive_audio_sha256")
        and record.get("positive_manifest_input_sha256")
    ]
    excluded_pairs = len(contrastive_all) - len(usable_pairs)
    if not usable_pairs:
        fail("zero usable contrastive pairs; the preregistration stops before training")
    counterpart_ids = [record["negative_counterpart_id"] for record in usable_pairs]
    if len(set(counterpart_ids)) != len(counterpart_ids):
        fail("contrastive negative counterpart ids are not globally unique")
    log(f"contrastive pairs: {len(usable_pairs)} usable, {excluded_pairs} excluded")

    # --- Stage 1 pack -----------------------------------------------------
    if args.dry_run:
        # Whole canonical pairs first (cross-fitting needs both templates of a canonical),
        # then negative rows so the null branch and the activation guard are exercised too.
        budget = max(2, args.dry_run_rows)
        wanted_pairs = max(1, (budget * 2 // 3) // 2)
        grouped: dict[str, list[str]] = {}
        for record in manifest_all:
            info = terms.get(record["id"]) or {}
            if "canonical" in info:
                grouped.setdefault(info["canonical"], []).append(record["id"])
        row_ids: list[str] = []
        for group in grouped.values():
            if len(row_ids) // 2 >= wanted_pairs:
                break
            if len(group) == 2:
                row_ids.extend(group)
        for record in manifest_all:
            if len(row_ids) >= budget:
                break
            if "canonical" not in (terms.get(record["id"]) or {}):
                row_ids.append(record["id"])
        row_ids = [record["id"] for record in manifest_all if record["id"] in set(row_ids)]
        lattice_by_id = {row["id"]: row for row in jargon_lattice_rows}
        planted: dict[str, tuple[int, np.ndarray]] = {}
        for row_id in row_ids:
            info = terms.get(row_id) or {}
            canonical = info.get("canonical")
            vector = vectors.get(term_ids.get(canonical or "", ""))
            lattice = lattice_by_id.get(row_id)
            if canonical is None or vector is None or lattice is None:
                continue
            transcript, spans = render_lattice_text(lattice["steps"])
            span = find_exact(transcript, canonical)
            if span is None:
                pair = contrastive.get(row_id)
                if pair is None:
                    continue
                span = (
                    (int(pair["emitted_start"]), int(pair["emitted_end"]))
                    if pair.get("raw_transcript") == transcript
                    else align_span(
                        pair.get("raw_transcript") or "",
                        transcript,
                        int(pair["emitted_start"]),
                        int(pair["emitted_end"]),
                    )
                )
            if span is None:
                continue
            frame = earliest_intersecting_frame(spans, span[0], span[1])
            if frame is not None:
                planted[row_id] = (frame, vector)
        states_path, index_path = build_dry_run_fixture(
            output / "dry-run-fixture", repo, manifest_all, row_ids, planted
        )
        manifest = [manifest_by_id[row_id] for row_id in row_ids]
        stub = True
        log(f"dry run: fabricated a {len(row_ids)}-row state pack at {states_path}")
    else:
        if args.states is None or args.index is None:
            fail("--states and --index are required outside --dry-run")
            raise AssertionError
        states_path = args.states.resolve()
        index_path = args.index.resolve()
        manifest = manifest_all
        stub = args.stub_replay
        if len(manifest) != EXPECTED_JARGON_ROWS:
            fail(f"the jargon manifest has {len(manifest)} rows, the corpus fixes {EXPECTED_JARGON_ROWS}")

    index_records = read_jsonl(index_path)
    baseline_rows_path = index_path.parent / "baseline-rows.jsonl"
    baseline_rows = (
        {record["id"]: record for record in read_jsonl(baseline_rows_path)}
        if baseline_rows_path.exists()
        else {}
    )
    rows = build_rows(
        manifest, terms, index_records, {row["id"]: row for row in jargon_lattice_rows}, baseline_rows
    )
    if not args.dry_run:
        if len(rows) != EXPECTED_JARGON_ROWS:
            fail(f"{len(rows)} rows assembled, expected {EXPECTED_JARGON_ROWS}")
        positive_count = sum(1 for row in rows if row.is_positive)
        if positive_count != EXPECTED_POSITIVES or len(rows) - positive_count != EXPECTED_NEGATIVES:
            fail(
                f"{positive_count} positives / {len(rows) - positive_count} negatives, expected "
                f"{EXPECTED_POSITIVES}/{EXPECTED_NEGATIVES}"
            )
    pack = StatePack(states_path)
    total_frames = sum(row.frame_count for row in rows)
    expected_bytes = sum(row.byte_count for row in rows)
    if pack.size != expected_bytes:
        fail(f"{states_path}: {pack.size} bytes, the index accounts for {expected_bytes}")
    log(f"{len(rows)} rows, {total_frames} encoder frames, {pack.size} state bytes")

    state_identity_mismatches = 0
    for row in rows:
        if row.state_sha256 and hashlib.sha256(pack.row_bytes(row)).hexdigest() != row.state_sha256:
            state_identity_mismatches += 1
        if not np.isfinite(pack.states(row)).all():
            fail(f"{row.row_id}: Stage 1 states contain a non-finite value")
    if state_identity_mismatches:
        fail(f"{state_identity_mismatches} rows disagree with their Stage 1 state_sha256")

    baseline_domain_disagreements = sum(
        1
        for row in rows
        if row.is_positive
        and contains_exact(row.baseline_raw_text, row.canonical)
        != contains_exact(row.baseline_final_text, row.canonical)
    )
    log(f"baseline raw-vs-final containment disagreements: {baseline_domain_disagreements}")

    build_glossaries(rows, term_ids)
    label_report = resolve_labels(rows, contrastive, args.strict_span_map)
    assign_folds(rows)
    log(f"localization label sources: {json.dumps(label_report['sources'], sort_keys=True)}")
    if label_report["unmappable"]:
        log(f"unmappable localization rows: {len(label_report['unmappable'])}")

    # --- per-fold training, fit-side selection, out-of-fold replay --------
    rng = np.random.Generator(np.random.PCG64(SEED))
    fold_params = {"A": init_params(rng), "B": init_params(rng)}
    replay_dir = output / "replay"
    replay_dir.mkdir(parents=True, exist_ok=True)
    pack_root = output / "packs"

    fold_reports: dict[str, dict] = {}
    selection: dict[str, dict] = {}
    outcomes: list[RowOutcome] = []
    all_decisions: dict[str, Decision] = {}
    replay_argv: list[list[str]] = []

    for fold in ("A", "B"):
        fit, test = fold_sets(rows, fold)
        if not test or not fit:
            fail(f"fold {fold} has an empty side: {len(fit)} fit, {len(test)} test")
        params = fold_params[fold]
        examples, used_pairs, skipped = build_examples(fit, vectors, surface_vectors)
        log(
            f"fold {fold}: {len(fit)} fit rows, {len(test)} test rows, {len(examples)} examples, "
            f"{used_pairs} contrastive distractors, skipped={json.dumps(skipped, sort_keys=True)}"
        )
        report = train_fold(pack, examples, params, fold)
        report["contrastive_distractors"] = used_pairs
        report["skipped_examples"] = skipped
        std = channel_std(pack, fit)
        report["channel_std_mean"] = float(std.mean())

        fit_decisions = {row.row_id: decide(params, pack, row, vectors, id_to_canonical) for row in fit}
        test_decisions = {row.row_id: decide(params, pack, row, vectors, id_to_canonical) for row in test}
        all_decisions.update(test_decisions)

        def make_provider(eta: float, decisions: dict[str, Decision]) -> Callable[[Row], np.ndarray | None]:
            def provider(row: Row) -> np.ndarray | None:
                decision = decisions[row.row_id]
                if decision.term_id is None:
                    return None
                vector = vectors[decision.term_id]
                assert vector is not None
                return adapt_states(params, pack.states(row), vector, std, eta, decision.window)

            return provider

        fit_prepared: dict[float, dict[str, Prepared]] = {}
        for eta in ETA_BUDGET:
            directory = pack_root / f"fold{fold}" / f"eta{eta:g}-fit"
            manifest_path, adapted_states, adapted_index = write_pack(
                directory, fit, manifest_by_id, make_provider(eta, fit_decisions), pack
            )
            rows_path = replay_dir / f"fold{fold}-eta{eta:g}-fit.rows.jsonl"
            refuse_overwrite(rows_path)
            replayed, argv = run_replay(
                args.tail_runner,
                args.model,
                args.repair_vocabulary,
                manifest_path,
                adapted_states,
                adapted_index,
                rows_path,
                repo,
                {row.row_id: (row.baseline_raw_text, row.baseline_final_text) for row in fit} if stub else None,
            )
            replay_argv.append(argv)
            fit_prepared[eta] = prepare(fit, fit_decisions, replayed, taught_surfaces, canonicals)
            if not args.keep_packs:
                shutil.rmtree(directory, ignore_errors=True)

        best: tuple[tuple[float, float, float], float, float, dict] | None = None
        grid: list[dict] = []
        for eta in ETA_BUDGET:
            for tau in tau_grid(fit_decisions.values()):
                point = summarise(apply_tau(fit_prepared[eta], fit, tau))
                feasible = (
                    point["unsupported_activations"] == 0
                    and point["lost_m0_hits"] == 0
                    and point["changed_span_precision"] == 1.0
                )
                grid.append({"eta": eta, "tau": tau, "feasible": feasible, **point})
                if not feasible:
                    continue
                key = (float(point["recall_hits"]), float(tau), -float(eta))
                if best is None or key > best[0]:
                    best = (key, eta, tau, point)
        if best is None:
            fail(
                f"fold {fold}: no (eta, tau) satisfies zero unsupported activations, zero lost fit "
                "hits, and changed_span_precision = 1.0; the preregistration kills the track"
            )
            raise AssertionError
        _, eta, tau, fit_point = best
        selection[fold] = {"eta": eta, "tau": tau, "fit": fit_point}
        log(f"fold {fold}: selected eta={eta:g} tau={tau:.12g} (fit recall_hits={fit_point['recall_hits']})")

        directory = pack_root / f"fold{fold}" / f"eta{eta:g}-test"
        manifest_path, adapted_states, adapted_index = write_pack(
            directory, test, manifest_by_id, make_provider(eta, test_decisions), pack
        )
        rows_path = replay_dir / f"fold{fold}-test.rows.jsonl"
        refuse_overwrite(rows_path)
        replayed, argv = run_replay(
            args.tail_runner,
            args.model,
            args.repair_vocabulary,
            manifest_path,
            adapted_states,
            adapted_index,
            rows_path,
            repo,
            {row.row_id: (row.baseline_raw_text, row.baseline_final_text) for row in test} if stub else None,
        )
        replay_argv.append(argv)
        if not args.keep_packs:
            shutil.rmtree(directory, ignore_errors=True)
        outcomes.extend(apply_tau(prepare(test, test_decisions, replayed, taught_surfaces, canonicals), test, tau))
        fold_reports[fold] = report
        fold_dir = output / f"fold-{fold}"
        fold_dir.mkdir(parents=True, exist_ok=True)
        np.savez(fold_dir / "weights.npz", **params)
        (fold_dir / "optimizer-report.json").write_text(
            json.dumps(
                {**report, "selected_eta": eta, "selected_tau": tau, "operating_grid": grid},
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )

    # --- identity controls -------------------------------------------------
    identity: dict[str, dict] = {}
    if args.identity_controls:
        controls = (
            ("I0", "empty glossary: the block is never evaluated"),
            ("I1", "nonempty glossary, tau forced above 1: the block runs and accepts nothing"),
        )
        for name, note in controls:
            if name == "I0":

                def identity_provider(row: Row) -> np.ndarray | None:
                    return None

            else:

                def identity_provider(row: Row) -> np.ndarray | None:
                    decision = all_decisions[row.row_id]
                    if decision.term_id is None or decision.probability < 2.0:
                        return None
                    fail(f"{row.row_id}: I1 accepted a candidate at tau > 1")
                    raise AssertionError

            directory = pack_root / f"identity-{name}"
            manifest_path, adapted_states, adapted_index = write_pack(
                directory, rows, manifest_by_id, identity_provider, pack
            )
            state_mismatches = 0
            with adapted_states.open("rb") as handle:
                for entry, row in zip(read_jsonl(adapted_index), rows):
                    handle.seek(entry["byte_offset"])
                    payload = handle.read(entry["byte_count"])
                    reference = row.state_sha256 or hashlib.sha256(pack.row_bytes(row)).hexdigest()
                    if hashlib.sha256(payload).hexdigest() != reference:
                        state_mismatches += 1
            rows_path = replay_dir / f"identity-{name}.rows.jsonl"
            refuse_overwrite(rows_path)
            replayed, argv = run_replay(
                args.tail_runner,
                args.model,
                args.repair_vocabulary,
                manifest_path,
                adapted_states,
                adapted_index,
                rows_path,
                repo,
                {row.row_id: (row.baseline_raw_text, row.baseline_final_text) for row in rows} if stub else None,
            )
            replay_argv.append(argv)
            text_mismatches = sum(
                1 for row in rows if replayed[row.row_id]["transcript_sha256"] != row.transcript_sha256
            )
            final_mismatches = sum(
                1
                for row in rows
                if replayed[row.row_id]["final_text"] != row.baseline_final_text
            )
            identity[name] = {
                "note": note,
                "rows": len(rows),
                "state_mismatches": state_mismatches,
                "text_mismatches": text_mismatches,
                "final_text_mismatches": final_mismatches,
            }
            log(
                f"identity {name}: {state_mismatches} state, {text_mismatches} raw-transcript, "
                f"{final_mismatches} final-text mismatches"
            )
            if not args.keep_packs:
                shutil.rmtree(directory, ignore_errors=True)
    if not args.keep_packs:
        shutil.rmtree(pack_root, ignore_errors=True)

    # --- endpoints ---------------------------------------------------------
    overall = summarise(outcomes)
    by_row = {item.row.row_id: item for item in outcomes}
    positives = [item for item in outcomes if item.row.is_positive]
    negatives = [item for item in outcomes if not item.row.is_positive]

    clusters_m1: list[np.ndarray] = []
    clusters_id: list[np.ndarray] = []
    gains: list[float] = []
    cluster_index: dict[str, list[RowOutcome]] = {}
    for item in positives:
        cluster_index.setdefault(item.row.canonical or "", []).append(item)
    for canonical in canonicals:
        group = cluster_index.get(canonical, [])
        if not group:
            continue
        clusters_m1.append(np.array([1.0 if item.m1_hit else 0.0 for item in group]))
        clusters_id.append(
            np.array(
                [
                    1.0 if (item.accepted and item.decision.canonical == item.row.canonical) else 0.0
                    for item in group
                ]
            )
        )
        gains.append(sum(float(item.m1_hit) - float(item.m0_hit) for item in group))

    recall_ci = bootstrap_count(clusters_m1, SEED, BOOTSTRAP_B)
    recall_rate_ci = bootstrap_rate(clusters_m1, SEED, BOOTSTRAP_B)
    id_ci = bootstrap_rate(clusters_id, SEED, BOOTSTRAP_B)
    permutation_p = paired_permutation(gains, SEED, PERMUTATION_FLIPS)

    pair_rank_correct = 0
    pair_rank_opportunities = 0
    pair_rank_excluded: dict[str, int] = {}
    pair_clusters: list[np.ndarray] = []
    for record in usable_pairs:
        positive = by_row.get(record["positive_id"])
        counterpart = str(record["negative_counterpart_id"]).split(":", 1)[-1].split("#")[0]
        negative = by_row.get(counterpart)
        vector = vectors.get(term_ids.get(record["canonical"], ""))
        if positive is None or vector is None:
            pair_rank_excluded["positive_absent_or_unrepresentable"] = (
                pair_rank_excluded.get("positive_absent_or_unrepresentable", 0) + 1
            )
            continue
        if negative is None:
            kind = f"counterpart_outside_state_pack:{record.get('negative_source_kind') or 'unknown'}"
            pair_rank_excluded[kind] = pair_rank_excluded.get(kind, 0) + 1
            continue
        positive_score = row_score(fold_params[positive.row.fold], pack, positive.row, vector)
        negative_score = row_score(fold_params[negative.row.fold], pack, negative.row, vector)
        pair_rank_opportunities += 1
        win = 1.0 if positive_score > negative_score else 0.0
        pair_rank_correct += int(win)
        pair_clusters.append(np.array([win]))
    pair_rank_ci = bootstrap_rate(pair_clusters, SEED, BOOTSTRAP_B)

    general_corpus = read_jsonl(args.general_corpus)
    if len(general_corpus) != EXPECTED_GENERAL_ROWS:
        fail(f"the general corpus has {len(general_corpus)} rows, expected {EXPECTED_GENERAL_ROWS}")
    guard = general_guard(
        general_corpus,
        read_jsonl(args.general_results),
        {row["id"]: row for row in general_lattice_rows},
        uwer,
        per_row_edits,
    )
    if guard["decomposition_error"] > 1e-9:
        fail(
            f"per-row U-WER decomposition disagrees with the corpus value by "
            f"{guard['decomposition_error']:.3g}; the bootstrap would not be the same statistic"
        )
    uwer_ci = bootstrap_ratio(guard["numerators"], guard["denominators"], SEED, BOOTSTRAP_B)

    negative_opportunities = len(negatives)
    cp_upper = clopper_pearson_upper(negative_opportunities)
    unsupported_rows = [item for item in negatives if item.unsupported]
    false_term_rows = [
        item
        for item in negatives
        if any(
            contains_exact_term(item.m1_text, surface)
            and not contains_exact_term(item.row.reference.casefold(), surface.casefold())
            for surface in taught_surfaces
        )
    ]
    replay_domain_disagreements = sum(
        1
        for item in positives
        if item.m1_raw_hit is not None and item.m1_raw_hit != item.m1_hit
    )
    raw_domain_recall = sum(1 for item in positives if item.m1_raw_hit)
    raw_domain_available = sum(1 for item in positives if item.m1_raw_hit is not None)

    representable_positives = [
        item for item in positives if vectors.get(item.row.target_term_id or "") is not None
    ]
    forced_null_positives = [
        item for item in positives if vectors.get(item.row.target_term_id or "") is None
    ]
    domain_hits: dict[str, tuple[int, int]] = {}
    for item in positives:
        hit, total = domain_hits.get(item.row.domain, (0, 0))
        domain_hits[item.row.domain] = (hit + int(item.m1_hit), total + 1)

    named_present = {
        name: any(
            re.search(re.escape(name.split()[0]), item.row.reference, re.IGNORECASE) for item in negatives
        )
        for name in NAMED_ACTIVATION_CLASSES
    }
    token_map_sources: dict[str, int] = {}
    for item in outcomes:
        token_map_sources[item.token_map_source] = token_map_sources.get(item.token_map_source, 0) + 1

    elapsed = time.time() - started

    # --- artifacts ---------------------------------------------------------
    metrics: list[tuple[str, float]] = [
        ("recall_hits", overall["recall_hits"]),
        ("jargon_term_recall", overall["recall_hits"] / max(1, overall["positives"])),
        ("recall_hits_ci_lo", recall_ci[0]),
        ("recall_hits_ci_hi", recall_ci[1]),
        ("jargon_term_recall_ci_lo", recall_rate_ci[0]),
        ("jargon_term_recall_ci_hi", recall_rate_ci[1]),
        ("recall_hits_raw_domain", raw_domain_recall),
        ("recall_hits_raw_domain_opportunities", raw_domain_available),
        ("replay_domain_disagreements", replay_domain_disagreements),
        ("baseline_domain_disagreements", baseline_domain_disagreements),
        ("m0_recall_hits", overall["m0_recall_hits"]),
        ("lost_m0_hits", overall["lost_m0_hits"]),
        ("unsupported_activations", len(unsupported_rows)),
        (
            "unsupported_activations_per_1k",
            (len(unsupported_rows) / negative_opportunities * 1000.0) if negative_opportunities else 0.0,
        ),
        ("unsupported_activations_upper_per_1k", (cp_upper * 1000.0) if cp_upper is not None else -1.0),
        ("unsupported_activation_opportunities", negative_opportunities),
        ("jargon_false_terms", len(false_term_rows)),
        ("changed_span_precision", overall["changed_span_precision"]),
        ("changed_spans", overall["changed_spans"]),
        ("changed_spans_correct", overall["changed_spans_correct"]),
        ("critical_syntax_corruption", overall["critical_syntax_corruption"]),
        ("changed_rows_adapted_tail", overall["replay_changed_rows"]),
        ("accepted_rows", overall["accepted"]),
        ("candidate_id_accuracy", overall["candidate_id_correct"] / max(1, overall["positives"])),
        ("candidate_id_accuracy_ci_lo", id_ci[0]),
        ("candidate_id_accuracy_ci_hi", id_ci[1]),
        (
            "adapter_pair_rank_accuracy",
            (pair_rank_correct / pair_rank_opportunities) if pair_rank_opportunities else -1.0,
        ),
        ("adapter_pair_rank_accuracy_ci_lo", pair_rank_ci[0]),
        ("adapter_pair_rank_accuracy_ci_hi", pair_rank_ci[1]),
        ("adapter_pair_rank_opportunities", pair_rank_opportunities),
        ("state_identity_mismatches", state_identity_mismatches),
        ("uwer_general", guard["uwer_general"]),
        ("uwer_general_ci_lo", uwer_ci[0]),
        ("uwer_general_ci_hi", uwer_ci[1]),
        ("general_lattice_raw_agreement", guard["lattice_raw_agreement"]),
        ("permutation_p_value", permutation_p),
        ("recall_representable", sum(1 for item in representable_positives if item.m1_hit)),
        ("recall_representable_opportunities", len(representable_positives)),
        ("recall_forced_null", sum(1 for item in forced_null_positives if item.m1_hit)),
        ("recall_forced_null_opportunities", len(forced_null_positives)),
        ("unmappable_localization_rows", len(label_report["unmappable"])),
        ("contrastive_pairs_usable", len(usable_pairs)),
        ("contrastive_pairs_excluded", excluded_pairs),
        ("encoder_frames_total", total_frames),
        ("rows_total", len(rows)),
        ("embedding_rows", int(embedding.shape[0])),
        ("embedding_dim", int(embedding.shape[1])),
        ("model_parameters", PARAMETER_COUNT),
        ("tokenizer_lattice_tokens_checked", check["checked_tokens"]),
        ("tokenizer_lattice_match_rate", check["rate"]),
        ("runtime_seconds", elapsed),
    ]
    for fold in ("A", "B"):
        if fold in selection:
            metrics.append((f"selected_eta_fold_{fold.lower()}", selection[fold]["eta"]))
            metrics.append((f"selected_tau_fold_{fold.lower()}", selection[fold]["tau"]))
            metrics.append((f"fit_recall_hits_fold_{fold.lower()}", selection[fold]["fit"]["recall_hits"]))
    for name, report in identity.items():
        metrics.append((f"identity_{name.lower()}_state_mismatches", report["state_mismatches"]))
        metrics.append((f"identity_{name.lower()}_text_mismatches", report["text_mismatches"]))
        metrics.append((f"identity_{name.lower()}_final_mismatches", report["final_text_mismatches"]))
    for domain, (hit, total) in sorted(domain_hits.items()):
        metrics.append((f"recall_hits_domain_{domain}", hit))
        metrics.append((f"recall_domain_{domain}", hit / total if total else 0.0))
    for name, present in named_present.items():
        key = name.replace("+", "plus").replace("#", "sharp")
        metrics.append((f"activation_class_present_{key}", int(present)))

    metrics_path = output / "metrics.jsonl"
    refuse_overwrite(metrics_path)
    write_jsonl(
        metrics_path,
        [{"run": METRICS_RUN, "metric": name, "value": finite(value)} for name, value in metrics],
    )

    rows_out_path = output / "rows.jsonl"
    refuse_overwrite(rows_out_path)
    write_jsonl(
        rows_out_path,
        [
            {
                "row_id": item.row.row_id,
                "fold": item.row.fold,
                "domain": item.row.domain,
                "label_canonical": item.row.canonical if item.row.is_positive else None,
                "label_is_null": not item.row.is_positive,
                "label_source": item.row.label_source,
                "label_span": list(item.row.label_span) if item.row.label_span else None,
                "label_frame": item.row.label_frame,
                "provenance_contrastive_pair": (item.row.contrastive or {}).get("negative_counterpart_id"),
                "provenance_contrastive_status": (item.row.contrastive or {}).get("counterpart_status"),
                "snapshot_ids": item.row.glossary,
                "snapshot_size": len(item.row.glossary),
                "target_term_id": item.row.target_term_id,
                "selected_term_id": item.decision.term_id if item.accepted else None,
                "selected_canonical": item.decision.canonical if item.accepted else None,
                "argmax_term_id": item.decision.term_id,
                "argmax_canonical": item.decision.canonical,
                "selected_null": not item.accepted,
                "structural_null": item.decision.structural_null,
                "score": item.decision.score,
                "probability": item.decision.probability,
                "null_probability": item.decision.null_probability,
                "tau": selection[item.row.fold]["tau"],
                "eta": selection[item.row.fold]["eta"],
                "frame": item.decision.frame,
                "frame_window": list(item.decision.window),
                "changed_span": list(item.changed_span) if item.changed_span else None,
                "changed_frames": list(item.changed_frames) if item.changed_frames else None,
                "target_span": list(item.target_span) if item.target_span else None,
                "changed_span_frame_overlap": item.frame_overlap,
                "replaced_text": item.replaced,
                "token_map_source": item.token_map_source,
                "render_mode": item.render_mode,
                "m0_text": item.m0_text,
                "m0_sha256": sha256_text(item.m0_text),
                "m1_text": item.m1_text,
                "m1_sha256": sha256_text(item.m1_text),
                "m1_raw_text": item.m1_raw_text,
                "m0_hit": item.m0_hit,
                "m1_hit": item.m1_hit,
                "m1_raw_hit": item.m1_raw_hit,
                "lost_m0_hit": item.m0_hit and not item.m1_hit,
                "candidate_id_correct": bool(
                    item.accepted and item.decision.canonical == item.row.canonical
                ),
                "changed_span_correct": item.span_correct,
                "unsupported_surfaces": item.unsupported,
                "critical_syntax_corruption": item.corrupting,
                "replay_changed_raw": item.replay_changed,
            }
            for item in sorted(outcomes, key=lambda entry: entry.row.row_id)
        ],
    )

    embedding_meta = {
        "tensor": EMBED_TENSOR_NAME,
        "n_dims": embed_record.n_dims,
        "ne": list(embed_record.ne),
        "ggml_type": embed_record.ggml_type,
        "ggml_type_name": GGML_TYPE_NAMES[embed_record.ggml_type],
        "payload_offset": embed_record.payload_offset,
        "payload_bytes": embed_record.payload_bytes,
        "payload_sha256": EMBED_EXPECTED["payload_sha256"],
        "f32_shape": [int(embedding.shape[0]), int(embedding.shape[1])],
        "hparams": model.hparams,
        "tdt_durations": list(model.tdt_durations),
        "tensor_records": len(model.records),
        "vocab_tokens": len(model.id_to_token),
        "blank_id": tokenizer.blank_id,
        "unk_id": tokenizer.unk_id,
        "max_token_bytes": tokenizer.max_token_bytes,
    }
    embedding_meta_path = output / "embedding-metadata.json"
    refuse_overwrite(embedding_meta_path)
    embedding_meta_path.write_text(json.dumps(embedding_meta, indent=2, sort_keys=True), encoding="utf-8")

    script_path = Path(__file__).resolve()
    pins = {
        "general_corpus_sha256": sha256_file(args.general_corpus),
        "jargon_corpus_sha256": sha256_file(args.jargon_manifest),
        "jargon_terms_sha256": sha256_file(args.terms),
        "repair_vocabulary_sha256": sha256_file(args.repair_vocabulary),
        "coreml_encoder": str(
            repo / ".build/asr-research/three-bets/palettize6/standard/parakeet_encoder_6bit.mlmodelc"
        ),
        "coreml_encoder_digest": PINNED["coreml_encoder_digest"],
        "coreml_max_s": PINNED["coreml_max_s"],
        "coreml_encoder_short": str(
            repo / ".build/asr-research/three-bets/palettize6/short/parakeet_encoder_6bit.mlmodelc"
        ),
        "coreml_short_digest": PINNED["coreml_short_digest"],
        "coreml_short_max_s": PINNED["coreml_short_max_s"],
        "coreml_encoder_tiny": str(
            repo / ".build/asr-research/three-bets/palettize6/tiny/parakeet_encoder_6bit.mlmodelc"
        ),
        "coreml_tiny_digest": PINNED["coreml_tiny_digest"],
        "coreml_tiny_max_s": PINNED["coreml_tiny_max_s"],
        "assist_model_sha256": "none",
        "assist_model_2_sha256": "none",
        "assist_model_3_sha256": "none",
        "assist_model_4_sha256": "none",
        "assist_model_5_sha256": "none",
        "model_sha256": sha256_file(args.model),
        "model_bytes": args.model.stat().st_size,
        "sidecar_sha256": "none",
        "bench_sha256": sha256_file(args.tail_runner) if args.tail_runner.exists() else "none",
    }
    for key in (
        "general_corpus_sha256",
        "jargon_corpus_sha256",
        "jargon_terms_sha256",
        "repair_vocabulary_sha256",
        "model_sha256",
    ):
        if pins[key] != PINNED[key]:
            fail(f"{key} is {pins[key]}, the preregistration pins {PINNED[key]}")
    if pins["model_bytes"] != PINNED["model_bytes"]:
        fail(f"model_bytes is {pins['model_bytes']}, the preregistration pins {PINNED['model_bytes']}")
    if sha256_file(args.jargon_lattice) != PINNED["jargon_lattice_sha256"]:
        fail("the jargon lattice digest is not the preregistered one")
    if sha256_file(args.general_lattice) != PINNED["general_lattice_sha256"]:
        fail("the general lattice digest is not the preregistered one")

    manifest_out_path = output / "manifest.json"
    refuse_overwrite(manifest_out_path)
    manifest_out_path.write_text(
        json.dumps(
            {
                "run": METRICS_RUN,
                "track": "glossary-conditioned-decoding",
                "workstream": "precision-recall",
                "wave": "wave1",
                "run_ordinal": 1,
                "stage": "stage2",
                "stage2_coreml_loaded": False,
                "prereg_path": str(args.prereg),
                "prereg_sha256": sha256_file(args.prereg) if args.prereg.exists() else "none",
                "prereg_freeze_commit": PREREG_FREEZE_COMMIT,
                "dry_run": bool(args.dry_run),
                "stub_replay": bool(stub),
                "pins": pins,
                "environment": environment_identity(),
                "screen_inputs": {
                    "states": str(states_path),
                    "states_sha256": sha256_file(states_path),
                    "states_bytes": pack.size,
                    "index": str(index_path),
                    "index_sha256": sha256_file(index_path),
                    "baseline_rows": str(baseline_rows_path) if baseline_rows_path.exists() else "none",
                    "baseline_rows_sha256": (
                        sha256_file(baseline_rows_path) if baseline_rows_path.exists() else "none"
                    ),
                    "jargon_manifest": str(args.jargon_manifest),
                    "jargon_lattice": str(args.jargon_lattice),
                    "jargon_lattice_sha256": sha256_file(args.jargon_lattice),
                    "general_lattice": str(args.general_lattice),
                    "general_lattice_sha256": sha256_file(args.general_lattice),
                    "general_corpus": str(args.general_corpus),
                    "general_results": str(args.general_results),
                    "general_results_sha256": sha256_file(args.general_results),
                    "contrastive_rows": str(args.contrastive_rows),
                    "contrastive_rows_sha256": sha256_file(args.contrastive_rows),
                    "repair_vocabulary": str(args.repair_vocabulary),
                    "tail_runner": str(args.tail_runner),
                    "tail_runner_sha256": pins["bench_sha256"],
                    "script": str(script_path),
                    "script_sha256": sha256_file(script_path),
                    "numpy": np.__version__,
                    "python": sys.version.split()[0],
                    "encoder_frames_total": total_frames,
                    "rows_total": len(rows),
                },
                "embedding": embedding_meta,
                "tokenizer_check": {
                    "checked_tokens": check["checked_tokens"],
                    "mismatches": check["mismatches"],
                    "match_rate": check["rate"],
                    "round_trip_rows": check["round_trip_rows"],
                    "round_trip_failures": check["round_trip_failures"],
                    "unrepresentable": list(observed_unrepresentable),
                },
                "folds": {
                    fold: {
                        "selected_eta": selection[fold]["eta"],
                        "selected_tau": selection[fold]["tau"],
                        "fit": selection[fold]["fit"],
                        "training": {
                            key: value for key, value in fold_reports[fold].items() if key != "history"
                        },
                    }
                    for fold in selection
                },
                "identity_controls": identity,
                "localization": {
                    "sources": label_report["sources"],
                    "unmappable": label_report["unmappable"],
                },
                "contrastive": {
                    "rows": len(contrastive_all),
                    "usable_pairs": len(usable_pairs),
                    "excluded": excluded_pairs,
                    "counterpart_ids": counterpart_ids,
                    "pair_rank_excluded": pair_rank_excluded,
                },
                "token_map_sources": token_map_sources,
                "named_activation_classes_present": named_present,
                "replay_invocations": replay_argv,
                "deviations": list(DEVIATIONS),
                "runtime_seconds": elapsed,
            },
            indent=2,
            sort_keys=True,
        ),
        encoding="utf-8",
    )

    command_path = output / "command.txt"
    if not command_path.exists():
        command_path.write_text(
            "cd /Users/vlad/Desktop/voiceoour && env PYTHONHASHSEED=0 VECLIB_MAXIMUM_THREADS=6 "
            "bench/.venv/bin/python "
            + " ".join([str(script_path), *sys.argv[1:]])
            + "\n",
            encoding="utf-8",
        )

    # --- disposition -------------------------------------------------------
    recall = overall["recall_hits"]
    kill_reasons: list[str] = []
    if recall < BAR_KILL:
        kill_reasons.append(f"recall_hits {recall} < {BAR_KILL}")
    if unsupported_rows:
        kill_reasons.append(f"{len(unsupported_rows)} unsupported activations")
    if false_term_rows:
        kill_reasons.append(f"jargon_false_terms {len(false_term_rows)} > 0")
    if overall["lost_m0_hits"]:
        kill_reasons.append(f"{overall['lost_m0_hits']} lost M0 hits")
    if overall["changed_span_precision"] != 1.0:
        kill_reasons.append(f"changed_span_precision {overall['changed_span_precision']:.6f} != 1.0")
    if overall["critical_syntax_corruption"]:
        kill_reasons.append(f"critical_syntax_corruption {overall['critical_syntax_corruption']} > 0")
    for name, report in identity.items():
        if report["state_mismatches"] or report["text_mismatches"] or report["final_text_mismatches"]:
            kill_reasons.append(f"identity {name} mismatch")
    if guard["uwer_general"] > UWER_GENERAL_CEILING:
        kill_reasons.append(f"uwer_general {guard['uwer_general']:.6f} > {UWER_GENERAL_CEILING}")
    if elapsed > RUNTIME_CEILING_S:
        kill_reasons.append(f"runtime {elapsed / 3600:.2f} h > 8 h")
    if kill_reasons:
        disposition = "KILL"
    elif recall >= BAR_STRONG:
        disposition = "STRONG"
    elif recall >= BAR_MEANINGFUL:
        disposition = "MEANINGFUL"
    else:
        disposition = "NO EFFECT"

    verdict_path = (args.verdict or (output.parent / "verdict.md")).resolve()
    refuse_overwrite(verdict_path)
    verdict_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Verdict - glossary-conditioned-decoding, Wave 1 (state-dump + cached-replay pilot)",
        "",
        f"Disposition: **{disposition}**" + (" - " + "; ".join(kill_reasons) if kill_reasons else ""),
        "",
        f"Preregistration freeze commit `{PREREG_FREEZE_COMMIT}`; run `{METRICS_RUN}`; "
        f"runtime {elapsed / 60:.1f} min."
        + (
            " **Dry run with a fabricated state pack and a stubbed replay: not evidence.**"
            if (args.dry_run or stub)
            else ""
        ),
        "",
        "## Primary and guards",
        "",
        "| endpoint | value | bar |",
        "|---|---|---|",
        f"| `recall_hits` (cross-fitted over {overall['positives']} positives) | {recall} | "
        f">= {BAR_MEANINGFUL} meaningful, >= {BAR_STRONG} strong, < {BAR_KILL} kill |",
        f"| `jargon_term_recall` | {recall / max(1, overall['positives']):.6f} | - |",
        f"| `recall_hits` 95% cluster bootstrap | [{recall_ci[0]:.1f}, {recall_ci[1]:.1f}] | - |",
        f"| M0 (structural null) `recall_hits` | {overall['m0_recall_hits']} | reference |",
        f"| lost M0 hits | {overall['lost_m0_hits']} | 0 |",
        f"| `unsupported_activations_per_1k` | "
        f"{(len(unsupported_rows) / negative_opportunities * 1000.0) if negative_opportunities else 0.0:.3f}"
        f" ({len(unsupported_rows)} of {negative_opportunities} opportunities) | 0 |",
        f"| one-sided 95% Clopper-Pearson upper, per 1k | "
        f"{(cp_upper * 1000.0) if cp_upper is not None else float('nan'):.3f} | reported; zero is never "
        "certainty |",
        f"| `jargon_false_terms` | {len(false_term_rows)} | 0 |",
        f"| `changed_span_precision` | {overall['changed_span_precision']:.6f} "
        f"({overall['changed_spans_correct']}/{overall['changed_spans']}) | 1.0 |",
        f"| `critical_syntax_corruption` | {overall['critical_syntax_corruption']} | 0 |",
        f"| `uwer_general` (structural empty-glossary branch) | {guard['uwer_general']:.6f} "
        f"[{uwer_ci[0]:.6f}, {uwer_ci[1]:.6f}] | <= {UWER_GENERAL_CEILING} |",
        f"| paired permutation p ({len(gains)} clusters, {PERMUTATION_FLIPS} flips) | "
        f"{permutation_p:.6f} | - |",
        "",
        "Identity controls: " + json.dumps(identity, sort_keys=True),
        "",
        "## Secondaries (never promoted)",
        "",
        f"- `candidate_id_accuracy` = {overall['candidate_id_correct']}/{overall['positives']} = "
        f"{overall['candidate_id_correct'] / max(1, overall['positives']):.6f} "
        f"[{id_ci[0]:.6f}, {id_ci[1]:.6f}]",
        f"- `adapter_pair_rank_accuracy` = {pair_rank_correct}/{pair_rank_opportunities}"
        + (f"; excluded {json.dumps(pair_rank_excluded, sort_keys=True)}" if pair_rank_excluded else ""),
        f"- `state_identity_mismatches` = {state_identity_mismatches}",
        f"- changed rows from the adapted TDT tail = {overall['replay_changed_rows']}",
        "- recall by domain: "
        + ", ".join(f"{domain} {hit}/{total}" for domain, (hit, total) in sorted(domain_hits.items())),
        f"- representable canonicals {sum(1 for item in representable_positives if item.m1_hit)}/"
        f"{len(representable_positives)}; forced-null canonicals "
        f"{sum(1 for item in forced_null_positives if item.m1_hit)}/{len(forced_null_positives)}",
        f"- named activation classes present among the negatives: {json.dumps(named_present, sort_keys=True)}",
        f"- raw-domain cross-check: {raw_domain_recall}/{raw_domain_available} available, "
        f"{replay_domain_disagreements} disagreements with the shipped final domain",
        f"- token map sources: {json.dumps(token_map_sources, sort_keys=True)}",
        "",
        "## Operating points",
        "",
    ]
    for fold in sorted(selection):
        entry = selection[fold]
        lines.append(
            f"- fold {fold}: eta={entry['eta']:g}, tau={entry['tau']:.12g}; fit recall_hits="
            f"{entry['fit']['recall_hits']}, fit unsupported={entry['fit']['unsupported_activations']}, "
            f"fit lost M0={entry['fit']['lost_m0_hits']}, fit changed_span_precision="
            f"{entry['fit']['changed_span_precision']:.6f}"
        )
    lines += [
        "",
        "## Inputs",
        "",
        f"- state pack `{states_path}`: {pack.size} bytes, {total_frames} encoder frames, {len(rows)} rows",
        f"- index `{index_path}`",
        f"- decoder embedding `{EMBED_TENSOR_NAME}`: "
        f"{GGML_TYPE_NAMES[embed_record.ggml_type]} {list(embed_record.ne)} at byte "
        f"{embed_record.payload_offset}, {embed_record.payload_bytes} bytes, payload sha256 verified "
        f"against the preregistration",
        f"- tokenizer: {check['checked_tokens']} cached-lattice chosen tokens, "
        f"{check['mismatches']} mismatches; {check['round_trip_rows']} transcript round trips, "
        f"{len(check['round_trip_failures'])} failures",
        f"- contrastive pairs: {len(usable_pairs)} usable of {len(contrastive_all)} rows",
        f"- localization label sources: {json.dumps(label_report['sources'], sort_keys=True)}",
        f"- model parameters: {PARAMETER_COUNT} across {len(PARAM_NAMES)} tensors",
        "",
        "## Deviations",
        "",
        "The preregistration is silent on each item below, or the frozen semantics were not "
        "reachable from Stage 2. None of them changes an endpoint, split, bar, or hyper-parameter.",
        "",
    ]
    for number, item in enumerate(DEVIATIONS, start=1):
        lines.append(f"{number}. {item}")
    verdict_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    wave_prereg = output.parent / "prereg.md"
    if args.prereg.exists() and not wave_prereg.exists():
        wave_prereg.write_text(
            args.prereg.read_text(encoding="utf-8") + f"\n\nFreeze commit: {PREREG_FREEZE_COMMIT}\n",
            encoding="utf-8",
        )

    log(
        f"disposition {disposition}: recall_hits={recall} m0={overall['m0_recall_hits']} "
        f"unsupported={len(unsupported_rows)} uwer_general={guard['uwer_general']:.6f} "
        f"p={permutation_p:.6f}"
    )
    log(f"artifacts under {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
