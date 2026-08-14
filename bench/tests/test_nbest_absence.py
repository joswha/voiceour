from __future__ import annotations

from voiceour_bench.nbest_absence import hypothesis_texts, target_absence


def _man(row_id, term, expect):
    return {"id": row_id, "canonical_term": term, "expect_term": expect}


def _row(row_id, hyps=None, final=None):
    row = {"type": "row", "id": row_id}
    if hyps is not None:
        row["hypotheses"] = [{"rank": i, "text": t, "score": -float(i)} for i, t in enumerate(hyps)]
    if final is not None:
        row["raw_transcript"] = final
    return row


def test_term_present_in_alternate_hypothesis_is_covered():
    man = [_man("a", "kubectl", True)]
    res = [_row("a", hyps=["cube cuddle get pods", "kubectl get pods"])]
    summary = target_absence(man, res)
    assert summary["opportunities"] == 1
    assert summary["covered_in_nbest"] == 1
    assert summary["absent_from_nbest"] == 0
    assert summary["absence_rate"] == 0.0


def test_term_absent_from_all_hypotheses_counts_absent():
    man = [_man("a", "kubectl", True)]
    res = [_row("a", hyps=["cube cuddle get pods", "cubectal get pods"])]
    summary = target_absence(man, res)
    assert summary["absent_from_nbest"] == 1
    assert summary["absence_rate"] == 1.0
    assert summary["absent_ids"] == ["a"]


def test_negatives_are_not_opportunities():
    man = [_man("neg", "C", False), _man("pos", "Rust", True)]
    res = [_row("neg", hyps=["we can see the sea"]), _row("pos", hyps=["written in Rust"])]
    summary = target_absence(man, res)
    assert summary["opportunities"] == 1
    assert summary["covered_in_nbest"] == 1


def test_case_sensitive_exact_surface():
    # "rust" (ordinary) must not count as the term "Rust".
    man = [_man("a", "Rust", True)]
    res = [_row("a", hyps=["covered in rust"])]
    summary = target_absence(man, res)
    assert summary["absent_from_nbest"] == 1


def test_falls_back_to_final_text_without_hypotheses():
    man = [_man("a", "kubectl", True)]
    res = [_row("a", final="kubectl get pods")]
    summary = target_absence(man, res)
    assert summary["covered_in_nbest"] == 1
    assert summary["max_hypotheses_seen"] == 1


def test_hypothesis_texts_prefers_nbest_union():
    row = _row("a", hyps=["one", "two"], final="three")
    assert hypothesis_texts(row) == ["one", "two"]


def test_empty_opportunities_yield_none_rate():
    summary = target_absence([], [])
    assert summary["opportunities"] == 0
    assert summary["absence_rate"] is None
