"""Closed-lexicon checks for one-word grammar fixes and spoken-list numerals in the bench edit policy.

`inflection(x, y)` is context-free lexical eligibility, for tagging lab data only. `grammar_edit(a, i, key)`
authorizes replacing the source word a[i] with `key` in its source context; `grammar_options(a, i)` lists every
key it authorizes. The slips it covers: subject-verb agreement, present to past with a stated past time, a past
form for a participle or the reverse, the bare verb after a modal or do-support, a/an, "I" -> "me" after a
preposition, and "of" -> "have" after could/should/would/must/might. Word choice and homophones (then/than,
its/it's, less/fewer) stay out. `list_edit(a, i, j, b, k, m)` authorizes one list numeral b[k:m] for the source
words a[i:j], checked against the whole spoken enumeration in `a` and every list numeral in `b`.

Each predicate refuses what the words do not show: a pair outside the closed paradigms, a polarity change, a
report turned into an instruction or the reverse, a changed count, order or referent, a literal, and any clause
whose subject, tense or list structure is ambiguous. No state is mutable.
"""
import re
from types import MappingProxyType

from polish_fillers import filler_end

_PLAIN = re.compile(r"[a-z]+(?:'[a-z]+)?")
_ALPHA = re.compile(r"[a-z]+")
_NUMERAL = re.compile(r"(\d{1,2})[.)]")


def _words(text):
    return frozenset(text.split())


_HESITATIONS = _words("um uh er erm uhm hmm mm")
# Words that may sit between a subject and its verb without changing which word is the subject.
_TRANSPARENT = _HESITATIONS | _words("still also always usually often sometimes already really even just never ever")
_DETS = _words("the this that these those my our your his her their its each every a an")
_NOMINATIVE = MappingProxyType({"i": "1s", "he": "3s", "she": "3s", "we": "pl", "they": "pl"})
_OBJECTS = _words("me him her us them it you")
_MODALS = _words("can could will would shall should may might must can't couldn't won't wouldn't shouldn't "
                 "mustn't")
_AUX = _MODALS | _words("do does did don't doesn't didn't am is are was were isn't aren't wasn't weren't have has "
                        "had haven't hasn't hadn't")
_HAVE = _words("have has had having haven't hasn't hadn't i've we've you've they've could've should've would've "
               "must've might've")
_OPENERS = _HESITATIONS | _words("but so because cause since when whenever if that though although while after "
                                 "before until once where then okay ok alright well yeah yes now also plus "
                                 "yesterday today")
_PREPOSITIONS = _words("to with for from about between at by of without behind among against toward towards into "
                       "onto via per than like")
_NUMBERS = _words(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
    "seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million "
    "billion dozen once twice half couple first second third fourth fifth sixth seventh eighth ninth tenth "
    "eleventh twelfth twentieth hundredth firstly secondly thirdly fourthly")
_COUNT_WORDS = (_NUMBERS - _words("zero one once twice half couple first second third fourth fifth sixth seventh "
                                  "eighth ninth tenth eleventh twelfth twentieth hundredth firstly secondly "
                                  "thirdly fourthly")) | _words("several many multiple both")
_FUNCTION = (_DETS | _OBJECTS | _AUX | _PREPOSITIONS | frozenset(_NOMINATIVE) | _HESITATIONS | _words(
    "and or nor but so yet because if when while although though unless whether then once where what which who "
    "whom whose how why there here now not no yes yeah okay ok please only very too also just some any all both "
    "either neither another such none nothing something anything everything nobody someone anyone everyone "
    "somebody anybody everybody myself yourself himself herself itself ourselves themselves be been being in on "
    "up down out off over under after before since until till through during within across along around near "
    "upon as other others more most less least fewer much many several lot lots again instead anyway maybe perhaps"))
_NEGATIVES = _words("not no never none nothing nobody nowhere neither nor cannot")
_BREAKS = frozenset(".?!;:,")
_ENDS = frozenset(".?!")

