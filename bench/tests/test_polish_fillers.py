import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
from polish_fillers import FILLERS, filler_end, stutter, stutter_twin  # noqa: E402
from polish_tokens import scan  # noqa: E402


def end(text, i, stop=None):
    a = scan(text)
    return filler_end(a, i, len(a) if stop is None else stop)


def test_policy_phrases_stay_fillers():
    policy = {"um", "uh", "like", "you know", "kind of", "sort of", "basically", "essentially", "so", "okay", "ok",
              "right", "well", "the thing is", "here's the thing", "just", "alright", "anyway"}
    assert policy <= FILLERS
    assert not {"i mean", "yeah", "anyhow", "honestly", "actually"} & FILLERS


@pytest.mark.parametrize(("text", "i", "expected"), [
    ("Um, can you check it?", 0, 1),
    ("Uh uh, not on main.", 0, 0),  # an answer, not a hesitation
    ('Name the alias "um" for now.', 3, 3),  # quoted
    ("Okay, push the tag.", 0, 1),
    ("Is it okay to push the tag?", 2, 2),
    ("Can I push now? Okay.", 4, 4),  # a standalone answer
    ("All right, let's go.", 0, 2),
    ("The import finished alright.", 3, 3),
    ("Right click the file.", 0, 0),
    ("Right, we ship it today.", 0, 1),
    ("Turn left here. Right, then stop.", 3, 3),
    ("Is it right?", 2, 2),
    ("So many builds fail.", 0, 0),
    ("So we ship it Friday.", 0, 1),
    ("The build is green, so we ship.", 4, 4),
    ("The build is, like, slow.", 3, 4),
    ("The build takes, like, 40 seconds.", 3, 3),
    ("Ship it by, like, Friday.", 3, 3),
    ("It looks like the cache.", 2, 2),
    ("The page is like really slow.", 3, 4),
    ("Delete whatever you know is stale.", 2, 2),
    ("The cache is, you know, stale.", 3, 5),
    ("Do you know why it fails?", 1, 1),
    ("Add a check for this kind of input.", 5, 5),
    ("The import is kind of slow.", 3, 5),
    ("The import kind of works now.", 2, 2),
    ("It kind of works now.", 1, 1),
    ("It is kind of like the old one.", 2, 2),
    ("Can you just check the logs?", 2, 3),
    ("Don't just restart the pod.", 1, 1),
    ("Run just test before you push.", 1, 1),
    ("Just the logs, please.", 0, 0),
    ("The bundle is essentially 3 MB.", 3, 3),
    ("We basically need a new cache.", 1, 2),
    ("It's basically the same bug.", 1, 1),
    ("The thing is, it leaks.", 0, 3),
    ("The thing is broken.", 0, 0),
    ("Here's the thing, we wait.", 0, 3),
])
def test_filler_end_reads_context(text, i, expected):
    assert end(text, i) == expected


def test_filler_phrase_must_end_by_stop():
    assert end("It is, you know, fine.", 2, 3) == 2
    assert end("It is, you know, fine.", 2) == 4


@pytest.mark.parametrize(("text", "i", "j", "expected"), [
    ("The the build failed.", 0, 1, True),
    ("I I think it works.", 0, 1, True),
    ("Move the, um, the button.", 1, 3, True),
    ("We should, uh, we should revert it.", 0, 3, True),
    ("Can you, can you rerun it?", 0, 2, True),
    ("We need two, two hosts.", 2, 3, True),
    ("Bump the timeout to thirty, um, thirty seconds.", 4, 6, True),
    ("Use the old old theme.", 2, 3, False),  # contrastive doubling
    ("Open port forty forty.", 2, 3, False),  # one number
    ("Set it to two, two and four.", 3, 4, False),  # a list of values
    ("Use version two, version two point one.", 1, 3, False),  # a different number
    ("Close it. Close it later.", 0, 2, False),  # two sentences
    ("Did it pass? No. No logs yet.", 3, 4, False),
    ("Update the parser, the parser docs and tests.", 1, 3, False),  # a list item
    ("Don't merge it, merge it later.", 1, 3, False),  # two clauses
    ("Fix what you can, you can skip the rest.", 2, 4, False),
    ("It is really, really slow.", 2, 3, False),  # emphasis
    ("Pass dash dash verbose.", 1, 2, False),  # an operator
])
def test_stutter_needs_a_safe_identical_copy(text, i, j, expected):
    assert stutter(scan(text), i, j) is expected


def test_stutter_names_the_copy_that_must_survive():
    a = scan("Move the, um, the button.")
    assert stutter_twin(a, 1, 3) == range(3, 4)


@pytest.mark.parametrize(("src", "out"), [
    ("Put the logs in the right folder.", "Put the logs in the folder."),
    ("Right click the tab.", "Click the tab."),
    ("The import takes like 40 seconds.", "The import takes 40 seconds."),
    ("Tell me whatever you know about the crash.", "Tell me whatever about the crash."),
    ("I know you know the script.", "I know the script."),
    ("If you like, you can split it.", "If you can split it."),
    ("Add a guard for this kind of payload.", "Add a guard for this payload."),
    ("It kind of works on Linux.", "It works on Linux."),
    ("Don't just rerun the job, find the cause.", "Don't rerun the job, find the cause."),
    ("Use the old old theme.", "Use the old theme."),
    ("Set the mode to four four.", "Set the mode to four."),
    ("Update the parser, the parser docs and tests.", "Update the parser docs and tests."),
    ("Close it. Close it later.", "Close it later."),
    ("Pass dash dash verbose to the script.", "Pass dash verbose to the script."),
])
def test_content_reading_is_refused_and_restored(src, out):
    from polishlab import merge_allowed, verify
    assert not verify(src, out)[0]
    assert merge_allowed(src, out) == src


@pytest.mark.parametrize(("src", "out"), [
    ("Um, can you check the logs?", "Can you check the logs?"),
    ("The build is, like, slow on arm.", "The build is slow on arm."),
    ("So the tests, you know, fail on main.", "The tests fail on main."),
    ("Okay, just run the linter again.", "Run the linter again."),
    ("All right, let's merge it.", "Let's merge it."),
    ("The import is kind of slow.", "The import is slow."),
    ("The the parser drops tabs.", "The parser drops tabs."),
    ("We need two, two hosts for this.", "We need two hosts for this."),
    ("Okay, so we should, uh, we should ship it today.", "We should ship it today."),
])
def test_filler_and_stutter_cleanup_is_accepted(src, out):
    from polishlab import merge_allowed, verify
    assert verify(src, out) == (True, "ok")
    assert merge_allowed(src, out) == out


def test_merge_keeps_the_filler_edit_and_restores_the_content_word():
    from polishlab import merge_allowed, verify
    src = "Um, put it in the right folder."
    out = "Put it in the folder."
    assert not verify(src, out)[0]
    assert merge_allowed(src, out) == "Put it in the right folder."
