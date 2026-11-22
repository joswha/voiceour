#!/usr/bin/env python3
"""Compile a bounded set of candidate completions from source text, never from reference answers.

    python3 bench/polish/guided_cases.py <input.jsonl> <guided.jsonl>

Identity is always available. Other candidates combine permitted fillers, stutters, corrections, grammar fixes and
list formatting. The bounded set can miss the reference. The runner restricts tokens to the supplied strings;
it does not certify the edit policy.
"""
import argparse
import json
from pathlib import Path

from polish_corrections import CUES, correction
from polish_fillers import filler_end, stutter
from polish_grammar import grammar_options
from polish_tokens import scan
from polishlab import verify


def options(words):
    cue_heads = {cue.split()[0] for cue in CUES}
    for k, w in enumerate(words):
        if w.key in cue_heads:
            for stop in range(k + 1, min(k + 5, len(words)) + 1):
                for start in range(max(0, k - 16), k):
                    if correction(words, start, stop):
                        yield (start, stop, "")
    for i, w in enumerate(words):
        if w.literal:
            continue
        stop = filler_end(words, i, len(words))
        if stop > i:
            yield (i, stop, "")
        for j in range(i + 1, min(i + 5, len(words)) + 1):
            if stutter(words, i, j):
                yield (i, j, "")
        for key in grammar_options(words, i):
            yield (i, i + 1, key + w.punct)


def render(words, edits):
    pieces = []
    pos = 0
    for i, j, replacement in sorted(edits):
        pieces.extend((w, w.raw) for w in words[pos:i])
        if replacement:
            pieces.append((words[i], replacement))
        elif pieces and pieces[-1][1].endswith(",") and words[j - 1].punct == ",":
            prev, raw = pieces[-1]
            if not prev.literal:
                pieces[-1] = (prev, raw[:-1])
        pos = j
    pieces.extend((w, w.raw) for w in words[pos:])
    if not pieces:
        return ""
    w, first = pieces[0]
    if (w is not words[0] or first != w.raw) and not w.literal:
        first = first[:1].upper() + first[1:]
    return first + "".join(w.gap + raw for w, raw in pieces[1:])


def numbered(text):
    """Only explicit ordinal or number-plus-cardinal markers in ascending order. verify checks the result."""
    words = scan(text)
    items = []
    ordinals = ("first", "second", "third", "fourth", "fifth")
    cardinals = ("one", "two", "three", "four", "five")
    for ordinal, cardinal in zip(ordinals, cardinals, strict=True):
        start = items[-1][1] + 1 if items else 0
        for i in range(start, len(words) - 1):
            if words[i].key == ordinal:
                items.append((i, i + 1))
                break
            if words[i].key == "number" and words[i + 1].key == cardinal and i + 2 < len(words):
                items.append((i, i + 2))
                break
        else:
            break
    if len(items) < 3:
        return None
    intro = "".join(w.gap + w.raw for w in words[:items[0][0]]).rstrip(",. :")
    result = [intro + ":"] if intro else []
    for n, (_, content) in enumerate(items):
        end = items[n + 1][0] if n + 1 < len(items) else len(words)
        lead = words[content]
        raw = lead.raw if lead.literal else lead.raw[:1].upper() + lead.raw[1:]
        line = raw + "".join(w.gap + w.raw for w in words[content + 1:end])
        result.append(f"{n + 1}. {line.rstrip(',.')}" + ("" if line.endswith(("?", "!")) else "."))
    return "\n".join(result)


def plans(proposals):
    used, maximal = set(), []
    for edit in proposals:
        span = range(*edit[:2])
        if used.isdisjoint(span):
            maximal.append(edit)
            used.update(span)
    yield maximal
    for edit in proposals:
        yield [edit]
    for n in range(len(maximal)):
        yield maximal[:n] + maximal[n + 1:]


def candidates(text, limit=48):
    """Identity, a combined plan, individual edits and all-but-one, capped before inference."""
    if not 1 <= limit <= 128:
        raise ValueError("limit must be between 1 and 128")
    if not text.strip() or text.strip() != text:
        raise ValueError("guided cases require nonempty input without surrounding whitespace")
    words = scan(text)
    proposals = list(dict.fromkeys(options(words)))
    answer = {text: None}
    for plan in plans(proposals):
        if len(answer) >= limit:
            break
        value = render(words, plan)
        if value and value not in answer and verify(text, value)[0]:
            answer[value] = None
        if value and len(answer) < limit:
            as_list = numbered(value)
            if as_list and as_list not in answer and verify(text, as_list)[0]:
                answer[as_list] = None
    return list(answer)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", type=Path)
    ap.add_argument("dest", type=Path)
    ap.add_argument("--limit", type=int, default=48)
    args = ap.parse_args()
    if args.source.resolve() == args.dest.resolve():
        ap.error("output cannot replace input")
    with args.source.open() as src, args.dest.open("x") as dest:
        for line in src:
            row = json.loads(line)
            inp = row["input"]
            output = {"id": row["id"], "input": inp, "allowed_outputs": candidates(inp, args.limit)}
            dest.write(json.dumps(output) + "\n")


if __name__ == "__main__":
    main()