# Closed verb paradigms. Tags: base, 3s (third person singular present), past, part (past participle); for be,
# 1s/3s/pl present and psg/ppl past.
_BE = (("1s", "am"), ("3s", "is"), ("pl", "are"), ("psg", "was"), ("ppl", "were"), ("part", "been"))
_CLOSED = (
    ("be", _BE),
    ("be", (("3s", "isn't"), ("pl", "aren't"), ("psg", "wasn't"), ("ppl", "weren't"))),
    ("closed", (("base", "have"), ("3s", "has"), ("past", "had"), ("part", "had"))),
    ("closed", (("base", "haven't"), ("3s", "hasn't"), ("past", "hadn't"))),
    ("closed", (("base", "do"), ("3s", "does"), ("past", "did"), ("part", "done"))),
    ("closed", (("base", "don't"), ("3s", "doesn't"), ("past", "didn't"))),
)
# base, 3s, past, participle. Irregular verbs, and regular ones whose spelling the suffix rules would misread.
_VERB_TABLE = """
go goes went gone|see sees saw seen|take takes took taken|write writes wrote written|rewrite rewrites rewrote
rewritten|make makes made made|get gets got gotten|give gives gave given|find finds found found|tell tells told
told|break breaks broke broken|speak speaks spoke spoken|bring brings brought brought|buy buys bought bought|pay
pays paid paid|say says said said|lay lays laid laid|catch catches caught caught|teach teaches taught taught|think
thinks thought thought|fight fights fought fought|seek seeks sought sought|meet meets met met|fall falls fell
fallen|know knows knew known|throw throws threw thrown|grow grows grew grown|blow blows blew blown|draw draws drew
drawn|fly flies flew flown|show shows showed shown|send sends sent sent|spend spends spent spent|lend lends lent
lent|bend bends bent bent|build builds built built|rebuild rebuilds rebuilt rebuilt|forget forgets forgot
forgotten|forgive forgives forgave forgiven|begin begins began begun|choose chooses chose chosen|run runs ran
run|rerun reruns reran rerun|come comes came come|become becomes became become|freeze freezes froze frozen|leave
leaves left left|keep keeps kept kept|sleep sleeps slept slept|sweep sweeps swept swept|feel feels felt felt|deal
deals dealt dealt|hear hears heard heard|hold holds held held|lose loses lost lost|mean means meant meant|lead
leads led led|feed feeds fed fed|bleed bleeds bled bled|speed speeds sped sped|drive drives drove driven|ride rides
rode ridden|rise rises rose risen|wake wakes woke woken|wear wears wore worn|tear tears tore torn|swear swears swore
sworn|win wins won won|sell sells sold sold|stand stands stood stood|understand understands understood
understood|sit sits sat sat|stick sticks stuck stuck|strike strikes struck struck|spin spins spun spun|dig digs dug
dug|swing swings swung swung|sing sings sang sung|ring rings rang rung|sink sinks sank sunk|drink drinks drank
drunk|swim swims swam swum|eat eats ate eaten|hide hides hid hidden|slide slides slid slid|shoot shoots shot
shot|shine shines shone shone|bind binds bound bound|grind grinds ground ground|hang hangs hung hung|shake shakes
shook shaken|steal steals stole stolen|undo undoes undid undone|redo redoes redid redone|put puts put put|set sets
set set|reset resets reset reset|cut cuts cut cut|hit hits hit hit|let lets let let|quit quits quit quit|read reads
read read|shut shuts shut shut|split splits split split|spread spreads spread spread|cost costs cost cost|hurt hurts
hurt hurt|need needs needed needed|proceed proceeds proceeded proceeded|exceed exceeds exceeded exceeded|succeed
succeeds succeeded succeeded|cache caches cached cached|apply applies applied applied|reply replies replied
replied|supply supplies supplied supplied|rely relies relied relied|comply complies complied complied|imply implies
implied implied|multiply multiplies multiplied multiplied
"""
_PARADIGMS = _CLOSED + tuple(
    ("table", tuple(zip(("base", "3s", "past", "part"), row.split(), strict=True)))
    for row in " ".join(_VERB_TABLE.split()).replace(" | ", "|").split("|"))


