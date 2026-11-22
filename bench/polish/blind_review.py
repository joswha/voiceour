#!/usr/bin/env python3
"""Randomize a local polish comparison. Only the separate key identifies the systems.

    python3 bench/polish/blind_review.py prepare --source cases.jsonl --model base=rows.jsonl --out-dir NEW_DIR
    python3 bench/polish/blind_review.py score --out-dir NEW_DIR --answers ratings.json

Each model supplies raw output and the frozen merge. --arm accepts an additional rendered output as-is. Sampling
is uniform over cases, not just disagreements. The page shows the source as context and also rates identity as a
candidate. Identical alternatives share one rating on a row. The export contains positions and ratings, not text.
"""
import argparse
import base64
import hashlib
import html
import json
import os
import random
import re
import secrets
import sys
from collections import Counter
from pathlib import Path

from polishlab import merge_allowed

ROOT = Path(__file__).resolve().parents[2]
MEANING = {"same": "Same meaning", "changed": "Meaning changed", "unsure": "Cannot tell"}
CLEANUP = {"enough": "Ready to use", "missed": "Noise or a fix remains", "excess": "Edited too much",
           "unsure": "Cannot tell"}
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}")


def read_rows(path, field):
    rows = {}
    with path.open(encoding="utf-8") as lines:
        for n, line in enumerate(lines, 1):
            try:
                r = json.loads(line)
                i, text = r["id"], r[field]
                if not isinstance(i, str) or not i or i in rows or not isinstance(text, str):
                    raise ValueError
            except (KeyError, TypeError, ValueError):
                raise ValueError(f"invalid or duplicate row {n} in {field} file") from None
            rows[i] = text
    return rows


def collect_arms(source, models, extras):
    arms = {"source": source}
    for transform, specs in ((True, models), (False, extras)):
        for spec in specs:
            name, sep, filename = spec.partition("=")
            if not sep or not filename or not NAME.fullmatch(name):
                raise ValueError("each arm needs a short name followed by = and its JSONL path")
            entries = read_rows(Path(filename).expanduser(), "output")
            if source.keys() != entries.keys():
                raise ValueError("case ids do not match the source; no partial comparison was written")
            new = {name: entries} if not transform else {
                name + "/raw": entries,
                name + "/merged": {i: merge_allowed(s, entries[i]) for i, s in source.items()},
            }
            if arms.keys() & new.keys():
                raise ValueError("duplicate arm name")
            arms.update(new)
    if len(arms) < 2:
        raise ValueError("supply at least one model or extra arm")
    return arms


def design(source, arms, sample, rng):
    if not source or sample < 1:
        raise ValueError("no cases to review or nonpositive sample size")
    deck, mapping = [], []
    for i in rng.sample(sorted(source), min(sample, len(source))):
        groups = {}
        for name, values in arms.items():
            groups.setdefault(values[i], []).append(name)
        outputs = list(groups)
        rng.shuffle(outputs)
        deck.append((source[i], outputs))
        mapping.append({"id": i, "slots": [groups[o] for o in outputs]})
    return deck, mapping


def choose(axis, options, group):
    choices = "".join(f'<label><input type="radio" name="{group}" value="{val}"> {label}</label>'
                      for val, label in options.items())
    return f'<fieldset data-axis="{axis}"><legend>{axis.capitalize()}</legend>{choices}</fieldset>'


def page(deck, study):
    sections = []
    for n, (src, outputs) in enumerate(deck):
        slots = []
        for k, out in enumerate(outputs):
            labels = choose("meaning", MEANING, f"m{n}-{k}") + choose("cleanup", CLEANUP, f"c{n}-{k}")
            slots.append(f'<article><h3>Version {k + 1}</h3><p class="text">{html.escape(out)}</p>{labels}</article>')
        sections.append(f'<section hidden><h2>Dictation {n + 1}</h2><b>Original transcript</b>'
                        f'<p class="text">{html.escape(src)}</p>' + "".join(slots) + '</section>')
    script = Path(__file__).with_name("blind_review.js").read_text(encoding="utf-8")
    integrity = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode("ascii")
    csp = f"default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-{integrity}'; form-action 'none'"
    return (f'<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" '
            f'content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="{csp}">'
            '<title>Private dictation comparison</title><style>body{font:16px/1.5 system-ui;max-width:56rem;'
            'margin:auto;padding:1rem}article{border-block-start:1px solid;padding:.25rem 0}label{display:inline-block;'
            'margin-right:.9rem}button{margin-right:.6rem;padding:.4rem}.text{white-space:pre-wrap;overflow-wrap:anywhere}'
            'fieldset{margin:.5rem 0;padding:.3rem .6rem}[hidden]{display:none}</style>'
            f'<body data-study="{study}"><h1>Private dictation comparison</h1>'
            '<p>Rate each version against the original. Judge meaning before cleanup. Identical text is shown once. '
            'The order changes for each dictation. No model names or verdicts are shown.</p>'
            '<nav><button id="prev">Previous</button><button id="next">Next</button>'
            '<button id="save">Export ratings</button><output id="progress" aria-live="polite"></output></nav>'
            '<p id="storage"></p>' + "".join(sections) + f'<script>{script}</script></body></html>')


