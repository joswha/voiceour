"""Pure metric functions for Voiceour benchmark reports."""

from __future__ import annotations

import math
import re
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from typing import Any

import jiwer

from .normalizer import english_normalize

PUNCT_MARKS: tuple[str, ...] = (".", ",", "?", "!")
_WORD_RE = re.compile(r"[^\W_]+(?:['’][^\W_]+)?", re.UNICODE)
_FORMAT_TOKEN_RE = re.compile(r"[^\W_]+(?:['’][^\W_]+)?|[^\w\s]", re.UNICODE)
_SENTENCE_ENDS = {".", "?", "!"}


def _as_list(values: Iterable[str | None]) -> list[str]:
    return [value or "" for value in values]


def _require_same_length(left: Sequence[Any], right: Sequence[Any]) -> None:
    if len(left) != len(right):
        raise ValueError(f"metric inputs must have the same length, got {len(left)} and {len(right)}")


def _word_count(texts: Sequence[str]) -> int:
    return sum(len(text.split()) for text in texts)


def _char_count(texts: Sequence[str]) -> int:
    return sum(len(text) for text in texts)


def _edit_distance(left: Sequence[Any], right: Sequence[Any]) -> int:
    """Levenshtein edit distance with O(min(n, m)) memory."""

    if len(left) < len(right):
        shorter, longer = left, right
    else:
        shorter, longer = right, left
    previous = list(range(len(shorter) + 1))
    for i, item in enumerate(longer, start=1):
        current = [i]
        for j, other in enumerate(shorter, start=1):
            substitution_cost = 0 if item == other else 1
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitution_cost,
                )
            )
        previous = current
    return previous[-1]


def _formatted_tokens(text: str) -> list[str]:
    """Case- and punctuation-preserving tokens for F-WER."""

    return _FORMAT_TOKEN_RE.findall(text or "")


def uwer(refs: Iterable[str | None], hyps: Iterable[str | None]) -> float:
    """Unformatted WER after Whisper English normalization.

    This is a jiwer WER over normalized word streams. Empty-reference corpora are
    defined as 0.0 when hypotheses are also empty and 1.0 otherwise, avoiding an
    undefined division while keeping insertions visible.
    """

    ref_list = [english_normalize(value) for value in _as_list(refs)]
    hyp_list = [english_normalize(value) for value in _as_list(hyps)]
    _require_same_length(ref_list, hyp_list)
    if _word_count(ref_list) == 0:
        return 0.0 if _word_count(hyp_list) == 0 else 1.0
    return float(jiwer.process_words(ref_list, hyp_list).wer)


def cer(refs: Iterable[str | None], hyps: Iterable[str | None]) -> float:
    """Character error rate after Whisper English normalization."""

    ref_list = [english_normalize(value) for value in _as_list(refs)]
    hyp_list = [english_normalize(value) for value in _as_list(hyps)]
    _require_same_length(ref_list, hyp_list)
    if _char_count(ref_list) == 0:
        return 0.0 if _char_count(hyp_list) == 0 else 1.0
    return float(jiwer.process_characters(ref_list, hyp_list).cer)


def fwer(refs: Iterable[str | None], hyps: Iterable[str | None]) -> float:
    """Formatted WER over case- and punctuation-preserving tokens.

    Words retain original case and punctuation marks are standalone tokens, so a
    missing comma or incorrect capitalization can contribute to the edit rate.
    """

    ref_list = _as_list(refs)
    hyp_list = _as_list(hyps)
    _require_same_length(ref_list, hyp_list)
    edits = 0
    ref_total = 0
    hyp_total = 0
    for ref, hyp in zip(ref_list, hyp_list, strict=True):
        ref_tokens = _formatted_tokens(ref)
        hyp_tokens = _formatted_tokens(hyp)
        edits += _edit_distance(ref_tokens, hyp_tokens)
        ref_total += len(ref_tokens)
        hyp_total += len(hyp_tokens)
    if ref_total == 0:
        return 0.0 if hyp_total == 0 else 1.0
    return edits / ref_total


@dataclass(frozen=True)
class _LabeledTokens:
    tokens: list[str]
    labels: list[str | None]


