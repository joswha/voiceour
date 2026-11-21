#!/usr/bin/env python3
"""Polish research helpers: held-out case scoring and the deterministic edit verifier.

    python3 bench/polish/polishlab.py score <rows.jsonl> [<rows.jsonl> ...]        # {"id","output","ms"}
    python3 bench/polish/polishlab.py verify-pairs <pairs.jsonl> [--keep out.jsonl]  # {"input","target"}

`verify(src, out)` accepts a cleaned text only when every change from the source is one of: a filler
deletion, a self-correction deletion (a span holding a cue word and the words it retracts), a stutter, a
one-word inflection, a spoken list marker turned into a numeral, or punctuation/case outside protected
tokens. `merge_allowed(src, out)` keeps each such change and restores the source everywhere else.
research/polish-2026-11-21.md records why each rule exists.
"""
import difflib
import json
import re
import statistics
import sys
from pathlib import Path

CASES_PATH = Path(__file__).resolve().parent / "cases" / "agent36.jsonl"

# "i mean" is deliberately not a filler: deleting it alone can merge a retracted phrase into the text.
# "essentially" is the owner's own "basically": 78 times in 60 of his 498 History dictations.
FILLERS = {"um", "uh", "like", "you know", "kind of", "sort of", "basically", "essentially", "so", "okay", "ok",
           "right", "well", "the thing is", "here's the thing", "just", "alright", "anyway"}
CUES = {"no", "wait", "actually", "i mean", "scratch that", "sorry", "rather", "no wait"}
NEGATIONS = {"not", "no", "never", "don't", "doesn't", "can't", "won't", "isn't", "aren't", "didn't", "shouldn't",
             "wasn't", "weren't", "haven't", "hasn't", "couldn't", "wouldn't", "nothing", "none", "nobody"}
# "like" after these words is a comparison or a verb, never a filler: "looks like a bug", "something like this",
# "stuff like that", "I'd like to". A bare pronoun is not enough: the owner says "we like merge it" as a filler.
LIKE_CONTENT_AFTER = {"look", "looks", "looked", "looking", "feel", "feels", "felt", "feeling", "sound", "sounds",
                      "sounded", "seem", "seems", "seemed", "something", "anything", "nothing", "stuff", "things",
                      "would", "i'd", "we'd", "you'd", "they'd", "more", "much", "exactly"}
IRREGULAR = {("was", "were"), ("were", "was"), ("is", "are"), ("are", "is"), ("have", "has"), ("has", "have"),
             ("seen", "saw"), ("doesn't", "don't"), ("don't", "doesn't"), ("does", "do"), ("do", "does"),
             ("me", "i"), ("him", "he"), ("her", "she"), ("them", "they"), ("us", "we"), ("went", "gone"),
             ("gone", "went"), ("done", "did"), ("did", "done"), ("isn't", "aren't"), ("aren't", "isn't"),
             ("wasn't", "weren't"), ("weren't", "wasn't"), ("a", "an"), ("an", "a")}
LIST_WORDS = {"first", "second", "third", "fourth", "fifth", "number", "one", "two", "three", "four", "five",
              "firstly", "secondly", "thirdly", "then", "next", "finally", "lastly"}
TOKEN = re.compile(r"[\w'~/.$,:-]*\w[\w'~/.$-]*|\S")


def tokens(text):
    out = []
    for t in TOKEN.findall(text):
        t = t.strip(",.:;!?")  # trailing punctuation is free to change
        if t:
            out.append(t)
    return out


def protected(tok, terms=()):
    return tok in terms or bool(re.search(r"\d|[/_~$]|--|[a-z][A-Z]|^[A-Z]{2,}$|\.\w", tok))


def is_filler_span(words):
    i, n = 0, len(words)
    while i < n:
        for size in (3, 2, 1):
            if " ".join(words[i:i + size]) in FILLERS:
                i += size
                break
        else:
            return False
    return True


def like_is_content(la, k):
    """Whether la[k] == "like" is a comparison or a verb ("I like how", "kind of like the old one") rather than a
    filler, judged from its neighbours."""
    if la[k] != "like":
        return False
    prev = la[k - 1] if k else ""
    nxt = la[k + 1] if k + 1 < len(la) else ""
    return prev in LIKE_CONTENT_AFTER or (
        prev in {"i", "we", "they", "you"} and nxt in {"how", "it", "that", "this", "them", "to", "when"}) or (
        prev == "of" and k >= 2 and la[k - 2] in {"kind", "sort"} and nxt in {"the", "a", "an", "this", "that"})


def has_cue(words):
    joined = " ".join(words)
    return any(re.search(rf"\b{re.escape(c)}\b", joined) for c in CUES)


