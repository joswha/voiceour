#!/usr/bin/env python3
"""Polish research helpers: held-out case scoring and the deterministic edit verifier.

    python3 bench/polish/polishlab.py score <rows.jsonl> [<rows.jsonl> ...]        # {"id","output","ms"}
    python3 bench/polish/polishlab.py verify-pairs <pairs.jsonl> [--keep out.jsonl]  # {"input","target"}

`verify(src, out)` accepts a cleaned text only when every change from the source is one of: a filler deletion
(polish_fillers), a stutter, a cue-marked self-correction (polish_corrections), a one-word grammar fix or a spoken
list turned into a numbered list (polish_grammar), or punctuation and case these edits need. Literals (code, paths,
flags, numbers, quoted text, Glossary terms; polish_tokens) never change. `merge_allowed(src, out)` keeps the
approved edits, restores the source elsewhere and returns the whole source when the composition fails `verify`.
research/polish-2026-11-21.md records why each rule exists.
"""
import difflib
import json
import re
import statistics
import sys
from pathlib import Path

from polish_corrections import CUES, correction
from polish_fillers import FILLERS, filler_end, stutter_twin
from polish_grammar import grammar_edit, inflection, list_edit
from polish_tokens import protected, scan

__all__ = ["CUES", "FILLERS", "has_cue", "inflection", "is_filler_span", "merge_allowed", "protected",
           "tokens", "verify"]

CASES_PATH = Path(__file__).resolve().parent / "cases" / "agent36.jsonl"


def tokens(text):
    return [w.body for w in scan(text)]


def has_cue(words):
    """Lexical statistic for pair generation, not permission to retract a clause."""
    return any(w in CUES or " ".join(words[i:i + 2]) in CUES for i, w in enumerate(words))


def is_filler_span(words):
    """Lexical classification for training statistics only, never permission to delete."""
    i = 0
    while i < len(words):
        for size in range(min(3, len(words) - i), 0, -1):
            if " ".join(words[i:i + size]) in FILLERS:
                i += size
                break
        else:
            return False
    return True


def _fillers(a, i, end):
    while i < end:
        stop = filler_end(a, i, end)
        if stop <= i:
            break
        i = stop
    return i


def _deletion(a, i, j, kept):
    """`kept` holds the source positions the alignment leaves unchanged."""
    if i == j:
        return False
    if correction(a, i, j):
        return True

    def removable(lo, hi):
        if any(w.literal for w in a[lo:hi]):
            return False
        k = _fillers(a, lo, hi)
        if k == hi:
            return True
        # A slid cut deletes the same words, so the copies at i..j survive in place of lo..hi.
        survivors = (kept | set(range(i, j))) - set(range(lo, hi))
        twin = stutter_twin(a, k, hi)
        return twin is not None and survivors.issuperset(twin)

    if removable(i, j):
        return True
    # Only shift lexically identical copies. Do not slide a correction or a sentence boundary.
    lo, hi = i, j
    while lo and a[lo - 1].raw == a[hi - 1].raw and not a[lo - 1].punct:
        lo, hi = lo - 1, hi - 1
        if removable(lo, hi):
            return True
    while j < len(a) and a[i].raw == a[j].raw and not a[i].punct:
        i, j = i + 1, j + 1
        if removable(i, j):
            return True
    return False


def _replacement(a, i, j, b, k, m):
    core = []
    pos = i
    while pos < j:
        end = filler_end(a, pos, j)
        if end > pos:
            pos = end
        else:
            core.append(pos)
            pos += 1
    return len(core) == m - k and all(not (a[p].literal or b[q].literal)
                                      and grammar_edit(a, p, b[q].key) and not _punctuation(a, p, b, q)
                                      for q, p in enumerate(core, k))


def _sentence_start(words, i):
    return not i or bool(set(words[i - 1].punct) & {".", "?", "!"})


def _equal_word(a, i, b, j, removed=frozenset()):
    x, y = a[i], b[j]
    if x.literal or y.literal:
        if x.raw != y.raw or (i and j and x.gap != y.gap):
            return "changed literal"
    elif x.body != y.body and x.body.replace("’", "'") != y.body.replace("’", "'"):
        if y.body != "I" and not (_sentence_start(b, j) and x.body[:1].upper() + x.body[1:] == y.body):
            return "changed case"
    return _punctuation(a, i, b, j, removed)