def _normalize_word_tokens(word: str) -> list[str]:
    return [token for token in english_normalize(word).split() if token]


def _trailing_punct_records(text: str) -> _LabeledTokens:
    raw = text or ""
    matches = list(_WORD_RE.finditer(raw))
    tokens: list[str] = []
    labels: list[str | None] = []
    for index, match in enumerate(matches):
        next_start = matches[index + 1].start() if index + 1 < len(matches) else len(raw)
        between_words = raw[match.end() : next_start]
        trailing_label: str | None = None
        for char in between_words:
            if char in PUNCT_MARKS:
                trailing_label = char
        normalized = _normalize_word_tokens(match.group())
        if not normalized:
            continue
        tokens.extend(normalized)
        labels.extend([None] * (len(normalized) - 1))
        labels.append(trailing_label)
    return _LabeledTokens(tokens=tokens, labels=labels)


def _alignment_pairs(ref_tokens: Sequence[str], hyp_tokens: Sequence[str]) -> list[tuple[int | None, int | None]]:
    if not ref_tokens and not hyp_tokens:
        return []
    if not ref_tokens:
        return [(None, idx) for idx in range(len(hyp_tokens))]
    if not hyp_tokens:
        return [(idx, None) for idx in range(len(ref_tokens))]

    output = jiwer.process_words(" ".join(ref_tokens), " ".join(hyp_tokens))
    pairs: list[tuple[int | None, int | None]] = []
    for chunk in output.alignments[0]:
        ref_indexes = list(range(chunk.ref_start_idx, chunk.ref_end_idx))
        hyp_indexes = list(range(chunk.hyp_start_idx, chunk.hyp_end_idx))
        if chunk.type in {"equal", "substitute"}:
            shared = min(len(ref_indexes), len(hyp_indexes))
            pairs.extend(zip(ref_indexes[:shared], hyp_indexes[:shared], strict=True))
            pairs.extend((idx, None) for idx in ref_indexes[shared:])
            pairs.extend((None, idx) for idx in hyp_indexes[shared:])
        elif chunk.type == "delete":
            pairs.extend((idx, None) for idx in ref_indexes)
        elif chunk.type == "insert":
            pairs.extend((None, idx) for idx in hyp_indexes)
        else:  # pragma: no cover - defensive for future jiwer chunk kinds
            raise ValueError(f"unknown jiwer alignment chunk type: {chunk.type}")
    return pairs


def _prf(tp: int, fp: int, fn: int) -> dict[str, float | int]:
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"precision": precision, "recall": recall, "f1": f1, "tp": tp, "fp": fp, "fn": fn}


def punct_f1(refs: Iterable[str | None], hyps: Iterable[str | None]) -> dict[str, Any]:
    """Trailing punctuation precision/recall/F1 for `.`, `,`, `?`, and `!`.

    The implementation aligns Whisper-normalized word streams with jiwer and
    scores the punctuation label attached immediately after each aligned word.
    Punctuation not attached to a normalized word is ignored, and if multiple
    target marks trail the same word the last one is scored. Inserted hypothesis
    words contribute false positives; deleted reference words contribute false
    negatives.
    """

    ref_list = _as_list(refs)
    hyp_list = _as_list(hyps)
    _require_same_length(ref_list, hyp_list)
    counts = {mark: {"tp": 0, "fp": 0, "fn": 0} for mark in PUNCT_MARKS}

    for ref, hyp in zip(ref_list, hyp_list, strict=True):
        ref_records = _trailing_punct_records(ref)
        hyp_records = _trailing_punct_records(hyp)
        for ref_idx, hyp_idx in _alignment_pairs(ref_records.tokens, hyp_records.tokens):
            ref_label = ref_records.labels[ref_idx] if ref_idx is not None else None
            hyp_label = hyp_records.labels[hyp_idx] if hyp_idx is not None else None
            for mark in PUNCT_MARKS:
                if ref_label == mark and hyp_label == mark:
                    counts[mark]["tp"] += 1
                elif ref_label == mark:
                    counts[mark]["fn"] += 1
                elif hyp_label == mark:
                    counts[mark]["fp"] += 1

    marks = {mark: _prf(**counts[mark]) for mark in PUNCT_MARKS}
    macro_f1 = sum(float(marks[mark]["f1"]) for mark in PUNCT_MARKS) / len(PUNCT_MARKS)
    total_tp = sum(counts[mark]["tp"] for mark in PUNCT_MARKS)
    total_fp = sum(counts[mark]["fp"] for mark in PUNCT_MARKS)
    total_fn = sum(counts[mark]["fn"] for mark in PUNCT_MARKS)
    return {"marks": marks, "macro_f1": macro_f1, "micro": _prf(total_tp, total_fp, total_fn)}


