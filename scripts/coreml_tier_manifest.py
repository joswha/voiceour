#!/usr/bin/env python3
"""Generate a Voiceour ASR model manifest (schema v1) for a CoreML encoder tier set.

The manifest is the artifact-hosting side of the experimental ANE encoder path: it
names every file of each compiled tier with its digest and size, the runtime that
consumes them, the source checkpoint they were converted from, and an admission
status. The app does not read this file today; it exists so that hosting the tier
artifacts is a decision about infrastructure, not about tooling.

Stdlib only. The output is structurally validated against the checked-in schema's
required fields and value patterns before it is written; a validation failure is a
non-zero exit, never a best-effort manifest.

Usage:
  scripts/coreml_tier_manifest.py \
    --tiny PATH.mlmodelc --short PATH.mlmodelc --standard PATH.mlmodelc \
    --notice Vendor/parakeet/NOTICE.md \
    --output manifest.json
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

SOURCE_REPOSITORY = "ggml-org/parakeet-GGUF"
SOURCE_REVISION = "35156454d1a39de06863303dd209fd2bed6ee079"
SOURCE_MODEL_ID = "parakeet-tdt-0.6b-v3-encoder-6bit-palettized"
ENGINE = "parakeet-coreml"
ENGINE_REVISION = "592feef04a1802b18cbeffd0fd0eb5d02570c2ec"
HELPER = "voiceour-asr"
CONVERSION_TOOL = "coremltools 9.0b1 kmeans palettization, 6-bit per_grouped_channel g=32"
TIER_BOUNDS = {"tiny": 6.0, "short": 8.0, "standard": 15.0}

PATH_RE = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))(?!.*\\)[A-Za-z0-9._/-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tier_files(name: str, root: Path) -> list[dict]:
    if not root.is_dir() or root.suffix != ".mlmodelc":
        raise SystemExit(f"{name}: {root} is not a compiled .mlmodelc directory")
    entries = []
    for file in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = f"{name}/{root.name}/{file.relative_to(root)}"
        if not PATH_RE.match(rel):
            raise SystemExit(f"{name}: path {rel!r} violates the manifest path pattern")
        entries.append(
            {
                "path": rel,
                "role": "compiledGraph",
                "format": "mlmodelc",
                "sha256": sha256_file(file),
                "sizeBytes": file.stat().st_size,
            }
        )
    if not entries:
        raise SystemExit(f"{name}: {root} contains no files")
    return entries


def repo_head() -> str:
    out = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    )
    return out.stdout.strip()


def validate(manifest: dict) -> None:
    for key in ("schemaVersion", "runtime", "source", "files", "capabilities", "limits", "license"):
        if key not in manifest:
            raise SystemExit(f"manifest missing required key {key}")
    if manifest["schemaVersion"] != 1:
        raise SystemExit("schemaVersion must be 1")
    files = manifest["files"]
    if not 1 <= len(files) <= 64:
        raise SystemExit(f"files count {len(files)} outside schema bounds 1..64")
    for entry in files:
        if not PATH_RE.match(entry["path"]) or len(entry["path"]) > 240:
            raise SystemExit(f"bad file path {entry['path']!r}")
        if not SHA_RE.match(entry["sha256"]):
            raise SystemExit(f"bad sha256 for {entry['path']!r}")
        if not 1 <= entry["sizeBytes"] <= 17179869184:
            raise SystemExit(f"bad sizeBytes for {entry['path']!r}")
    if not re.match(r"^[0-9a-f]{40}$", manifest["source"]["revision"]):
        raise SystemExit("source.revision must be a 40-hex commit")
    if not SHA_RE.match(manifest["license"]["noticeSha256"]):
        raise SystemExit("license.noticeSha256 must be 64-hex")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tiny", required=True, type=Path)
    parser.add_argument("--short", required=True, type=Path)
    parser.add_argument("--standard", required=True, type=Path)
    parser.add_argument("--notice", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    files: list[dict] = []
    for name, root in (("tiny", args.tiny), ("short", args.short), ("standard", args.standard)):
        files.extend(tier_files(name, root))

    total_bytes = sum(entry["sizeBytes"] for entry in files)
    manifest = {
        "schemaVersion": 1,
        "runtime": {
            "helper": HELPER,
            "engine": ENGINE,
            "engineRevision": ENGINE_REVISION,
        },
        "source": {
            "repository": SOURCE_REPOSITORY,
            "revision": SOURCE_REVISION,
            "modelId": SOURCE_MODEL_ID,
            "conversion": {
                "tool": CONVERSION_TOOL,
                "revision": repo_head(),
                "reproducible": False,
            },
        },
        "files": files,
        "capabilities": {
            "modes": ["finalUtterance"],
            "languages": ["en"],
            "languageSelection": "fixed",
            "formatting": "punctuationAndCase",
            "timestamps": "word",
            "confidence": {"kind": "tokenPosterior", "usable": True},
        },
        "limits": {
            "maxAudioSeconds": TIER_BOUNDS["standard"],
            "maxDownloadBytes": total_bytes,
            "maxResidentBytes": total_bytes,
        },
        "license": {
            "spdx": "CC-BY-4.0",
            "commercialUse": True,
            "noticeSha256": sha256_file(args.notice),
        },
        "admission": {
            "status": "researchOnly",
            "blockers": [
                "cross-SoC replication outstanding (all evidence is one M4 Pro)",
                "artifact hosting decision and Makefile environment forwarding are maintainer-owned",
            ],
            "validatedThroughAudioSeconds": 71356.0,
        },
    }
    validate(manifest)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(
        f"manifest: {len(files)} files, {total_bytes / 1e6:.1f} MB across 3 tiers -> {args.output}"
    )


if __name__ == "__main__":
    main()
