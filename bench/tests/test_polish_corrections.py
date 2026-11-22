import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "polish"))
from polish_corrections import CUES, MAX_SPAN, correction  # noqa: E402
from polish_tokens import scan  # noqa: E402
from polishlab import merge_allowed, verify  # noqa: E402


def _span(src, deleted):
    words = scan(src)
    gone = deleted.split()
    starts = [k for k in range(len(words) - len(gone) + 1) if [w.raw for w in words[k:k + len(gone)]] == gone]
    assert len(starts) == 1, (src, deleted)
    return words, starts[0], starts[0] + len(gone)


@pytest.mark.parametrize(("src", "deleted"), [
    # reparandum and cue; the repair starts where the reparandum starts
    ("Ping Laura, sorry, ping Devon about the outage.", "Ping Laura, sorry,"),
    ("Paint the header green, no, sorry, blue.", "green, no, sorry,"),
    ("Book the review for Tuesday, er, I mean Thursday, after lunch.", "Tuesday, er, I mean"),
    ("Run the import on staging, hmm, actually, on production tonight.", "staging, hmm, actually, on"),
    ("Merge into develop, or rather into main.", "develop, or rather into"),
    ("Notify the team, wait, the team leads.", "the team, wait,"),
    ("Turn off the cache, no wait, turn on the cache.", "off the cache, no wait, turn"),
    # a number replaced by a number of the same form, the words around it repeated
    ("Point the runner at port 8080, no wait, port 9090.", "port 8080, no wait,"),
    ("Point the runner at port 8080, no wait, port 9090.", "8080, no wait, port"),
    ("Cap the batch at 15,000, no, 20,000 rows.", "15,000, no,"),
    # "make it" before a numeric repair, and a restated frame with a pronoun for the kept noun phrase
    ("Make the cutoff 2 hours, actually, make it 4 hours.", "2 hours, actually, make it"),
    ("Copy the report to Laura, no wait, copy it to Devon and archive it.", "Laura, no wait, copy it to"),
    # "Scratch that." retracts exactly the previous sentence
    ("Archive the old logs. Scratch that. Compress them instead.", "Archive the old logs. Scratch that."),
])
def test_reparandum_with_its_cue_may_go(src, deleted):
    assert correction(*_span(src, deleted))


@pytest.mark.parametrize(("src", "deleted"), [
    # the cue alone, the cue with its repair, or a qualifier of the repair
    ("Point the runner at port 8080, no wait, port 9090.", "no wait,"),
    ("Point the runner at port 8080, no wait, port 9090.", "no wait, port 9090."),
    ("Ping Laura, sorry, ping Devon about the outage.", "sorry, ping Devon"),
    ("Use the blue theme, no, the dark theme", "no, the dark theme"),
    ("Archive every log, sorry, except the audit logs.", "Archive every log, sorry,"),
    ("Archive every log, sorry, except the audit logs.", "every log, sorry, except"),
    ("Retry each call, no wait, never on auth failures.", "Retry each call, no wait,"),
    ("Run every suite, sorry, don't run the slow ones.", "Run every suite, sorry,"),
    # unmarked cue words are content
    ("We don't actually need the flag.", "don't actually"),
    ("Pick the queue rather than the cron job.", "the queue rather"),
    ("Deploy and wait for the health check before you switch traffic.", "and wait for the health check"),
    ("Ship it with no extra logging.", "with no"),
    ("Say sorry for the delay, then send the contract.", "Say sorry"),
    ("Also scratch that job from the nightly list.", "Also scratch that"),
    ("Delete the temp files, I mean it.", "Delete the temp files, I mean"),
    ("use 4 sorry 6 workers for the import", "4 sorry"),
    # quoted cues and flags are literal
    ('Reply "no, wait" to the bot and close the ticket.', 'Reply "no, wait"'),
    ("Run the build with --no-cache, then push.", "with --no-cache,"),
    # a literal goes only for a number of the same form in the repeated frame
    ("Bump the image to 3.2, no, bump the chart instead.", "Bump the image to 3.2, no,"),
    ("Point it at ./src, no, ./lib for the build.", "./src, no,"),
    ("Rename the helper to parseRow. Scratch that. Rename it to parseLine.",
     "Rename the helper to parseRow. Scratch that."),
    ("Set the timeout to 30 seconds, no, 60 minutes.", "30 seconds, no,"),
    ("Poll every 10ms, sorry, 10s.", "10ms, sorry,"),
    # scope: one clause, or exactly one sentence before "Scratch that."
    ("Clear the cache, then rebuild it. Scratch that. Rebuild the index.",
     "Clear the cache, then rebuild it. Scratch that."),
    ("Tag the release. Push the tag, no wait, push the branch.", "Tag the release. Push the tag, no wait,"),
    ("Set the pool to 10, no, 20, no wait, 30 connections.", "10, no, 20, no wait,"),
    ("Did the backup run? No. No alerts fired.", "Did the backup run? No."),
    ("Delete the archive. Sorry, it's already gone.", "Delete the archive. Sorry,"),
    ("Fix the typo. Also bump the version, no, scratch that.", "Also bump the version, no, scratch that."),
    # a repair that is not a replacement
    ("Merge it now, actually, wait for review.", "Merge it now, actually,"),
    ("Restart the worker, sorry, did it already restart?", "Restart the worker, sorry,"),
    ("Ship the patch tonight, wait, check the logs first.", "Ship the patch tonight, wait,"),
    ("Set the timeout to 30, no wait, it should stay at 60.", "30, no wait,"),
    ("Deploy to staging, and by staging, I mean, the EU cluster.", "by staging, I mean,"),
    # the cut starts inside the reparandum
    ("Turn off the cache, no wait, turn on the cache.", "the cache, no wait,"),
    ("Send the build to Laura, no wait, send it to Devon.", "Laura, no wait,"),
    ("Don't lock the branch, no wait, lock the branch.", "lock the branch, no wait,"),
    ("Don't send the build to Laura, no wait, send it to Devon.", "Laura, no wait, send it to"),
    # ordinary instructions, not cues
    ("Then rebuild the index, no wait, forget the rebuild.", "Then rebuild the index, no wait, forget the rebuild."),
    ("Close the old tickets, no, never mind.", "Close the old tickets, no, never mind."),
])
def test_unclear_or_partial_corrections_are_kept(src, deleted):
    assert not correction(*_span(src, deleted))


