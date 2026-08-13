from __future__ import annotations

import importlib.util
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from typing import TYPE_CHECKING

from voiceoour_asr import cache
from voiceoour_asr.errors import ErrorCode
from voiceoour_asr.protocol import (
    Cancelled,
    HealthResponse,
    Result,
    Timings,
    TranscribeRequest,
    Transcript,
    protocol_error,
)

from .base import Backend
from .mlx import load_pcm16_mono_wav

if TYPE_CHECKING:  # pragma: no cover - typing only, avoids importing numpy at startup
    import numpy as np

#: Mirrors ark_mlx.processor: ARK consumes 16 kHz mono and refuses clips beyond
#: 30 s (the Whisper encoder window it inherits). Duplicated as plain constants so
#: importing this module does not drag in librosa/transformers/mlx.
SAMPLE_RATE = 16_000
MAX_AUDIO_SECONDS = 30.0

#: Upstream ark_asr_mlx.api.ArkASR.transcribe default.
MAX_NEW_TOKENS = 256

#: Length of the silent clip warm_up decodes; see ArkBackend.warm_up.
WARM_UP_SECONDS = 10.0

#: Third-party packages the vendored runtime needs. Probed by spec rather than
#: imported, because importing them costs seconds and would delay `hello`.
_RUNTIME_MODULES = ("mlx", "librosa", "transformers")


def wav_duration_seconds(path: Path) -> float | None:
    """Duration of a PCM WAV from its header, or None when it is not readable as one."""
    import wave

    try:
        with wave.open(str(path), "rb") as reader:
            frame_rate = reader.getframerate()
            frame_count = reader.getnframes()
    except (wave.Error, EOFError, OSError):
        return None
    if frame_rate <= 0:
        return None
    return frame_count / frame_rate


