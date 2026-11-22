"""bench/polish/polish_grammar.py: one-word grammar fixes and spoken-list numerals, on hand-written sentences."""
import difflib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
from polish_grammar import grammar_edit, grammar_options, inflection, list_edit  # noqa: E402
from polish_tokens import scan  # noqa: E402
from polishlab import merge_allowed, verify  # noqa: E402


def _at(words, key):
    return next(n for n, w in enumerate(words) if w.key == key)


def _list_ops(src, out):
    a, b = scan(src), scan(out)
    ops = difflib.SequenceMatcher(None, [w.key for w in a], [w.key for w in b], autojunk=False).get_opcodes()
    return [list_edit(a, i, j, b, k, m) for op, i, j, k, m in ops if op in ("replace", "insert")]


@pytest.mark.parametrize(("x", "y"), [
    ("keeps", "keep"), ("went", "gone"), ("A", "an"), ("checks", "check"), ("I", "me"), ("doesn't", "don't"),
])
def test_inflection_accepts_forms_of_one_word(x, y):
    assert inflection(x, y)


@pytest.mark.parametrize(("x", "y"), [
    ("log", "login"), ("should", "shouldn't"), ("seven", "seventy"), ("earlier", "earliest"), ("its", "it's"),
    ("fee", "feed"), ("then", "than"), ("employer", "employee"), ("simply", "simplies"),
])
def test_inflection_refuses_other_words_polarity_numbers_and_degree(x, y):
    assert not inflection(x, y)


@pytest.mark.parametrize(("src", "key", "new"), [
    ("the workers keeps crashing after the deploy", "keeps", "keep"),
    ("so it fail every time on arm", "fail", "fails"),
    ("they was reviewing the patch", "was", "were"),
    ("you was right about the cache", "was", "were"),
    ("there is three jobs queued", "is", "are"),
    ("each of the runners are idle", "are", "is"),
    ("the deploy script do the migration", "do", "does"),
    ("the release have shipped", "have", "has"),
    ("the parser don't handle tabs", "don't", "doesn't"),
    ("we hit a error in the parser", "a", "an"),
    ("we need an user account", "an", "a"),
    ("I seen the banner on staging", "seen", "saw"),
    ("we done the rollout already", "done", "did"),
    ("the patch has went out", "went", "gone"),
    ("they have took the lock", "took", "taken"),
    ("I push the fix yesterday", "push", "pushed"),
    ("she write the changelog last week", "write", "wrote"),
    ("the nightly job fall over again last night", "fall", "fell"),
    ("send it to Maya and I", "i", "me"),
    ("we could of caught that", "of", "have"),
    ("it should checks the token", "checks", "check"),
    ("could you checks the logs", "checks", "check"),
    ("did you sent the invite", "sent", "send"),
    ("it doesn't works on arm", "works", "work"),
])
def test_grammar_edit_fixes_a_slip_in_context(src, key, new):
    a = scan(src)
    assert grammar_edit(a, _at(a, key), new)


