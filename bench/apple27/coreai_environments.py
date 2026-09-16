"""Print (never execute) exact isolated environment installation commands."""

from __future__ import annotations

import argparse
import shlex
from pathlib import Path

BASE = (
    "coreai-core==1.0.0b2",
    "coreai-torch==0.4.2",
    "torch==2.11.0",
    "numpy",
    "scipy",
    "soundfile",
)
ENVIRONMENTS = {
    "parakeet": (*BASE, "transformers[audio]==5.9.0"),
    "whisper": (*BASE, "transformers==4.57.3"),
    "wav2vec2": (*BASE, "torchaudio==2.11.0"),
}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print separate Python 3.12 uv environments; no installs or downloads are executed.",
        epilog="Both Whisper variants share their environment. Never install Parakeet's Transformers 5.9 "
        "over Whisper's 4.57.3. Export manifests record every installed dependency version. "
        "Apple exporter pins coreai-torch 0.4.1; these prototypes explicitly use the existing 0.4.2 toolchain.",
    )
    parser.add_argument("engine", choices=ENVIRONMENTS)
    parser.add_argument("--directory", type=Path, help="Default .build/apple27/envs/<engine>")
    args = parser.parse_args()
    directory = args.directory or Path(".build/apple27/envs") / args.engine
    print(shlex.join(["uv", "--no-config", "venv", "--python", "3.12", str(directory)]))
    print(
        shlex.join(
            [
                "uv",
                "--no-config",
                "pip",
                "install",
                "--python",
                str(directory / "bin/python"),
                "--prerelease",
                "allow",
                *ENVIRONMENTS[args.engine],
            ]
        )
    )


if __name__ == "__main__":
    main()
