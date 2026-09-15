"""Stage 2 of the Core AI encoder experiment: convert the exported encoder.

Runs on the Mac, in this directory's own uv project, and never imports NeMo: the
source-checkpoint provenance arrives in the sidecar `export_encoder.py` wrote
beside the `.pt2` on the devbox. From the repository root:

    cd bench/coreai && uv sync
    cd bench/coreai && uv run python convert_encoder.py \
        --program encoder-15s.pt2 \
        --output ../../.build/coreai/parakeet-encoder-15s.aimodel

That writes the `.aimodel` and, beside it,
`parakeet-encoder-15s.manifest.json`: source checkpoint, exported program,
artifact tree digest, tool versions and the `coreai-torch` pin, the IO contract,
and the two smoke differences against the `.pt2` program's own output.

Deliberately out of scope, as the plan says: no AOT compilation (`coreai-build`
is absent on this Mac, so the artifact is specialized at runtime) and no
palettization — the weights keep whatever precision `optimize()` leaves, which
the manifest records as `compression: "none"`.

The small digest helpers are duplicated from `export_encoder.py` rather than
shared: the two stages run on different machines and each must be a single file.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import hashlib
import json
import platform
import shutil
import sys
import tomllib
from dataclasses import dataclass, field
from datetime import UTC, datetime
from importlib import metadata
from pathlib import Path

import numpy as np
import torch
from coreai.runtime import NDArray
from coreai_torch import TorchConverter, get_decomp_table

TOOL = "convert_encoder.py"

# The IO contract is the Core ML tier's, verbatim (CoreMLEncoder.validate).
MEL_BINS = 128
MEL_FRAMES = 1_501
ENCODER_CHANNELS = 1_024
SUBSAMPLING = 8
ENCODER_FRAMES = (MEL_FRAMES + SUBSAMPLING - 1) // SUBSAMPLING

FUNCTION_NAME = "main"
INPUT_NAMES = ["mel", "mel_length"]
OUTPUT_NAMES = ["encoder", "encoder_length"]

IO_CONTRACT = {
    "function": FUNCTION_NAME,
    "inputs": [
        {"name": "mel", "dtype": "float32", "shape": [1, MEL_BINS, MEL_FRAMES]},
        {"name": "mel_length", "dtype": "int32", "shape": [1]},
    ],
    "outputs": [
        {"name": "encoder", "dtype": "float32", "shape": [1, ENCODER_CHANNELS, ENCODER_FRAMES]},
        {"name": "encoder_length", "dtype": "int32", "shape": [1]},
    ],
}

MANIFEST_SCHEMA = "voiceour.coreai.artifact/1"
EXPORT_SIDECAR_SCHEMA = "voiceour.coreai.export/1"
DEFAULT_SEED = 20_260_915

READ_CHUNK_BYTES = 8 * 1024 * 1024


@dataclass
class SmokeCase:
    """One input pair plus the `.pt2` program's own answer for it."""

    name: str
    mel: np.ndarray
    mel_length: np.ndarray
    reference_encoder: np.ndarray
    reference_length: int
    extra: dict = field(default_factory=dict)