def _build_index():
    index = {}
    for n, (_, forms) in enumerate(_PARADIGMS):
        for _, form in forms:
            if n not in index.setdefault(form, []):
                index[form].append(n)
    return MappingProxyType({form: tuple(ns) for form, ns in index.items()})


_INDEX = _build_index()
_GROUP = MappingProxyType({"base": "now", "3s": "now", "1s": "now", "pl": "now", "psg": "past", "ppl": "past"})
_AGREES = MappingProxyType({"base": frozenset({"1s", "pl"}), "3s": frozenset({"3s"}), "1s": frozenset({"1s"}),
                            "pl": frozenset({"pl"}), "psg": frozenset({"1s", "3s"}), "ppl": frozenset({"pl"})})
# Fixed one-way slips, each with its own context rule below. Word choices and homophones (then/than, its/it's,
# less/fewer) are not speech slips and stay out.
_CONFUSABLE = MappingProxyType({"a": ("an",), "an": ("a",), "i": ("me",), "of": ("have",)})
_OF_MODALS = _words("could should would must might")
# Auxiliaries that take a bare verb: "could you checks" -> "check", "did they sent" -> "send".
_BARE_AUX = _words("can could will would shall should may might must can't couldn't won't wouldn't shouldn't "
                   "mustn't do does did don't doesn't didn't")
_WH = _words("what why how where when who which")
_IRREGULAR_PLURALS = _words("people children men women")
_UNCOUNTED = _words("data media news series species staff team police crew group family")
# The word after a verb that has no closed-class form must read as that verb's complement; otherwise "the old
# test on main" reads as subject "the old" plus verb "test" and licenses test -> tests, and "you guys" licenses
# guys -> guy. A noun subject takes only these; a pronoun takes a determiner too; he/she/it/I, which no plural
# noun follows, also take a preposition or a past time.
_COMPLEMENT = _OBJECTS | _words("nothing everything something anything up down out off over back away through "
                                "around together apart")
_WIDE_NEXT = _DETS | _PREPOSITIONS | _words("in on at yesterday last")
_FUTURE = _words("will won't gonna tomorrow next later soon tonight upcoming")
_PAST_TIME = _words("night week weekend month year time sprint quarter release monday tuesday wednesday thursday "
                    "friday saturday sunday")
_COUNTERFACTUAL = _words("if wish though whether unless suppose imagine rather")
_PERFECT_SKIP = _TRANSPARENT | {"not"}
_OBJECT_START = _DETS | _OBJECTS | _words("that this everything nothing something anything all")
_CONSONANT_SOUND = ("one", "once", "uni", "use", "usa", "usu", "uti", "ure", "uri", "eu", "ewe", "url", "usb", "ui",
                    "ux", "uuid", "utf")
_VOWEL_SOUND = ("hour", "honest", "honor", "honour", "heir")
_AFTER_OBJECT = _words("but and or so because since too as please then when if after before about on in for at by "
                       "today tomorrow yesterday later")


def _negative(key):
    return key in _NEGATIVES or key.endswith("n't")


def _suffix_s(base):
    if base.endswith(("s", "sh", "ch", "x", "z")):
        return base + "es"
    if base.endswith("y") and base[-2] not in "aeiou":
        return base[:-1] + "ies"
    if base.endswith("o"):
        return None  # echoes or demos: the spelling is not derivable
    return base + "s"


def _unsuffix_s(word):
    if word.endswith("ies") and len(word) > 4:
        base = word[:-3] + "y"
    elif word.endswith(("sses", "shes", "ches", "xes", "zzes", "oes")):
        base = word[:-2]
    else:
        base = word[:-1]
    return base if _suffix_s(base) == word else None


def _suffix_ed(base):
    if base.endswith("e"):
        return base + "d"
    if base.endswith("y"):
        return base + "ed" if base[-2] in "aeiou" else base[:-1] + "ied"
    if base.endswith("c") or (base[-1] not in "aeiouwxy" and base[-2] in "aeiou" and base[-3] not in "aeiou"):
        return None  # open/opened against stop/stopped: consonant doubling depends on stress
    return base + "ed"


