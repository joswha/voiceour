"""Unit tests for MLX evidence mapping and beam n-best ranking.

These exercise the pure, model-free layers only: the ``AlignedResult`` ->
``Transcript`` mapping and the n-best ranking / raw-score selection. Synthetic
``parakeet_mlx.alignment`` dataclasses stand in for real decoder output, so no
checkpoint download or GPU work is required.
"""

from __future__ import annotations

import math
import wave
from threading import Event

import pytest
from parakeet_mlx.alignment import AlignedResult, AlignedSentence, AlignedToken

from voiceoour_asr.backends.mlx import MLXBackend, _DecodeOutput
from voiceoour_asr.decoding import (
    aligned_result_to_transcript,
    geometric_mean_confidence,
    tokens_to_words,
)
from voiceoour_asr.decoding.nbest import (
    FORCED_CANDIDATE_SCORING_AVAILABLE,
    NBestHypothesis,
    build_nbest_model,
    forced_candidate_scoring_note,
    rank_hypotheses,
)
from voiceoour_asr.protocol import AudioMeta, ConfidenceMode, ErrorCode, TranscribeRequest
from voiceoour_asr import cache


def test_transcribe_fails_fast_while_parakeet_is_still_being_acquired(tmp_path, monkeypatch):
    """A cold Parakeet acquisition must not be charged to the utterance budget.

    The ARK backends already guard this, but the default backend is the one that
    actually meets a cold cache on a fresh install. Parakeet is 2.3 GB and the
    client's transcribe timeout is 30 s, so blocking here spends the whole budget,
    times out, and has the client terminate the sidecar mid-download -- leaving a
    partial cache for the next attempt. Say so immediately instead.
    """
    monkeypatch.setattr(cache, "cache_ok", lambda spec: False)
    wav = tmp_path / "clip.wav"
    wav.write_bytes(b"RIFF" + b"\x00" * 40)
    backend = MLXBackend()

    response = backend.transcribe(
        TranscribeRequest(
            request_id="cold",
            audio=AudioMeta(
                path=str(wav),
                format="wav",
                sample_rate_hz=16_000,
                channels=1,
                duration_ms=8_000,
                byte_count=wav.stat().st_size,
            ),
        ),
        Event(),
    )

    assert response.type == "error"
    assert response.code == ErrorCode.MODEL_NOT_INSTALLED
    assert cache.MODEL_ID in (response.detail or "")


def _token(text: str, start: float, duration: float, confidence: float) -> AlignedToken:
    return AlignedToken(
        id=abs(hash(text)) % 1000,
        text=text,
        start=start,
        duration=duration,
        confidence=confidence,
    )


def _geo(*values: float) -> float:
    return math.exp(sum(math.log(v) for v in values) / len(values))


# --------------------------------------------------------------------------- #
# AlignedResult -> Transcript / Word mapping
# --------------------------------------------------------------------------- #


def test_aligned_result_maps_tokens_into_words_with_confidence():
    tokens = [
        _token(" hello", 0.0, 0.5, 0.9),
        _token(" wor", 0.5, 0.3, 0.8),
        _token("ld", 0.8, 0.2, 0.6),
    ]
    sentence = AlignedSentence(text="hello world", tokens=tokens)
    result = AlignedResult(text="hello world", sentences=[sentence])

    transcript = aligned_result_to_transcript(result, confidence_mode=ConfidenceMode.GREEDY_ENTROPY)

    assert transcript.text == "hello world"
    assert transcript.language == "en"
    assert transcript.confidence_mode is ConfidenceMode.GREEDY_ENTROPY
    assert transcript.segments is not None and len(transcript.segments) == 1

    segment = transcript.segments[0]
    assert segment.text == "hello world"
    assert segment.start_ms == 0
    assert segment.end_ms == 1000

    assert segment.words is not None
    assert [w.text for w in segment.words] == ["hello", "world"]

    hello, world = segment.words
    assert (hello.start_ms, hello.end_ms) == (0, 500)
    assert hello.confidence == pytest.approx(0.9, abs=1e-6)
    # "world" merges two subword tokens -> geometric mean of their confidences.
    assert (world.start_ms, world.end_ms) == (500, 1000)
    assert world.confidence == pytest.approx(_geo(0.8, 0.6), abs=1e-6)

    # Aggregate transcript confidence is the geometric mean over every token.
    assert transcript.confidence == pytest.approx(_geo(0.9, 0.8, 0.6), abs=1e-6)