def _comma_of_removed(a, i, removed):
    """Whether the comma on a[i] belonged to an approved deletion: it opened the removed words right after a[i]
    ("not, you know, float"), or closed a removed span earlier in its clause ("the debug build, I mean the release
    build, for")."""
    if i + 1 in removed:
        return True
    p = i - 1
    while p >= 0 and not any(c in ".!?;:" for c in a[p].punct) and "\n" not in a[p + 1].gap:
        if p in removed and "," in a[p].punct:
            return True
        p -= 1
    return False


def _punctuation(a, i, b, j, removed=frozenset()):
    x, y = a[i], b[j]
    if ("?" in x.punct) != ("?" in y.punct):
        return "changed question"
    if i and j and ("\n" in x.gap) != ("\n" in y.gap):
        return "changed line break"
    if x.punct == y.punct:
        return ""
    if i + 1 < len(a) and j + 1 < len(b):
        # Formatting a spoken list is the only reason to change an internal sentence boundary.
        if not (b[j + 1].body.isdecimal() and b[j + 1].punct == "." and "\n" in b[j + 1].gap):
            if any(c in ".!:;" for c in x.punct + y.punct):
                return "changed sentence boundary"
    comma_only = set(x.punct + y.punct) <= {","}
    if comma_only and _comma_of_removed(a, i, removed):
        return ""
    if "," in x.punct or "," in y.punct:
        # Preserve commas between unchanged words. They can delimit a condition or a vocative.
        if i + 1 < len(a) and j + 1 < len(b) and a[i + 1].key == b[j + 1].key \
                and not (comma_only and a[i + 1].key in {"and", "but", "or", "so", "then"}):
            return "changed clause punctuation"
    if x.key in {"no", "not", "never", "don't", "only", "unless"} or x.key.endswith("n't"):
        return "changed scope punctuation"
    return ""


def _edits(a, b):
    keys = [w.key for w in a]
    ops = difflib.SequenceMatcher(None, keys, [w.key for w in b], autojunk=False).get_opcodes()
    kept = {p for op, i, j, _, _ in ops if op == "equal" for p in range(i, j)}
    verdicts = {}
    for op, i, j, k, m in ops:
        if op == "delete":
            verdicts[i, j] = "" if _deletion(a, i, j, kept) else "deleted content"
        elif op == "replace":
            ok = list_edit(a, i, j, b, k, m) or _replacement(a, i, j, b, k, m)
            verdicts[i, j] = "" if ok else "replaced content"
        elif op == "insert":
            verdicts[i, j] = "" if list_edit(a, i, j, b, k, m) else "inserted content"
    removed = frozenset(p for (i, j), why in verdicts.items() if not why for p in range(i, j))
    for op, i, j, k, m in ops:
        if op == "equal":
            for p in range(j - i):
                yield i + p, i + p + 1, k + p, k + p + 1, _equal_word(a, i + p, b, k + p, removed)
        else:
            yield i, j, k, m, verdicts[i, j]


def _global_change(a, b):
    if a and not b:
        return "empty output"
    # A question cannot silently vanish with a deleted tag or a deleted correction span.
    if sum(w.punct.count("?") for w in a) != sum(w.punct.count("?") for w in b):
        return "changed question"
    return ""


def verify(src, out, terms=()):
    """Check a complete candidate against the bench edit policy, not against human judgment."""
    if src == out:
        return True, "ok"
    a, b = scan(src, terms), scan(out, terms)
    reason = _global_change(a, b) or next((r for *_, r in _edits(a, b) if r), "")
    return not reason, reason or "ok"


def merge_allowed(src, out, terms=()):
    """Deliver approved edits only. Recheck the composed result before returning it."""
    if src == out:
        return src
    a, b = scan(src, terms), scan(out, terms)
    if _global_change(a, b):
        return src
    edits = list(_edits(a, b))
    if all(not r for *_, r in edits):
        return out
    # Never splice fragments from opposite sides of a self-correction together.
    if any(w.key in {"scratch", "mean", "no", "wait", "actually", "rather", "sorry"} for w in a):
        return src
    pieces = []
    for i, j, k, m, reason in edits:
        for w in (a[i:j] if reason else b[k:m]):
            pieces.append((w.gap or " " if pieces else "") + w.raw)
    merged = "".join(pieces)
    return merged if verify(src, merged, terms)[0] else src


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