def _regular_word(word):
    """Whether suffix rules may read `word` as a verb or noun stem: plain, not a function word or number, not
    already -ing/-ed, and not -ly ("he simply", "it really"), whose verbs sit in the table."""
    return bool(_ALPHA.fullmatch(word)) and len(word) >= 3 and word not in _FUNCTION and word not in _NUMBERS \
        and not word.endswith(("ing", "ed", "ly")) and word not in _INDEX


def _paradigms(x):
    """(family, forms) for every paradigm holding x. family is be, closed, table or regular."""
    if x in _INDEX:
        return tuple(_PARADIGMS[n] for n in _INDEX[x])
    if not _regular_word(x):
        return ()
    base = _unsuffix_s(x) if x.endswith("s") and not x.endswith(("ss", "us", "is")) else x
    if base is None or not _regular_word(base):
        return ()
    past = _suffix_ed(base)
    forms = [("base", base), ("3s", _suffix_s(base)), ("past", past), ("part", past)]
    # A derived spelling that is another verb's own form ("fee" -> "feed") is not this word's inflection.
    forms = tuple((t, f) for t, f in forms if f and (f == base or f not in _INDEX))
    return (("regular", forms),) if (forms and any(f == x for _, f in forms)) else ()


def _neighbors(x):
    forms = {f for _, fs in _paradigms(x) for _, f in fs}
    forms.update(_CONFUSABLE.get(x, ()))
    forms.discard(x)
    return forms


def _norm(word):
    return word.lower().replace("’", "'")


def inflection(x, y):
    """Context-free: whether y is another form of x in the closed lexicon. For tagging lab data, never as
    permission to deliver an edit; `grammar_edit` decides that in context."""
    x, y = _norm(x), _norm(y)
    if x == y or not _PLAIN.fullmatch(x) or not _PLAIN.fullmatch(y):
        return False
    if _negative(x) != _negative(y) or x in _NUMBERS or y in _NUMBERS:
        return False
    return y in _neighbors(x) or x in _neighbors(y)


# Context helpers. Every position is an index into the source sequence `a` of polish_tokens.Word.

def _content(w):
    return not w.literal and bool(_ALPHA.fullmatch(w.key)) and w.key not in _FUNCTION and w.key not in _NUMBERS


def _clause_start(a, p):
    if p == 0 or "\n" in a[p].gap:
        return True
    prev = a[p - 1]
    return bool(set(prev.punct) & _BREAKS) or (prev.key in _OPENERS and not prev.literal)


def _back(a, i, skip=_TRANSPARENT):
    p = i - 1
    while p >= 0 and a[p].key in skip and not a[p].punct and not a[p].literal:
        p -= 1
    return p


def _forward(a, i):
    if a[i].punct:
        return -1
    n = i + 1
    while n < len(a) and a[n].key in _HESITATIONS:
        n += 1
    return n if n < len(a) else -1


def _noun_number(key):
    if key in _IRREGULAR_PLURALS:
        return "pl"
    if key in _UNCOUNTED or not _ALPHA.fullmatch(key) or key in _FUNCTION or key in _NUMBERS:
        return None
    if key.endswith("ss"):
        return "3s"
    if key.endswith(("us", "is", "ics")):
        return None
    return "pl" if key.endswith("s") else "3s"


def _existential(a, i):
    """Number of the noun after "there is/are": only a count or a single article settles it."""
    n = _forward(a, i)
    if n < 0:
        return None
    w = a[n]
    if w.body.isdecimal():
        return "3s" if int(w.body) == 1 else "pl"
    if w.key in _COUNT_WORDS:
        return "pl"
    if w.key in ("a", "an", "one", "another"):
        quantity = n + 1 < len(a) and a[n + 1].key in _words("few lot lots couple bunch number ton handful")
        return None if quantity else "3s"
    return None