def keeps_reparandum(words):
    """True when a correction deletion holds only the cue (or fillers then the cue): the retracted words
    before it would survive, so deleting the cue alone would turn "X, scratch that, Y" into "X Y"."""
    for k in range(len(words)):
        if words[k] in CUES or " ".join(words[k:k + 2]) in CUES:
            return k == 0 or is_filler_span(words[:k])
    return False


def inflection(a, b):
    if (a, b) in IRREGULAR:
        return True
    return a[:3] == b[:3] and abs(len(a) - len(b)) <= 3 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.75


def _strip_fillers(words):
    """The words of a span with its filler phrases removed, longest phrase first."""
    core, i = [], 0
    while i < len(words):
        for size in (3, 2, 1):
            if " ".join(words[i:i + size]) in FILLERS:
                i += size
                break
        else:
            core.append(words[i])
            i += 1
    return core


def _deletion_ok(la, i1, i2):
    gone = la[i1:i2]
    if is_filler_span(gone) and not any(like_is_content(la, k) for k in range(i1, i2)):
        return True
    # A stutter or repeated phrase of up to four words (the cleanup stage's own repeat limit), possibly with
    # fillers between the two copies ("their, you know, their"); either copy may be the deleted one.
    core = _strip_fillers(gone)
    if 0 < len(core) <= 4 and (core == la[i2:i2 + len(core)] or (i1 >= len(core) and core == la[i1 - len(core):i1])):
        return True
    return has_cue(gone) and i2 < len(la) and not keeps_reparandum(gone)


def deletion_allowed(la, i1, i2):
    """Whether deleting la[i1:i2] is an allowed edit. difflib may place an ambiguous deletion a token off ("you
    know you" -> "you" reads as deleting "you know" or "know you"), so every placement that deletes the same
    words is tried."""
    if _deletion_ok(la, i1, i2):
        return True
    j1, j2 = i1, i2
    while j1 > 0 and la[j1 - 1] == la[j2 - 1]:
        j1, j2 = j1 - 1, j2 - 1
        if _deletion_ok(la, j1, j2):
            return True
    j1, j2 = i1, i2
    while j2 < len(la) and la[j1] == la[j2]:
        j1, j2 = j1 + 1, j2 + 1
        if _deletion_ok(la, j1, j2):
            return True
    return False


def verify(src, out, terms=()):
    """Return (accepted, reason). `terms` are Glossary spellings that must survive byte for byte."""
    if not out.strip():
        return (not src.strip()), "empty output"
    a, b = tokens(src), tokens(out)
    la, lb = [t.lower() for t in a], [t.lower() for t in b]
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, la, lb, autojunk=False).get_opcodes():
        if op == "equal":
            if any(x != y and protected(x, terms) for x, y in zip(a[i1:i2], b[j1:j2], strict=True)):
                return False, f"recased protected token {a[i1:i2]}"
            continue
        gone, new = la[i1:i2], lb[j1:j2]
        if op == "delete":
            if any(t in terms for t in a[i1:i2]) and not has_cue(gone):
                return False, f"deleted protected term {a[i1:i2]}"
            if deletion_allowed(la, i1, i2):
                continue  # filler, stutter, or a correction with what it retracts
            if has_cue(gone):
                if i2 >= len(a):
                    return False, "correction deleted the tail"
                if keeps_reparandum(gone):
                    return False, f"correction kept its reparandum {gone}"
            return False, f"deleted content {gone}"
        if op == "insert":
            if all(re.fullmatch(r"\d+", t) for t in new):
                continue  # list markers
            return False, f"inserted {new}"
        if all(w in LIST_WORDS for w in gone) and all(re.fullmatch(r"\d+", t) for t in new):
            continue
        core = [w for k, w in enumerate(gone, i1) if not is_filler_span([w]) or like_is_content(la, k)]
        if len(core) == 1 and len(new) == 1 and inflection(core[0], new[0]) and \
                core[0] not in NEGATIONS - {"doesn't", "don't", "isn't", "aren't", "wasn't", "weren't"}:
            continue
        if len(gone) == len(new) and all(inflection(x, y) for x, y in zip(gone, new, strict=True)):
            continue
        if has_cue(gone) and not keeps_reparandum(gone) and new and new == la[i2:i2 + len(new)]:
            continue
        return False, f"replaced {gone} -> {new}"
    return True, "ok"


WORD = re.compile(r"\n|[^\s]+")


def _key(word):
    if word == "\n":
        return word
    return _bare(word).lower() or word


def _bare(word):
    return word.strip(",.:;!?()\"'")