def private_write(path, text):
    with os.fdopen(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w", encoding="utf-8") as dest:
        dest.write(text)


def prepare(src_path, model_specs, extra_specs, out_dir, sample):
    out = out_dir.expanduser().resolve()
    if out.is_relative_to(ROOT) or any((p / ".git").exists() for p in (out, *out.parents)):
        raise ValueError("private review files cannot go inside a Git work tree")
    source = read_rows(src_path, "input")
    arms = collect_arms(source, model_specs, extra_specs)
    deck, mapping = design(source, arms, sample, random.SystemRandom())
    study = secrets.token_hex(16)
    rendered = page(deck, study)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    private_write(out / "key.json", json.dumps({"version": 1, "study": study, "n_source": len(source),
                                                "arms": list(arms), "cases": mapping}))
    private_write(out / "review.html", rendered)
    return {"sampled": len(deck), "population": len(source), "distinct_versions": sum(len(o) for _, o in deck)}


def score(key, answers):
    if key["version"] != 1 or answers.get("version") != 1 or answers.get("study") != key["study"]:
        raise ValueError("ratings do not belong to this study")
    cases, records = key["cases"], answers.get("ratings")
    if not isinstance(records, list) or len(records) != len(cases):
        raise ValueError("ratings do not cover the study")
    by_arm = {s: Counter() for s in key["arms"]}
    good = {s: [] for s in by_arm}
    incomplete = 0
    for case, record in zip(cases, records, strict=True):
        if not isinstance(record, list) or len(record) != len(case["slots"]):
            raise ValueError("wrong number of alternatives")
        for arms, rating in zip(case["slots"], record, strict=True):
            if not isinstance(rating, dict) or set(rating) - {"meaning", "cleanup"}:
                raise ValueError("invalid rating")
            m, c = rating.get("meaning"), rating.get("cleanup")
            if (m is not None and m not in MEANING) or (c is not None and c not in CLEANUP):
                raise ValueError("unknown rating")
            if m is None or c is None:
                incomplete += 1
                continue
            for arm in arms:
                by_arm[arm]["meaning_" + m] += 1
                by_arm[arm]["cleanup_" + c] += 1
                good[arm].append(None if "unsure" in (m, c) else (m == "same" and c == "enough"))
    if incomplete:
        raise ValueError(f"{incomplete} versions still need ratings; results stay blind")
    report = {k: dict(v) for k, v in by_arm.items()}
    pairs = []
    for k, a in enumerate(key["arms"]):
        for b in key["arms"][k + 1:]:
            known = [(x, y) for x, y in zip(good[a], good[b], strict=True) if x is not None and y is not None]
            pairs.append({"arms": [a, b], "rated_without_uncertainty": len(known),
                          "first_only_usable": sum(x and not y for x, y in known),
                          "second_only_usable": sum(y and not x for x, y in known)})
    return {"fully_rated_cases": len(cases), "per_arm": report, "paired": pairs}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subs = ap.add_subparsers(dest="cmd", required=True)
    prep = subs.add_parser("prepare")
    prep.add_argument("--source", required=True, type=Path)
    prep.add_argument("--model", action="append", default=[])
    prep.add_argument("--arm", action="append", default=[])
    prep.add_argument("--sample", type=int, default=60)
    sc = subs.add_parser("score")
    sc.add_argument("--answers", required=True, type=Path)
    for cmd in (prep, sc):
        cmd.add_argument("--out-dir", required=True, type=Path)
    args = ap.parse_args()
    try:
        if args.cmd == "prepare":
            result = prepare(args.source.expanduser(), args.model, args.arm, args.out_dir, args.sample)
        else:
            key = json.loads((args.out_dir / "key.json").read_bytes())
            result = score(key, json.loads(args.answers.read_bytes()))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"blind review: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
