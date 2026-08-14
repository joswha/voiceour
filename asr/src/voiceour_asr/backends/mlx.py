from __future__ import annotations

import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from threading import Event
from typing import TYPE_CHECKING

from voiceour_asr import cache
from voiceour_asr.decoding import aligned_result_to_transcript
from voiceour_asr.errors import ErrorCode
from voiceour_asr.protocol import (
    Cancelled,
    ConfidenceMode,
    DecoderInfo,
    ErrorMessage,
    HealthResponse,
    Hypothesis,
    Result,
    Timings,
    TranscribeRequest,
    protocol_error,
)

from .base import Backend, validate_transcribe_request

if TYPE_CHECKING:  # pragma: no cover - typing only; trie is pure Python
    from voiceour_asr.decoding.trie import PhraseTrie

#: Upper bound on *representable* bias phrases accepted per request; beyond this
#: the bias list is rejected with BIAS_LIST_TOO_LARGE to keep the phrase trie
#: and its per-beam-step advance cost bounded.
MAX_BIAS_PHRASES = 500


def load_pcm16_mono_wav(path: Path, expected_rate: int):
    """Decode a 16-bit mono PCM WAV at expected_rate to float32 samples in [-1, 1).

    Fast path for the app's own recordings (16 kHz mono s16 WAV): avoids the
    ffmpeg subprocess parakeet_mlx.load_audio spawns per request. Returns a
    numpy array, or None when the file needs the generic decoder.
    """
    import wave

    import numpy as np

    try:
        with wave.open(str(path), "rb") as reader:
            if reader.getcomptype() != "NONE":
                return None
            if reader.getnchannels() != 1 or reader.getsampwidth() != 2:
                return None
            if reader.getframerate() != expected_rate:
                return None
            frames = reader.readframes(reader.getnframes())
    except (wave.Error, EOFError, OSError):
        return None
    samples = np.frombuffer(frames, dtype="<i2")
    return samples.astype(np.float32) / 32768.0


@dataclass
class _DecodeOutput:
    """Richer decode result handed back from the single MLX thread.

    ``primary`` is the rank-0 ``parakeet_mlx`` AlignedResult used for the main
    transcript; ``ranked`` is the ordered ``(AlignedResult, score, raw_score)``
    list backing the wire hypotheses. On the greedy default path ``ranked``
    holds exactly one rank-0 entry.
    """

    mode: str
    beam_size: int | None
    primary: object
    ranked: list = field(default_factory=list)
    bias_enabled: bool = False
    bias_snapshot_id: str | None = None


