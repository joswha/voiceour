#!/usr/bin/env python3

"""Generate VoiceCore's ordinary-word resource from the frozen repair vocabulary."""

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "bench" / "autoresearch" / "repair.vocabulary.json"
DEFAULT_OUTPUT = ROOT / "Sources" / "VoiceCore" / "Resources" / "ordinary-words.txt"


def string_array(document: dict[str, object], key: str) -> list[str]:
    value = document.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{key} must be an array of strings")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    document = json.loads(args.source.read_text(encoding="utf-8"))
    words = sorted(
        set(string_array(document, "ordinary_words"))
        | set(string_array(document, "single_letter_words"))
    )
    if any(not word or "\n" in word or "\r" in word for word in words):
        raise ValueError("ordinary words must be non-empty single-line strings")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(("\n".join(words) + "\n").encode("utf-8"))
    print(f"wrote {len(words)} words to {args.output}")


if __name__ == "__main__":
    main()
