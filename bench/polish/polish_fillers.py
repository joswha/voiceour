"""Filler and repeat permissions for the bench edit policy.

Every deletion and replacement branch asks `filler_end` and `stutter`; nothing else drops a word without a
correction cue. A filler phrase counts only where its neighbours rule out the content reading of the same words,
and a repeat only where its copies cannot be two list items, a number, an operator, emphasis or two clauses.
Anything ambiguous stays content, so the verifier refuses rather than guesses.

The phrases are the policy's fillers (research/polish-2026-11-21.md) and their transcription spellings ("kinda",
"y'know", "all right", "anyways", "er", "hmm"); this module adds no new words to the policy.
"""

_HESITATIONS = frozenset({"um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "hm"})
_NUMBERS = frozenset({
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
    "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
    "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "half", "quarter",
    "dozen", "couple"})
_QUANTIFIERS = frozenset({"all", "every", "everything", "everyone", "everybody", "each", "both", "any", "most", "many",
                          "much", "several", "few", "whole", "entire", "always", "never", "nothing", "none", "nobody",
                          "no"})
# Words that let an approximation reach a value one word later: "like a few", "basically about 3".
_APPROX_LEADS = frozenset({"a", "an", "about", "around", "roughly", "approximately", "almost", "nearly", "over",
                           "under", "up", "at", "maybe"})
_NEGATIONS = frozenset({"not", "no", "never", "nor", "neither", "nothing", "none", "nobody", "nowhere", "cannot",
                        "without"})
_PERSONS = frozenset({"i", "we", "you", "they"})
_SUBJECTS = _PERSONS | {"he", "she", "it", "i'm", "i've", "i'll", "i'd", "we're", "we've", "we'll", "we'd", "you're",
                        "you've", "you'll", "you'd", "they're", "they've", "they'll", "they'd", "he's", "she's",
                        "it's", "that's", "there's", "here's", "let's"}
_DETERMINERS = frozenset({"a", "an", "the", "this", "these", "those", "my", "our", "your", "their", "his", "her",
                          "its"})
_MODALS = frozenset({"can", "could", "would", "will", "should", "might", "may", "must"})
_AUX = _MODALS | {"is", "are", "was", "were", "am", "be", "been", "do", "does", "did", "have", "has"}
_COPULA = frozenset({"is", "are", "was", "were", "am", "be", "been", "being", "it's", "that's", "he's", "she's",
                     "there's", "we're", "they're", "you're", "i'm"})
_PREPOSITIONS = frozenset({"to", "of", "in", "on", "at", "for", "with", "from", "by", "into", "onto", "about",
                           "around", "over", "under", "until", "till", "after", "before", "within", "between", "than",
                           "per"})
_INTENSIFIERS = frozenset({"really", "very", "totally", "completely", "super", "literally", "extremely", "pretty",
                           "way", "seriously"})


def _forms(*stems):
    return {s + end for s in stems for end in ("", "s", "es", "ed", "d", "ing")} | {
        s[:-1] + "ing" for s in stems if s.endswith("e")}


# Status predicates: dropping a hedge before them turns partial success into success ("it kind of works").
_OUTCOMES = frozenset(_forms("work", "pass", "finish", "fix", "solve", "resolve", "succeed", "complete", "run",
                             "help") | {"ran", "running", "done", "ready", "fine", "ok", "okay", "good", "correct",
                                        "right", "safe", "stable", "true", "there", "over"})

# A discourse marker opening a sentence must be followed by a comma or by a word that starts a clause; "so many",
# "so that", "well before", "right now" and "right click" are content.
_DISCOURSE = _HESITATIONS | {"so", "okay", "ok", "alright", "all", "anyway", "anyways", "well", "basically",
                             "essentially", "like", "you", "y'know", "ya", "here's", "just", "right"}
_CLAUSE_START = _SUBJECTS | _DETERMINERS | _DISCOURSE | {"let", "there", "here", "now", "then", "please", "also",
                                                         "first", "if", "when"}
_RIGHT_NEXT = _SUBJECTS | _HESITATIONS | {"so", "okay", "ok", "well", "anyway", "anyways", "alright", "yeah", "yes",
                                           "and", "but"}
# Lexical only: decides where a sentence opens, never whether a word may go.
_OPENERS = sorted({(h,) for h in _HESITATIONS} | {
    ("so",), ("okay",), ("ok",), ("alright",), ("all", "right"), ("anyway",), ("anyways",), ("well",), ("right",),
    ("basically",), ("essentially",), ("like",), ("you", "know"), ("y'know",), ("ya", "know"),
    ("here's", "the", "thing"), ("the", "thing", "is")}, key=lambda p: (-len(p), p))
# Lexical only: skipped when looking for the word a hedge or softener applies to.
_SKIP = _HESITATIONS | {"like", "basically", "essentially", "just", "so", "okay", "ok", "well", "right", "alright",
                        "anyway", "anyways", "kinda", "sorta", "y'know"}
_SKIP_PAIRS = frozenset({("you", "know"), ("ya", "know"), ("kind", "of"), ("sort", "of"), ("all", "right")})

_HEDGE_STOPS = _DETERMINERS | {"that", "like", "of", "as", "thing", "things", "stuff", "one", "ones", "what", "which",
                               "how", "some", "any", "every", "each", "no", "another", "other"}
_HEDGE_HOSTS = _COPULA | _AUX | _SUBJECTS | {"just", "also", "still", "really", "even", "and", "but"}
_JUST_STOPS = _DETERMINERS | _SUBJECTS | _PREPOSITIONS | _QUANTIFIERS | {
    "that", "like", "as", "be", "been", "being", "is", "are", "was", "were", "am", "have", "has", "had", "now", "then",
    "once", "so", "too", "enough", "here", "there", "what", "when", "how", "where", "why", "if", "because", "me", "us",
    "him", "them", "fine", "ok", "okay", "right", "one"}

_MAX_REPEAT = 4  # the app's cleanup stage collapses repeats of up to four words
_BREAKS = frozenset(".!?;:")
# Words that cannot end a clause, so one of two copies can go even across a comma: "the, the", "to, to", "it's,
# it's". Object pronouns and auxiliaries can end a clause: "fix it, it crashes" is two clauses.
_SEPARABLE = frozenset({"a", "an", "the", "my", "our", "your", "their", "its", "to", "of", "for", "from", "with", "at",
                        "into", "onto", "about", "like", "than", "between", "without", "and", "or", "but", "if",
                        "because", "whether", "unless", "although", "while", "i", "we", "they", "he", "she", "only",
                        "also", "just", "even", "both", "either"}) | (_SUBJECTS - _PERSONS - {"he", "she", "it"})
# Directly adjacent, these repeat only as a stutter: "can you you check", "it on on the cache".
_ADJACENT = _SEPARABLE | _AUX | {"that", "you", "it", "on", "in", "by", "as", "this", "so", "not"}
# Doubling these is emphasis or a different value: "very, very", "much, much", "so so".
_DEGREE = frozenset({"very", "really", "so", "too", "much", "more", "most", "less", "way", "far", "super", "extremely",
                     "totally", "quite", "pretty"})
# Spoken symbols: "dash dash", "greater than greater than", "star star" spell different operators.
_OPERATORS = frozenset({"dash", "dashes", "hyphen", "minus", "plus", "dot", "dots", "period", "point", "slash",
                        "slashes", "backslash", "star", "stars", "asterisk", "hash", "pound", "equals", "equal",
                        "greater", "less", "ampersand", "pipe", "bar", "colon", "semicolon", "comma", "tilde",
                        "caret", "underscore", "bang", "percent", "dollar", "backtick", "quote", "quotes", "bracket",
                        "brace", "paren", "parenthesis", "angle", "arrow"})
_NUMBER_LINKS = frozenset({"point", "dot", "oh", "and", "or", "to", "through", "by", "x", "plus", "minus"})
# "like" with no commas around it is a filler only after these words ("can you like check", "with like the same
# clips", "it's like confusing"); after anything else it may compare, give an example or be the verb.
_LIKE_FILLER_AFTER = _PERSONS | _MODALS | _COPULA | _PREPOSITIONS | {
    "and", "but", "then", "just", "also", "really", "it", "that", "was", "were", "is", "are", "be", "so", "or"}
# After a person, "like" is the verb before an object or a clause: "I like how", "we like the new icon".
_LIKE_VERB_NEXT = _DETERMINERS | {"it", "them", "him", "her", "this", "that", "these", "those", "how", "when",
                                  "what", "to", "where", "who", "me", "us", "you", "one", "ones"}
# "you know" is a clause after these words ("do you know", "unless you know", "I think you know the answer") or
# before these ("you know what", "you know it").
_KNOW_CLAUSE_BEFORE = {"do", "does", "did", "don't", "didn't", "doesn't", "if", "whether", "unless", "as", "what",
                       "whatever", "who", "how", "which", "that", "would", "could", "might", "may", "will",
                       "you'll", "think", "guess", "bet", "hope", "assume", "suppose", "believe", "sure", "know",
                       "say", "said", "tell", "told", "mean"}
_KNOW_CLAUSE_NEXT = {"what", "how", "why", "where", "when", "if", "whether", "that", "it", "him", "her", "them",
                     "me", "us", "about", "who", "which", "everything", "nothing", "everyone", "anything",
                     "something", "better", "more"}
# A noun-phrase head before "kind of" makes it the noun: "this kind of bug", "a weird kind of thing".
_KIND_NOUN_BEFORE = _DETERMINERS | {"what", "which", "any", "some", "every", "each", "no", "another", "other",
                                    "same", "different", "one", "certain", "all", "whatever", "new", "right",
                                    "wrong", "particular", "specific", "weird", "special", "similar", "whole",
                                    "main", "first", "last", "only", "that", "that's", "of", "for", "in", "on"}
# Sentence-opening "so"/"well" before these are degree or purpose words: "So many", "So that", "Well before".
_SO_CONTENT_NEXT = {"many", "much", "far", "that", "long", "few", "little", "often", "soon", "what", "do", "did"}
_WELL_CONTENT_NEXT = {"before", "after", "over", "under", "enough", "done", "within", "beyond", "above", "below",
                      "past", "ahead", "into", "known", "tested", "documented", "written"}


def _ends_sentence(w):
    return any(c in ".!?" for c in w.punct)


def _starts_sentence(a, p):
    return p == 0 or "\n" in a[p].gap or _ends_sentence(a[p - 1])


def _open_left(a, p):
    """Nothing binds a[p] to the word before it: a sentence or line start, or punctuation."""
    return _starts_sentence(a, p) or bool(a[p - 1].punct)


def _opening(a, p):
    """Whether a[p] opens its sentence, possibly after discourse words ("Okay, so, um, ...")."""
    while not _starts_sentence(a, p):
        for phrase in _OPENERS:
            s = p - len(phrase)
            words = a[s:p] if s >= 0 else ()
            if words and all(w.key == k and not w.literal for w, k in zip(words, phrase, strict=True)) \
                    and not any(w.punct for w in words[:-1]):
                p = s
                break
        else:
            return False
    return True


def _negative(w):
    return w.key in _NEGATIONS or w.key.endswith("n't")


def _negated_before(a, p):
    while not _starts_sentence(a, p):
        p -= 1
        if _negative(a[p]):
            return True
    return False


def _digits(w):
    return w.literal and any(c.isdigit() for c in w.body)


def _value(w):
    return _digits(w) or w.key in _NUMBERS or w.key in _QUANTIFIERS


def _quantity(a, p):
    w = a[p]
    return _value(w) or (w.key in _APPROX_LEADS and not w.punct and p + 1 < len(a) and _value(a[p + 1]))


def _after(a, e):
    """The first word after a[:e] that is not a discourse word, within the sentence, or None."""
    p = e
    while p < len(a):
        if _ends_sentence(a[p - 1]) or "\n" in a[p].gap:
            return None
        if a[p].literal:
            return p
        if p + 1 < len(a) and (a[p].key, a[p + 1].key) in _SKIP_PAIRS:
            p += 2
        elif a[p].key in _SKIP:
            p += 1
        else:
            return p
    return None


def _hesitation(a, i, e):
    w = a[i]
    # "uh uh", "uh huh" and "mm hmm" answer a question.
    if w.key == "uh" and not w.punct and e < len(a) and a[e].key in {"uh", "huh"}:
        return False
    return not (i and not a[i - 1].punct and (a[i - 1].key, w.key) in {("uh", "uh"), ("mm", "hmm"), ("mm", "hm")})


def _opening_marker(next_words=None, blocked=frozenset()):
    """A sentence-opening marker. `next_words` None: any following word that is not literal and not `blocked`."""
    def rule(a, i, e):
        if not _opening(a, i):
            return False
        last = a[e - 1]
        # Standing alone ("Okay." "Right.") a marker can be the answer to a question.
        if e == len(a) or _ends_sentence(last) or "\n" in a[e].gap:
            return False
        if last.punct:
            return True
        nxt = a[e]
        if nxt.literal or nxt.key in blocked:
            return False
        return next_words is None or nxt.key in next_words
    return rule


_right_marker = _opening_marker(_RIGHT_NEXT)


def _right(a, i, e):
    # Wherever "left" is in play, "right" may be a direction or an answer.
    return not any(w.key == "left" for w in a) and _right_marker(a, i, e)


def _like(a, i, e):
    p = _after(a, e)
    if p is None or _quantity(a, p):
        return False  # "like 20 minutes" is an estimate
    if "," in a[i].punct and _open_left(a, i):
        # Set off by commas it is parenthetical, unless it hedges a preposition's object: "by, like, Friday".
        return _starts_sentence(a, i) or a[i - 1].key not in _PREPOSITIONS
    if a[i].punct or a[e].literal:
        return False
    if _starts_sentence(a, i):
        # "Like latency is bad" opens with a filler; "Like I said" and "Like the old one, ..." do not.
        return a[e].key not in _SUBJECTS and a[e].key not in _HEDGE_STOPS and a[e].key not in _PERSONS
    if a[i - 1].punct or a[i - 1].literal:
        return False
    prev, nxt = a[i - 1].key, a[e]
    if prev not in _LIKE_FILLER_AFTER or nxt.literal:
        return False
    if prev in _PERSONS and (nxt.key in _LIKE_VERB_NEXT or nxt.key.endswith("ing")):
        return False  # "I like how", "we like the new icon", "you like running it": the verb
    if prev in _COPULA and nxt.key in _HEDGE_STOPS:
        return False  # "this is like the bug we had": a comparison
    return True


def _you_know(a, i, e):
    if _open_left(a, i) and (e == len(a) or bool(a[e - 1].punct) or "\n" in a[e].gap):
        return True  # set off on both sides
    # Unpunctuated it is a clause after "do", "if", "unless", "I think" and before an object or a wh-clause.
    if i and (a[i - 1].literal or a[i - 1].key in _KNOW_CLAUSE_BEFORE):
        return False
    if e == len(a) or a[e - 1].punct:
        return False
    return not a[e].literal and a[e].key not in _KNOW_CLAUSE_NEXT


def _request(a, i):
    """Whether a[i] follows "can you", "could we" and the like: the next verb is asked for, not reported."""
    return i >= 2 and not a[i - 2].punct and a[i - 1].key in _PERSONS and a[i - 2].key in _MODALS


def _hedge(a, i, e):
    """"kind of" as a hedge on a predicate, not the noun in "this kind of input"."""
    if e < len(a) and a[e].key in _HEDGE_STOPS and not _ends_sentence(a[e - 1]):
        return False
    p = _after(a, e)
    if p is None or a[p].literal or _quantity(a, p) or a[p].key in _HEDGE_STOPS or _negative(a[p]) \
            or (a[p].key in _OUTCOMES and not _request(a, i)):
        return False
    if _open_left(a, i) or a[i - 1].key in _HEDGE_HOSTS:
        return True
    # After a noun subject ("the island kind of jumps"), unless a determiner or modifier makes it the noun.
    return not a[i - 1].literal and a[i - 1].key not in _KIND_NOUN_BEFORE


def _hedge_adverb(a, i, e):
    """"basically" and "essentially" hedging a clause, not a value, a status or an identity."""
    p = _after(a, e)
    if p is not None:
        nxt = a[p]
        if _quantity(a, p) or _negative(nxt) or (nxt.key in _OUTCOMES and not _request(a, i)):
            return False
        # After a copula it hedges a noun phrase: "it's basically the same bug" is not "the same bug".
        if i and not a[i - 1].punct and a[i - 1].key in _COPULA and (nxt.literal or nxt.key in _HEDGE_STOPS):
            return False
    if p is None or a[e - 1].punct:
        # Closing its clause it can hedge the value just before it: "3 megabytes basically".
        q = i
        for _ in range(2):
            if _starts_sentence(a, q):
                break
            q -= 1
            if _value(a[q]):
                return False
    return True


def _just(a, i, e):
    """"just" softening a request ("can you just check"), never "only", "recently" or the `just` runner."""
    p = _after(a, e)
    if p is None or a[p].literal or _quantity(a, p) or a[p].key in _JUST_STOPS or _negative(a[p]):
        return False
    if _negated_before(a, i):
        return False  # "don't just restart it" limits the negation
    if _opening(a, i) or _open_left(a, i):
        return True  # "Just check it." / "I'll send it, just expect it late."
    prev = a[i - 1].key
    if prev in {"please", "let's", "to", "i'll", "we'll", "you'll", "i'd", "we'd", "you'd"}:
        return True
    if i < 2 or a[i - 2].punct:
        return False
    first = a[i - 2].key
    return (first in _MODALS and prev in _PERSONS) or (first in _PERSONS and prev in _MODALS)


def _thing_is(a, i, e):
    if not _opening(a, i) or e == len(a) or _ends_sentence(a[e - 1]) or "\n" in a[e].gap:
        return False
    last = a[e - 1]
    # "The thing is broken" is content; "the thing is, ..." and "the thing is we ..." introduce a clause.
    return bool(set(last.punct) & {",", ":"}) or (not last.punct and not a[e].literal and a[e].key in _SUBJECTS)


def _heres_thing(a, i, e):
    return _opening(a, i) and bool(a[e - 1].punct)


_RULES = {("like",): _like, ("you", "know"): _you_know, ("y'know",): _you_know, ("ya", "know"): _you_know,
          ("kind", "of"): _hedge, ("sort", "of"): _hedge, ("kinda",): _hedge, ("sorta",): _hedge,
          ("basically",): _hedge_adverb, ("essentially",): _hedge_adverb, ("just",): _just,
          ("the", "thing", "is"): _thing_is, ("here's", "the", "thing"): _heres_thing, ("right",): _right,
          ("so",): _opening_marker(blocked=_SO_CONTENT_NEXT),
          ("well",): _opening_marker(blocked=_WELL_CONTENT_NEXT)}
_RULES.update({(h,): _hesitation for h in _HESITATIONS})
_RULES.update({m: _opening_marker()
               for m in [("okay",), ("ok",), ("alright",), ("all", "right"), ("anyway",), ("anyways",)]})

FILLERS = frozenset(" ".join(phrase) for phrase in _RULES)


def filler_end(a, i, stop):
    """Exclusive end of the longest filler phrase that starts at a[i] and ends by `stop`, or `i` when the words
    there are content in this context. The context may lie outside [i, stop)."""
    stop = min(stop, len(a))
    for size in (3, 2, 1):
        e = i + size
        if e > stop:
            continue
        words = a[i:e]
        rule = _RULES.get(tuple(w.key for w in words))
        if rule is None or any(w.literal for w in words) or "?" in words[-1].punct:
            continue  # a filler carrying "?" is a tag question
        if any(w.punct for w in words[:-1]) or any("\n" in w.gap for w in words[1:]):
            continue
        if rule(a, i, e):
            return e
    return i


def _copy_at(a, s, keys):
    if s < 0 or s + len(keys) > len(a):
        return None
    words = a[s:s + len(keys)]
    if any(w.key != k or w.literal for w, k in zip(words, keys, strict=True)) or any(w.punct for w in words[:-1]):
        return None
    return range(s, s + len(keys))


def _copy_after(a, p, keys):
    while p < len(a):
        e = filler_end(a, p, len(a))
        if e == p:
            break
        p = e
    return _copy_at(a, p, keys)


def _copy_before(a, p, keys):
    while p:
        for s in range(p - 1, max(p - 3, 0) - 1, -1):  # filler phrases are at most three words
            if filler_end(a, s, p) == p:
                p = s
                break
        else:
            break
    return _copy_at(a, p - len(keys), keys)


def _whole_number(a, copies):
    """Each copy is a whole number, not part of a longer one ("four four three") or one value of a list."""
    end, start = copies[-1].stop, copies[0].start
    if a[end - 1].punct or end == len(a) or "\n" in a[end].gap:
        return False
    nxt = a[end]
    if nxt.key in _NUMBERS or nxt.key in _NUMBER_LINKS or _digits(nxt):
        return False
    return not (start and not _ends_sentence(a[start - 1]) and a[start - 1].key in _NUMBERS | {"point", "dot"})


def _restart(a, keys, start):
    """A restarted clause opening ("I think, I think", "can you, can you"), not one that closes a clause
    ("fix what you can, you can skip the rest")."""
    if len(keys) < 2 or not (keys[0] in _SUBJECTS or (keys[0] in _AUX and keys[1] in _SUBJECTS)):
        return False
    return _open_left(a, start) or _opening(a, start) or a[start - 1].key in {"and", "but", "then", "so"}


def _safe_repeat(a, keys, copies):
    last = keys[-1]
    if last in _DEGREE or any(k in _OPERATORS for k in keys):
        return False
    gaps = []
    for x, y in zip(copies, copies[1:], strict=False):
        if y.start < x.stop:
            return False
        # Copies in two sentences or two lines are two statements: "No. No alerts fired."
        if any(_BREAKS.intersection(a[q].punct) for q in range(x.stop - 1, y.start)) \
                or any("\n" in a[q].gap for q in range(x.stop, y.stop)):
            return False
        gaps.append(bool(a[x.stop - 1].punct) or y.start > x.stop)
    if any(k in _NUMBERS for k in keys):
        return last in _NUMBERS and all(gaps) and _whole_number(a, copies)
    if any(k in _NEGATIONS or k.endswith("n't") for k in keys) and not all(gaps):
        return False  # "not not working"
    if _restart(a, keys, copies[0].start):
        return True
    # A content word or a clause-final word repeated across a comma can be two list items or two clauses:
    # "the parser, the parser config", "Safari, Safari on iOS", "old old build".
    return all(last in (_SEPARABLE if gap else _ADJACENT) for gap in gaps)


def stutter_twin(a, i, j):
    """The kept copy (a range of `a`) that makes deleting a[i:j] a stutter, or None.

    Apart from filler phrases, a[i:j] must be one to four words, possibly said several times, next to one more
    identical copy, with nothing but fillers and commas between the copies. The kept copy must survive the edit."""
    j = min(j, len(a))
    core, p = [], i
    while p < j:
        e = filler_end(a, p, j)
        if e > p:
            p = e
        else:
            core.append(p)
            p += 1
    if not core or any(a[q].literal or "?" in a[q].punct for q in range(i, j)):
        return None
    keys = [a[q].key for q in core]
    for c in range(1, min(_MAX_REPEAT, len(keys)) + 1):
        if len(keys) % c or keys != keys[:c] * (len(keys) // c):
            continue
        starts = range(0, len(core), c)
        if any(core[s + c - 1] != core[s] + c - 1 or any(a[q].punct for q in core[s:s + c - 1]) for s in starts):
            continue
        copies = [range(core[s], core[s] + c) for s in starts]
        for twin in (_copy_after(a, j, keys[:c]), _copy_before(a, i, keys[:c])):
            if twin is not None and _safe_repeat(a, keys[:c], sorted([twin, *copies], key=lambda r: r.start)):
                return twin
    return None


def stutter(a, i, j):
    """Whether deleting a[i:j] removes a stutter or a restarted phrase while an identical copy stays."""
    return stutter_twin(a, i, j) is not None