def _subject(a, i):
    """(class, kind, modified) of the subject right before the finite verb a[i]: class 1s, 3s or pl; kind pronoun,
    noun or there; modified when a noun subject has a word between determiner and head. None when the words do
    not show one subject plainly: an imperative, an inverted question, a coordinated or relative subject."""
    p = _back(a, i)
    if p < 0 or a[p].punct or a[p].literal:
        return None
    key = a[p].key
    prev = a[p - 1].key if p and not a[p - 1].punct else ""
    if key in _NOMINATIVE:
        cls = _NOMINATIVE[key]
        if prev in _AUX or (cls != "pl" and prev in ("and", "or", "nor")):
            return None
        return cls, "pronoun", False
    if key in ("it", "you"):
        return (("3s" if key == "it" else "pl"), "pronoun", False) if _clause_start(a, p) else None
    if key == "there":
        cls = _existential(a, i) if _clause_start(a, p) else None
        return (cls, "there", False) if cls else None
    number = _noun_number(key)
    if number is None or not _content(a[p]) or key.endswith(("ing", "ed")):
        return None
    q, modified = p - 1, False
    if q >= 0 and a[q].key not in _DETS and _content(a[q]) and not a[q].punct:
        q, modified = q - 1, True
    if q < 0 or a[q].key not in _DETS or a[q].punct or a[q].literal:
        return None
    det = a[q].key
    if (det in ("these", "those") and number != "pl") or (det in ("a", "an", "this", "each", "every")
                                                          and number != "3s"):
        return None
    if q >= 2 and a[q - 1].key == "of" and a[q - 2].key in ("one", "each", "either", "neither") \
            and not a[q - 1].punct and not a[q - 2].punct:
        return ("3s", "noun", modified) if _clause_start(a, q - 2) else None
    return (number, "noun", modified) if _clause_start(a, q) else None


def _verb_next(a, i, kind):
    """Whether the word after a[i] reads as a complement of a verb at a[i] (see _COMPLEMENT)."""
    n = _forward(a, i)
    if n < 0 or a[n].literal:
        return False
    key = a[n].key
    if key in _COMPLEMENT or (key.endswith("ing") and len(key) > 4 and key not in _FUNCTION):
        return True
    if kind != "pronoun":
        return False
    return key in _DETS or (a[_back(a, i)].key in ("i", "he", "she", "it") and key in _WIDE_NEXT)


def _sentence(a, i):
    lo = i
    while lo > 0 and not set(a[lo - 1].punct) & _ENDS and "\n" not in a[lo].gap:
        lo -= 1
    hi = i
    while hi + 1 < len(a) and not set(a[hi].punct) & _ENDS and "\n" not in a[hi + 1].gap:
        hi += 1
    return lo, hi + 1


def _past_context(a, i):
    """An explicit past time in the verb's sentence and no future in it. "this morning", "on Friday" and another
    past verb are not enough: they also go with plans and with present facts."""
    lo, hi = _sentence(a, i)
    keys = [w.key for w in a[lo:hi]]
    pairs = list(zip(keys, keys[1:], strict=False))
    if any(k in _FUTURE or k.endswith("'ll") for k in keys) or ("going", "to") in pairs:
        return False
    return "yesterday" in keys or "ago" in keys[1:] or any(k == "last" and n in _PAST_TIME for k, n in pairs)


# One rule per kind of slip. Each sees x = a[i].key and the proposed key y.

def _agreement(a, i, x, y):
    """Same tense, the form that agrees with a plain subject: "the logs shows" -> "show"."""
    subject = _subject(a, i)
    if subject is None:
        return False
    cls, kind, modified = subject
    for family, forms in _paradigms(x):
        tx = {t for t, f in forms if f == x and t in _AGREES}
        ty = {t for t, f in forms if f == y and t in _AGREES}
        if not any(_GROUP[t] == _GROUP[u] and cls not in _AGREES[t] and cls in _AGREES[u] for t in tx for u in ty):
            continue
        if kind == "there" and family != "be":
            continue
        if family not in ("be", "closed") and (
                (kind == "noun" and modified and family == "regular") or not _verb_next(a, i, kind)):
            continue
        if x in ("were", "weren't") and _COUNTERFACTUAL & {w.key for w in a[max(0, i - 5):i]}:
            continue  # "if I were you" is not a slip
        return True
    return False


