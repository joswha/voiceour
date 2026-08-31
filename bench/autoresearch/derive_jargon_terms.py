"""Derive per-row canonical-term annotations for the frozen jargon corpus.

One-shot generator for `bench/autoresearch/jargon.terms.json`, committed for
provenance. The jargon manifest (`benchmarks/data/jargon/manifest.jsonl`) is a
frozen, SHA-pinned local dataset whose row ids encode `jg_NNNN_<domain>_<slug>`.
For positive rows (domain != "negative") the slug names a technical term whose
canonical orthography appears verbatim in the properly cased reference; this
script locates that surface deterministically and records it. Negative rows are
ordinary prose whose slug is a truncated sentence prefix; they carry no
canonical term and exist to expose false replacements and false re-casings.

The scorer treats the emitted JSON as the term ground truth:
- positives: exact case-sensitive canonical surface for recall
- negatives: rows on which any canonical surface absent from the reference
  counts as a false term, and case-preserving WER guards re-casing damage

Regeneration requires the identical manifest; the derivation is a pure
function of it. Run from `bench/`:

    uv --no-config run --offline python autoresearch/derive_jargon_terms.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "benchmarks/data/jargon/manifest.jsonl"
OUTPUT = Path(__file__).resolve().parent / "jargon.terms.json"

ID_PATTERN = re.compile(r"^jg_(\d{4})_([a-z0-9]+)_(.+)$")
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9+#./_-]+")
MAX_SURFACE_TOKENS = 5


def normalize(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", text.lower())


def find_surface(reference: str, slug: str) -> str | None:
    """Locate the slug's cased surface form in the reference text."""
    slug_norm = normalize(slug)
    tokens = TOKEN_PATTERN.findall(reference)
    for width in range(1, MAX_SURFACE_TOKENS + 1):
        for start in range(len(tokens) - width + 1):
            window = tokens[start : start + width]
            if normalize("".join(window)) == slug_norm:
                return " ".join(window).strip(".,")
    return None


def main() -> int:
    rows = [
        json.loads(line)
        for line in MANIFEST.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    annotations: dict[str, dict] = {}
    failures: list[str] = []
    for row in rows:
        match = ID_PATTERN.match(row["id"])
        if match is None:
            failures.append(f"unparseable id {row['id']!r}")
            continue
        domain = match.group(2)
        if domain == "negative":
            annotations[row["id"]] = {"domain": domain}
            continue
        surface = find_surface(row["reference"], match.group(3))
        if surface is None:
            failures.append(f"no canonical surface for {row['id']!r}")
            continue
        annotations[row["id"]] = {"domain": domain, "canonical": surface}

    if failures:
        for reason in failures:
            print(f"derive_jargon_terms.py: FAIL: {reason}", file=sys.stderr)
        return 1

    positives = sum(1 for entry in annotations.values() if "canonical" in entry)
    negatives = len(annotations) - positives
    OUTPUT.write_text(
        json.dumps(annotations, indent=1, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"derive_jargon_terms.py: wrote {OUTPUT.name}: "
        f"{positives} positives, {negatives} negatives"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