def test_word_boundary_detects_raw_sentencepiece_marker():
    # Robust to the raw "▁" marker, not just its decoded leading space.
    tokens = [
        _token("\u2581foo", 0.0, 0.2, 0.7),
        _token("\u2581bar", 0.2, 0.2, 0.5),
    ]
    words = tokens_to_words(tokens)
    assert [w.text for w in words] == ["foo", "bar"]


def test_multiple_sentences_become_multiple_segments():
    s1 = AlignedSentence(text="one", tokens=[_token(" one", 0.0, 0.4, 0.95)])
    s2 = AlignedSentence(text="two", tokens=[_token(" two", 0.4, 0.4, 0.85)])
    result = AlignedResult(text="one two", sentences=[s1, s2])

    transcript = aligned_result_to_transcript(result, confidence_mode=ConfidenceMode.BEAM_LOGPROB)

    assert transcript.confidence_mode is ConfidenceMode.BEAM_LOGPROB
    assert transcript.segments is not None
    assert [seg.text for seg in transcript.segments] == ["one", "two"]
    assert transcript.segments[1].start_ms == 400


def test_empty_result_leaves_fields_nil():
    transcript = aligned_result_to_transcript(
        AlignedResult(text="", sentences=[]),
        confidence_mode=ConfidenceMode.GREEDY_ENTROPY,
    )
    assert transcript.text == ""
    assert transcript.segments is None
    assert transcript.confidence is None


def test_geometric_mean_confidence_edge_cases():
    assert geometric_mean_confidence([]) is None
    assert geometric_mean_confidence([0.5]) == pytest.approx(0.5, abs=1e-6)
    assert geometric_mean_confidence([0.4, 0.9]) == pytest.approx(_geo(0.4, 0.9), abs=1e-6)


# --------------------------------------------------------------------------- #
# N-best ranking / raw-score selection
# --------------------------------------------------------------------------- #


def _hyp(score: float, n_tokens: int, *, raw_score: float | None = None) -> NBestHypothesis:
    return NBestHypothesis(
        text=f"h{score}",
        score=score,
        raw_score=score if raw_score is None else raw_score,
        tokens=[_token("x", 0.0, 0.1, 1.0) for _ in range(n_tokens)],
    )


def test_rank_orders_by_score_and_truncates_top_k():
    a = _hyp(-2.0, 3)
    b = _hyp(-1.0, 5)
    c = _hyp(-3.0, 2)

    ranked = rank_hypotheses([a, b, c], top_k=2)

    assert [h.score for h in ranked] == [-1.0, -2.0]
    assert ranked[0] is b
    assert ranked[1] is a
    assert len(ranked) == 2
    # Unbiased: raw_score is identical to score for every hypothesis.
    for h in [a, b, c]:
        assert h.raw_score == h.score


def test_length_penalty_changes_ordering():
    short = _hyp(-2.0, 1)
    long = _hyp(-3.0, 3)

    without = rank_hypotheses([short, long], top_k=2, length_penalty=0.0)
    assert without[0] is short  # raw score -2.0 beats -3.0

    with_penalty = rank_hypotheses([short, long], top_k=2, length_penalty=1.0)
    # normalized: short -2.0/1 = -2.0 ; long -3.0/3 = -1.0 -> long wins
    assert with_penalty[0] is long


def test_ranking_uses_score_not_raw_score():
    # Forward-compat with biasing: `score` (possibly bias-adjusted) drives the
    # ranking while `raw_score` reports the untouched model score.
    penalized = _hyp(-5.0, 1, raw_score=-1.0)
    boosted = _hyp(-1.5, 1, raw_score=-2.0)

    ranked = rank_hypotheses([penalized, boosted], top_k=2)

    assert ranked[0] is boosted
    assert ranked[1] is penalized
    # raw_score carried through unchanged, independent of ranking order.
    assert ranked[0].raw_score == -2.0
    assert ranked[1].raw_score == -1.0


