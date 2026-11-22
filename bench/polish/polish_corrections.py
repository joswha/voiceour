"""Spoken self-corrections for the bench edit policy.

A self-correction is reparandum, cue, repair: "point it at port 8080, no wait, port 9090". `correction(a, i, j)`
answers whether deleting the source words `a[i:j]` removes one reparandum with its cue while the repair that
replaces it survives right after the cut. It authorizes deletions only. Anything it cannot read unambiguously
stays in the text: a cue alone, a cue with its repair, a repair's qualifier, a guess about scope.

- Cues: "no", "wait", "sorry", "actually", "I mean", "or rather", "scratch that". A cue is whole non-literal words
  set off by punctuation: the reparandum ends with a mark, and "no", "wait", "sorry", "actually" and "scratch
  that" carry their own (or lead straight into another cue). So "no errors", "wait for", "rather than", "sorry
  for the delay", "scratch that test", a quoted "no" and `--no-cache` are content. "actually" and "wait" alone are
  weak: "merge it now, actually, wait for review" adds a step. The hesitations um, uh, er and hmm may stand
  around the cues.
- Reparandum: ends at the cue and stays inside one clause (no clause punctuation, line break, "and" or "then"
  inside it), or is exactly the previous sentence when "Scratch that." opens a sentence. A cue that closes its
  sentence retracts that whole sentence.
- Repair: must follow and start where the reparandum starts: the same word, or the same kind of word (number,
  determiner, preposition, pronoun; after a strong cue any content word). A repair led by a qualifier ("not",
  "except", "also", "if", ...) amends rather than replaces, a question does not replace an instruction, and a
  repair that restates words kept left of the cut shows that the reparandum started earlier.
- Polarity: when exactly one side is negated, the repair must also restate the reparandum, and a cut that keeps
  a negation before a restated content word is refused ("don't [lock it, no wait,] lock it").
- After the cue: hesitations; "make it" before a numeric repair ("2 hours, actually, make it 4 hours"); and the
  repair's restated frame when the kept frame says the same with a noun for its pronoun ("copy the report to
  Laura, no wait, copy it to Devon" -> "copy the report to Devon").
- Literals (code, quotes, flags, numbers, Glossary terms) are never in the cue or after it. In the reparandum a
  literal may go only when the repair repeats the reparandum word for word except that a number becomes another
  number of the same form ("port 8080" -> "port 9090", never "30 seconds" -> "60 minutes" or "10ms" -> "10s").

Equivalent placements are tried: difflib can put a cut a few words over when the repair repeats the words around
it ("to Laura, no wait, to Devon" cut as "Laura, no wait, to"). Stacked corrections and spans over
`MAX_SPAN` words are refused rather than searched.
"""
import re

MAX_SPAN = 24
# Cue phrases as space-joined Word keys.
CUES = frozenset({"no", "wait", "sorry", "actually", "i mean", "or rather", "scratch that"})

# single: carries its own closing mark or leads into another cue; binding: leads straight into its repair;
# retract: carries its own closing mark and may form a sentence of its own.
_ROLES = {("no",): "single", ("wait",): "single", ("sorry",): "single", ("actually",): "single",
          ("i", "mean"): "binding", ("or", "rather"): "binding", ("scratch", "that"): "retract"}
_STRONG = frozenset({"no", "sorry", "i mean", "or rather", "scratch that"})
_HESITATIONS = frozenset({"um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm"})
# "I mean it", "I mean what I said", "I mean to": the speaker means something, nothing is retracted.
_MEAN_CONTENT = frozenset({"it", "that", "this", "what", "to", "by", "is", "was", "well", "business"})
_NUMBER_WORDS = frozenset("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
                          "fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy "
                          "eighty ninety hundred thousand million billion half dozen".split())
_DETERMINERS = frozenset("the a an this that these those my your our their his her its some any every each all "
                         "both another".split())
_PREPOSITIONS = frozenset("to on in at for from into onto with by of about over under via through against "
                          "between within behind near inside outside across toward towards per".split())
_PRONOUNS = frozenset("i you we they he she it me us them him i'm you're we're they're he's she's it's i'll "
                      "you'll we'll they'll i've you've we've they've i'd you'd we'd they'd".split())
_AUXILIARIES = frozenset("is are was were be been am can could should would will shall may might must do does "
                         "did have has had cannot".split())
_WH = frozenset("what why how where when who which whose whom".split())
_COORDINATORS = frozenset("and but or nor then so also plus".split())
# A repair led by one of these adds to the reparandum ("..., sorry, not the e2e ones") rather than replacing it.
_QUALIFIERS = frozenset("not never no none nothing nobody except excluding without but besides apart also too "
                        "plus and or nor then unless if until including even especially first before after once "
                        "when while whenever because since though although instead".split())
_FOCUS = frozenset({"just", "only", "simply"})
_NEGATIONS = frozenset("not never no none nothing nobody nowhere neither nor without except cannot".split())
_POLARITY_ONLY = frozenset("not never always no do does did".split())
_NT = {"won't": "will", "can't": "can", "shan't": "shall", "ain't": "is"}
_OBJECT_PRONOUNS = frozenset({"it", "them", "this", "that", "these", "those"})
_NUMBER_LITERAL = re.compile(r"v?\d+(?:[.,:]\d+)*(?:%|[a-z]{1,3})?", re.IGNORECASE)