@dataclass(frozen=True)
class _CaseTokens:
    tokens: list[str]
    capitalized: list[bool]
    sentence_initial: list[bool]


def _first_cased_char(word: str) -> str | None:
    for char in word:
        if char.isalpha():
            return char
    return None


def _case_records(text: str) -> _CaseTokens:
    raw = text or ""
    matches = list(_WORD_RE.finditer(raw))
    tokens: list[str] = []
    capitalized: list[bool] = []
    sentence_initial: list[bool] = []
    starts_sentence = True
    for index, match in enumerate(matches):
        word = match.group()
        first_cased = _first_cased_char(word)
        is_capitalized = bool(first_cased and first_cased.isupper())
        normalized = _normalize_word_tokens(word)
        for offset, token in enumerate(normalized):
            tokens.append(token)
            capitalized.append(is_capitalized if offset == 0 else False)
            sentence_initial.append(starts_sentence if offset == 0 else False)
        next_start = matches[index + 1].start() if index + 1 < len(matches) else len(raw)
        between_words = raw[match.end() : next_start]
        starts_sentence = any(char in _SENTENCE_ENDS for char in between_words)
    return _CaseTokens(tokens=tokens, capitalized=capitalized, sentence_initial=sentence_initial)


def case_f1(refs: Iterable[str | None], hyps: Iterable[str | None]) -> dict[str, Any]:
    """Capitalization F1 over jiwer-aligned normalized words.

    A positive label means the original word begins with an uppercase cased
    character. The report includes overall capitalization F1 plus separate
    buckets for reference sentence-initial and non-sentence-initial words.
    Inserted capitalized hypothesis words are false positives; deleted
    capitalized reference words are false negatives.
    """

    ref_list = _as_list(refs)
    hyp_list = _as_list(hyps)
    _require_same_length(ref_list, hyp_list)
    buckets = {
        "overall": {"tp": 0, "fp": 0, "fn": 0},
        "sentence_initial": {"tp": 0, "fp": 0, "fn": 0},
        "non_sentence_initial": {"tp": 0, "fp": 0, "fn": 0},
    }

    for ref, hyp in zip(ref_list, hyp_list, strict=True):
        ref_records = _case_records(ref)
        hyp_records = _case_records(hyp)
        for ref_idx, hyp_idx in _alignment_pairs(ref_records.tokens, hyp_records.tokens):
            ref_cap = ref_records.capitalized[ref_idx] if ref_idx is not None else False
            hyp_cap = hyp_records.capitalized[hyp_idx] if hyp_idx is not None else False
            bucket_names = ["overall"]
            if ref_idx is not None:
                bucket_names.append(
                    "sentence_initial" if ref_records.sentence_initial[ref_idx] else "non_sentence_initial"
                )
            elif hyp_cap:
                bucket_names.append("non_sentence_initial")
            for bucket_name in bucket_names:
                bucket = buckets[bucket_name]
                if ref_cap and hyp_cap:
                    bucket["tp"] += 1
                elif ref_cap:
                    bucket["fn"] += 1
                elif hyp_cap:
                    bucket["fp"] += 1

    return {name: _prf(**bucket) for name, bucket in buckets.items()}