def test_cue_words_are_whole_lowercase_keys():
    assert {"no", "wait", "sorry", "actually", "i mean", "or rather", "scratch that"} <= CUES
    assert not CUES & {"rather", "never mind", "forget it"}


def test_long_and_cue_dense_spans_stay_bounded():
    words = scan("Set it to 1, no, 2, no, 3, no, 4, no, 5, no, 6, no, 7, no, 8, no, 9, no, 10 now. " * 3)
    assert not correction(words, 0, MAX_SPAN + 1)
    allowed = {(i, j) for i in range(len(words)) for j in range(i + 1, min(len(words), i + MAX_SPAN) + 1)
               if correction(words, i, j)}
    assert (4, 6) in allowed  # "2, no," repaired by "3,"
    assert all(j - i <= 3 for i, j in allowed)  # never a stacked chain


@pytest.mark.parametrize(("src", "out"), [
    ("Point the runner at port 8080, no wait, port 9090.", "Point the runner at port 9090."),
    ("Copy the report to Laura, no wait, copy it to Devon and archive it.", "Copy the report to Devon and archive it."),
    ("Archive the old logs. Scratch that. Compress them instead.", "Compress them instead."),
    ("Ping Laura, sorry, ping Devon about the outage.", "Ping Devon about the outage."),
    ("Make the cutoff 2 hours, actually, make it 4 hours.", "Make the cutoff 4 hours."),
])
def test_verify_and_merge_deliver_a_genuine_correction(src, out):
    assert verify(src, out)[0]
    assert merge_allowed(src, out) == out


@pytest.mark.parametrize(("src", "out"), [
    ("Point the runner at port 8080, no wait, port 9090.", "Point the runner at port 8080."),
    ("Point the runner at port 8080, no wait, port 9090.", "Point the runner at port 8080, port 9090."),
    ("Archive every log, sorry, except the audit logs.", "Except the audit logs."),
    ("Don't lock the branch, no wait, lock the branch.", "Don't lock the branch."),
    ("We don't actually need the flag.", "We need the flag."),
    ("Pick the queue rather than the cron job.", "Pick the cron job."),
    ('Reply "no, wait" to the bot.', "Reply to the bot."),
    ("Point it at ./src, no, ./lib for the build.", "Point it at ./lib for the build."),
    ("Set the timeout to 30 seconds, no, 60 minutes.", "Set the timeout to 60 minutes."),
    ("Did the backup run? No. No alerts fired.", "Did the backup run? No alerts fired."),
])
def test_verify_and_merge_keep_the_source_for_a_wrong_correction(src, out):
    assert not verify(src, out)[0]
    assert merge_allowed(src, out) == src


@pytest.mark.parametrize(("src", "out"), [
    # an allowed correction next to a refused value change
    ("Point the runner at port 8080, no wait, port 9090.", "Point the runner at port 9191."),
    # an allowed correction and a refused verb change elsewhere in the same dictation
    ("Ping Laura, sorry, ping Devon about the outage, then close the ticket.",
     "Ping Devon about the outage, then reopen the ticket."),
])
def test_refused_edit_beside_a_correction_restores_the_source(src, out):
    assert not verify(src, out)[0]
    assert merge_allowed(src, out) == src