class ArkBackend(Backend):
    """ARK-ASR: an audio-conditioned Qwen2 decoder, text out and nothing else.

    No transducer lattice, so no alignments, no confidence and no n-best; the
    wire result carries the transcript alone.
    """

    def __init__(self, spec: cache.ModelSpec, backend_id: str) -> None:
        self._spec = spec
        self._backend_id = backend_id
        self._model = None
        self._load_ms = 0
        self._warmed = False
        # MLX Metal streams are thread-affine: loading the model on one thread and
        # running inference on another fails with "There is no Stream(gpu, 0) in
        # current thread". All MLX work is therefore serialized onto this single
        # dedicated thread.
        self._ark_thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="voiceoour-ark")
        try:
            missing = [name for name in _RUNTIME_MODULES if importlib.util.find_spec(name) is None]
        except Exception as exc:  # pragma: no cover - depends on optional runtime health
            self._import_error: Exception | None = exc
        else:
            self._import_error = ImportError(f"missing modules: {', '.join(missing)}") if missing else None

    @property
    def backend_id(self) -> str:
        return self._backend_id

    def health(self):
        ok = cache.cache_ok(self._spec)
        return HealthResponse(
            request_id="health",
            ready=self._import_error is None and ok,
            model_loaded=self._model is not None,
            cache_ok=ok,
        )

    def _load_model(self):
        return self._ark_thread.submit(self._load_model_on_ark_thread).result()

    def warm_up(self):
        """Load the model and transcribe ten seconds of silence on the ARK thread.

        Ten seconds, not a token's worth: the mel spectrogram is padded to the
        clip length, so MLX compiles the encoder graph per input shape, and the
        first librosa/transformers import alone costs seconds. A short warm-up
        would leave both costs on the user's first real dictation.
        """
        self._load_model()
        self._ark_thread.submit(self._warm_up_on_ark_thread).result()

    def _warm_up_on_ark_thread(self):
        if self._warmed:
            return
        import mlx.core as mx
        import numpy as np

        silence = np.zeros(int(WARM_UP_SECONDS * SAMPLE_RATE), dtype=np.float32)
        self._generate(silence, SAMPLE_RATE, Event(), max_new_tokens=MAX_NEW_TOKENS)
        self._warmed = True
        mx.clear_cache()
        print(
            f"voiceoour-asr ark mem after warm-up: "
            f"active={mx.get_active_memory() // 2**20}MB "
            f"peak={mx.get_peak_memory() // 2**20}MB",
            file=sys.stderr,
        )

    def _load_model_on_ark_thread(self):
        if self._import_error is not None:
            raise self._import_error
        if self._model is not None:
            return self._model
        start = time.perf_counter()
        snapshot = cache.ensure_model(self._spec)
        from .ark_mlx.api import ArkASR

        self._model = ArkASR.from_pretrained(str(snapshot))
        self._load_ms = int((time.perf_counter() - start) * 1000)
        return self._model

    def _generate(self, audio, sample_rate: int | None, cancelled: Event, max_new_tokens: int) -> str | None:
        """Greedy decode, one token at a time, checking cancellation between tokens.

        This duplicates ark_asr_mlx.generation.generate_transcription rather than
        calling it: that loop runs to EOS or max_new_tokens with no way in, and a
        3B decode is long enough that an abandoned dictation must not hold the
        single MLX thread. Returns None when the request was cancelled mid-decode.
        """
        import mlx.core as mx
        import numpy as np

        ark = self._model
        model = ark.model
        processor = ark.processor

        if cancelled.is_set():
            return None
        inputs = processor.process(audio, sample_rate)
        input_ids = mx.array(inputs.input_ids)
        input_features = mx.array(inputs.input_features).astype(model.audio_encoder.whisper.conv1.weight.dtype)
        prompt_embeddings = model.prepare_prompt_embeddings(
            input_ids,
            input_features,
            inputs.audio_start,
            inputs.audio_count,
        )
        if cancelled.is_set():
            return None
        kv_cache = model.make_cache()
        logits = model(input_ids, cache=kv_cache, input_embeddings=prompt_embeddings)
        mx.eval(logits)

        suppressed = processor.suppressed_token_ids(model.config.eos_token_id)
        mask = np.zeros(model.config.vocab_size, dtype=np.bool_)
        mask[suppressed] = True
        suppression_mask = mx.array(mask)

        generated: list[int] = []
        for _ in range(max_new_tokens):
            if cancelled.is_set():
                return None
            next_logits = mx.where(suppression_mask, -float("inf"), logits[0, -1])
            token = mx.argmax(next_logits)
            mx.eval(token)
            token_id = int(token.item())
            if token_id == model.config.eos_token_id:
                break
            generated.append(token_id)
            logits = model(mx.array([[token_id]], dtype=mx.int32), cache=kv_cache)
            mx.eval(logits)
        return processor.tokenizer.decode(generated, skip_special_tokens=True).strip()

    def _infer_on_ark_thread(self, audio_path: Path, cancelled: Event) -> str | None:
        import mlx.core as mx

        try:
            samples: np.ndarray | None = load_pcm16_mono_wav(audio_path, SAMPLE_RATE)
            if samples is not None:
                return self._generate(samples, SAMPLE_RATE, cancelled, MAX_NEW_TOKENS)
            # Anything the fast path rejects (other rates, non-PCM) goes through the
            # vendored processor, which decodes and resamples it with librosa.
            return self._generate(audio_path, None, cancelled, MAX_NEW_TOKENS)
        finally:
            active_mb = mx.get_active_memory() // 2**20
            cache_mb = mx.get_cache_memory() // 2**20
            peak_mb = mx.get_peak_memory() // 2**20
            mx.clear_cache()
            print(
                f"voiceoour-asr ark mem: active={active_mb}MB cache={cache_mb}MB peak={peak_mb}MB",
                file=sys.stderr,
            )

    def transcribe(self, request: TranscribeRequest, cancelled: Event):
        # request.bias_phrases is deliberately ignored: shallow-fusion biasing needs a
        # beam and a transducer blank, and ARK has neither. The glossary path degrades
        # to a no-op here rather than failing a dictation the user can still use.
        if cancelled.is_set():
            return Cancelled(request_id=request.request_id)
        if request.expected_model:
            if request.expected_model.model_id and request.expected_model.model_id != self._spec.model_id:
                return protocol_error(
                    ErrorCode.MANIFEST_MISMATCH,
                    request_id=request.request_id,
                    detail="expected_model model_id mismatch",
                )
            if request.expected_model.revision and request.expected_model.revision != self._spec.revision:
                return protocol_error(
                    ErrorCode.MANIFEST_MISMATCH,
                    request_id=request.request_id,
                    detail="expected_model revision mismatch",
                )
        audio_path = Path(request.audio.path)
        if not audio_path.exists():
            return protocol_error(ErrorCode.AUDIO_NOT_FOUND, request_id=request.request_id, detail=str(audio_path))
        if request.audio.format.lower() != "wav":
            return protocol_error(
                ErrorCode.UNSUPPORTED_AUDIO_FORMAT, request_id=request.request_id, detail=request.audio.format
            )
        # Checked before the model is loaded so an over-long clip never pays a 7 GB
        # load. Files the header reader cannot measure fall through to the vendored
        # processor's own 30 s guard, which surfaces as INFERENCE_FAILED below.
        duration = wav_duration_seconds(audio_path)
        if duration is not None and duration > MAX_AUDIO_SECONDS:
            return protocol_error(
                ErrorCode.INFERENCE_FAILED,
                request_id=request.request_id,
                detail=f"audio is {duration:.2f}s; ARK-ASR accepts at most {MAX_AUDIO_SECONDS:.0f}s per clip",
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
        start = time.perf_counter()
        try:
            text = self._ark_thread.submit(self._infer_on_ark_thread, audio_path, cancelled).result()
        except Exception as exc:
            return protocol_error(ErrorCode.INFERENCE_FAILED, request_id=request.request_id, detail=str(exc))
        inference_ms = int((time.perf_counter() - start) * 1000)
        if text is None or cancelled.is_set():
            return Cancelled(request_id=request.request_id)
        return Result(
            request_id=request.request_id,
            backend_id=self._backend_id,
            model_id=self._spec.model_id,
            model_revision=self._spec.revision,
            transcript=Transcript(text=text),
            timings_ms=Timings(load=self._load_ms, inference=inference_ms, total=self._load_ms + inference_ms),
        )
