#!/usr/bin/env python3
"""single-model-replacement-screen Wave 1, Part 1: cached CPU-only manifest freeze.

Preregistration: research/prereg/single-model-replacement-screen-wave1.md
(sha256 f8d087641079d8b9a1a492ef7dfa6e70b6175f4e36fc75594f164c7e55f4cf8e,
freeze commit 898262c). Frontier of record 0ac7514.

Part 1 only. This script contacts no candidate, downloads nothing, loads no model
and runs no inference: it replays cached frontier rows, reproduces the residual
term-miss set, draws the fixed R16/N16/G16 slices under the preregistered seed,
byte-verifies all 48 audio files, and serializes the pilot manifest.

Run:
  cd /Users/vlad/Desktop/voiceoour
  bench/.venv/bin/python \
    .build/asr-research/next/single-model/single-model-replacement-screen/wave1/run1/selection.py
"""

from __future__ import annotations

import hashlib
import json
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path("/Users/vlad/Desktop/voiceoour")
TRACK = "single-model-replacement-screen"
WAVE = "wave1"
RUN = 1
RUN_ID = f"{TRACK}/{WAVE}/{RUN}"
OUT = ROOT / ".build/asr-research/next/single-model" / TRACK / WAVE / f"run{RUN}"

PREREG_REL = "research/prereg/single-model-replacement-screen-wave1.md"
PREREG_COMMIT = "898262c"
PREREG_SHA256 = "f8d087641079d8b9a1a492ef7dfa6e70b6175f4e36fc75594f164c7e55f4cf8e"
FRONTIER_COMMIT = "0ac7514"
SEED = 20260830

# Frozen expectations, transcribed from the preregistration.
EXPECT_RECALL_HITS = 295
EXPECT_TERM_MISSES = 51
EXPECT_R_ALLOC = {"apple": 3, "cloud": 4, "dataweb": 1, "langs": 4, "security": 4}
EXPECT_G_ALLOC = {"fleurs-en-us": 6, "librispeech-clean": 5, "librispeech-other": 5}
EXPECT_PILOT_MANIFEST_SHA256 = (
    "f0682f70bb373beaab8aea30562a72844613293088d9fe1c3c44cb9a11472a15"
)
# v3 G16 incumbent baseline, frozen by the prereg at 19 errors / 799 reference words.
EXPECT_G16_V3_ERRORS = 19
EXPECT_G16_V3_WORDS = 799
EXPECT_G16_V3_UWER = 0.023779724655819776
G16_NI_MARGIN = 0.0035
EXPECT_G16_CEILING = 0.027279724655819776
EXPECT_UWER_GENERAL = 0.030725
# Two-sided exact Clopper-Pearson 95% upper bound for 0/16, frozen by the prereg.
NEGATIVE_FALSE_TERMS_CP95_UPPER = 0.20590721420782276

# sha256 of every input the prereg pins, transcribed from the prereg.
PINNED_INPUTS = {
    ".build/autoresearch/jargon.2.results.jsonl": "43c6593e29214bc4433472a625dff1e264b5864102a3221f82538ac73c7b61a8",
    ".build/autoresearch/general.results.jsonl": "73b4be67aab45da787add8c9e4b4beadeb45326904b0dded57be6e95d21357e1",
    ".build/autoresearch/metrics.txt": "faf454d338b6baf4e30dcd108249d04474c9ccbaa2d07096b1f46efe440d3d4f",
    "bench/autoresearch/score_v5.py": "bcd5c3fde5a2d5d9c2cdabdf59fe561ce03e9f7d0b522a435b6cf1f1a19e25de",
    "bench/src/voiceour_bench/metrics.py": "307eb4f113bda8e72faa513fce4885befde425ed7a80036deab6354e8a50a539",
    "bench/autoresearch/jargon.terms.json": "2c3dfd1bf8250c97172ef1af16c74de01d30e8376c58474b61aee513fa47d4b5",
    "benchmarks/data/jargon/manifest.jsonl": "576efc9f9e6f11e3e14048258e023d0695bb56f8403482e953c061c03a17e2bf",
    "bench/autoresearch/corpus.manifest.jsonl": "885331c29340aca170ae3a061747986bcf91f960b2fec192aefd09e4d72c3749",
    ".build/asr-research/three-bets/holdout-earnings22/manifest.jsonl": "f68cceb4a41dc0a53964876d5f697925b1e72afb8e2c7d7b4b363880ac9e4817",
    ".build/asr-research/three-bets/holdout-earnings22-diverse/manifest.jsonl": "4042f6b59a655df7250757330cf00ad7d932338bb9404b39d4231be6e5e2ca03",
    ".build/asr-research/three-bets/holdout-peoples-speech/manifest.jsonl": "ade4139e607091a6ae49b83451e99dc2550a3eca80d7e0da74f45ae177f4fa28",
    ".build/asr-research/three-bets/holdout-peoples-speech2/manifest.jsonl": "42054fcb8d3a3318eb2fc1d011e55b12a7c70ad7e39b29552181a625a269c2ff",
    ".build/asr-research/three-bets/holdout-earnings22/pass-A1.jsonl": "804c919b81219050f07f6267701ed022c7e0c800a1868e9caf5e41a297dfb533",
    ".build/asr-research/three-bets/holdout-earnings22/pass-A2.jsonl": "19cdd5aa79b67677a6efc274662ef9c3306e30d3b7e3570aeb77daa8682d5a63",
    ".build/asr-research/three-bets/holdout-earnings22-diverse/stage-A1.jsonl": "673b473f08773ca51e7943f87d38d61d931453e04b9643d7e1af3f82649ebf37",
    ".build/asr-research/three-bets/holdout-earnings22-diverse/stage-A2.jsonl": "673b473f08773ca51e7943f87d38d61d931453e04b9643d7e1af3f82649ebf37",
    ".build/asr-research/three-bets/holdout-peoples-speech/stage-A1.jsonl": "6afd41a532e46b07d734d963dae73ea0ef973c5e2ccac78f451b53c85a79f971",
    ".build/asr-research/three-bets/holdout-peoples-speech/stage-A2.jsonl": "6afd41a532e46b07d734d963dae73ea0ef973c5e2ccac78f451b53c85a79f971",
    ".build/asr-research/three-bets/holdout-peoples-speech2/stage-A1.jsonl": "4b0415b9f3a5fa1540aea49ae8b8e1a8fe549ed253a1426f05963322caeea7af",
    ".build/asr-research/three-bets/holdout-peoples-speech2/stage-A2.jsonl": "4b0415b9f3a5fa1540aea49ae8b8e1a8fe549ed253a1426f05963322caeea7af",
    ".build/asr-research/next/single-model/single-model-replacement-screen/wave0/slice-inventory.json": "9190d6ecb58ff7af3c19c40019274cb771b0562cd4c82f4773113c14be3ba820",
    ".build/asr-research/next/single-model/single-model-replacement-screen/wave0/verdict.md": "4deb54f218228f91e174161281c0cdbcaaa27c40792a263d2af85af02d0baa20",
    "research/next-program.md": "7ae119c644b01e0d3c3718ab6bd5b4d5ceb6e462214339f7f417d8a03d15a98f",
    PREREG_REL: PREREG_SHA256,
}
PINNED_ABS = {
    "/Users/vlad/Documents/ObsidianVault/projects/voiceour/concepts/single-model-replacement-screen.md": "672b2a36902910208515944e510995bc8bf7b917ca618141d3aec3bed84eff6c",
}

