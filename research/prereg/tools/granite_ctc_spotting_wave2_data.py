"""Builds the fresh data of research/prereg/granite-ctc-word-spotting-wave2.md.

Positives and hard negatives are synthesized offline with macOS `say` into files (no playback) and
converted to 16 kHz mono 16-bit WAV with `afconvert`. Real speech comes from the test splits of
`hf-audio/open-asr-leaderboard` through the bench's own dataset helpers. Taught aliases for the
exploratory arm are derived from wave 1's baseline outputs.

    uv --no-config run --project bench python research/prereg/tools/granite_ctc_spotting_wave2_data.py \
        --out .build/spot/wave2 --wave1 .build/spot/run1 --terms bench/autoresearch/jargon.terms.json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bench" / "src"))

from datasets import Audio, load_dataset  # noqa: E402
from voiceour_bench import datasets_prep as dp  # noqa: E402

VOICES = ["Daniel", "Karen", "Moira", "Rishi"]

TEMPLATES = [
    "Can you check whether {t} is set up correctly on the new machine?",
    "We decided to replace the old setup with {t} next quarter.",
    "I just read the release notes for {t} and nothing looks risky.",
    "Please add a short note about {t} to the onboarding guide.",
    "Does {t} still work after the latest upgrade?",
    "The second option uses {t}, which the team already knows well.",
    "Let me open {t} and walk you through the configuration.",
    "Our tests started failing right after {t} changed its defaults.",
]

NEGATIVES = [
    "We explored the cave behind the old mill.",
    "She runs a small bakery near the station.",
    "I am not sure the train leaves at noon.",
    "The child stacked a cube on the kitchen table.",
    "The red dish slipped and broke on the floor.",
    "A bird built a nest in the old oak tree.",
    "My nephew loves the dino toy he got for his birthday.",
    "Add some fresh basil to the sauce before serving.",
    "The avocado on the counter is finally ripe.",
    "I could have called you earlier this morning.",
    "We could then leave a little earlier tomorrow.",
    "The argument went on far longer than anyone expected.",
    "The boats were tied up along the dock all night.",
    "Her grade on the final exam was better than expected.",
    "Please post it to the front desk by Friday.",
    "Please hand me the instrument case by the door.",
    "Be quick, the train is about to leave.",
    "What a lovely view from the balcony.",
    "We drank warm apple cider by the fire.",
    "She can name every bird in the park.",
    "Is it so hard to call ahead?",
    "That a dog could open the gate surprised everyone.",
    "The queue at the bakery was longer than usual.",
    "We launched the boat at sunrise.",
    "The closure of the bridge delayed everyone.",
    "The sequel lit up the box office last summer.",
    "My map of the city is completely out of date.",
    "The view did look amazing from the summit.",
    "The jet flew low over the empty beach.",
    "The cotton shirt shrank in the wash.",
    "They planted terraced gardens on the hillside.",
    "A pod of dolphins swam alongside the ferry.",
    "The guard dog barked at the delivery van.",
    "Grandpa told us a story about his old village.",
    "The kettle started to whistle on the stove.",
    "They found a hidden stash of coins in the wall.",
    "My aunt makes the best apple pie in town.",
    "He forgot to water the plants before leaving.",
    "We watched the sun set over the harbor.",
    "She hummed a tune while folding the laundry.",
    "The library closes early on Sundays.",
    "Turn left at the bakery and walk two blocks.",
    "The puppy chewed through the garden hose.",
    "Can you pass the salt and the pepper?",
    "The meeting moved to Thursday afternoon.",
    "He wore a heavy coat because of the wind.",
    "I need a minute to finish this email.",
    "The bus was late again this morning.",
    "They painted the fence a bright shade of green.",
    "Grandma knits scarves for the whole family.",
    "The engine made a strange rattling noise.",
    "The road through the valley was closed for repairs.",
    "Please water the tomatoes while I am away.",
    "Is it true that the bridge will open next week?",
    "Ken loves to tinker with old radios.",
    "The jungle path was muddy after the storm.",
    "They followed the deer tracks into the forest.",
    "He used a sharp chisel to carve the wood.",
    "Our neighbors adopted two cats last spring.",
    "The soup needs a little more salt.",
]

# The preregistration named tedlium too; on 2026-11-06 the hub repository no longer holds its data
# files (the config resolves to zero rows), so wave 2 runs on the other three, decided before any
# wave-2 output existed.
REAL_SPEECH = [("voxpopuli", None), ("earnings22", None), ("gigaspeech", 2000)]


def synthesize(text: str, voice: str, wav: Path) -> None:
    """Writes `text` in `voice` to `wav`, keeping a file an earlier run completed.

    `say` occasionally stalls forever on one request, so each attempt is bounded and retried; the
    text, voice and conversion are unchanged, so a retry writes the same audio.
    """
    if wav.exists() and wav.stat().st_size > 0:
        return
    wav.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(3):
        with tempfile.TemporaryDirectory() as scratch:
            aiff = Path(scratch) / "speech.aiff"
            partial = wav.with_suffix(".partial.wav")
            try:
                subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True, timeout=120)
                subprocess.run(
                    ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(partial)],
                    check=True,
                    timeout=120,
                )
            except subprocess.TimeoutExpired:
                print(f"say timed out on attempt {attempt + 1}: {voice}: {text}", flush=True)
                continue
            partial.replace(wav)
            return
    raise RuntimeError(f"say failed three times: {voice}: {text}")


def row(row_id: str, wav: Path, reference: str, **extra) -> dict:
    return {
        "id": row_id,
        "audio_path": str(wav.resolve()),
        "reference": reference,
        "audio_s": dp._audio_seconds(wav),
        **dp._audio_identity(wav),
        **extra,
    }


def write(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for item in rows:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")
    print(path, len(rows), flush=True)


def synthetic(out: Path, targets: list[str]) -> None:
    positives = []
    for index, term in enumerate(targets):
        for slot in (0, 1):
            template = TEMPLATES[(index + 3 * slot) % len(TEMPLATES)]
            voice = VOICES[(2 * index + slot) % len(VOICES)]
            text = template.format(t=term)
            slug = re.sub(r"[^a-z0-9]+", "_", term.lower()).strip("_")
            wav = out / "audio" / f"p2_{index:03d}_{slot}_{slug}.wav"
            synthesize(text, voice, wav)
            positives.append(row(f"p2_{index:03d}_{slot}_{slug}", wav, text, canonical_term=term, voice=voice))
    write(out / "positives.manifest.jsonl", positives)

    negatives = []
    for index, text in enumerate(NEGATIVES):
        for voice in (VOICES[index % 4], VOICES[(index + 2) % 4]):
            wav = out / "audio" / f"n2_{index:03d}_{voice.lower()}.wav"
            synthesize(text, voice, wav)
            negatives.append(row(f"n2_{index:03d}_{voice.lower()}", wav, text, voice=voice))
    write(out / "negatives.manifest.jsonl", negatives)


def real_speech(out: Path) -> None:
    rows = []
    root = dp.repo_root()
    with dp._hf_cache_env(root):
        for config, limit in REAL_SPEECH:
            dataset = load_dataset("hf-audio/open-asr-leaderboard", config, split="test")
            dataset = dataset.cast_column("audio", Audio(decode=False))
            count = len(dataset) if limit is None else min(limit, len(dataset))
            for index, item in enumerate(dataset.select(range(count))):
                wav = out / "real" / config / f"{index:06d}.wav"
                if not wav.exists():
                    dp._write_dataset_audio(item["audio"], wav)
                rows.append(row(f"r2-{config}-{index:06d}", wav, item.get("text") or "", corpus=config))
    write(out / "real.manifest.jsonl", rows)


def taught_aliases(out: Path, wave1: Path, terms_path: Path) -> None:
    """The heard-as form a user would teach from each wave-1 baseline miss.

    Words are compared lowercased with edge punctuation stripped and aligned by unit-cost
    Levenshtein. The canonical's reference words map to the hypothesis words aligned to them; those
    words, in their original spelling with edge punctuation stripped, are the alias. Empty aliases
    and aliases equal to the canonical (case-insensitively) are dropped; the app's own safety rules
    are applied by the spotter run, which reads the file as an import would.
    """

    terms = json.loads(terms_path.read_text())
    meta, *rows = [json.loads(line) for line in (wave1 / "synthetic-jargon.spot.jsonl").open()]
    references = {
        json.loads(line)["id"]: json.loads(line)["reference"]
        for line in (Path(".build/spot/corpus/frozen-complete") / "synthetic-jargon.manifest.jsonl").open()
    }
    strip = lambda word: word.strip(".,;:!?…()[]{}\"'«»“”‘’")  # noqa: E731
    aliases: dict[str, set[str]] = {}
    for item in rows:
        info = terms.get(item["id"])
        if not info or not info.get("canonical"):
            continue
        canonical = info["canonical"]
        if re.search(rf"(?<!\w){re.escape(canonical)}(?!\w)", item["m0_final"]):
            continue
        reference = references[item["id"]].split()
        hypothesis = item["m0_final"].split()
        key = [strip(w).lower() for w in canonical.split()]
        ref_keys = [strip(w).lower() for w in reference]
        start = next((i for i in range(len(ref_keys)) if ref_keys[i : i + len(key)] == key), None)
        if start is None:
            continue
        pairs = align(ref_keys, [strip(w).lower() for w in hypothesis])
        span = [h for r, h in pairs if r is not None and start <= r < start + len(key) and h is not None]
        if not span:
            continue
        alias = " ".join(strip(hypothesis[h]) for h in range(min(span), max(span) + 1)).strip()
        if alias and alias.lower() != canonical.lower():
            aliases.setdefault(canonical, set()).add(alias)
    vocabulary = json.loads(Path("bench/autoresearch/repair.vocabulary.json").read_text())
    entries = [
        {"term": canonical, "heard_as": sorted(aliases.get(canonical, []))}
        for canonical in vocabulary["surfaces"] + vocabulary["protected_surfaces"]
    ]
    (out / "taught.glossary.json").write_text(json.dumps(entries, indent=1, ensure_ascii=False) + "\n")
    print(out / "taught.glossary.json", sum(len(v) for v in aliases.values()), "aliases for", len(aliases), "terms")


def align(reference: list[str], hypothesis: list[str]) -> list[tuple[int | None, int | None]]:
    rows, cols = len(reference), len(hypothesis)
    cost = [[0] * (cols + 1) for _ in range(rows + 1)]
    for i in range(rows + 1):
        cost[i][0] = i
    for j in range(cols + 1):
        cost[0][j] = j
    for i in range(1, rows + 1):
        for j in range(1, cols + 1):
            cost[i][j] = min(
                cost[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]),
                cost[i - 1][j] + 1,
                cost[i][j - 1] + 1,
            )
    pairs: list[tuple[int | None, int | None]] = []
    i, j = rows, cols
    while i > 0 or j > 0:
        if i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]):
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            pairs.append((i - 1, None))
            i -= 1
        else:
            pairs.append((None, j - 1))
            j -= 1
    return list(reversed(pairs))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--wave1", type=Path, required=True)
    parser.add_argument("--terms", type=Path, required=True)
    parser.add_argument("--part", choices=["synthetic", "real", "aliases", "all"], default="all")
    options = parser.parse_args()
    targets = json.loads((options.wave1 / "synthetic-jargon.spot.jsonl").open().readline())["targets"]
    if options.part in ("synthetic", "all"):
        synthetic(options.out, targets)
    if options.part in ("aliases", "all"):
        taught_aliases(options.out, options.wave1, options.terms)
    if options.part in ("real", "all"):
        real_speech(options.out)


if __name__ == "__main__":
    main()