def sha256_file(path: Path) -> tuple[str, int]:
    """Return the file's hex SHA-256 and its byte size, read in one pass."""
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(READ_CHUNK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def artifact_digest(path: Path) -> dict:
    """Digest a file or a directory tree by the experiment's artifact rule.

    Every regular file (symlinks excluded, so the rule stays literal), sorted by
    relative POSIX path — a lone file uses its own basename — contributes one
    ``"<relative path> <hex sha256>\\n"`` line. The artifact digest is the
    SHA-256 of those lines concatenated as UTF-8; the byte total is the sum of
    the file sizes. This is the rule the Swift bench's
    `encoder_meta.model_tree_sha256` reports, so the two are comparable.
    """
    if path.is_dir():
        pairs = [
            (entry.relative_to(path).as_posix(), entry)
            for entry in path.rglob("*")
            if entry.is_file() and not entry.is_symlink()
        ]
        pairs.sort(key=lambda item: item[0])
        kind = "directory"
    elif path.is_file():
        pairs = [(path.name, path)]
        kind = "file"
    else:
        raise SystemExit(f"{TOOL}: not a file or a directory: {path}")

    if not pairs:
        raise SystemExit(f"{TOOL}: no regular files to digest under {path}")

    files: list[dict] = []
    lines: list[str] = []
    total = 0
    for relative, entry in pairs:
        digest, size = sha256_file(entry)
        files.append({"path": relative, "sha256": digest, "size_bytes": size})
        lines.append(f"{relative} {digest}\n")
        total += size
    return {
        "kind": kind,
        "tree_sha256": hashlib.sha256("".join(lines).encode("utf-8")).hexdigest(),
        "total_bytes": total,
        "file_count": len(files),
        "files": files,
    }


def now_utc() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def distribution_version(name: str) -> str | None:
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError:
        return None


def declared_coreai_torch_pin() -> tuple[str | None, str | None]:
    """The `coreai-torch` requirement and its git SHA as this project declares them."""
    project = Path(__file__).resolve().parent / "pyproject.toml"
    if not project.is_file():
        return None, None
    data = tomllib.loads(project.read_text(encoding="utf-8"))
    for requirement in data.get("project", {}).get("dependencies", []):
        if not requirement.startswith("coreai-torch"):
            continue
        url = requirement.split("@", 1)[1].strip() if "@" in requirement else None
        sha = requirement.rsplit("@", 1)[1].strip() if url and "@" in url else None
        return url, sha
    return None, None


def coreai_torch_pin() -> dict:
    """Pair the declared pin with the commit actually installed.

    uv records the resolved commit in the distribution's PEP 610
    `direct_url.json`, so the manifest carries a measured commit rather than a
    restatement of the requirement. A resolved commit that disagrees with the
    declared pin is fatal: the artifact would otherwise be attributed to a
    commit that did not build it.
    """
    declared_url, declared_sha = declared_coreai_torch_pin()
    resolved: str | None = None
    installed_url: str | None = None
    try:
        distribution = metadata.distribution("coreai-torch")
    except metadata.PackageNotFoundError:
        distribution = None
    if distribution is not None:
        raw = distribution.read_text("direct_url.json")
        if raw:
            record = json.loads(raw)
            installed_url = record.get("url")
            resolved = (record.get("vcs_info") or {}).get("commit_id")
    if resolved is not None and declared_sha is not None and resolved != declared_sha:
        raise SystemExit(
            f"{TOOL}: the installed coreai-torch is commit {resolved}, but "
            f"bench/coreai/pyproject.toml pins {declared_sha}. Re-run `uv sync` in bench/coreai."
        )
    return {
        "url": installed_url or declared_url,
        "declared_sha": declared_sha,
        "resolved_commit_id": resolved,
    }


def convert_versions() -> dict:
    return {
        "python": platform.python_version(),
        "torch": torch.__version__,
        "numpy": np.__version__,
        "coreai_torch": distribution_version("coreai-torch"),
        "coreai_core": distribution_version("coreai-core"),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "coreai_torch_git": coreai_torch_pin(),
    }


def read_export_sidecar(path: Path, program: Path) -> dict:
    """Load the stage-1 sidecar and refuse anything that cannot describe this program."""
    if not path.is_file():
        raise SystemExit(
            f"{TOOL}: missing export sidecar {path}.\n"
            f"{TOOL}: copy it from the devbox beside {program.name}, or pass --export-metadata. "
            f"The source checkpoint's digest is measured there and is never invented here."
        )
    record = json.loads(path.read_text(encoding="utf-8"))
    if record.get("schema") != EXPORT_SIDECAR_SCHEMA:
        raise SystemExit(f"{TOOL}: {path} is schema {record.get('schema')!r}, expected {EXPORT_SIDECAR_SCHEMA!r}")
    if record.get("status") != "ok":
        raise SystemExit(f"{TOOL}: {path} records status {record.get('status')!r}; the export did not complete")
    if record.get("io") != IO_CONTRACT:
        raise SystemExit(
            f"{TOOL}: {path} records a different IO contract than this script expects.\n"
            f"  sidecar:  {json.dumps(record.get('io'), sort_keys=True)}\n"
            f"  expected: {json.dumps(IO_CONTRACT, sort_keys=True)}"
        )
    source = record.get("source_checkpoint") or {}
    for key in ("model_id", "revision", "sha256", "size_bytes"):
        if not source.get(key):
            raise SystemExit(f"{TOOL}: {path} has no source_checkpoint.{key}")
    if not (record.get("exported_program") or {}).get("sha256"):
        raise SystemExit(f"{TOOL}: {path} has no exported_program.sha256")
    if not isinstance(record.get("versions"), dict) or not record["versions"]:
        raise SystemExit(f"{TOOL}: {path} has no versions record; the manifest copies it verbatim")
    return record


def load_exported_program(path: Path) -> torch.export.ExportedProgram:
    if not path.is_file():
        raise SystemExit(f"{TOOL}: missing exported program: {path}")
    try:
        return torch.export.load(path)
    except Exception as error:
        raise RuntimeError(f"{TOOL}: torch.export.load failed for {path}") from error


def reference_outputs(module: torch.nn.Module, program: Path, mel: np.ndarray, mel_length: np.ndarray) -> tuple:
    """Run the `.pt2` program once and hold its answer to the IO contract."""
    with torch.no_grad():
        states, lengths = module(torch.from_numpy(mel), torch.from_numpy(mel_length))
    expected = (1, ENCODER_CHANNELS, ENCODER_FRAMES)
    if tuple(states.shape) != expected or states.dtype != torch.float32:
        raise SystemExit(
            f"{TOOL}: {program} produced encoder {tuple(states.shape)} {states.dtype}, "
            f"expected {expected} torch.float32"
        )
    if tuple(lengths.shape) != (1,):
        raise SystemExit(f"{TOOL}: {program} produced encoder_length {tuple(lengths.shape)}, expected (1,)")
    return states.detach().cpu().numpy().copy(), int(lengths.reshape(-1)[0])


def build_smoke_cases(module: torch.nn.Module, program: Path, seed: int) -> list[SmokeCase]:
    """The zero mel and one seeded random mel, with the program's own outputs."""
    mel_length = np.array([MEL_FRAMES], dtype=np.int32)

    zero_mel = np.zeros((1, MEL_BINS, MEL_FRAMES), dtype=np.float32)
    generator = torch.Generator().manual_seed(seed)
    random_mel = torch.randn(1, MEL_BINS, MEL_FRAMES, generator=generator).numpy().copy()

    cases: list[SmokeCase] = []
    for name, mel, extra in (("zero", zero_mel, {}), ("random", random_mel, {"seed": seed})):
        encoder, length = reference_outputs(module, program, mel, mel_length)
        cases.append(
            SmokeCase(
                name=name,
                mel=mel,
                mel_length=mel_length,
                reference_encoder=encoder,
                reference_length=length,
                extra=extra,
            )
        )
    return cases


def convert(program: torch.export.ExportedProgram, source: Path, pin: dict):
    """Decompose, convert to Core AI IR and optimize; no compression is applied."""
    try:
        decomposed = program.run_decompositions(get_decomp_table())
    except Exception as error:
        raise RuntimeError(f"{TOOL}: run_decompositions failed for {source}") from error
    try:
        coreai_program = (
            TorchConverter()
            .add_exported_program(decomposed, input_names=INPUT_NAMES, output_names=OUTPUT_NAMES)
            .to_coreai()
        )
        coreai_program.optimize()
    except Exception as error:
        raise RuntimeError(
            f"{TOOL}: coreai-torch conversion failed for {source} "
            f"(coreai-torch {pin.get('resolved_commit_id') or pin.get('declared_sha')})"
        ) from error
    return coreai_program, decomposed


async def run_smoke(asset, artifact: Path, cases: list[SmokeCase]) -> dict:
    """Run every case through the Core AI runtime and diff against the `.pt2`."""
    results: dict = {}
    async with asset.executable() as model:
        available = list(model.function_names)
        if FUNCTION_NAME not in available:
            raise SystemExit(f"{TOOL}: {artifact} exposes {available}, not a {FUNCTION_NAME!r} function")
        function = model.load_function(FUNCTION_NAME)
        desc = function.desc
        if list(desc.input_names) != INPUT_NAMES:
            raise SystemExit(f"{TOOL}: {artifact} takes inputs {list(desc.input_names)}, expected {INPUT_NAMES}")
        if list(desc.output_names) != OUTPUT_NAMES:
            raise SystemExit(f"{TOOL}: {artifact} returns outputs {list(desc.output_names)}, expected {OUTPUT_NAMES}")

        for case in cases:
            outputs = await function({"mel": NDArray(case.mel), "mel_length": NDArray(case.mel_length)})
            missing = [name for name in OUTPUT_NAMES if name not in outputs]
            if missing:
                raise SystemExit(
                    f"{TOOL}: {artifact} returned {sorted(outputs)} on the {case.name} mel; missing {missing}"
                )
            encoder = outputs["encoder"].numpy()
            encoder_length = outputs["encoder_length"].numpy()

            expected = (1, ENCODER_CHANNELS, ENCODER_FRAMES)
            if tuple(encoder.shape) != expected or encoder.dtype != np.float32:
                raise SystemExit(
                    f"{TOOL}: {artifact} returned encoder {tuple(encoder.shape)} on the {case.name} mel, "
                    f"expected {expected}"
                )
            if tuple(encoder_length.shape) != (1,) or encoder_length.dtype != np.int32:
                raise SystemExit(
                    f"{TOOL}: {artifact} returned encoder_length {tuple(encoder_length.shape)} on the "
                    f"{case.name} mel, expected int32 [1]"
                )
            runtime_length = int(encoder_length.reshape(-1)[0])
            if runtime_length != case.reference_length or not np.isfinite(encoder).all():
                raise RuntimeError(f"{TOOL}: {artifact} returned invalid states or encoder_length on {case.name}")
            difference = float(np.abs(encoder.astype(np.float32) - case.reference_encoder).max())
            record = {
                "max_abs_diff": difference,
                "encoder_shape": list(encoder.shape),
                "encoder_length_shape": list(encoder_length.shape),
                "encoder_length_reference": case.reference_length,
                "encoder_length_runtime": runtime_length,
            }
            record.update(case.extra)
            results[case.name] = record
    return results


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=TOOL,
        description="Convert the exported Parakeet encoder to a Core AI .aimodel and record its provenance.",
    )
    parser.add_argument("--program", required=True, type=Path, help="the .pt2 written by export_encoder.py")
    parser.add_argument("--output", required=True, type=Path, help="the .aimodel artifact to write")
    parser.add_argument(
        "--export-metadata",
        type=Path,
        default=None,
        help="the stage-1 sidecar; defaults to the program with a .export.json suffix",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="the artifact manifest to write; defaults to the output with a .manifest.json suffix",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="seed for the random smoke mel")
    parser.add_argument("--force", action="store_true", help="overwrite an existing artifact or manifest")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    program_path: Path = args.program
    artifact: Path = args.output
    sidecar_path: Path = (
        args.export_metadata if args.export_metadata is not None else program_path.with_suffix(".export.json")
    )
    manifest_path: Path = args.manifest if args.manifest is not None else artifact.with_suffix(".manifest.json")

    if artifact.suffix != ".aimodel":
        raise SystemExit(f"{TOOL}: --output must name a .aimodel directory: {artifact}")
    for existing in (artifact, manifest_path):
        if existing.exists() and not args.force:
            raise SystemExit(f"{TOOL}: refusing to overwrite {existing}; pass --force or remove it")

    sidecar = read_export_sidecar(sidecar_path, program_path)
    pin = coreai_torch_pin()

    measured = artifact_digest(program_path)
    recorded_sha = sidecar["exported_program"]["sha256"]
    if measured["files"][0]["sha256"] != recorded_sha:
        raise SystemExit(
            f"{TOOL}: {program_path} is not the program {sidecar_path} describes.\n"
            f"  measured sha256={measured['files'][0]['sha256']}\n"
            f"  sidecar  sha256={recorded_sha}"
        )

    print(f"{TOOL}: loading {program_path}", flush=True)
    exported = load_exported_program(program_path)
    module = exported.module()
    print(f"{TOOL}: running the exported program on the zero and seeded-random mels", flush=True)
    cases = build_smoke_cases(module, program_path, args.seed)

    print(f"{TOOL}: converting to Core AI IR", flush=True)
    coreai_program, decomposed = convert(exported, program_path, pin)

    # The torch side holds ~2.4 GB of encoder weights that the Core AI program no
    # longer needs; drop them before the runtime loads its own copy.
    del decomposed, module, exported
    gc.collect()

    artifact.parent.mkdir(parents=True, exist_ok=True)
    if artifact.exists():
        if artifact.is_dir():
            shutil.rmtree(artifact)
        else:
            artifact.unlink()
    print(f"{TOOL}: writing {artifact}", flush=True)
    try:
        asset = coreai_program.save_asset(artifact)
    except Exception as error:
        raise RuntimeError(f"{TOOL}: save_asset failed for {artifact}") from error

    print(f"{TOOL}: smoking the artifact through the Core AI runtime", flush=True)
    smoke = asyncio.run(run_smoke(asset, artifact, cases))

    artifact_record = artifact_digest(artifact)
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "status": "ok",
        "created_at": now_utc(),
        "compression": "none",
        "aot": False,
        "palettization": False,
        "source_checkpoint": sidecar["source_checkpoint"],
        "exported_program": {
            "file": program_path.name,
            "sha256": measured["files"][0]["sha256"],
            "size_bytes": measured["total_bytes"],
            "tree_sha256": measured["tree_sha256"],
            "strict": sidecar["exported_program"].get("strict"),
            "retried_non_strict": sidecar["exported_program"].get("retried_non_strict"),
        },
        "artifact": {
            "path": str(artifact),
            "file": artifact.name,
            **artifact_record,
        },
        "io": IO_CONTRACT,
        "versions": {
            "export": sidecar["versions"],
            "convert": convert_versions(),
        },
        "smoke": smoke,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8")

    print(f"{TOOL}: artifact        {artifact}")
    print(f"{TOOL}: tree sha256     {artifact_record['tree_sha256']}")
    print(f"{TOOL}: tree bytes      {artifact_record['total_bytes']} in {artifact_record['file_count']} files")
    print(f"{TOOL}: compression     none")
    for name, result in smoke.items():
        print(
            f"{TOOL}: smoke {name:<9} encoder {result['encoder_shape']} "
            f"encoder_length {result['encoder_length_shape']}={result['encoder_length_runtime']} "
            f"max|diff|={result['max_abs_diff']:.6g}"
        )
    print(f"{TOOL}: manifest        {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
