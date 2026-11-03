# CGranite — provenance and adaptations

`Vendor/granite` is Voiceour's native inference for IBM Granite Speech 5.0 TurboCTC (`granite_speech5_ctc`
GGUF). It is an adapted, reduced port of the `granite5_ctc` family of **transcribe.cpp**, built against the
ggml already vendored in `Vendor/parakeet/ggml` (0.19.0, SwiftPM target `CGgml`). It does not link or vendor
transcribe.cpp or its newer ggml.

- Upstream: <https://github.com/handy-computer/transcribe.cpp>
- Commit: `5700f127e38dd53c4735ea23ef743b4b538eacd4` (2026-10-27)
- License: MIT, Copyright (c) 2026 The transcribe.cpp authors. `LICENSE` in this directory is the upstream
  `LICENSE` file, verbatim. Every source file here starts with a header naming its upstream origin.
- Public API: `include/granite.h` is Voiceour's own narrow C API (one utterance per call); it replaces
  upstream's `include/transcribe.h` session/run/result ABI and is not derived from it.

The model weights are not part of this directory. The pinned artifact is the Q8_0 GGUF conversion of
`ibm-granite/granite-speech-5.0-470m-turboctc` (Apache-2.0) recorded in `GraniteModelContract`
(`Sources/VoiceCore/ASRProtocol.swift`) and the repository `NOTICE`.

## File mapping

Upstream paths are relative to the transcribe.cpp root at the commit above; line ranges are that commit's.

| Port file | Derived from |
|---|---|
| `src/granite-impl.h` | `src/arch/granite5_ctc/weights.h:48-176` (hyperparameters, block/top weight slots), `src/arch/granite5_ctc/granite5_ctc.h:40-73` (model/session ownership), `src/arch/granite5_ctc/encoder.h:94-183` (stage/graph structures, entry points) |
| `src/granite-gguf.cpp` | `src/arch/granite5_ctc/weights.cpp:26-197` (hyperparameter keys and invariants) and `:235-327` (tensor catalog); `src/transcribe-weights-util.cpp:15-84` and `src/transcribe-weights-util.h:50-54` (lookup, dtype allowlists, exact-shape check); `src/transcribe-meta.cpp:26-192` (type-checked KV reads, INT32 `subsample_layers`); `src/transcribe-tokenizer.cpp:174-291` (SentencePiece and GPT-2 decode) and `:812-900` (vocabulary load); `src/transcribe-unicode.cpp:36-115,250-321` (UTF-8 stepping, GPT-2 byte map) |
| `src/granite-frontend.cpp` | `src/arch/granite5_ctc/encoder.cpp:55-182` (frame budget, waveform padding, deltas, stacking); `src/transcribe-mel.cpp:287-353` (baked window/filterbank), `:376-510` (centred reflect padding), `:590-692` (vDSP double FFT, `cblas_sgemm` filterbank, `log10` clamp), `:832-873` (`per_utterance` normalization with explicit frame count) |
| `src/granite-encoder.cpp` | `src/arch/granite5_ctc/encoder.cpp:22-51,188-233,249-365,371-620` (helpers, Shaw position rows, key pad mask, conv module, pair pooling, time trim, 16-block graph, self-conditioning, tied head); `src/granite_conformer/shaw_attn.cpp:29-175` (block-local Shaw attention, skew branch); `src/conformer/conformer.cpp:35-113` (LayerNorm, feed-forward, macaron residual, `rel_shift`), `:216-250` (F32 kernel promotion for the direct depthwise op), `:300-308` (fused BatchNorm) |
| `src/granite.cpp` | `src/arch/granite5_ctc/model.cpp:44-65` (teardown), `:87-136` (BatchNorm fusion), `:139-235` (load sequence), `:260-351` (per-run graph context, scheduler, inputs, compute), `:391-441` (frontend → encoder → host logits → decode); `src/arch/granite5_ctc/decoder.cpp:19-43,69-105` (argmax, first-frame softmax probability, group-then-drop-blank collapse, ms per encoder frame); `src/transcribe-load-common.cpp:295-443` (backend plan), `:505-605,607-635` (read-only mapping of the whole file, per-tensor placement, copy fallback), `:712-787` (bounded tensor upload); `src/transcribe-batch-util.cpp:70-88` (`ggml_backend_set_n_threads` via the registry); `src/transcribe-log.h` (callback sink with stderr fallback) |