def correction(a, i, j):
    """Whether deleting a[i:j] removes a reparandum and its cue while a genuine repair survives after it."""
    if not 0 <= i < j <= len(a) or j - i > MAX_SPAN:
        return False
    return any(_single(a, s, e) for s, e in _placements(a, i, j))


def _placements(a, i, j):
    """Cuts that leave the same words: the cut slides over words it would delete in both positions, at most
    MAX_SPAN words either way."""
    yield i, j
    k = 1
    while k <= MAX_SPAN and i - k >= 0 and _same(a[i - k], a[j - k]):
        yield i - k, j - k
        k += 1
    k = 0
    while k < MAX_SPAN and j + k < len(a) and _same(a[i + k], a[j + k]):
        k += 1
        yield i + k, j + k


def _same(x, y):
    """Words a cut may slide over: equal keys, and a literal keeps its exact spelling."""
    return x.key == y.key and (x.body == y.body or not (x.literal or y.literal))



def _single(a, i, j):
    # The reparandum holds no punctuation or line break before its last word, so the cue region can only start
    # after the first one.
    c = i + 1
    while c < j and not a[c - 1].punct and "\n" not in a[c].gap:
        c += 1
    return c < j and any(_check(a, i, c, e, j, units) for e, units in _regions(a, c, j))


def _regions(a, c, stop):
    """(end, units) for each cue region a[c:end] that holds a cue; a unit is (end, key, role), and a hesitation
    has an empty role."""
    found, units, p = [], [], c
    while p < stop:
        unit = _unit(a, p, stop)
        if unit is None:
            break
        units.append(unit)
        p = unit[0]
        if any(u[2] for u in units):
            found.append((p, list(units)))
    return found


def _unit(a, p, stop):
    if a[p].literal:
        return None
    if a[p].key in _HESITATIONS:
        return p + 1, "", ""
    for size in (2, 1):
        words = a[p:p + size]
        role = _ROLES.get(tuple(x.key for x in words)) if p + size <= stop else None
        if role and not any(x.literal for x in words) and all(
                not x.punct and "\n" not in y.gap for x, y in zip(words, words[1:], strict=False)):
            return p + size, " ".join(x.key for x in words), role
    return None


def _check(a, i, c, e, j, units):
    n = len(a)
    reparandum, after = a[i:c], list(a[e:j])
    if any(w.literal for w in a[c:j]) or not _within_clause(a, i, c):
        return False
    p = i
    while p < c and (unit := _unit(a, p, c)):
        p = unit[0]
    if p == c:
        return False  # only cues and hesitations would be retracted: "no wait, no wait,"
    keys = {u[1] for u in units if u[2]}
    strong = bool(keys & _STRONG)
    s, cs = _sentence_start(a, i), _clause_start(a, i)
    own_sentence = _ends_sentence(a[c - 1]) or "\n" in a[c].gap
    closes = e == n or _ends_sentence(a[e - 1]) or "\n" in a[e].gap
    if not (own_sentence or a[c - 1].punct):
        return False  # an unmarked cue word is content: "we don't actually need it"
    if own_sentence and "scratch that" not in keys:
        return False  # "No." or "Sorry." after a sentence may answer or apologize
    if (own_sentence or closes) and (after or i != s):
        return False  # a sentence-level retraction takes the whole sentence and nothing after the cue
    r = j
    while r < n and _hesitation(a[r]):
        r += 1
    if r >= n:
        return False  # the repair must survive
    lead = [w.key for w in after] in (["make", "it"], ["make", "that"]) and not any(w.punct for w in after)
    f = i
    if after and not lead:
        f = _frame(a, i, cs, after)
        if f is None:
            return False
    clause = list(a[r:_end(a, r, lambda w: bool(w.punct))])
    rep = (after if f < i else []) + clause
    replaced, kept = a[f:c], a[cs:f]
    x, y = replaced[0], next((w for w in rep if w.key not in _FOCUS), rep[0])
    same = x.key == y.key
    if lead and (i == cs or not (same or (_numeric(x) and _numeric(y)))):
        return False
    if not _cues_set_off(a, units, lead):
        return False
    if not same and ((not rep[0].literal and rep[0].key in _QUALIFIERS) or _coordinator(x)
                     or (x.key in _PREPOSITIONS) != (y.key in _PREPOSITIONS)):
        return False
    if _negated(replaced) != _negated(rep):
        plain = _plain(replaced)
        if not plain or _plain(rep)[:len(plain)] != plain:
            return False  # "run every suite, sorry, don't run the slow ones" amends instead of retracting
    if not same:
        if y.key in {w.key for w in kept}:
            return False  # the repair restarts left of the cut
        head = [w.key for w in replaced[:2]]
        if any([w.key for w in rep[k:k + len(head)]] == head for k in range(1, 4)):
            return False  # the repair restates the reparandum after words that replace what precedes it
        if not _parallel(x, y, strong):
            return False
    if same and _kind(x) == "content" and _negated(kept):
        return False  # "don't [lock it, no wait,] lock it" would keep the retracted negation
    if f == cs and _kind(y) in ("auxiliary", "wh") and _kind(x) not in ("auxiliary", "wh"):
        if "?" in a[_end(a, r, _ends_sentence) - 1].punct:
            return False  # a question does not replace an instruction
    return _literals_repaired(reparandum, clause)