def _tense(a, i, x, y):
    """Present to past only for a stated subject and an explicit past time: "I send it yesterday" -> "sent".
    Never the reverse, never for an imperative: a report must not become an instruction or the other way."""
    subject = _subject(a, i)
    if subject is None or subject[1] == "there" or not _past_context(a, i):
        return False
    cls, kind, _ = subject
    for family, forms in _paradigms(x):
        tags = {t for t, f in forms if f == x}
        if not tags & {"base", "3s", "1s", "pl"}:
            continue
        wanted = ("ppl" if cls == "pl" else "psg") if family == "be" else "past"
        if (wanted, y) not in forms:
            continue
        # A suffix-derived verb needs a pronoun subject it agrees with and a verb's complement: "you guys
        # yesterday" must not become "you guyed".
        if family == "regular" and not (kind == "pronoun" and any(cls in _AGREES[t] for t in tags & _AGREES.keys())
                                        and _verb_next(a, i, kind)):
            continue
        return True
    return False


def _participle(a, i, x, y):
    """ "has went" -> "gone" after a have auxiliary; "I seen it" -> "saw" for a pronoun subject with an object."""
    for family, forms in _paradigms(x):
        if family == "regular":
            continue
        past = {f for t, f in forms if t == "past"}
        part = {f for t, f in forms if t == "part"}
        if x in past and x not in part and y in part and y not in past:
            p = _back(a, i, _PERFECT_SKIP)
            if p >= 0 and a[p].key in _HAVE and not a[p].punct:
                return True
        if x in part and x not in past and y in past and y not in part and x not in ("gone", "been"):
            subject = _subject(a, i)
            n = _forward(a, i)
            if subject and subject[1] == "pronoun" and n >= 0 and not a[n].literal and a[n].key in _OBJECT_START:
                return True
    return False


def _vowel_sound(word):
    return word.startswith(_VOWEL_SOUND) or (word[0] in "aeiou" and not word.startswith(_CONSONANT_SOUND))


def _article(a, i, x, y):
    if {x, y} != {"a", "an"}:
        return False
    n = _forward(a, i)
    if n < 0 or a[n].literal or not _ALPHA.fullmatch(a[n].key):
        return False
    return (y == "an") == _vowel_sound(a[n].key)


def _object_case(a, i, x, y):
    """ "to Sam and I" -> "me": a coordinated object right after a preposition."""
    if (x, y) != ("i", "me") or i < 3:
        return False
    head, other, conj = a[i - 3], a[i - 2], a[i - 1]
    if head.punct or other.punct or conj.punct or conj.key not in ("and", "or") or head.key not in _PREPOSITIONS:
        return False
    body = other.body
    name = not other.literal and body.isalpha() and body[:1].isupper() and body[1:].islower()
    if not (name or other.key in _OBJECTS - {"it"}):
        return False
    return bool(a[i].punct) or i + 1 == len(a) or a[i + 1].key in _AFTER_OBJECT


def _modal_have(a, i, x, y):
    """ "should of" -> "have": "of" is never English right after these modals."""
    return (x, y) == ("of", "have") and 0 < i < len(a) - 1 and not a[i].punct and not a[i - 1].punct \
        and a[i - 1].key in _OF_MODALS and not a[i + 1].literal


def _after_auxiliary(a, i, x, y):
    """The bare verb after a modal or do-support: "it should checks" -> "check", "could you checks" -> "check",
    "did you sent" -> "send". A positive do/does/did needs the inverted subject, because "we did checks" has do
    as the main verb and "checks" as its object; a past form is only made bare after did/didn't, where did keeps
    the tense ("should went" may mean "should have gone")."""
    p = _back(a, i)
    if p < 0 or a[p].punct or a[p].literal:
        return False
    inverted = a[p].key in _NOMINATIVE or a[p].key in ("it", "you")
    aux = _back(a, p) if inverted else p
    if aux < 0 or a[aux].punct or a[aux].literal or a[aux].key not in _BARE_AUX:
        return False
    key = a[aux].key
    before = a[aux - 1] if aux and not a[aux - 1].punct else None
    if inverted:
        if not (_clause_start(a, aux) or (before is not None and before.key in _WH)):
            return False
    elif key in ("do", "does", "did") or before is None or not (
            before.key in _NOMINATIVE or before.key in ("it", "you") or _content(before)):
        return False  # "May releases are slow", "in may releases", "the can checks": no auxiliary there
    for family, forms in _paradigms(x):
        tags = {t for t, f in forms if f == x}
        if family == "be" or ("base", y) not in forms:
            continue
        if family == "regular" and inverted and not _verb_next(a, i, "pronoun"):
            continue  # "can you guys check": the word after the pronoun is not always the verb
        if "3s" in tags or ("past" in tags and key in ("did", "didn't")):
            return True
    return False


