# VoiceOour ASR sidecar

The sidecar is a `uv`-managed Python package. It speaks ASR protocol v1 as newline-delimited JSON over stdio.

Invariant: stdout is protocol-only; all logs/progress go to stderr.

## Protocol

The sidecar is a persistent process. It emits `hello` on startup, then keeps stdin/stdout open for `health`, `transcribe`, and `cancel` messages. Health replies are immediate on the main reader thread. Each `transcribe` request runs on a worker thread so the main thread can keep reading later messages, including `cancel`.

Every `transcribe` request emits exactly one terminal message: `result`, `error`, or `cancelled`. A `cancel` message sets the cancellation event for the matching in-flight `request_id`; backends check that event before doing work, during cheap polling points, and immediately before returning a result when possible.

Set `VOICEOOUR_PRELOAD=1` to start a best-effort daemon warm-up after `hello` on any backend that loads a model (`mlx`, `ark-0.6b`, `ark-3b`). The fake backend ignores preload.

## Commands

```sh
uv --no-config sync
VOICEOOUR_ASR_BACKEND=fake|mlx|ark-0.6b|ark-3b uv --no-config run python -m voiceoour_asr
uv --no-config run pytest
```

## Backends

- `fake`: deterministic development backend. Returns `fake transcript duration_ms=<n>`, supports cancellation state, and returns timeout for zero-timeout requests.
- `mlx`: real `parakeet-mlx` backend using `mlx-community/parakeet-tdt-0.6b-v3` pinned at `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`. The default.
- `ark-0.6b`: ARK-ASR `leope/ark-asr-0.6B-mlx` pinned at `6ec069bd68cbbe165aa42728eac482c90cb58d2f`.
- `ark-3b`: ARK-ASR `leope/ark-asr-3B-mlx` pinned at `63d9fb8ba352c5c7c65ff2336019048170563d63`. Needs roughly 7.5 GB resident.

Select with `VOICEOOUR_ASR_BACKEND=fake|mlx|ark-0.6b|ark-3b`.

### ARK-ASR

ARK is an audio-conditioned Qwen2 decoder: it emits text and nothing else. Its results carry the transcript alone — no per-word or per-segment alignments, no confidence, no n-best hypotheses, no decoder block. Bias phrases are accepted and ignored, since shallow-fusion biasing needs a beam and a transducer blank and ARK has neither.

It also inherits Whisper's 30 s encoder window: a longer clip is rejected with `inference_failed` naming the measured duration.

The ARK model repos ship their MLX runtime as Python source inside the model repo. That source is vendored under `src/voiceoour_asr/backends/ark_mlx/` (Apache-2.0; see the `NOTICE` and `LICENSE` there) so the app never imports code downloaded from Hugging Face at runtime, and the download fetches weights and tokenizer assets only.

## Cache

`voiceoour_asr.cache.ensure_model(spec)` stores each pinned model under its own directory:

```text
~/Library/Caches/VoiceOour/parakeet
~/Library/Caches/VoiceOour/ark-0.6b
~/Library/Caches/VoiceOour/ark-3b
```

`VOICEOOUR_MODEL_CACHE` overrides the Parakeet directory. Each directory holds a `manifest.json` with model id, pinned revision, and snapshot path. Once a manifest exists, the sidecar sets `HF_HUB_OFFLINE=1` before loading.

## Historical sherpa-onnx evaluation

Sherpa-onnx was briefly evaluated as an opt-in CPU backend and then removed; consult git history for the archived benchmark details.

## Protocol tests

`asr/tests/test_protocol.py` decodes every JSON file in `../fixtures/protocol/`. Swift tests decode the same fixtures. Update both when the wire contract changes.

## Real proof

```sh
../scripts/make_fixture.sh
uv --no-config run python ../scripts/phase0_asr_proof.py ../fixtures/audio/hello_16k_mono.wav
```

Expected: non-empty transcript containing `hello` or `world`, plus cold-load, warm-inference, and RSS output.