## Adaptations

API and ggml substitutions:

- Built on vendored ggml 0.19. The Granite path in upstream calls no `ggml_prec_set_acc` (its
  `ggml_prec_set_acc` uses are in unrelated conformer/other-family helpers that were not ported), so the
  rule "replace `ggml_prec_set_acc(x, GGML_PREC_F32)` by `ggml_mul_mat_set_prec(x, GGML_PREC_F32)`" has no
  call site here; no other API was backported. Every graph operation used (`ggml_norm`, `ggml_mul_mat`,
  `ggml_get_rows` on Q8_0, `ggml_fill`, `ggml_concat`, `ggml_soft_max`, `ggml_conv_2d_dw_direct`, views,
  permutes) exists in 0.19 with the same signature.
- `ggml_backend_dev_caps.mmap_support` does not exist in 0.19: mapping is gated on
  `caps.buffer_from_host_ptr` only. Upstream's pre-Apple7 Metal exclusion is dropped (Voiceour is
  arm64-only, all Apple7+).
- Backends: requested GPU device (Metal) first, then accelerator devices (Accelerate BLAS), then the
  mandatory CPU fallback — Parakeet's order in `Vendor/parakeet/src/parakeet.cpp`. No explicit-device or
  discrete-before-integrated selection. CPU-only when `use_gpu` is false or no GPU device exists.
- Weights: when `map_weights` and the primary device accepts host pointers, the whole GGUF is mapped
  `PROT_READ`/`MAP_SHARED`, wrapped with `ggml_backend_dev_buffer_from_host_ptr`, and each tensor whose type,
  size, contiguity, bounds, alignment and allocation size match is placed at its file address with
  `ggml_backend_tensor_alloc`. Everything else is uploaded into an ordinary primary-backend buffer with
  `pread` (<= 16 MiB staging chunks for device buffers). No `TRANSCRIBE_NO_MMAP` environment switch.
  Mapped memory is never written.
- BatchNorm fusion: the fused scale/bias live in a separate small buffer on the **primary** backend
  (upstream put them on the CPU fallback); values are computed with the same F32 arithmetic.
- The baked frontend tensors are read from the loaded weights with `ggml_backend_tensor_get` rather than a
  second file read; the values are identical.
- One persistent scheduler per context (graph size 16384, `parallel = false`, `op_offload = true`); a fresh
  16 MiB `no_alloc` metadata context per run; the scheduler is reset and the metadata context freed after
  every run, on every exit path. Upstream recreated the scheduler per run through its public wrapper.
- Logging goes through `granite_log_set` (stderr when unset), one line per message prefixed `granite: `.
  Nothing is ever written to stdout. ggml's own logger is not touched (it is shared with Parakeet).

Behaviour changes required by Voiceour's contract:

- Short input: inputs shorter than the minimum that yields one encoder frame after every subsampling block
  are right-padded with zeros to exactly that minimum, computed from the GGUF hyperparameters at load
  (1,120 samples for the pinned model). Upstream failed such clips with `TRANSCRIBE_ERR_GGUF` (graph
  collapse) or `TRANSCRIBE_ERR_INVALID_ARG` (frontend). Zero samples succeed with zero tokens.
- PCM validation: negative length, NULL PCM with a positive length and non-finite samples are rejected with
  `GRANITE_ERR_INVALID_ARGUMENT`.