_RULES = (_agreement, _tense, _participle, _article, _object_case, _modal_have, _after_auxiliary)


def grammar_edit(a, i, new_key):
    """Whether replacing a[i] with the word whose key is `new_key` fixes a grammatical slip in place, keeping
    polarity, referent, count, tense of a report or instruction, and every literal."""
    if not 0 <= i < len(a):
        return False
    x, y = a[i].key, _norm(new_key)
    if a[i].literal or x == y or not _PLAIN.fullmatch(x) or not _PLAIN.fullmatch(y):
        return False
    if _negative(x) != _negative(y) or x in _NUMBERS or y in _NUMBERS or y not in _neighbors(x):
        return False
    return any(rule(a, i, x, y) for rule in _RULES)


def grammar_options(a, i):
    """Every key `grammar_edit(a, i, key)` authorizes for a[i], sorted; candidates come from the closed lexicon."""
    if not 0 <= i < len(a) or a[i].literal:
        return ()
    return tuple(y for y in sorted(_neighbors(a[i].key)) if grammar_edit(a, i, y))


# Spoken lists.

_ORDINALS = MappingProxyType({"first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
                              "fourth": 4, "fourthly": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
                              "ninth": 9, "tenth": 10})
_MARKER_CARDINALS = MappingProxyType(
    {w: n for n, w in enumerate("one two three four five six seven eight nine ten".split(), 1)})


def _build_phrases():
    out = [((w,), "explicit", v) for w, v in _ORDINALS.items()]
    out += [(("first", "of", "all"), "explicit", 1), (("first", "off"), "explicit", 1)]
    out += [((lead, w), "explicit", v) for lead in ("number", "step") for w, v in _MARKER_CARDINALS.items()]
    out += [((w,), "bare", v) for w, v in _MARKER_CARDINALS.items()]
    out += [((w,), "seq", None) for w in ("then", "next", "afterwards")] + [(("after", "that"), "seq", None)]
    out += [((w,), "final", None) for w in ("finally", "lastly")]
    return tuple(sorted(out, key=lambda phrase: -len(phrase[0])))


_PHRASES = _build_phrases()
_LEAD = _HESITATIONS | _words("okay ok so alright well right now and also")
_THEN_BLOCK = _words("since until till by back even only just right but from if when")
_BLOCK_AFTER = _NUMBERS | _words("of and or to than time times place thing things half ones step steps priority")
_CONDITIONS = _words("if when whenever once unless until till while after before otherwise whether")


def _item_start(a, p):
    """Whether a[p] opens a clause: the text start, a line break, punctuation, or only lead-ins ("okay so") since
    one of those."""
    while p > 0 and "\n" not in a[p].gap:
        prev = a[p - 1]
        if set(prev.punct) & _BREAKS:
            return True
        if prev.key not in _LEAD or prev.literal:
            return False
        p -= 1
    return True


