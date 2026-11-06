"""Analysis for research/prereg/granite-ctc-word-spotting.md.

Reads `voiceour-bench granite-spot` rows for the three frozen manifests, applies the
preregistered measures, folds, selection and bars, checks identity controls I2-I4, and writes
`metrics.json` and `verdict.md` beside the inputs.

    uv --no-config run --project bench python research/prereg/tools/granite_ctc_spotting_analysis.py \
        --run .build/spot/run1 --corpus .build/spot/corpus/frozen-complete \
        --terms bench/autoresearch/jargon.terms.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bench" / "src"))

from voiceour_bench.metrics import contains_exact_term, uwer  # noqa: E402

MANIFESTS = ("synthetic-jargon", "nonspeech", "confirmation")


def read_jsonl(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def fold_of(key: str) -> int:
    return hashlib.sha256(key.encode("utf-8")).digest()[0] % 2


def fold_key(manifest: str, row: dict, terms: dict) -> str:
    if manifest == "synthetic-jargon":
        info = terms.get(row["id"])
        if info and info.get("canonical"):
            return "term:" + info["canonical"]
        return "row:" + row["id"]
    if manifest == "confirmation":
        if row["corpus"] == "fleurs-en-us":
            return "sent:" + str(row.get("sentence_id") if row.get("sentence_id") is not None else row["id"])
        return f"spk:{row['corpus']}:{row['speaker_id']}"
    return "row:" + row["id"]


class Row:
    __slots__ = ("id", "manifest", "fold", "reference", "canonical", "m0", "finals", "spot")

    def __init__(self, manifest: str, manifest_row: dict, spot_row: dict, terms: dict):
        self.id = manifest_row["id"]
        self.manifest = manifest
        self.fold = fold_of(fold_key(manifest, manifest_row, terms))
        self.reference = manifest_row.get("reference") or ""
        info = terms.get(self.id) if manifest == "synthetic-jargon" else None
        self.canonical = info.get("canonical") if info and info.get("canonical") else None
        if manifest == "synthetic-jargon" and self.id.startswith("techterms") and manifest_row.get("expect_term"):
            self.canonical = manifest_row.get("canonical_term")
        self.m0 = spot_row["m0_final"]
        self.finals: dict[int, str] = {}
        for final in spot_row["finals"]:
            for point in final["points"]:
                self.finals[point] = final["text"]
        self.spot = spot_row

    def final(self, point: int | None) -> str:
        return self.m0 if point is None else self.finals.get(point, self.m0)


def is_jargon_positive(row: Row) -> bool:
    return row.manifest == "synthetic-jargon" and row.canonical is not None and not row.id.startswith("techterms")


def false_activation(row: Row, point: int | None, targets: list[str]) -> bool:
    text = row.final(point)
    if text == row.m0:
        return False
    folded_reference = row.reference.casefold()
    return any(
        contains_exact_term(text, canonical)
        and not contains_exact_term(row.m0, canonical)
        and not contains_exact_term(folded_reference, canonical.casefold())
        for canonical in targets
    )


def evaluate(rows: list[Row], point: int | None, targets: list[str], fold: int | None = None) -> dict:
    scoped = [row for row in rows if fold is None or row.fold == fold]
    positives = [row for row in scoped if is_jargon_positive(row)]
    hits = sum(contains_exact_term(row.final(point), row.canonical) for row in positives)
    baseline = sum(contains_exact_term(row.m0, row.canonical) for row in positives)
    lost = sum(
        contains_exact_term(row.m0, row.canonical) and not contains_exact_term(row.final(point), row.canonical)
        for row in positives
    )
    false_rows = [row.id for row in scoped if false_activation(row, point, targets)]
    return {
        "positives": len(positives),
        "hits": hits,
        "baseline_hits": baseline,
        "gain": hits - baseline,
        "lost": lost,
        "false_activations": len(false_rows),
        "false_activation_rows": false_rows[:50],
    }


def select(rows: list[Row], grid: list[list[float]], targets: list[str], fold: int) -> int | None:
    best: tuple | None = None
    for point, (total, per_token, scale) in enumerate(grid):
        result = evaluate(rows, point, targets, fold)
        if result["false_activations"] or result["lost"] or result["gain"] <= 0:
            continue
        key = (-result["hits"], total, per_token, scale)
        if best is None or key < best[0]:
            best = (key, point)
    return None if best is None else best[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--terms", type=Path, required=True)
    options = parser.parse_args()

    terms = json.loads(options.terms.read_text())
    rows: list[Row] = []
    meta = None
    spot_rows_by_manifest: dict[str, list[dict]] = {}
    for manifest in MANIFESTS:
        spot = read_jsonl(options.run / f"{manifest}.spot.jsonl")
        meta = meta or spot[0]
        if spot[0]["grid"] != meta["grid"] or spot[0]["targets"] != meta["targets"]:
            raise SystemExit(f"{manifest}: grid or targets differ between runs")
        spot_rows = {row["id"]: row for row in spot[1:]}
        spot_rows_by_manifest[manifest] = spot[1:]
        manifest_rows = read_jsonl(options.corpus / f"{manifest}.manifest.jsonl")
        if set(spot_rows) != {row["id"] for row in manifest_rows}:
            raise SystemExit(f"{manifest}: row sets differ")
        rows.extend(Row(manifest, row, spot_rows[row["id"]], terms) for row in manifest_rows)

    grid = meta["grid"]
    targets = meta["targets"]
    positives = [row for row in rows if is_jargon_positive(row)]
    if len(positives) != 346:
        raise SystemExit(f"expected 346 jargon positives, found {len(positives)}")
    h0 = sum(contains_exact_term(row.m0, row.canonical) for row in positives)
    misses = 346 - h0

    selected = {fold: select(rows, grid, targets, fold) for fold in (0, 1)}
    held_out = {}
    for fold in (0, 1):
        point = selected[fold]
        held_out[1 - fold] = evaluate(rows, point, targets, 1 - fold)
    cross = {
        key: held_out[0][key] + held_out[1][key]
        for key in ("gain", "lost", "false_activations", "hits", "baseline_hits", "positives")
    }
    pass_gain = max(10, math.ceil(0.25 * misses))
    kill_gain = max(5, math.ceil(0.10 * misses))
    if cross["false_activations"] > 0 or cross["lost"] > 0 or cross["gain"] < kill_gain:
        verdict = "KILL"
    elif cross["gain"] >= pass_gain:
        verdict = "PASS"
    else:
        verdict = "INCONCLUSIVE"

    shipping = None
    shipping_full = None
    if verdict == "PASS" and None not in selected.values():
        chosen = [grid[selected[fold]] for fold in (0, 1)]
        minimum = [min(chosen[0][axis], chosen[1][axis]) for axis in range(3)]
        shipping = grid.index(minimum)
        shipping_full = evaluate(rows, shipping, targets)
        if shipping_full["false_activations"] or shipping_full["lost"]:
            verdict = "KILL"

    # Identity controls.
    identity = {}
    pipeline_mismatch = []
    pipeline_rows = 0
    for manifest, spot_name in (
        ("synthetic-jargon", "synthetic-jargon"),
        ("nonspeech", "nonspeech"),
        ("confirmation-first1000", "confirmation"),
    ):
        pipeline = {r["id"]: r for r in read_jsonl(options.run / f"{manifest}.pipeline.jsonl") if r.get("type") == "row"}
        spots = {r["id"]: r for r in spot_rows_by_manifest[spot_name]}
        for row_id, pipe in pipeline.items():
            pipeline_rows += 1
            if pipe.get("error") or pipe["raw_transcript"] != spots[row_id]["raw_text"]:
                pipeline_mismatch.append(row_id)
    identity["I2_decode"] = {"rows": pipeline_rows, "mismatches": len(pipeline_mismatch), "examples": pipeline_mismatch[:10]}
    word_failures = [row.id for row in rows if not row.spot["words_match_text"]]
    identity["I3_words"] = {
        "rows": len(rows),
        "failures": len(word_failures),
        "rate": len(word_failures) / len(rows),
        "examples": word_failures[:10],
    }
    pass2 = {r["id"]: r for r in read_jsonl(options.run / "synthetic-jargon.pass2.spot.jsonl")[1:]}
    text_diff = 0
    window_diff = 0
    max_delta = 0.0
    for row in spot_rows_by_manifest["synthetic-jargon"]:
        other = pass2[row["id"]]
        text_diff += row["raw_text"] != other["raw_text"]
        first = [(s["term"], s["variant"], s["start_ms"], s["end_ms"]) for s in row["spots"]]
        second = [(s["term"], s["variant"], s["start_ms"], s["end_ms"]) for s in other["spots"]]
        if first != second:
            window_diff += 1
        else:
            for a, b in zip(row["spots"], other["spots"]):
                max_delta = max(max_delta, abs(a["score"] - b["score"]))
    identity["I4_determinism"] = {
        "rows": len(pass2),
        "text_differences": text_diff,
        "window_differences": window_diff,
        "max_abs_score_delta": max_delta,
    }
    invalid = (
        identity["I2_decode"]["mismatches"] > 0
        or identity["I3_words"]["rate"] > 0.001
        or text_diff > 0
        or window_diff > 0
    )

    # Exploratory.
    point_for_exploration = shipping if shipping is not None else selected[0] if selected[0] is not None else selected[1]
    tech = [row for row in rows if row.id.startswith("techterms")]
    tech_pos = [row for row in tech if row.canonical]
    exploration = {
        "exploration_point": point_for_exploration,
        "techterms_hits_m0": sum(contains_exact_term(r.m0, r.canonical) for r in tech_pos),
        "techterms_hits_m1": sum(contains_exact_term(r.final(point_for_exploration), r.canonical) for r in tech_pos),
        "techterms_positives": len(tech_pos),
        "techterms_negative_false_activations": sum(
            false_activation(r, point_for_exploration, targets) for r in tech if not r.canonical
        ),
    }
    domains = defaultdict(lambda: [0, 0, 0])
    for row in positives:
        domain = terms[row.id].get("domain")
        domains[domain][0] += 1
        domains[domain][1] += contains_exact_term(row.m0, row.canonical)
        domains[domain][2] += contains_exact_term(row.final(point_for_exploration), row.canonical)
    exploration["hits_by_domain"] = {d: {"positives": v[0], "m0": v[1], "m1": v[2]} for d, v in sorted(domains.items())}
    unrenderable = sum(1 for row in rows for s in row.spot["spots"] if s["first_word"] is None)
    exploration["unrenderable_spots"] = unrenderable
    spot_us = sorted(row.spot["spot_us"] for row in rows)
    exploration["spot_us_p50"] = spot_us[len(spot_us) // 2]
    exploration["spot_us_p95"] = spot_us[int(len(spot_us) * 0.95)]
    special = defaultdict(Counter)
    for row in rows:
        corpus = row.manifest
        for token, count in row.spot["special_tokens"].items():
            special[corpus][token] += count
    exploration["special_tokens"] = {corpus: dict(counter.most_common(20)) for corpus, counter in special.items()}
    confirmation = [row for row in rows if row.manifest == "confirmation"]
    exploration["confirmation_uwer_m0"] = uwer([r.reference for r in confirmation], [r.m0 for r in confirmation])
    exploration["confirmation_uwer_m1"] = uwer(
        [r.reference for r in confirmation], [r.final(point_for_exploration) for r in confirmation]
    )

    curve = []
    for point, values in enumerate(grid):
        result = evaluate(rows, point, targets)
        curve.append({"point": point, "grid": values, **{k: result[k] for k in ("hits", "gain", "lost", "false_activations")}})

    metrics = {
        "verdict": "INVALID" if invalid else verdict,
        "preregistered_verdict_before_identity": verdict,
        "H0": h0,
        "misses": misses,
        "pass_gain_bar": pass_gain,
        "kill_gain_bar": kill_gain,
        "selected": {str(fold): (None if selected[fold] is None else {"point": selected[fold], "grid": grid[selected[fold]]}) for fold in (0, 1)},
        "held_out": held_out,
        "cross_fitted": cross,
        "shipping_point": None if shipping is None else {"point": shipping, "grid": grid[shipping]},
        "shipping_full_data": shipping_full,
        "identity": identity,
        "exploration": exploration,
        "rows": Counter(row.manifest for row in rows),
        "targets": len(targets),
        "patterns": len(meta["patterns"]),
        "curve": curve,
    }
    (options.run / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps({k: metrics[k] for k in ("verdict", "H0", "misses", "pass_gain_bar", "kill_gain_bar", "selected", "cross_fitted", "shipping_point")}, indent=1))
    print(json.dumps({k: (v if k != "shipping_full_data" else v) for k, v in [("shipping_full_data", shipping_full), ("identity", identity)]}, indent=1))
    print(json.dumps(exploration, indent=1)[:4000])


if __name__ == "__main__":
    main()
