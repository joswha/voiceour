"""Analysis for research/prereg/granite-ctc-word-spotting-wave2.md.

    uv --no-config run --project bench python research/prereg/tools/granite_ctc_spotting_wave2_analysis.py \
        --run .build/spot/wave2
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bench" / "src"))

from voiceour_bench.metrics import contains_exact_term, uwer  # noqa: E402

FROZEN = [6.0, 1.5, 1.0]
EXPLORE = [8.0, 1.5, 1.0]
SETS = ("positives", "negatives", "real", "nonspeech")


def read_jsonl(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def load(run: Path, arm: str) -> tuple[dict, dict[str, dict], dict[str, dict]]:
    meta = None
    spots: dict[str, dict] = {}
    manifest: dict[str, dict] = {}
    for name in SETS:
        rows = read_jsonl(run / f"{name}.{arm}.spot.jsonl")
        if meta is None:
            meta = rows[0]
        elif rows[0]["grid"] != meta["grid"] or rows[0]["targets"] != meta["targets"]:
            raise SystemExit(f"{name}.{arm}: grid or targets differ")
        for row in rows[1:]:
            row["set"] = name
            spots[row["id"]] = row
        for row in read_jsonl(run / f"{name}.manifest.jsonl"):
            manifest[row["id"]] = row
    if set(spots) != set(manifest):
        raise SystemExit(f"{arm}: spot rows and manifests differ")
    return meta, spots, manifest


def final(row: dict, point: int | None) -> str:
    if point is None:
        return row["m0_final"]
    for item in row["finals"]:
        if point in item["points"]:
            return item["text"]
    return row["m0_final"]


def measure(spots: dict, manifest: dict, targets: list[str], point: int | None) -> dict:
    hits = baseline = lost = 0
    false_rows: list[str] = []
    damaged: list[str] = []
    changed = 0
    per_voice = defaultdict(lambda: [0, 0, 0])
    false_by_set = Counter()
    for row_id, row in spots.items():
        reference = manifest[row_id].get("reference") or ""
        text = final(row, point)
        m0 = row["m0_final"]
        canonical = manifest[row_id].get("canonical_term") if row["set"] == "positives" else None
        if canonical:
            hit0 = contains_exact_term(m0, canonical)
            hit1 = contains_exact_term(text, canonical)
            baseline += hit0
            hits += hit1
            lost += hit0 and not hit1
            voice = manifest[row_id].get("voice")
            per_voice[voice][0] += 1
            per_voice[voice][1] += hit0
            per_voice[voice][2] += hit1
        if text == m0:
            continue
        changed += 1
        folded = reference.casefold()
        if any(
            contains_exact_term(text, c) and not contains_exact_term(m0, c) and not contains_exact_term(folded, c.casefold())
            for c in targets
        ):
            false_rows.append(row_id)
            false_by_set[row["set"]] += 1
        if uwer([reference], [text]) > uwer([reference], [m0]):
            damaged.append(row_id)
    positives = sum(1 for row in spots.values() if row["set"] == "positives")
    return {
        "positives": positives,
        "baseline_hits": baseline,
        "hits": hits,
        "gain": hits - baseline,
        "lost": lost,
        "false_activations": len(false_rows),
        "false_activation_rows": false_rows[:50],
        "false_by_set": dict(false_by_set),
        "changed_rows": changed,
        "damaged_rows": len(damaged),
        "damaged_examples": damaged[:20],
        "per_voice": {voice: {"positives": v[0], "m0": v[1], "m1": v[2]} for voice, v in sorted(per_voice.items())},
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=Path, required=True)
    options = parser.parse_args()

    meta, spots, manifest = load(options.run, "plain")
    grid = meta["grid"]
    frozen = grid.index(FROZEN)
    explore = grid.index(EXPLORE)
    targets = meta["targets"]

    primary = measure(spots, manifest, targets, frozen)
    misses = primary["positives"] - primary["baseline_hits"]
    pass_gain = max(10, math.ceil(0.25 * misses))
    kill_gain = max(5, math.ceil(0.10 * misses))
    if primary["false_activations"] or primary["lost"] or primary["damaged_rows"] > 1 or primary["gain"] < kill_gain:
        verdict = "KILL"
    elif primary["damaged_rows"] == 0 and primary["gain"] >= pass_gain:
        verdict = "PASS"
    else:
        verdict = "INCONCLUSIVE"

    exploration: dict = {"explore_point": measure(spots, manifest, targets, explore)}
    if all((options.run / f"{name}.taught.spot.jsonl").exists() for name in SETS):
        taught_meta, taught, _ = load(options.run, "taught")
        exploration["taught_baseline"] = measure(taught, manifest, taught_meta["targets"], None)
        exploration["taught_frozen"] = measure(taught, manifest, taught_meta["targets"], frozen)
        exploration["taught_explore"] = measure(taught, manifest, taught_meta["targets"], explore)
        exploration["taught_patterns"] = len(taught_meta["patterns"])
    spot_us = sorted(row["spot_us"] for row in spots.values())
    exploration["spot_us_p50"] = spot_us[len(spot_us) // 2]
    exploration["spot_us_p95"] = spot_us[int(len(spot_us) * 0.95)]
    exploration["rows"] = dict(Counter(row["set"] for row in spots.values()))
    exploration["real_rows_by_corpus"] = dict(Counter(manifest[i].get("corpus") for i, r in spots.items() if r["set"] == "real"))
    exploration["words_mismatch_rows"] = sum(not row["words_match_text"] for row in spots.values())

    metrics = {
        "verdict": verdict,
        "frozen_point": {"index": frozen, "grid": FROZEN},
        "misses": misses,
        "pass_gain_bar": pass_gain,
        "kill_gain_bar": kill_gain,
        "primary": primary,
        "exploration": exploration,
    }
    (options.run / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, indent=1)[:6000])


if __name__ == "__main__":
    main()