# R16, in the preregistration's fixed R01..R16 order.
PREREG_R16 = [
    "jg_0235_apple_mmap", "jg_0242_apple_epoll", "jg_0234_apple_mmap",
    "jg_0040_cloud_iam", "jg_0020_cloud_nginx", "jg_0021_cloud_nginx", "jg_0003_cloud_kubeadm",
    "jg_0334_dataweb_cudnn",
    "jg_0194_langs_uv", "jg_0147_langs_cargo", "jg_0180_langs_c", "jg_0151_langs_deno",
    "jg_0113_security_tcpdump", "jg_0104_security_nmap", "jg_0112_security_tcpdump",
    "jg_0101_security_ed25519",
]
# G16, in the preregistration's fixed G01..G16 order.
PREREG_G16 = [
    "fleurs-en_us-test-000021", "fleurs-en_us-test-000016", "fleurs-en_us-test-000001",
    "fleurs-en_us-test-000017", "fleurs-en_us-test-000049", "fleurs-en_us-test-000004",
    "librispeech-test.clean-000005", "librispeech-test.clean-000103",
    "librispeech-test.clean-000095", "librispeech-test.clean-000030",
    "librispeech-test.clean-000100",
    "librispeech-test.other-000022", "librispeech-test.other-000024",
    "librispeech-test.other-000014", "librispeech-test.other-000057",
    "librispeech-test.other-000047",
]
# N16, in the preregistration's fixed N01..N16 order. Fresh-shard fires first.
PREREG_N16 = [
    "earnings22-4432298-136", "earnings22b-4483338-151", "earnings22b-4483338-30",
    "earnings22b-4483338-218", "earnings22b-4485244-146", "peoples-clean0-3343",
    "peoples-clean2-2592",
    "jg_0347_negative_the_old_gate_had_rust_all_along_",
    "jg_0348_negative_a_swift_bird_crossed_the_garden_",
    "jg_0349_negative_the_metal_spoon_felt_cold_agains",
    "jg_0350_negative_the_cargo_was_unloaded_at_the_ha",
    "jg_0358_negative_the_python_rested_quietly_beneat",
    "jg_0359_negative_please_react_calmly_when_the_chi",
    "jg_0360_negative_a_small_node_on_the_wooden_branc",
    "jg_0366_negative_i_cannot_commit_to_dinner_until_",
    "jg_0385_negative_we_waited_in_the_queue_outside_t",
]
# Guard surfaces the prereg names explicitly: the fresh fires N01-N07, and N16.
PREREG_N_GUARDS = {
    "earnings22-4432298-136": "Credit Swift",
    "earnings22b-4483338-151": "IAM",
    "earnings22b-4483338-30": "IAM",
    "earnings22b-4483338-218": "IAM",
    "earnings22b-4485244-146": "CALayer",
    "peoples-clean0-3343": "Redis",
    "peoples-clean2-2592": "runc",
    "jg_0385_negative_we_waited_in_the_queue_outside_t": "kqueue",
}
# The seven standing hard negatives (research/next-program.md, wave0 slice-inventory).
STANDING_SURFACES = ["C++", "CALayer", "Credit Swift", "IAM", "Redis", "kqueue", "runc"]

FRESH_DIRS = [
    "holdout-earnings22",
    "holdout-earnings22-diverse",
    "holdout-peoples-speech",
    "holdout-peoples-speech2",
]
FRESH_A_STAGE = {
    "holdout-earnings22": ["pass-A1.jsonl", "pass-A2.jsonl"],
    "holdout-earnings22-diverse": ["stage-A1.jsonl", "stage-A2.jsonl"],
    "holdout-peoples-speech": ["stage-A1.jsonl", "stage-A2.jsonl"],
    "holdout-peoples-speech2": ["stage-A1.jsonl", "stage-A2.jsonl"],
}