def test_top_k_bounds():
    hyps = [_hyp(-1.0, 1), _hyp(-2.0, 1)]
    assert rank_hypotheses(hyps, top_k=0) == []
    assert len(rank_hypotheses(hyps, top_k=10)) == 2


# --------------------------------------------------------------------------- #
# Factory + honest feasibility contract
# --------------------------------------------------------------------------- #


def test_build_nbest_model_rejects_non_tdt():
    with pytest.raises(TypeError):
        build_nbest_model(object())


def test_forced_candidate_scoring_is_honestly_unavailable():
    assert FORCED_CANDIDATE_SCORING_AVAILABLE is False
    note = forced_candidate_scoring_note()
    assert "Biasing" in note and "token" in note


# --------------------------------------------------------------------------- #
# transcribe() wiring: greedy default vs env-gated beam (no checkpoint)
# --------------------------------------------------------------------------- #


def _wav(path):
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(16000)
        writer.writeframes(b"\x00\x00" * 16000)
    return path


def _request(path):
    return TranscribeRequest(
        request_id="req-1",
        audio=AudioMeta(
            path=str(path),
            format="wav",
            sample_rate_hz=16000,
            channels=1,
            duration_ms=1000,
            byte_count=32000,
        ),
    )


def _stub_backend(monkeypatch, output):
    backend = MLXBackend()
    captured = {}
    monkeypatch.setattr(backend, "_load_model", lambda: None)

    def fake_infer(audio_path, use_beam):
        captured["use_beam"] = use_beam
        return output

    monkeypatch.setattr(backend, "_infer_on_mlx_thread", fake_infer)
    return backend, captured


def test_greedy_default_emits_single_rank0_and_greedy_decoder(monkeypatch, tmp_path):
    monkeypatch.delenv("VOICEOOUR_ASR_DECODING", raising=False)
    primary = AlignedResult(
        text="hi there",
        sentences=[AlignedSentence(text="hi there", tokens=[_token(" hi", 0.0, 0.5, 0.9)])],
    )
    output = _DecodeOutput(mode="greedy", beam_size=None, primary=primary, ranked=[(primary, 0.0, 0.0)])
    backend, captured = _stub_backend(monkeypatch, output)

    result = backend.transcribe(_request(_wav(tmp_path / "a.wav")), Event())

    assert captured["use_beam"] is False
    assert result.transcript.confidence_mode is ConfidenceMode.GREEDY_ENTROPY
    assert result.decoder.mode == "greedy"
    assert result.decoder.beam_size is None
    assert len(result.hypotheses) == 1
    assert result.hypotheses[0].rank == 0
    assert result.hypotheses[0].text == "hi there"


def test_beam_env_emits_ranked_hypotheses_and_beam_decoder(monkeypatch, tmp_path):
    monkeypatch.setenv("VOICEOOUR_ASR_DECODING", "beam")
    r0 = AlignedResult(text="best", sentences=[AlignedSentence(text="best", tokens=[_token(" best", 0.0, 0.4, 0.9)])])
    r1 = AlignedResult(text="rest", sentences=[AlignedSentence(text="rest", tokens=[_token(" rest", 0.0, 0.4, 0.7)])])
    output = _DecodeOutput(
        mode="beam",
        beam_size=5,
        primary=r0,
        ranked=[(r0, -1.0, -1.0), (r1, -2.0, -2.0)],
    )
    backend, captured = _stub_backend(monkeypatch, output)

    result = backend.transcribe(_request(_wav(tmp_path / "b.wav")), Event())

    assert captured["use_beam"] is True
    assert result.transcript.confidence_mode is ConfidenceMode.BEAM_LOGPROB
    assert result.decoder.mode == "beam"
    assert result.decoder.beam_size == 5
    assert [h.rank for h in result.hypotheses] == [0, 1]
    assert [h.text for h in result.hypotheses] == ["best", "rest"]
    assert result.hypotheses[0].raw_score == -1.0
