# VoiceOour ASR sidecar

The sidecar is a `uv`-managed Python package. It speaks ASR protocol v1 as newline-delimited JSON over stdio.

Invariant: stdout is protocol-only; all logs/progress go to stderr.

## Protocol

The sidecar is a persistent process. It emits `hello` on startup, then keeps stdin/stdout open for `health`, `transcribe`, and `cancel` messages. Health replies are immediate on the main reader thread. Each `transcribe` request runs on a worker thread so the main thread can keep reading later messages, including `cancel`.

Every `transcribe` request emits exactly one terminal message: `result`, `error`, or `cancelled`. A `cancel` message sets the cancellation event for the matching in-flight `request_id`; backends check that event before doing work, during cheap polling points, and immediately before returning a result when possible.

Set `VOICEOOUR_PRELOAD=1` with the `mlx` backend to start a best-effort daemon warm-up after `hello`. The fake backend ignores preload.

## Commands

```sh
uv --no-config sync
VOICEOOUR_ASR_BACKEND=fake|mlx uv --no-config run python -m voiceoour_asr
uv --no-config run pytest
```

## Backends

- `fake`: deterministic development backend. Returns `fake transcript duration_ms=<n>`, supports cancellation state, and returns timeout for zero-timeout requests.
- `mlx`: real `parakeet-mlx` backend using `mlx-community/parakeet-tdt-0.6b-v3` pinned at `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`.

Select with `VOICEOOUR_ASR_BACKEND=fake|mlx`.

## Cache

`voiceoour_asr.cache.ensure_model()` stores the model under:

```text
~/Library/Caches/VoiceOour/parakeet
```

It writes `manifest.json` with model id, pinned revision, and snapshot path. Once a manifest exists, the sidecar sets `HF_HUB_OFFLINE=1` before loading.

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