def over_edit_rate(raw_transcripts: Iterable[str | None], final_texts: Iterable[str | None]) -> float:
    """Content edit rate between normalized raw transcripts and final outputs.

    This measures how much deterministic cleanup changed the normalized word stream,
    aggregated as total word edit distance divided by total raw word count.
    """

    raws = [english_normalize(value) for value in _as_list(raw_transcripts)]
    finals = [english_normalize(value) for value in _as_list(final_texts)]
    _require_same_length(raws, finals)
    edits = 0
    raw_total = 0
    final_total = 0
    for raw, final in zip(raws, finals, strict=True):
        raw_tokens = raw.split()
        final_tokens = final.split()
        edits += _edit_distance(raw_tokens, final_tokens)
        raw_total += len(raw_tokens)
        final_total += len(final_tokens)
    if raw_total == 0:
        return 0.0 if final_total == 0 else 1.0
    return edits / raw_total


def rtfx(audio_seconds: Iterable[float | int | None], asr_milliseconds: Iterable[float | int | None]) -> float | None:
    """Real-time factor speedup: total audio seconds divided by ASR wall seconds."""

    total_audio = 0.0
    total_asr_ms = 0.0
    for audio_s, asr_ms in zip(audio_seconds, asr_milliseconds, strict=True):
        if audio_s is None or asr_ms is None:
            continue
        total_audio += float(audio_s)
        total_asr_ms += float(asr_ms)
    if total_asr_ms <= 0:
        return None
    return total_audio / (total_asr_ms / 1000.0)


def percentiles(values: Iterable[float | int | None]) -> dict[str, float | None]:
    """Return linear-interpolated percentiles for finite values."""

    clean = sorted(float(value) for value in values if value is not None and math.isfinite(float(value)))
    result: dict[str, float | None] = {}
    for percentile in (50, 95):
        key = f"p{int(percentile)}"
        if not clean:
            result[key] = None
            continue
        if len(clean) == 1:
            result[key] = clean[0]
            continue
        rank = (float(percentile) / 100.0) * (len(clean) - 1)
        lower = math.floor(rank)
        upper = math.ceil(rank)
        if lower == upper:
            result[key] = clean[int(rank)]
        else:
            fraction = rank - lower
            result[key] = clean[lower] + (clean[upper] - clean[lower]) * fraction
    return result