def _marker(a, p, anchor):
    """(start, core, end, value, kind) of a credible spoken list marker at a[p], an optional "and" included."""
    core = p + 1 if a[p].key == "and" and not a[p].punct and not a[p].literal else p
    if anchor and core != p:
        return None
    match = next((entry for entry in _PHRASES if core + len(entry[0]) < len(a)
                  and tuple(w.key for w in a[core:core + len(entry[0])]) == entry[0]), None)
    if match is None:
        return None
    phrase, kind, value = match
    end = core + len(phrase)
    span = a[p:end]
    if any(w.literal for w in span) or any(w.punct for w in span[:-1]):
        return None
    if phrase == ("after", "that") and not a[end - 1].punct:
        return None  # "after that finishes" is a condition, not a marker
    if kind in ("explicit", "bare") and (a[end].key in _BLOCK_AFTER or a[end].body.isdecimal()):
        return None  # "first two rows", "first of the month", "first time"
    if kind == "bare" and not (a[end - 1].punct and _item_start(a, p)):
        return None  # a bare "two" counts something unless it opens a clause and is set off
    if anchor:
        return (p, core, end, value, kind) if kind in ("explicit", "bare") and _item_start(a, p) else None
    prev = a[p - 1] if p and not a[p - 1].punct and "\n" not in a[p].gap else None
    if prev is not None and prev.key not in _LEAD:
        if phrase == ("then",) and prev.key in _THEN_BLOCK:
            return None
        if (kind == "explicit" or phrase == ("next",)) and (
                prev.key in _FUNCTION or prev.key in _NUMBERS or prev.body.isdecimal()):
            return None  # "do it first", "the next one", "page two"
    return p, core, end, value, kind


def _enumeration(a):
    """((start, core, end, value), ...) for the one spoken enumeration in `a`, or () when there is none or its
    structure is ambiguous: an anchor at a clause start, then consecutive explicit markers, or after "first" only
    sequence words; "finally" only last; no "then" that answers an if/when; every item non-empty."""
    marks, p = [], 0
    while p < len(a):
        m = _marker(a, p, not marks)
        if m is not None and marks and m[4] in ("seq", "final") and any(
                w.key in _CONDITIONS for w in a[marks[-1][2]:m[0]]):
            m = None  # "if it fails then roll back": the rollback stays conditional
        if m is None:
            p += 1
            continue
        marks.append(m)
        p = m[2]
    if len(marks) < 2:
        return ()
    kinds = [m[4] for m in marks]
    if "seq" in kinds and (marks[0][3] != 1 or any(k in ("explicit", "bare") for k in kinds[1:])):
        return ()  # "second X then Y": whether Y is item 3 or part of item 2 is not said
    if "final" in kinds[:-1]:
        return ()
    out, value = [], marks[0][3] - 1
    for n, (start, core, end, v, _) in enumerate(marks):
        value += 1
        if v is not None and v != value:
            return ()
        stop = marks[n + 1][0] if n + 1 < len(marks) else len(a)
        if all(w.key in _HESITATIONS for w in a[end:stop]):
            return ()
        out.append((start, core, end, value))
    return tuple(out)


def _list_numeral(words, p):
    """Value of a list numeral ("2." or "2)") opening an item at words[p], else None."""
    match = _NUMERAL.fullmatch(words[p].raw)
    if match is None or p + 1 >= len(words):
        return None
    if p and not words[p - 1].punct and "\n" not in words[p].gap and words[p - 1].key != "and":
        return None
    return int(match[1])


def _fillers_only(a, lo, hi):
    while lo < hi:
        end = filler_end(a, lo, hi)
        if end <= lo:
            return False
        lo = end
    return True


def list_edit(a, i, j, b, k, m):
    """Whether output numeral b[k] may stand for source words a[i:j] (i == j: inserted before them). The source
    must hold a credible spoken enumeration, the output's list numerals must be exactly its values in its order,
    and a[i:j] must be the matching marker with only fillers around it. Free digits, renumbering, merged or split
    items and an already numbered source are refused."""
    if m - k != 1 or k >= len(b):
        return False
    if _list_numeral(b, k) is None:
        return False
    marks = _enumeration(a)
    if not marks or any(_list_numeral(a, p) is not None for p in range(len(a))):
        return False
    slots = [p for p in range(len(b)) if _list_numeral(b, p) is not None]
    if [_list_numeral(b, p) for p in slots] != [mark[3] for mark in marks]:
        return False
    start, core, end, _ = marks[slots.index(k)]
    if i == j:
        return i in (start, core)
    if i > core or j < end:
        return False
    return (i >= start or _fillers_only(a, i, start)) and _fillers_only(a, end, j)