class MLXBackend(Backend):
    backend_id = "parakeet-mlx"

    def __init__(self) -> None:
        self._model = None
        self._load_ms = 0
        self._warmed = False
        # MLX Metal streams are thread-affine: loading the model on one thread and
        # running inference on another fails with "There is no Stream(gpu, 0) in
        # current thread" (regression caught by the mlx benchmark tier). All MLX
        # work is therefore serialized onto this single dedicated thread.
        self._mlx_thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="voiceour-mlx")
        try:
            from parakeet_mlx import from_pretrained  # noqa: F401
        except Exception as exc:  # pragma: no cover - depends on optional runtime health
            self._import_error = exc
        else:
            self._import_error = None

    def health(self):
        ok = cache.cache_ok(cache.PARAKEET)
        return HealthResponse(
            request_id="health",
            ready=self._import_error is None and ok,
            model_loaded=self._model is not None,
            cache_ok=ok,
        )

    def _load_model(self):
        return self._mlx_thread.submit(self._load_model_on_mlx_thread).result()

    def warm_up(self):
        """Load the model and run one throwaway inference on the MLX thread.

        from_pretrained only materializes weights; MLX is lazy, so the first
        generate() pays graph/kernel compilation (~0.8s measured). Running it
        on silence during preload keeps that cost off the first dictation.
        """
        self._load_model()
        self._mlx_thread.submit(self._warm_up_on_mlx_thread).result()

    def _warm_up_on_mlx_thread(self):
        if self._warmed:
            return
        model = self._model
        import mlx.core as mx
        from parakeet_mlx import DecodingConfig
        from parakeet_mlx.audio import get_logmel

        silence = mx.zeros((model.preprocessor_config.sample_rate // 2,), dtype=mx.float32)
        mel = get_logmel(silence, model.preprocessor_config)
        model.generate(mel, decoding_config=DecodingConfig())
        self._warmed = True
        mx.clear_cache()
        print(
            f"voiceour-asr mlx mem after warm-up: "
            f"active={mx.get_active_memory() // 2**20}MB "
            f"peak={mx.get_peak_memory() // 2**20}MB",
            file=sys.stderr,
        )

    def _load_model_on_mlx_thread(self):
        if self._import_error is not None:
            raise self._import_error
        if self._model is not None:
            return self._model
        start = time.perf_counter()
        snapshot = cache.ensure_model(cache.PARAKEET)
        from parakeet_mlx import from_pretrained

        self._model = from_pretrained(str(snapshot))
        self._load_ms = int((time.perf_counter() - start) * 1000)
        return self._model

    def _infer_on_mlx_thread(
        self,
        audio_path: Path,
        use_beam: bool,
        bias: PhraseTrie | None = None,
        bias_snapshot_id: str | None = None,
    ) -> _DecodeOutput:
        model = self._model
        import mlx.core as mx
        from parakeet_mlx import DecodingConfig
        from parakeet_mlx.audio import get_logmel, load_audio

        try:
            sample_rate = model.preprocessor_config.sample_rate
            samples = load_pcm16_mono_wav(audio_path, sample_rate)
            if samples is not None:
                audio = mx.array(samples)
            else:
                audio = load_audio(str(audio_path), sample_rate)
            mel = get_logmel(audio, model.preprocessor_config)

            if use_beam:
                # Opt-in richer beam n-best. Promotion is additive and in-place, so
                # all Metal work stays on this single dedicated MLX thread.
                from parakeet_mlx import Beam

                from voiceour_asr.decoding.nbest import DEFAULT_BEAM_SIZE, build_nbest_model

                model = build_nbest_model(model)
                self._model = model
                beam_size = DEFAULT_BEAM_SIZE
                config = DecodingConfig(decoding=Beam(beam_size=beam_size))
                ranked_batches = model.generate_nbest(mel, decoding_config=config, top_k=beam_size, bias=bias)
                ranked = ranked_batches[0] if ranked_batches else []
                if ranked:
                    primary = ranked[0][0]
                else:
                    from parakeet_mlx.alignment import AlignedResult

                    primary = AlignedResult("", [])
                return _DecodeOutput(
                    mode="beam",
                    beam_size=beam_size,
                    primary=primary,
                    ranked=ranked,
                    bias_enabled=bias is not None,
                    bias_snapshot_id=bias_snapshot_id if bias is not None else None,
                )

            alignments = model.generate(mel, decoding_config=DecodingConfig())
            first = alignments[0] if isinstance(alignments, list) and alignments else alignments
            return _DecodeOutput(mode="greedy", beam_size=None, primary=first, ranked=[(first, 0.0, 0.0)])
        finally:
            active_mb = mx.get_active_memory() // 2**20
            cache_mb = mx.get_cache_memory() // 2**20
            peak_mb = mx.get_peak_memory() // 2**20
            mx.clear_cache()
            print(
                f"voiceour-asr mlx mem: active={active_mb}MB cache={cache_mb}MB peak={peak_mb}MB",
                file=sys.stderr,
            )

    def transcribe(self, request: TranscribeRequest, cancelled: Event):
        if cancelled.is_set():
            return Cancelled(request_id=request.request_id)
        validation = validate_transcribe_request(
            request,
            model_id=cache.MODEL_ID,
            model_revision=cache.MODEL_REVISION,
        )
        if isinstance(validation, ErrorMessage):
            return validation
        audio_path = validation
        # Same race the ARK backend guards, and the default backend is the one that
        # actually meets a cold cache on a fresh install. Parakeet is 2.3 GB, so a
        # cold acquisition cannot fit inside the client's 30 s transcribe timeout:
        # blocking here would spend the whole budget, time out, and have the client
        # terminate the sidecar mid-download, leaving a partial cache for the next
        # attempt to trip over. The preload thread is already fetching after `hello`.
        if not cache.cache_ok(cache.PARAKEET):
            return protocol_error(
                ErrorCode.MODEL_NOT_INSTALLED,
                request_id=request.request_id,
                detail=f"{cache.MODEL_ID} is still being acquired; retry once it has finished",
            )
        try:
            self._load_model()
        except cache.ManifestMismatch as exc:
            return protocol_error(ErrorCode.MANIFEST_MISMATCH, request_id=request.request_id, detail=str(exc))
        except ImportError as exc:
            return protocol_error(ErrorCode.BACKEND_UNAVAILABLE, request_id=request.request_id, detail=str(exc))
        except Exception as exc:
            return protocol_error(ErrorCode.MODEL_LOAD_FAILED, request_id=request.request_id, detail=str(exc))
        if cancelled.is_set():
            return Cancelled(request_id=request.request_id)
        bias_phrases = request.bias_phrases or []
        bias = None
        if bias_phrases:
            # Opt-in shallow-fusion biasing (default off). Segmentation and trie
            # construction are pure Python (no Metal), so they run here; only the
            # beam decode is submitted to the single MLX thread. Bias requires beam.
            from voiceour_asr.decoding.trie import PhraseTrie
            from voiceour_asr.decoding.vocabulary import PieceVocabulary

            piece_vocab = PieceVocabulary(self._model.vocabulary)
            phrases: list = []
            for phrase in bias_phrases:
                ids = piece_vocab.segment(phrase.text)
                if ids is None:
                    continue  # unrepresentable phrase: skipped, not an error
                phrases.append(ids if phrase.weight is None else (ids, phrase.weight))
            if len(phrases) > MAX_BIAS_PHRASES:
                return protocol_error(
                    ErrorCode.BIAS_LIST_TOO_LARGE,
                    request_id=request.request_id,
                    detail=f"{len(phrases)} representable bias phrases exceeds cap {MAX_BIAS_PHRASES}",
                )
            bias = PhraseTrie(phrases, blank_id=len(self._model.vocabulary))
        start = time.perf_counter()
        try:
            if bias is not None:
                # Biased beam: single submission on the MLX thread.
                output = self._mlx_thread.submit(
                    self._infer_on_mlx_thread, audio_path, True, bias, request.bias_snapshot_id
                ).result()
            else:
                use_beam = os.environ.get("VOICEOUR_ASR_DECODING", "greedy").strip().lower() == "beam"
                output = self._mlx_thread.submit(self._infer_on_mlx_thread, audio_path, use_beam).result()
        except Exception as exc:
            return protocol_error(ErrorCode.INFERENCE_FAILED, request_id=request.request_id, detail=str(exc))
        inference_ms = int((time.perf_counter() - start) * 1000)
        if cancelled.is_set():
            return Cancelled(request_id=request.request_id)
        confidence_mode = ConfidenceMode.BEAM_LOGPROB if output.mode == "beam" else ConfidenceMode.GREEDY_ENTROPY
        transcript = aligned_result_to_transcript(output.primary, confidence_mode=confidence_mode)
        hypotheses = [
            Hypothesis(rank=rank, text=aligned.text, score=score, raw_score=raw_score, transcript=None)
            for rank, (aligned, score, raw_score) in enumerate(output.ranked)
        ]
        decoder = DecoderInfo(
            mode=output.mode,
            beam_size=output.beam_size,
            bias_enabled=output.bias_enabled,
            bias_snapshot_id=output.bias_snapshot_id,
        )
        return Result(
            request_id=request.request_id,
            backend_id=self.backend_id,
            model_id=cache.MODEL_ID,
            model_revision=cache.MODEL_REVISION,
            transcript=transcript,
            timings_ms=Timings(load=self._load_ms, inference=inference_ms, total=self._load_ms + inference_ms),
            hypotheses=hypotheses,
            decoder=decoder,
        )