def _cues_set_off(a, units, lead):
    n = len(a)
    for idx, (end, key, role) in enumerate(units):
        if not role:
            continue
        closed = end == n or bool(a[end - 1].punct) or "\n" in a[end].gap
        following = units[idx + 1] if idx + 1 < len(units) else None
        if role == "binding":
            if key == "i mean" and not closed and a[end].key in _MEAN_CONTENT:
                return False
        elif not (closed or (role == "single" and following and following[2])
                  or (key == "actually" and following is None and lead)):
            return False  # "scratch that test" is an instruction, "no extra logging" a determiner
    return True


def _frame(a, i, cs, after):
    """Start f of the kept words a[f:i] that the deleted repair frame restates, or None: the same words, or the
    same words with one pronoun for the kept noun phrase ("copy the report to" for "copy it to")."""
    if len(after) > 4 or any(w.literal or w.punct or _hesitation(w) for w in after) or _negated(after):
        return None
    if len(after) == 1:
        return i - 1 if i - 1 >= cs and a[i - 1].key == after[0].key else None
    inner = [w.key for w in after[1:-1]]
    for f in range(i - 2, cs - 1, -1):
        frame = a[f:i]
        if frame[0].key != after[0].key or frame[-1].key != after[-1].key:
            continue
        kept = [w.key for w in frame[1:-1]]
        if kept == inner or (len(inner) == 1 and inner[0] in _OBJECT_PRONOUNS and 0 < len(kept) <= 4
                             and not _negated(frame)):
            return f
    return None


def _literals_repaired(gone, clause):
    """A deleted literal needs the repair to say the reparandum again word for word, a number replaced by a
    number of the same form: shape alone never shows that a path, flag, name or unit was corrected."""
    if not any(w.literal for w in gone):
        return True
    if len(clause) < len(gone):
        return False
    changed = False
    for x, y in zip(gone, clause, strict=False):
        if x.literal or y.literal:
            if x.body == y.body:
                continue
            if not (_NUMBER_LITERAL.fullmatch(x.body) and _NUMBER_LITERAL.fullmatch(y.body)
                    and re.sub(r"\d+", "0", x.body) == re.sub(r"\d+", "0", y.body)):
                return False
            changed = True
        elif x.key != y.key:
            return False
    return changed


def _within_clause(a, i, c):
    if any(w.punct for w in a[i:c - 1]):
        return False
    return not any("\n" in a[k].gap or _coordinator(a[k]) for k in range(i + 1, c))


def _parallel(x, y, strong):
    kind = _kind(x)
    return kind == _kind(y) and (strong or kind in ("number", "determiner", "preposition", "pronoun"))


def _kind(w):
    k = w.key
    if _numeric(w):
        return "number"
    if w.literal:
        return "content"
    if k in _DETERMINERS:
        return "determiner"
    if k in _PREPOSITIONS:
        return "preposition"
    if k in _PRONOUNS:
        return "pronoun"
    if k in _AUXILIARIES or k.endswith("n't"):
        return "auxiliary"
    if k in _WH:
        return "wh"
    if k in _COORDINATORS:
        return "coordinator"
    return "content"


def _numeric(w):
    return bool(re.search(r"\d", w.body)) or all(part in _NUMBER_WORDS for part in w.key.split("-"))


def _negated(words):
    return any(not w.literal and (w.key in _NEGATIONS or w.key.endswith("n't")) for w in words)


def _plain(words):
    """Keys without polarity: "can't push it" gives ["can", "push", "it"], "don't push it" ["push", "it"]."""
    out = []
    for w in words:
        k = w.key
        if k.endswith("n't"):
            k = _NT.get(k, k[:-3])
        elif k == "cannot":
            k = "can"
        if k not in _POLARITY_ONLY:
            out.append(k)
    return out


def _hesitation(w):
    return not w.literal and w.key in _HESITATIONS


def _coordinator(w):
    return not w.literal and w.key in _COORDINATORS


def _ends_sentence(w):
    return any(ch in w.punct for ch in ".!?")


def _sentence_start(a, k):
    while k > 0 and not _ends_sentence(a[k - 1]) and "\n" not in a[k].gap:
        k -= 1
    return k


def _clause_start(a, k):
    while k > 0 and not a[k - 1].punct and "\n" not in a[k].gap and not _coordinator(a[k - 1]):
        k -= 1
    return k


def _end(a, k, stop):
    """Exclusive end of the clause or sentence that starts at a[k]."""
    n = len(a)
    while k < n:
        if stop(a[k]) or (k + 1 < n and "\n" in a[k + 1].gap):
            return k + 1
        k += 1
    return n