- Cancellation: the abort callback is polled at three stage boundaries — before the frontend, before graph
  compute, and after graph compute before CTC decoding. Upstream polled only before the frontend. No abort
  callback is installed on any backend: the vendored Metal backend defaults to three extra command buffers
  whose submission is skipped when a Metal abort callback is set.
- Results: each token carries its CTC run's encoder-frame span (`frame_begin`, `frame_end`), the softmax
  probability at the run's first frame (upstream's `p`), and `is_special`. Upstream published no timing.
  A run's results (including on failure) replace the previous run's.
- `is_special` is `tokenizer.ggml.token_type` in {UNKNOWN, CONTROL, USER}; for the pinned conversion this
  equals exactly the `tokenizer.json` `added_tokens` with `special: true` (255 ids, verified over the
  whole 16,384-entry vocabulary). Special tokens are still emitted, never filtered, exactly as upstream.
- Per-token bytes are precomputed for the whole vocabulary at load; because both decode flavours are
  per-token, concatenating consecutive tokens' bytes equals upstream's full-sequence `raw_text`. Upstream's
  whitespace collapse/trim into `full_text` is left to the caller.
- Errors: allocation/compute failures map to `GRANITE_ERR_BACKEND`; a malformed or unsupported GGUF fails
  `granite_init_from_file` with a logged reason. C++ exceptions never cross the C API.

Removed upstream features (not reachable from this API): multi-utterance batch execution and its frame
masks, streaming, the alternate direct-distance Shaw branch, debug tensor dumps and validation hooks,
environment knobs, language/capability metadata reads, the text encoder (merges, scores, piece→id map),
the non-Apple FFT and non-BLAS filterbank fallbacks, and the generic mel modes of other families.

## Model-format expectations

`granite_init_from_file` accepts a GGUF only when all of the following hold:

- `general.architecture` = `granite_speech5_ctc`.
- U32 keys `stt.granite5_ctc.encoder.{n_layers, hidden, n_heads, head_dim, intermediate, input_dim,
  output_dim, conv_kernel_size, conv_expansion, context_size, max_pos_emb, self_cond_layer}` and
  `stt.granite5_ctc.blank_id`; optional INT32 array `stt.granite5_ctc.encoder.subsample_layers` (entries in
  `[0, n_layers)`); `n_heads * head_dim == hidden`, odd kernel, `max_pos_emb >= context_size`,
  `self_cond_layer` in `[0, n_layers]`, `blank_id < output_dim`.
- Frontend: `stt.frontend.type = "mel"`, `.window = "hann_periodic"`, `.normalize = "per_utterance"`,
  optional `.pad_mode = "reflect"`, optional `.mel_norm = "htk"`; U32 `.sample_rate`, `.num_mels`, `.n_fft`
  (power of two), `.win_length`, `.hop_length`, `.delta_win_length = 3`, `.stack_factor = 2`; F32 `.dither`
  and `.logmel_floor_db` (type-checked; the floor is the fixed 8 log10 units of upstream and no dither is
  applied); optional bool `.deltas`; `num_mels * (deltas ? 2 : 1) * stack_factor == input_dim`.
- Tokenizer: `tokenizer.ggml.model` = `bpe` (SentencePiece decode: U+2581 → space, `<0xHH>` → byte) or
  `gpt2` (GPT-2 byte map); non-empty string array `tokenizer.ggml.tokens` with exactly `output_dim` entries;
  INT32 array `tokenizer.ggml.token_type` of the same length.
- Tensors: exactly the 32 per-block tensors × `n_layers` plus `enc.input_linear.{weight,bias}`,
  `enc.ctc_proj.{weight,bias}` (tied head), `enc.ctc_bypass.{weight,bias}`, `frontend.mel_filterbank`
  `[n_fft/2+1, num_mels]` and `frontend.window` `[win_length]` (520 for the pinned model), no others, with
  upstream's exact shapes. Linear weights may be F32, F16, BF16, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q4_K, Q5_K or
  Q6_K; depthwise kernels F32 or F16; every bias, norm, BatchNorm and frontend tensor F32.