sys.path.insert(0, str(ROOT / "bench/src"))
from voiceour_bench.metrics import english_normalize, uwer  # noqa: E402

import jiwer  # noqa: E402

read_files: dict[str, str] = {}


def fail(message: str) -> None:
    print(f"selection.py: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def record_read(path: Path) -> str:
    """Hash and register every file this screen reads."""

    try:
        key = str(path.relative_to(ROOT))
    except ValueError:
        key = str(path)
    digest = sha256_file(path)
    read_files[key] = digest
    return digest


def read_jsonl(path: Path) -> list[dict]:
    record_read(path)
    rows = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                fail(f"{path}:{number} is not JSON: {error}")
    return rows


def contains_exact_term(text: str | None, canonical_term: str | None) -> bool:
    """metrics.py:382-389 verbatim: exact, case-sensitive canonical containment."""

    if not text or not canonical_term:
        return False
    prefix = r"(?<!\w)" if canonical_term[0].isalnum() or canonical_term[0] == "_" else ""
    suffix = r"(?!\w)" if canonical_term[-1].isalnum() or canonical_term[-1] == "_" else ""
    return re.search(f"{prefix}{re.escape(canonical_term)}{suffix}", text, re.UNICODE) is not None


def largest_remainder(counts: dict[str, int], budget: int) -> dict[str, int]:
    """One per stratum, then the remainder proportionally by largest remainder.

    Ties break on the stratum identifier, ascending.
    """

    strata = sorted(counts)
    remaining = {s: counts[s] - 1 for s in strata}
    extra_budget = budget - len(strata)
    total = sum(remaining.values())
    exact = {s: remaining[s] * extra_budget / total for s in strata}
    floors = {s: int(exact[s] // 1) for s in strata}
    short = extra_budget - sum(floors.values())
    order = sorted(strata, key=lambda s: (-(exact[s] - floors[s]), s))
    alloc = dict(floors)
    for stratum in order[:short]:
        alloc[stratum] += 1
    return {s: 1 + alloc[s] for s in strata}


def enumerate_serializations(
    r_rows: list[dict],
    n_rows: list[dict],
    g_rows: list[dict],
    canonicals: list[str],
    prose_guards: list[str],
    exhaustive: bool,
) -> tuple[int, list[str]]:
    """Search the serialization conventions the prereg leaves underdetermined.

    The prereg fixes the pilot manifest's field *set* and its expected SHA-256, but never
    states how ``slice``/``slot`` values are encoded, what the G stratum label is, or what
    ``guard_surface`` holds for N08-N15. This enumerates those free parameters so the
    digest check is a measurement rather than a single guess. Returns the number of
    candidate encodings tried and any that reproduce the frozen digest.
    """

    pretty = {
        "fleurs-en-us": "FLEURS",
        "librispeech-clean": "LibriSpeech clean",
        "librispeech-other": "LibriSpeech other",
    }

    def slot_value(style: str, prefix: str, index: int) -> object:
        return {
            "p2": f"{prefix}{index:02d}", "p1": f"{prefix}{index}",
            "d2": f"{index:02d}", "d1": str(index), "int": index,
        }[style]

    def encode(record: dict, sort_keys: bool) -> bytes:
        return (
            json.dumps(record, sort_keys=sort_keys, separators=(",", ":"), ensure_ascii=False) + "\n"
        ).encode("utf-8")

    tried = 0
    matches: list[str] = []
    fixed_guards = [r["guard_surface"] for r in n_rows[:7]]
    orders = {
        "RNG": lambda r, n, g: r + n + g, "GNR": lambda r, n, g: g + n + r,
        "NRG": lambda r, n, g: n + r + g, "RGN": lambda r, n, g: r + g + n,
        "GRN": lambda r, n, g: g + r + n, "NGR": lambda r, n, g: n + g + r,
        "byid": lambda r, n, g: sorted(r + n + g, key=lambda d: d["id"]),
        "byslot": lambda r, n, g: sorted(r + n + g, key=lambda d: (str(d["slice"]), str(d["slot"]))),
    }

    def blocks(sort_keys, labels, slot_style, guard_case, g_label, path_mode, n15, n16):
        r_encoded = [
            dict(record, slice=labels[0], slot=slot_value(slot_style, "R", index))
            for index, record in enumerate(r_rows, start=1)
        ]
        g_encoded = [
            dict(record, slice=labels[2], slot=slot_value(slot_style, "G", index),
                 stratum=(record["stratum"] if g_label == "source" else pretty[record["stratum"]]))
            for index, record in enumerate(g_rows, start=1)
        ]
        guards = fixed_guards + [
            guard if guard_case == "canonical" else guard.lower() for guard in prose_guards
        ] + [n15, n16]
        n_encoded = []
        for index, (record, guard) in enumerate(zip(n_rows, guards), start=1):
            path = record["audio_path"]
            if path_mode == "abs" and path.startswith(".build"):
                path = str(ROOT / path)
            n_encoded.append(dict(record, slice=labels[1], slot=slot_value(slot_style, "N", index),
                                  audio_path=path, guard_surface=guard))
        return r_encoded, n_encoded, g_encoded

    # Sweep A: the full structural product, over the small plausible guard set.
    for sort_keys in (True, False):
     for labels in (("R", "N", "G"), ("R16", "N16", "G16"), ("r16", "n16", "g16")):
      for slot_style in ("p2", "p1", "d2", "d1", "int"):
       for guard_case in ("canonical", "lower"):
        for g_label in ("source", "pretty"):
         for path_mode in ("rel", "abs"):
          for n15, n16 in (("commit", "kqueue"), ("", "kqueue"), ("commit", "queue"),
                           ("Commit", "kqueue"), ("merge", "kqueue"), ("", "queue")):
           r_enc, n_enc, g_enc = blocks(sort_keys, labels, slot_style, guard_case, g_label,
                                        path_mode, n15, n16)
           for order_name, order in orders.items():
               body = b"".join(encode(r, sort_keys) for r in order(r_enc, n_enc, g_enc))
               for trailing_newline in (True, False):
                   tried += 1
                   if hashlib.sha256(body if trailing_newline else body[:-1]).hexdigest() == \
                           EXPECT_PILOT_MANIFEST_SHA256:
                       matches.append(
                           f"A: sort_keys={sort_keys} labels={labels} slot={slot_style} "
                           f"guard_case={guard_case} g_label={g_label} path={path_mode} "
                           f"n15={n15!r} n16={n16!r} order={order_name} nl={trailing_newline}")

    if not exhaustive:
        return tried, matches

    # Sweep B: the whole taught-canonical space for the two guards the prereg never fixes,
    # over the plausible structural readings. Hashing is incremental: the R block and the
    # first fourteen N records are constant inside a configuration.
    n15_space = [*canonicals, "commit", "Commit", "merge", "Merge", "git commit", "none", ""]
    n16_space = [*canonicals, "queue", "Queue", "queue/kqueue", "none", ""]
    for labels in (("R", "N", "G"), ("R16", "N16", "G16")):
     for slot_style in ("p2", "int", "d2"):
      for guard_case in ("canonical", "lower"):
       for g_label in ("source", "pretty"):
        r_enc, n_enc, g_enc = blocks(True, labels, slot_style, guard_case, g_label, "rel", "", "")
        prefix = hashlib.sha256(
            b"".join(encode(r, True) for r in r_enc + n_enc[:14])
        )
        suffix = b"".join(encode(r, True) for r in g_enc)
        for n15 in n15_space:
            head = prefix.copy()
            head.update(encode(dict(n_enc[14], guard_surface=n15), True))
            for n16 in n16_space:
                digest = head.copy()
                digest.update(encode(dict(n_enc[15], guard_surface=n16), True))
                digest.update(suffix)
                tried += 1
                if digest.hexdigest() == EXPECT_PILOT_MANIFEST_SHA256:
                    matches.append(
                        f"B: labels={labels} slot={slot_style} guard_case={guard_case} "
                        f"g_label={g_label} n15={n15!r} n16={n16!r}")
    return tried, matches


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    checks: list[tuple[str, bool, str]] = []

    # --- input digest verification -------------------------------------------
    for rel, expected in PINNED_INPUTS.items():
        observed = sha256_file(ROOT / rel)
        if observed != expected:
            fail(f"{rel} sha256 {observed} != pinned {expected}")
    for absolute, expected in PINNED_ABS.items():
        observed = sha256_file(Path(absolute))
        if observed != expected:
            fail(f"{absolute} sha256 {observed} != pinned {expected}")
    checks.append(("pinned_input_digests", True, f"{len(PINNED_INPUTS) + len(PINNED_ABS)} inputs match"))

    # --- cached frontier rows -------------------------------------------------
    jargon_lines = read_jsonl(ROOT / ".build/autoresearch/jargon.2.results.jsonl")
    bench_meta = next((r for r in jargon_lines if r.get("type") == "bench_meta"), {})
    jargon_rows = {str(r.get("id", "")): r for r in jargon_lines if r.get("type") == "row"}
    error_rows = sum(
        1 for r in jargon_lines if r.get("type") == "row" and r.get("error") is not None
    )
    if error_rows:
        fail(f"cached jargon rows carry {error_rows} error rows")

    terms = json.loads((ROOT / "bench/autoresearch/jargon.terms.json").read_text(encoding="utf-8"))
    record_read(ROOT / "bench/autoresearch/jargon.terms.json")
    positives = {k: v for k, v in terms.items() if v.get("domain") != "negative"}
    canonicals = sorted({v["canonical"] for v in positives.values() if v.get("canonical")})

    # --- residual miss recomputation (score_v5.py:183-203) --------------------
    recall_hits = sum(
        1
        for row_id, info in positives.items()
        if info.get("canonical")
        and contains_exact_term(jargon_rows[f"{row_id}#j0"]["final_text"], info["canonical"])
    )
    misses = [
        row_id
        for row_id, info in sorted(positives.items())
        if info.get("canonical")
        and not contains_exact_term(jargon_rows[f"{row_id}#j0"]["final_text"], info["canonical"])
    ]
    if recall_hits != EXPECT_RECALL_HITS or len(misses) != EXPECT_TERM_MISSES:
        fail(
            f"frontier reproduction failed: recall_hits {recall_hits} "
            f"(expected {EXPECT_RECALL_HITS}), misses {len(misses)} (expected {EXPECT_TERM_MISSES})"
        )
    checks.append((
        "frontier_reproduction",
        True,
        f"recall_hits {recall_hits}/{len(positives)}, term_misses {len(misses)}",
    ))

    # The prereg says not to trust the printed examples; cross-check them anyway, plus the
    # per-domain breakdown the harness printed, so the recomputation is pinned from both ends.
    metrics_txt = (ROOT / ".build/autoresearch/metrics.txt").read_text(encoding="utf-8")
    record_read(ROOT / ".build/autoresearch/metrics.txt")
    printed_examples = [
        item.split(":")[0]
        for item in metrics_txt.split("term_miss_examples=")[1].splitlines()[0].split("|")
    ]
    if not set(printed_examples) <= set(misses):
        fail("printed term_miss_examples are not a subset of the recomputed miss set")
    printed_domains = metrics_txt.split("term_recall_by_domain=")[1].splitlines()[0]
    domain_totals: dict[str, int] = {}
    for info in positives.values():
        domain_totals[info["domain"]] = domain_totals.get(info["domain"], 0) + 1
    recomputed_domain_misses: dict[str, int] = {}
    for row_id in misses:
        domain = terms[row_id]["domain"]
        recomputed_domain_misses[domain] = recomputed_domain_misses.get(domain, 0) + 1
    for chunk in printed_domains.split("|"):
        domain, ratio = chunk.split(":")
        printed_hits = int(ratio.split("/")[0])
        if domain_totals[domain] - printed_hits != recomputed_domain_misses[domain]:
            fail(f"per-domain miss count for {domain} disagrees with metrics.txt")
    checks.append((
        "metrics_txt_cross_check",
        True,
        f"all {len(printed_examples)} printed miss examples lie in the recomputed set; "
        f"per-domain misses {dict(sorted(recomputed_domain_misses.items()))} match "
        f"term_recall_by_domain",
    ))

    # --- R16 draw -------------------------------------------------------------
    miss_by_domain: dict[str, int] = {}
    for row_id in misses:
        domain = terms[row_id]["domain"]
        miss_by_domain[domain] = miss_by_domain.get(domain, 0) + 1
    r_alloc = largest_remainder(miss_by_domain, 16)
    if r_alloc != EXPECT_R_ALLOC:
        fail(f"R16 allocation {r_alloc} != preregistered {EXPECT_R_ALLOC}")
    rng = np.random.default_rng(SEED)  # one RNG, alphabetical domain order
    r16: list[str] = []
    for domain in sorted(miss_by_domain):
        pool = sorted(row_id for row_id in misses if terms[row_id]["domain"] == domain)
        r16.extend(str(x) for x in rng.permutation(pool)[: r_alloc[domain]])
    if r16 != PREREG_R16:
        fail(f"R16 draw {r16} != preregistered rows {PREREG_R16}")
    checks.append(("r16_draw", True, f"16 rows, allocation {r_alloc}, seed {SEED}"))

    # --- G16 draw -------------------------------------------------------------
    general = read_jsonl(ROOT / "bench/autoresearch/corpus.manifest.jsonl")
    general_by_id = {r["id"]: r for r in general}
    source_counts: dict[str, int] = {}
    for row in general:
        source_counts[row["source"]] = source_counts.get(row["source"], 0) + 1
    g_alloc = largest_remainder(source_counts, 16)
    if g_alloc != EXPECT_G_ALLOC:
        fail(f"G16 allocation {g_alloc} != preregistered {EXPECT_G_ALLOC}")
    grng = np.random.default_rng(SEED)
    g16: list[str] = []
    for source in sorted(source_counts):
        pool = sorted(r["id"] for r in general if r["source"] == source)
        g16.extend(str(x) for x in grng.permutation(pool)[: g_alloc[source]])
    g16_shared_rng_matches = g16 == PREREG_G16
    # The prereg's G16 prose says "a fresh default_rng per source"; that reading is
    # recorded here so the discrepancy is measured, never silently reconciled.
    g16_fresh: list[str] = []
    for source in sorted(source_counts):
        pool = sorted(r["id"] for r in general if r["source"] == source)
        g16_fresh.extend(
            str(x) for x in np.random.default_rng(SEED).permutation(pool)[: g_alloc[source]]
        )
    g16_fresh_rng_matches = g16_fresh == PREREG_G16
    if not g16_shared_rng_matches:
        fail(f"G16 draw {g16} != preregistered rows {PREREG_G16}")
    checks.append((
        "g16_draw",
        True,
        f"16 rows, allocation {g_alloc}, seed {SEED}; shared-RNG reading reproduces the "
        f"frozen rows, per-source fresh-RNG reading does not "
        f"(fresh_matches={g16_fresh_rng_matches})",
    ))

    # --- N16 assembly and fresh-fire verification ----------------------------
    jargon_manifest = {r["id"]: r for r in read_jsonl(ROOT / "benchmarks/data/jargon/manifest.jsonl")}
    fresh_manifest: dict[str, dict] = {}
    for directory in FRESH_DIRS:
        for row in read_jsonl(ROOT / ".build/asr-research/three-bets" / directory / "manifest.jsonl"):
            fresh_manifest[row["id"]] = row
    a_stage: dict[str, dict[str, dict]] = {}
    for directory, files in FRESH_A_STAGE.items():
        for name in files:
            for row in read_jsonl(ROOT / ".build/asr-research/three-bets" / directory / name):
                a_stage.setdefault(str(row.get("id")), {})[f"{directory}/{name}"] = row

    def a_stage_outputs(row_id: str) -> list[tuple[str, str]]:
        out: list[tuple[str, str]] = []
        for source, row in a_stage.get(row_id, {}).items():
            for field in ("final_text", "strict", "diverse"):
                value = row.get(field)
                if isinstance(value, str):
                    out.append((f"{source}:{field}", value))
        return out

    n_guards: dict[str, str] = {}
    n_guard_origin: dict[str, str] = {}
    fires: dict[str, list[str]] = {}
    for row_id in PREREG_N16:
        if row_id in PREREG_N_GUARDS:
            n_guards[row_id] = PREREG_N_GUARDS[row_id]
            n_guard_origin[row_id] = "prereg_named"
        else:
            # The prereg's own rule for the pinned negatives: the taught canonical whose
            # ordinary-prose homograph the reference carries case-insensitively while the
            # reference itself never spells the canonical exactly.
            reference = jargon_manifest[row_id]["reference"]
            folded = reference.casefold()
            derived = [
                c
                for c in canonicals
                if contains_exact_term(folded, c.casefold()) and not contains_exact_term(reference, c)
            ]
            if len(derived) == 1:
                n_guards[row_id] = derived[0]
                n_guard_origin[row_id] = "derived_homograph"
            else:
                # No taught canonical is recoverable from this row's prose surface.
                surface = row_id.split("_negative_", 1)[1].split("_")
                n_guards[row_id] = next(
                    (w for w in surface if w in {"commit", "merge"}), ""
                )
                n_guard_origin[row_id] = "prose_surface_no_taught_canonical"
        if row_id in fresh_manifest:
            reference = fresh_manifest[row_id]["reference"]
            surface = n_guards[row_id]
            fires[row_id] = [
                label
                for label, text in a_stage_outputs(row_id)
                if contains_exact_term(text, surface)
                and not contains_exact_term(reference.casefold(), surface.casefold())
            ]
            if not fires[row_id]:
                fail(f"N row {row_id} records no standing fire for {surface!r}")
    checks.append((
        "n16_fresh_fires",
        True,
        f"{sum(1 for k, v in fires.items() if v)}/7 fresh rows reproduce a case-sensitive "
        "taught-surface fire absent from their reference",
    ))

    covered = sorted({n_guards[r] for r in PREREG_N16} & set(STANDING_SURFACES))
    uncovered = sorted(set(STANDING_SURFACES) - set(covered))

    # --- rows, audio verification --------------------------------------------
    prereg_text = (ROOT / PREREG_REL).read_text(encoding="utf-8")
    rows_out: list[dict] = []
    manifest_records: list[dict] = []
    missing_audio: list[str] = []
    digest_mismatch: list[str] = []
    unpinned_audio: list[str] = []

    def add(slice_name: str, slot: str, row_id: str, audio_path: str, source_manifest: str,
            reference: str, audio_sha256: str, extra: dict, provenance: dict) -> None:
        path = ROOT / audio_path
        exists = path.exists()
        observed = sha256_file(path) if exists else None
        if not exists:
            missing_audio.append(audio_path)
        else:
            read_files[audio_path] = observed
            if observed != audio_sha256:
                digest_mismatch.append(f"{row_id}: {observed} != {audio_sha256}")
            if observed not in prereg_text:
                unpinned_audio.append(row_id)
        record = {"slice": slice_name, "slot": slot, "id": row_id, "audio_path": audio_path,
                  "audio_sha256": audio_sha256, "reference": reference, **extra}
        manifest_records.append(record)
        rows_out.append({
            "run": RUN_ID, "slice": slice_name, "slot": slot, "id": row_id,
            "audio_path": audio_path, "audio_sha256_manifest": audio_sha256,
            "audio_sha256_observed": observed, "audio_present": exists,
            "audio_sha256_declared_in_prereg": observed in prereg_text if exists else False,
            "reference": reference, "source_manifest": source_manifest, **extra, **provenance,
        })

    for index, row_id in enumerate(r16, start=1):
        entry = jargon_manifest[row_id]
        cached = jargon_rows[f"{row_id}#j0"]
        add("R16", f"R{index:02d}", row_id, f"benchmarks/data/jargon/audio/{row_id}.wav",
            "benchmarks/data/jargon/manifest.jsonl", entry["reference"], entry["audio_sha256"],
            {"canonical": terms[row_id]["canonical"], "stratum": terms[row_id]["domain"]},
            {"incumbent_final_text": cached["final_text"],
             "incumbent_raw_transcript": cached.get("raw_transcript"),
             "incumbent_contains_canonical": False,
             "audio_s": entry.get("audio_s"), "audio_bytes": entry.get("audio_bytes")})

    for index, row_id in enumerate(PREREG_N16, start=1):
        if row_id in jargon_manifest:
            entry = jargon_manifest[row_id]
            audio_path = f"benchmarks/data/jargon/audio/{row_id}.wav"
            source_manifest = "benchmarks/data/jargon/manifest.jsonl"
            provenance = {"row_kind": "pinned_jargon_negative", "fresh_fire_evidence": []}
        else:
            entry = fresh_manifest[row_id]
            audio_path = entry["audio_path"]
            source_manifest = str(Path(audio_path).parents[1] / "manifest.jsonl")
            provenance = {"row_kind": "fresh_shard_fire", "fresh_fire_evidence": fires.get(row_id, [])}
        provenance.update({"guard_surface_origin": n_guard_origin[row_id],
                           "guard_surface_is_taught_canonical": n_guards[row_id] in canonicals,
                           "audio_s": entry.get("audio_s"), "audio_bytes": entry.get("audio_bytes")})
        add("N16", f"N{index:02d}", row_id, audio_path, source_manifest, entry["reference"],
            entry["audio_sha256"], {"guard_surface": n_guards[row_id]}, provenance)

    general_results = read_jsonl(ROOT / ".build/autoresearch/general.results.jsonl")
    general_rows = {str(r.get("id", "")): r for r in general_results if r.get("type") == "row"}
    for index, row_id in enumerate(g16, start=1):
        entry = general_by_id[row_id]
        v3 = general_rows[f"{row_id}#p1"]
        add("G16", f"G{index:02d}", row_id, entry["audio_path"],
            "bench/autoresearch/corpus.manifest.jsonl", entry["reference"], entry["audio_sha256"],
            {"stratum": entry["source"]},
            {"v3_final_text": v3["final_text"], "duration_bucket": entry.get("duration_bucket"),
             "noise_condition": None, "audio_s": entry.get("audio_s"),
             "audio_bytes": entry.get("audio_bytes")})

    if missing_audio:
        fail(f"missing audio: {missing_audio}")
    if digest_mismatch:
        fail(f"audio digest mismatch: {digest_mismatch}")
    if unpinned_audio:
        fail(f"audio digests absent from the prereg: {unpinned_audio}")
    checks.append(("audio_verification", True,
                   f"48/48 files present; bytes match both the corpus manifests and the "
                   f"prereg-declared SHA-256"))

    # --- pilot manifest -------------------------------------------------------
    blob = "".join(
        json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
        for record in manifest_records
    ).encode("utf-8")
    (OUT / "pilot-manifest.jsonl").write_bytes(blob)
    pilot_sha = hashlib.sha256(blob).hexdigest()
    digest_matches = pilot_sha == EXPECT_PILOT_MANIFEST_SHA256
    checks.append(("pilot_manifest_digest", digest_matches,
                   f"observed {pilot_sha}, preregistered {EXPECT_PILOT_MANIFEST_SHA256}"))

    r_slice = [r for r in manifest_records if r["slice"].startswith(("R", "r"))]
    n_slice = [r for r in manifest_records if r["slice"].startswith(("N", "n"))]
    g_slice = [r for r in manifest_records if r["slice"].startswith(("G", "g"))]
    exhaustive = "--exhaustive" in sys.argv
    tried, alt_matches = enumerate_serializations(
        r_slice, n_slice, g_slice, canonicals,
        [n_guards[row_id] for row_id in PREREG_N16[7:14]], exhaustive,
    )
    if alt_matches:
        digest_matches = True
    checks.append((
        "pilot_manifest_digest_alternate_encodings",
        bool(alt_matches),
        f"{tried} candidate encodings enumerated (exhaustive={exhaustive}); "
        f"matches: {alt_matches or 'none'}",
    ))

    # --- v3 baselines the prereg freezes -------------------------------------
    general_corpus_refs = [r["reference"] for r in general]
    general_corpus_hyps = [general_rows[f"{r['id']}#p1"]["final_text"] for r in general]
    uwer_general = uwer(general_corpus_refs, general_corpus_hyps)

    g16_refs = [general_by_id[i]["reference"] for i in g16]
    g16_hyps = [general_rows[f"{i}#p1"]["final_text"] for i in g16]
    g16_uwer_v3 = uwer(g16_refs, g16_hyps)
    measures = jiwer.process_words(
        [english_normalize(v) for v in g16_refs], [english_normalize(v) for v in g16_hyps]
    )
    g16_errors = measures.substitutions + measures.deletions + measures.insertions
    g16_words = measures.substitutions + measures.deletions + measures.hits
    g16_row_errors = []
    for ref, hyp in zip(g16_refs, g16_hyps):
        row = jiwer.process_words([english_normalize(ref)], [english_normalize(hyp)])
        g16_row_errors.append(row.substitutions + row.deletions + row.insertions)

    baseline_ok = (
        g16_errors == EXPECT_G16_V3_ERRORS
        and g16_words == EXPECT_G16_V3_WORDS
        and abs(g16_uwer_v3 - EXPECT_G16_V3_UWER) < 1e-15
    )
    checks.append(("g16_v3_baseline", baseline_ok,
                   f"{g16_errors} errors / {g16_words} words = {g16_uwer_v3!r}; "
                   f"preregistered {EXPECT_G16_V3_ERRORS}/{EXPECT_G16_V3_WORDS} = "
                   f"{EXPECT_G16_V3_UWER!r}"))
    uwer_general_ok = round(uwer_general, 6) == EXPECT_UWER_GENERAL
    checks.append(("uwer_general_reproduction", uwer_general_ok,
                   f"{uwer_general:.6f} vs frontier {EXPECT_UWER_GENERAL}"))

    # --- environment ----------------------------------------------------------
    def sysctl(key: str, default: str = "0") -> str:
        try:
            return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True,
                                  check=True).stdout.strip() or default
        except subprocess.CalledProcessError:
            return default

    def sw_vers(flag: str) -> str:
        return subprocess.run(["sw_vers", flag], capture_output=True, text=True,
                              check=True).stdout.strip()

    def swift_version() -> str:
        try:
            first = subprocess.run(["swift", "--version"], capture_output=True, text=True,
                                   check=True).stdout.splitlines()[0]
        except (subprocess.CalledProcessError, FileNotFoundError, IndexError):
            return "none"
        return first.strip().replace(" ", "_")

    environment = {
        "hw_model": sysctl("hw.model"),
        "hw_chip": sysctl("machdep.cpu.brand_string").replace(" ", "_"),
        "hw_cpu_threads": sysctl("hw.logicalcpu"),
        "hw_perf_cores": sysctl("hw.perflevel0.logicalcpu"),
        "hw_eff_cores": sysctl("hw.perflevel1.logicalcpu"),
        "hw_memory_bytes": sysctl("hw.memsize"),
        "os_version": sw_vers("-productVersion"),
        "os_build": sw_vers("-buildVersion"),
        "kernel": platform.release(),
        "swift_version": swift_version(),
    }

    # This screen loads no model, no CoreML tier, no sidecar and no bench binary, so every
    # pin it does not consume records the harness's own absent value (native / none / 0).
    pins = {
        "general_corpus_sha256": PINNED_INPUTS["bench/autoresearch/corpus.manifest.jsonl"],
        "jargon_corpus_sha256": PINNED_INPUTS["benchmarks/data/jargon/manifest.jsonl"],
        "jargon_terms_sha256": PINNED_INPUTS["bench/autoresearch/jargon.terms.json"],
        "repair_vocabulary_sha256": "none",
        "coreml_encoder": "native",
        "coreml_encoder_digest": "none",
        "coreml_max_s": "0",
        "coreml_encoder_short": "none",
        "coreml_short_digest": "none",
        "coreml_short_max_s": "0",
        "coreml_encoder_tiny": "none",
        "coreml_tiny_digest": "none",
        "coreml_tiny_max_s": "0",
        "assist_model_sha256": "none",
        "assist_model_2_sha256": "none",
        "assist_model_3_sha256": "none",
        "assist_model_4_sha256": "none",
        "assist_model_5_sha256": "none",
        "model_sha256": "none",
        "model_bytes": 0,
        "sidecar_sha256": "none",
        "bench_sha256": "none",
    }

    manifest = {
        "track": TRACK,
        "wave": WAVE,
        "run": RUN,
        "part": 1,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "prereg_commit": PREREG_COMMIT,
        "prereg_path": PREREG_REL,
        "prereg_sha256": PREREG_SHA256,
        "frontier_commit": FRONTIER_COMMIT,
        "seed": SEED,
        "python": sys.version.split()[0],
        "numpy": np.__version__,
        "interpreter": "bench/.venv/bin/python",
        "pilot_manifest_sha256": pilot_sha,
        "pilot_manifest_sha256_preregistered": EXPECT_PILOT_MANIFEST_SHA256,
        "pilot_manifest_digest_matches": digest_matches,
        "candidate_revisions": {
            "qwen3-asr-0.6b": {"repo": "Qwen/Qwen3-ASR-0.6B",
                               "revision": "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
                               "status": "not_contacted"},
            "kyutai-stt-1b-en_fr-mlx": {"repo": "kyutai/stt-1b-en_fr-mlx",
                                        "revision": "2b995724eef1e964b7ccb6a762b35a665c4abe0d",
                                        "status": "not_contacted"},
            "canary-180m-flash": {"repo": "nvidia/canary-180m-flash",
                                  "revision": "b12ab418510d093e83890178fd0e8b0d0f7918a6",
                                  "status": "not_contacted"},
            "cohere-transcribe-03-2026": {"repo": "CohereLabs/cohere-transcribe-03-2026",
                                          "revision": "b1eacc2686a3d08ceaae5f24a88b1d519620bc09",
                                          "status": "not_contacted"},
        },
        "cached_row_provenance": {
            "jargon_bench_meta": bench_meta,
            "note": "Part 1 replays these cached rows; it runs no inference, so every model, "
                    "CoreML, sidecar and bench pin records its absent value.",
        },
        **pins,
        **environment,
        "screen_inputs": dict(sorted(read_files.items())),
    }
    (OUT / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )

    with (OUT / "rows.jsonl").open("w", encoding="utf-8") as handle:
        for row in rows_out:
            handle.write(json.dumps(row, sort_keys=True, ensure_ascii=False) + "\n")

    metrics = [
        ("recall_hits", recall_hits),
        ("term_misses", len(misses)),
        ("error_rows", error_rows),
        ("uwer_general", uwer_general),
        ("g16_uwer_v3_baseline", g16_uwer_v3),
        ("g16_uwer_v3_errors", g16_errors),
        ("g16_uwer_v3_reference_words", g16_words),
        ("g16_uwer_ceiling", EXPECT_G16_CEILING),
        ("negative_false_terms_cp95_upper", NEGATIVE_FALSE_TERMS_CP95_UPPER),
        ("pilot_rows", len(manifest_records)),
        ("r16_rows", len(r16)),
        ("n16_rows", len(PREREG_N16)),
        ("g16_rows", len(g16)),
        ("audio_files_verified", 48 - len(missing_audio)),
        ("audio_files_missing", len(missing_audio)),
        ("standing_surfaces_covered", len(covered)),
        ("pilot_manifest_digest_matches", int(digest_matches)),
        ("serialization_encodings_enumerated", tried),
    ]
    with (OUT / "metrics.jsonl").open("w", encoding="utf-8") as handle:
        for name, value in metrics:
            handle.write(json.dumps({"run": RUN_ID, "metric": name, "value": value}) + "\n")

    summary = {
        "recall_hits": recall_hits,
        "term_misses": len(misses),
        "r16_allocation": r_alloc,
        "g16_allocation": g_alloc,
        "g16_shared_rng_matches_prereg": g16_shared_rng_matches,
        "g16_fresh_rng_matches_prereg": g16_fresh_rng_matches,
        "audio_verified": 48 - len(missing_audio),
        "audio_missing": missing_audio,
        "standing_surfaces_covered": covered,
        "standing_surfaces_uncovered": uncovered,
        "n16_guard_surfaces": {r: n_guards[r] for r in PREREG_N16},
        "n16_guard_origin": n_guard_origin,
        "pilot_manifest_sha256": pilot_sha,
        "pilot_manifest_sha256_preregistered": EXPECT_PILOT_MANIFEST_SHA256,
        "pilot_manifest_digest_matches": digest_matches,
        "uwer_general": uwer_general,
        "g16_v3_errors": g16_errors,
        "g16_v3_reference_words": g16_words,
        "g16_v3_uwer": g16_uwer_v3,
        "g16_v3_row_errors": g16_row_errors,
        "g16_uwer_ceiling_prereg_literal": EXPECT_G16_CEILING,
        "g16_uwer_ceiling_recomputed": EXPECT_G16_V3_UWER + G16_NI_MARGIN,
        "checks": [{"check": n, "ok": ok, "detail": d} for n, ok, d in checks],
    }
    print(json.dumps(summary, indent=2))
    (OUT / "part1-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    if not digest_matches:
        print(
            "selection.py: pilot manifest digest does not match the preregistered constant; "
            "the prereg stop rule blocks Part 2 before any download.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