def merge_allowed(src, out, terms=()):
    """Edit-level acceptance: keep each change of `out` that `verify` would allow on its own and restore the
    source words everywhere else, so one disallowed edit no longer discards the whole cleanup."""
    a, b = WORD.findall(src), WORD.findall(out)
    ka, kb = [_key(w) for w in a], [_key(w) for w in b]
    merged = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ka, kb, autojunk=False).get_opcodes():
        sa, sb = a[i1:i2], b[j1:j2]
        gone, new = [k for k in ka[i1:i2] if k != "\n"], [k for k in kb[j1:j2] if k != "\n"]
        if op == "equal":
            merged += [x if protected(_bare(x), terms) and _bare(x) != _bare(y) else y
                       for x, y in zip(sa, sb, strict=True)]
            continue
        allowed = False
        if not gone and not new:
            allowed = True  # line breaks only
        elif op == "delete" or not new:
            allowed = not any(_key(t) in {x.lower() for x in terms} for t in sa) and deletion_allowed(ka, i1, i2)
        elif op == "insert" or not gone:
            allowed = all(re.fullmatch(r"\d+", t) for t in new)
        else:
            core = [ka[k] for k in range(i1, i2)
                    if ka[k] != "\n" and (not is_filler_span([ka[k]]) or like_is_content(ka, k))]
            allowed = (all(w in LIST_WORDS for w in gone) and all(re.fullmatch(r"\d+", t) for t in new)) or (
                len(core) == 1 and len(new) == 1 and inflection(core[0], new[0])
                and core[0] not in NEGATIONS - {"doesn't", "don't", "isn't", "aren't", "wasn't", "weren't"}) or (
                len(gone) == len(new) and all(inflection(x, y) for x, y in zip(gone, new, strict=True)))
        merged += sb if allowed else sa
    text = ""
    for w in merged:
        if w == "\n":
            text = text.rstrip(" ") + "\n"
        else:
            text += ("" if not text or text.endswith("\n") else " ") + w
    return text.strip()


def load_cases(path=CASES_PATH):
    return {c["id"]: c for c in (json.loads(line) for line in open(path))}


def _norm(s):
    return re.sub(r"\s+", " ", s.strip().rstrip(".!").strip())


def score(case, out):
    """Failure codes for one held-out case: K keep-token missing, D dropped-word still present,
    E expected fix missing, C a no-change case changed, 0 empty output."""
    codes = []
    if any(k not in out for k in case["keep"]):
        codes.append("K")
    if any(re.search(p, out, re.I) for p in case["drop"]):
        codes.append("D")
    if any(e.lower() not in out.lower() for e in case.get("expect", [])):
        codes.append("E")
    if case["kind"] in ("restraint", "safety") and _norm(out) != _norm(case["input"]):
        codes.append("C")
    if not out.strip():
        codes.append("0")
    return codes


def _percentile(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, round(p * (len(xs) - 1)))]


def cmd_score(paths):
    cases = load_cases()
    print(f"{'rows':60s} pass  verified  p50ms  p95ms   G01ms   G02ms")
    for path in paths:
        rows = {r["id"]: r for r in (json.loads(line) for line in open(path))}
        passed = sum(not score(cases[i], rows[i]["output"] or "") for i in cases)
        verified = sum(verify(cases[i]["input"], rows[i]["output"] or "")[0] for i in cases)
        ms = [rows[i]["ms"] for i in cases]
        print(f"{path[-60:]:60s} {passed:2d}/36  {verified:2d}/36  {statistics.median(ms):6.0f} "
              f"{_percentile(ms, 0.95):6.0f} {rows['G01']['ms']:7.0f} {rows['G02']['ms']:7.0f}")


def cmd_verify_pairs(path, keep=None):
    rows = [json.loads(line) for line in open(path)]
    kept, reasons = [], {}
    for r in rows:
        ok, why = verify(r["input"], r["target"], r.get("terms", ()))
        if ok:
            kept.append(r)
        else:
            key = why.split(" ")[0] + " " + why.split(" ")[1] if " " in why else why
            reasons[key] = reasons.get(key, 0) + 1
    print(json.dumps({"rows": len(rows), "accepted": len(kept), "rejected_by": reasons}, indent=1))
    if keep:
        with open(keep, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in kept)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "score":
        cmd_score(sys.argv[2:])
    elif len(sys.argv) >= 3 and sys.argv[1] == "verify-pairs":
        cmd_verify_pairs(sys.argv[2], sys.argv[sys.argv.index("--keep") + 1] if "--keep" in sys.argv else None)
    else:
        print(__doc__)
        sys.exit(2)