@pytest.mark.parametrize(("src", "key", "new"), [
    ("sort the rows by date", "date", "data"),  # another word
    ("delete the stale branch", "branch", "branches"),  # a noun's number
    ("The flaky test on main is slow", "test", "tests"),  # an adjective must not pass for a subject
    ("you guys should check the logs", "guys", "guy"),  # a noun after a pronoun is not its verb
    ("there are 4 failing job in the queue", "job", "jobs"),  # a noun's number, even after a count
    ("deploy the hotfix after review", "deploy", "deployed"),  # an instruction becomes a report
    ("merged the branch already", "merged", "merge"),  # a report becomes an instruction
    ("we use the shared bucket", "use", "used"),  # no stated past time
    ("I send the report yesterday and will send more tomorrow", "send", "sent"),  # the sentence has a future
    ("did they send it yesterday", "send", "sent"),  # do-support keeps the bare verb
    ("you shouldn't run it", "shouldn't", "should"),  # polarity
    ("the parser don't handle tabs", "don't", "does"),  # polarity
    ("restore the older snapshot", "older", "oldest"),  # degree
    ("keep the last seven logs", "seven", "seventy"),  # a number
    ("if I were you", "were", "was"),  # a counterfactual, not a slip
    ("Sam and I are on it", "are", "am"),  # a coordinated subject is plural
    ("the user name is wrong", "name", "names"),  # a compound noun, not a verb
    ("the new build is faster then the old one", "then", "than"),  # word choice is out of policy
    ("its been flaky all week", "its", "it's"),  # a homophone is out of policy
    ("we might loose the session", "loose", "lose"),
    ("there are less replicas now", "less", "fewer"),
    ("we may of missed it", "of", "have"),  # only could/should/would/must/might
    ("we did checks on the cluster", "checks", "check"),  # do as the main verb
    ("it should went out", "went", "go"),  # may mean "should have gone"
    ("it was done by the bot", "done", "did"),  # a passive, not a bare participle
    ("remove the fee from checkout", "fee", "feed"),
])
def test_grammar_edit_refuses_changes_of_meaning_and_ambiguity(src, key, new):
    a = scan(src)
    assert not grammar_edit(a, _at(a, key), new)


def test_grammar_edit_refuses_literals():
    a = scan("set the region to us-east-1 now")
    i = _at(a, "us-east-1")
    assert a[i].literal and not grammar_edit(a, i, "us-east-2")
    assert grammar_options(a, i) == ()


@pytest.mark.parametrize(("src", "key", "options"), [
    ("the workers keeps crashing after the deploy", "keeps", ("keep",)),
    ("the parser don't handle tabs", "don't", ("doesn't",)),
    ("we hit a error in the parser", "a", ("an",)),
    ("delete the stale branch", "branch", ()),
])
def test_grammar_options_lists_only_authorized_forms(src, key, options):
    a = scan(src)
    i = _at(a, key)
    assert grammar_options(a, i) == options
    assert all(grammar_edit(a, i, y) for y in grammar_options(a, i))


@pytest.mark.parametrize(("src", "out"), [
    ("first copy the config second restart the proxy third check the logs",
     "1. Copy the config.\n2. Restart the proxy.\n3. Check the logs."),
    ("First, copy the config. Second, restart the proxy.", "1. Copy the config.\n2. Restart the proxy."),
    ("number one tag the build number two push the tag", "1. Tag the build.\n2. Push the tag."),
    ("step one drain the node step two patch it", "1. Drain the node.\n2. Patch it."),
    ("first copy the config and then restart the proxy and finally check the logs",
     "1. Copy the config.\n2. Restart the proxy.\n3. Check the logs."),
    ("um first copy the config then uh restart the proxy", "1. Copy the config.\n2. Restart the proxy."),
    ("one, the parser. two, the lexer.", "1. The parser.\n2. The lexer."),
    ("first of all copy the config, second restart the proxy", "1. Copy the config,\n2. restart the proxy"),
    ("seventh rotate the keys eighth revoke the old ones", "7. Rotate the keys.\n8. Revoke the old ones."),
    # Numerals inserted before markers the output keeps.
    ("first copy the config then restart the proxy", "1. First copy the config.\n2. Then restart the proxy."),
])
def test_list_edit_numbers_a_spoken_enumeration(src, out):
    ops = _list_ops(src, out)
    assert ops and all(ops)