def _rate(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def _optional_prf(tp: int, fp: int, fn: int) -> dict[str, float | int | None]:
    precision = _rate(tp, tp + fp)
    recall = _rate(tp, tp + fn)
    f1_denominator = (2 * tp) + fp + fn
    return {
        "precision": precision,
        "recall": recall,
        "f1": _rate(2 * tp, f1_denominator),
        "tp": tp,
        "fp": fp,
        "fn": fn,
    }


def contains_exact_term(text: str | None, canonical_term: str | None) -> bool:
    """Return whether *text* contains the exact, case-sensitive canonical surface."""

    if not text or not canonical_term:
        return False
    prefix = r"(?<!\w)" if canonical_term[0].isalnum() or canonical_term[0] == "_" else ""
    suffix = r"(?!\w)" if canonical_term[-1].isalnum() or canonical_term[-1] == "_" else ""
    return re.search(f"{prefix}{re.escape(canonical_term)}{suffix}", text, re.UNICODE) is not None


def canonical_term_prf(
    canonical_terms: Iterable[str | None],
    expect_terms: Iterable[bool],
    hypotheses: Iterable[str | None],
) -> dict[str, float | int | None]:
    """Exact canonical-surface precision/recall/F1 over labeled term opportunities."""

    terms = list(canonical_terms)
    expected = list(expect_terms)
    outputs = list(hypotheses)
    _require_same_length(terms, expected)
    _require_same_length(terms, outputs)
    tp = fp = fn = opportunities = predicted_positive = 0
    for term, should_appear, output in zip(terms, expected, outputs, strict=True):
        if not term:
            continue
        opportunities += 1
        appears = contains_exact_term(output, term)
        predicted_positive += int(appears)
        if should_appear and appears:
            tp += 1
        elif should_appear:
            fn += 1
        elif appears:
            fp += 1
    return {
        **_optional_prf(tp, fp, fn),
        "opportunities": opportunities,
        "predicted_positive": predicted_positive,
    }


def hard_negative_false_replacement_rate(
    expect_terms: Iterable[bool],
    false_replacements: Iterable[bool | None],
) -> dict[str, float | int | None]:
    """False replacement frequency among observed hard-negative opportunities."""

    expected = list(expect_terms)
    replacements = list(false_replacements)
    _require_same_length(expected, replacements)
    observed = [
        bool(value)
        for should_appear, value in zip(expected, replacements, strict=True)
        if not should_appear and value is not None
    ]
    false_count = sum(observed)
    opportunities = len(observed)
    rate = _rate(false_count, opportunities)
    return {
        "false_replacements": false_count,
        "opportunities": opportunities,
        "rate": rate,
        "per_10k_opportunities": rate * 10_000.0 if rate is not None else None,
    }


def preservation_rate(observations: Iterable[bool | None]) -> dict[str, float | int | None]:
    """Preservation rate for explicitly observed untouched spans or no-op decisions."""

    observed = [bool(value) for value in observations if value is not None]
    preserved = sum(observed)
    opportunities = len(observed)
    return {
        "preserved": preserved,
        "opportunities": opportunities,
        "rate": _rate(preserved, opportunities),
    }


def no_op_preservation(
    before: Iterable[str | None],
    after: Iterable[str | None],
    expect_no_op: Iterable[bool],
) -> dict[str, float | int | None]:
    """Exact preservation rate for rows on which the terminology layer should keep."""

    originals = list(before)
    outputs = list(after)
    expected = list(expect_no_op)
    _require_same_length(originals, outputs)
    _require_same_length(originals, expected)
    observations = (
        original == output if should_keep and original is not None and output is not None else None
        for original, output, should_keep in zip(originals, outputs, expected, strict=True)
    )
    return preservation_rate(observations)


def candidate_recall_at_k(
    expected_term_ids: Iterable[str | None],
    candidate_term_ids: Iterable[Sequence[str] | None],
    k: int,
) -> dict[str, float | int | None]:
    """Recall@k over positive rows with an observed candidate list."""

    if k <= 0:
        raise ValueError("k must be positive")
    expected = list(expected_term_ids)
    candidates = list(candidate_term_ids)
    _require_same_length(expected, candidates)
    hits = opportunities = 0
    for term_id, row_candidates in zip(expected, candidates, strict=True):
        if not term_id or row_candidates is None:
            continue
        opportunities += 1
        hits += int(term_id in row_candidates[:k])
    return {"hits": hits, "opportunities": opportunities, "recall": _rate(hits, opportunities), "k": k}


def nbest_oracle_coverage(
    canonical_terms: Iterable[str | None],
    nbest_hypotheses: Iterable[Sequence[str] | None],
) -> dict[str, float | int | None]:
    """Coverage when any observed n-best hypothesis contains the exact canonical term."""

    terms = list(canonical_terms)
    hypotheses = list(nbest_hypotheses)
    _require_same_length(terms, hypotheses)
    covered = opportunities = 0
    for term, row_hypotheses in zip(terms, hypotheses, strict=True):
        if not term or row_hypotheses is None:
            continue
        opportunities += 1
        covered += int(any(contains_exact_term(hypothesis, term) for hypothesis in row_hypotheses))
    return {"covered": covered, "opportunities": opportunities, "coverage": _rate(covered, opportunities)}


def selector_accuracy(
    expected_term_ids: Iterable[str | None],
    candidate_term_ids: Iterable[Sequence[str] | None],
    selected_term_ids: Iterable[str | None],
) -> dict[str, float | int | None]:
    """Selector accuracy conditional on the expected term being in the shortlist."""

    expected = list(expected_term_ids)
    candidates = list(candidate_term_ids)
    selected = list(selected_term_ids)
    _require_same_length(expected, candidates)
    _require_same_length(expected, selected)
    correct = opportunities = 0
    for term_id, row_candidates, selection in zip(expected, candidates, selected, strict=True):
        if not term_id or row_candidates is None or term_id not in row_candidates:
            continue
        opportunities += 1
        correct += int(selection == term_id)
    return {"correct": correct, "opportunities": opportunities, "accuracy": _rate(correct, opportunities)}


def accepted_repair_precision(
    expected_term_ids: Iterable[str | None],
    selected_term_ids: Iterable[str | None],
    accepted_repairs: Iterable[bool | None],
) -> dict[str, float | int | None]:
    """Precision of accepted repairs plus observed positive-term prevalence."""

    expected = list(expected_term_ids)
    selected = list(selected_term_ids)
    accepted = list(accepted_repairs)
    _require_same_length(expected, selected)
    _require_same_length(expected, accepted)
    observed = [
        (term_id, selection, decision)
        for term_id, selection, decision in zip(expected, selected, accepted, strict=True)
        if decision is not None
    ]
    accepted_rows = [(term_id, selection) for term_id, selection, decision in observed if decision]
    correct = sum(term_id is not None and selection == term_id for term_id, selection in accepted_rows)
    positives = sum(term_id is not None for term_id, _, _ in observed)
    return {
        "correct": correct,
        "accepted": len(accepted_rows),
        "precision": _rate(correct, len(accepted_rows)),
        "positive_opportunities": positives,
        "opportunities": len(observed),
        "term_prevalence": _rate(positives, len(observed)),
    }


def reliability_metrics(
    confidences: Iterable[float | int | None],
    outcomes: Iterable[bool | None],
    bin_count: int = 10,
) -> dict[str, Any] | None:
    """Brier score, ECE, and equal-width reliability bins for observed decisions."""

    if bin_count <= 0:
        raise ValueError("bin_count must be positive")
    confidence_values = list(confidences)
    outcome_values = list(outcomes)
    _require_same_length(confidence_values, outcome_values)
    pairs: list[tuple[float, bool]] = []
    for confidence, outcome in zip(confidence_values, outcome_values, strict=True):
        if confidence is None or outcome is None:
            continue
        numeric = float(confidence)
        if not math.isfinite(numeric) or not 0.0 <= numeric <= 1.0:
            raise ValueError("confidence values must be finite and between 0 and 1")
        pairs.append((numeric, bool(outcome)))
    if not pairs:
        return None

    bins: list[dict[str, float | int | None]] = []
    ece = 0.0
    for index in range(bin_count):
        lower = index / bin_count
        upper = (index + 1) / bin_count
        members = [
            (confidence, correct)
            for confidence, correct in pairs
            if lower <= confidence < upper or index == bin_count - 1 and confidence == 1.0
        ]
        count = len(members)
        mean_confidence = sum(confidence for confidence, _ in members) / count if count else None
        accuracy = sum(correct for _, correct in members) / count if count else None
        gap = abs(accuracy - mean_confidence) if accuracy is not None and mean_confidence is not None else None
        if gap is not None:
            ece += (count / len(pairs)) * gap
        bins.append(
            {
                "lower": lower,
                "upper": upper,
                "count": count,
                "mean_confidence": mean_confidence,
                "accuracy": accuracy,
                "calibration_gap": gap,
            }
        )
    brier = sum((confidence - float(correct)) ** 2 for confidence, correct in pairs) / len(pairs)
    return {"brier": brier, "ece": ece, "count": len(pairs), "bins": bins}


def risk_coverage_points(
    confidences: Iterable[float | int | None],
    outcomes: Iterable[bool | None],
) -> list[dict[str, float | int | None]]:
    """Risk/coverage points at every distinct confidence threshold."""

    confidence_values = list(confidences)
    outcome_values = list(outcomes)
    _require_same_length(confidence_values, outcome_values)
    pairs: list[tuple[float, bool]] = []
    for confidence, outcome in zip(confidence_values, outcome_values, strict=True):
        if confidence is None or outcome is None:
            continue
        numeric = float(confidence)
        if not math.isfinite(numeric) or not 0.0 <= numeric <= 1.0:
            raise ValueError("confidence values must be finite and between 0 and 1")
        pairs.append((numeric, bool(outcome)))
    if not pairs:
        return []

    pairs.sort(key=lambda item: item[0], reverse=True)
    points: list[dict[str, float | int | None]] = [{"threshold": None, "covered": 0, "coverage": 0.0, "risk": None}]
    covered = errors = 0
    index = 0
    while index < len(pairs):
        threshold = pairs[index][0]
        while index < len(pairs) and pairs[index][0] == threshold:
            covered += 1
            errors += int(not pairs[index][1])
            index += 1
        points.append(
            {
                "threshold": threshold,
                "covered": covered,
                "coverage": covered / len(pairs),
                "risk": errors / covered,
            }
        )
    return points