@pytest.mark.parametrize(("src", "out"), [
    ("copy the config then restart the proxy", "1. Copy the config.\n2. Restart the proxy."),  # no marker
    ("restart it first then check the logs", "1. Restart it.\n2. Check the logs."),  # "first" inside a clause
    ("Delete the stale preview builds.", "Delete the 3 stale preview builds."),  # a free digit
    ("first drain the node second patch it", "2. Drain the node.\n1. Patch it."),  # order
    ("first copy the config second restart the proxy", "1. Copy the config.\n3. Restart the proxy."),  # value
    ("first copy the config then restart the proxy then check the logs",
     "1. Copy the config.\n2. Restart the proxy then check the logs."),  # count
    ("first check the disk and if it is full then clear the cache",
     "1. Check the disk and if it is full.\n2. Clear the cache."),  # a condition becomes a step
    ("first copy the config second restart it and then check the logs",
     "1. Copy the config.\n2. Restart it.\n3. Check the logs."),  # "then" may belong to item 2
    ("1. Copy the config. Second, restart the proxy.", "1. Copy the config.\n2. Restart the proxy."),
])
def test_list_edit_refuses_free_or_changed_numbering(src, out):
    assert not all(_list_ops(src, out))


@pytest.mark.parametrize(("src", "out"), [
    ("first copy the config second restart the proxy third check the logs",
     "1. Copy the config.\n2. Restart the proxy.\n3. Check the logs."),
    ("first copy the config then restart the proxy", "1. First copy the config.\n2. Then restart the proxy."),
    ("the workers keeps crashing and they was paging me", "The workers keep crashing and they were paging me."),
    ("the parser don't handle tabs", "The parser doesn't handle tabs."),
])
def test_verify_accepts_lists_and_slip_fixes(src, out):
    assert verify(src, out) == (True, "ok")
    assert merge_allowed(src, out) == out


@pytest.mark.parametrize(("src", "out"), [
    ("copy the config then restart the proxy", "1. Copy the config.\n2. Restart the proxy."),
    ("the parser don't handle tabs", "The parser does handle tabs."),
    ("merged the branch already so start on the docs", "Merge the branch already so start on the docs."),
])
def test_verify_refuses_free_numbers_polarity_and_mood(src, out):
    assert not verify(src, out)[0]


def test_merge_keeps_slip_fixes_and_restores_negation():
    src = "the workers keeps crashing and we shouldn't restart them"
    merged = merge_allowed(src, "The workers keep crashing and we should restart them.")
    assert merged == "The workers keep crashing and we shouldn't restart them."
    assert verify(src, merged)[0]


def test_merge_keeps_list_numbers_and_restores_a_changed_word():
    src = "first copy the config second restart the proxy"
    merged = merge_allowed(src, "1. Copy the config.\n2. Restart the gateway.")
    assert merged.startswith("1. Copy the config.\n2. Restart the ")
    assert "proxy" in merged and "gateway" not in merged
    assert verify(src, merged)[0]


def test_merge_drops_unspoken_list_numbers():
    src = "copy the config then restart the proxy"
    merged = merge_allowed(src, "1. Copy the config.\n2. Restart the proxy.")
    assert not any(c.isdigit() for c in merged)
    assert verify(src, merged)[0]


@pytest.mark.parametrize(("src", "out", "ok"), [
    ("Me and Nina tried the build yesterday.", "I and Nina tried the build yesterday.", True),
    ("Me and him was looking at the logs.", "I and he were looking at the logs.", True),
    ("Yeah her and me has tried it.", "Yeah she and I have tried it.", True),
    ("Me will follow up tomorrow.", "I will follow up tomorrow.", True),
    ("Check if her has restarted.", "Check if she has restarted.", True),
    ("The logs failed and I seen the button.", "The logs failed and I saw the button.", True),
    ("Maybe the exports was missing.", "Maybe the exports were missing.", True),
    ("Send it to Sam and me.", "Send it to Sam and I.", False),
    ("Give me and Nina the keys.", "Give I and Nina the keys.", False),
    ("Check if her laptop restarted.", "Check if she laptop restarted.", False),
    ("Me and Nina's laptop broke.", "I and Nina's laptop broke.", False),
    ("Me too.", "I too.", False),
])
def test_subject_pronoun_case(src, out, ok):
    assert verify(src, out)[0] is ok
