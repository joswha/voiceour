# CQwen3 — provenance and adaptations

`Vendor/qwen3` is a bench-only native decoder for Qwen3 GGUFs (`general.architecture = qwen3`), used by
`voiceour-bench polish` to measure a local polish pass. It is an adapted, reduced port of the qwen3 path of
**llama.cpp**, built against the ggml vendored in `Vendor/ggml` (0.19.0, SwiftPM target `CGgml`). It does not
link or vendor llama.cpp or its newer ggml, and nothing in the app or the sidecar links it.

- Upstream: <https://github.com/ggml-org/llama.cpp>
- Release and commit: `b12606`, `e412c6f468b7b9e0f16f2540244236f8ad68e9ae` (2026-11-21)
- License: MIT, Copyright (c) 2023-2026 The ggml authors. `LICENSE` in this directory is the upstream `LICENSE`
  file, verbatim. Every source file here starts with a header naming its upstream origin.
- Public API: `include/qwen3.h` is Voiceour's own narrow C API (one greedy generation per call); it replaces
  libllama's model/context/batch ABI and is not derived from it.

## File mapping

Upstream paths are relative to the llama.cpp root at the commit above; line ranges are that commit's.

| Port file | Derived from |
|---|---|
| `src/qwen3-impl.h` | `src/llama-hparams.h:168-181` (RoPE/YaRN defaults), the layer weight slots of `src/llama-model.h`, the per-layer K/V tensors of `src/llama-kv-cache.h` |
| `src/qwen3-gguf.cpp` | `src/models/qwen3.cpp:3-55` (qwen3 hyperparameters and tensor catalog, tied output); `src/llama-model.cpp` generic `load_hparams` keys and defaults (head_count_kv, key/value length, rope dimension, freq_base); `src/llama-model.cpp:4129-4166` (`create_tensor_qkv`, separate Q/K/V path only); `src/llama-vocab.cpp:3266-3305` (end-of-generation texts raised to CONTROL) and `:3395-3415` (the `</s>` exception) |
| `src/qwen3-graph.cpp` | `src/models/qwen3.cpp:57-159` (head and backbone); `src/llama-graph.cpp:1778-1799` (`build_rope_impl`), `:1936-1969` (`build_norm`), `:1986-2098` (`build_qkv`), `:2101-2324` (`build_ffn`, SILU with parallel gate), `:2806-2974` (`build_inp_embd`), `:3023-3043` (`build_inp_out_ids`), `:3174-3318` (`build_attn_mha`, flash-attention branch), `:3475-3563` (`build_attn`, expand order and K/V store); `src/llama-kv-cache.cpp:1406-1456` (`get_k`, `get_v`), `:1482-1571` (`cpy_k`, `cpy_v`, non-transposed V) |
| `src/qwen3.cpp` | `src/llama-model.cpp:2060-2140` and `src/llama-model-loader.cpp:1790-1835` (read-only mapping wrapped with `buffer_from_host_ptr`, per-tensor `ggml_backend_tensor_alloc`, upload otherwise); `src/llama-kv-cache.cpp:1297-1311` (`get_n_kv`, 256-cell padding), `:1617-1631` (cell indices), `:1702-1866` (causal F16 mask); `src/llama-context.cpp` (graph reuse when the ubatch shape is unchanged, ubatch split at `n_ubatch = 512`, per-row logits); `common/ngram-map.cpp:49-112` (`common_ngram_simple_draft`); the decode and verification loop of the polish-lab harness over libllama (`llama_memory_seq_rm` rollback); `src/llama-vocab.cpp:4077-4160` (token types as `token_to_piece` renders them). The logging sink mirrors `Vendor/granite`'s `granite_log_set`. |
| `src/qwen3-top-two.h` | Voiceour's exact top-two selector for an F32 logit row |

The Swift side (`Sources/VoiceourBench/Qwen3Tokenizer.swift`) ports `src/llama-vocab.cpp:392-399` (the qwen2
pre-tokenizer regex), `src/unicode.cpp:648-782` (`unicode_regex_split_custom_qwen2`) and
`src/llama-vocab.cpp:3788-3807` (`llama_decode_text`), and adds the reference tokenizer's NFC normalizer.

## Adaptations

API and ggml substitutions:

- Built on vendored ggml 0.19. b12606's `ggml_prec_set_acc(cur, GGML_PREC_F32)` on flash attention becomes
  `ggml_flash_attn_ext_set_prec(cur, GGML_PREC_F32)`; `ggml_flash_attn_ext_set_n_kv_max(cur, 0)` (no limit) and
  `ggml_flash_attn_ext_rows` (per-sequence KV rows) do not exist in 0.19 and are dropped: one sequence attends
  to the first `n_kv` cells with a causal mask, upstream's non-rows path. `ggml_build_forward_order` becomes
  `ggml_build_forward_expand` of the embedding rows first. Every other op (`ggml_get_rows` on Q8_0,
  `ggml_rms_norm`, `ggml_mul`, `ggml_rope_ext` NEOX, `ggml_set_rows` into F16, `ggml_flash_attn_ext`,
  `ggml_swiglu_split`, `ggml_add`, `ggml_mul_mat`) exists in 0.19 with the same signature. Metal kernels differ
  between the two ggml versions (b12606 adds `mul_mv_mma`), so logits can differ in the last bits.
- `ggml_backend_dev_caps.mmap_support` does not exist in 0.19: mapping is gated on `caps.buffer_from_host_ptr`.
  The whole GGUF is mapped `PROT_READ`/`MAP_SHARED` and wrapped once; tied output and token embedding are one
  mapped tensor (upstream duplicates it onto the output device). Mapped memory is never written.
- Backends: GPU (Metal) first, accelerators (Accelerate BLAS), then the CPU fallback; weights, KV cache and the
  token embedding all live on the primary backend (upstream keeps the embedding table on the CPU).
- KV cache: F16 K and V, `n_ctx` cells (2048 by default), cell i holds position i. Upstream clears the whole
  buffer at creation and again per request (`llama_memory_clear(data = true)`); here cells are zeroed the first
  time a graph attends to them, which keeps every attended cell finite and leaves untouched cells unallocated.
  Rollback after a rejected draft only moves `n_past`: the next evaluation overwrites those cells and the causal
  mask hides them meanwhile.
- Graphs are rebuilt only when `(n_tokens, n_outputs, n_kv)` changes, as llama.cpp reuses an unchanged graph.
  A non-final prompt ubatch ends its graph after the last layer's K/V store (no output head).
- Logging goes through `qwen3_log_set` (stderr when unset), one line per message prefixed `qwen3: `. Nothing is
  ever written to stdout. ggml's own logger is not touched. No Metal abort callback is installed; the abort
  callback is polled before each graph evaluation.
- Errors: allocation/compute failures map to `QWEN3_ERR_BACKEND`; a malformed or unsupported GGUF fails
  `qwen3_init_from_file` with a logged reason. C++ exceptions never cross the C API.

Behaviour of the generation loop (`qwen3_generate`), from the polish-lab harness:

- Greedy argmax (first maximum) over the whole vocabulary; stop when the EOS (`tokenizer.ggml.eos_token_id`) is
  chosen or `max_new_tokens` are out. Drafting is `common_ngram_simple_draft` with the same pattern, match
  search, minimum and maximum draft length, except that it drafts as soon as the history holds n + 2 tokens:
  upstream waits for n + m + 2, which left short prompts undrafted at large m. The draft is trimmed to the
  remaining output budget, verified with the fed token in one evaluation, and accepted while each draft equals
  the argmax before it, so the output equals undrafted greedy decoding. The default draft length is 24 tokens.
- Voiceour additions: each greedy choice records the runner-up token and both logits (`qwen3_get_decision`), and
  per-call timings count prefill, decode, evaluations, drafted and accepted tokens.
- On arm64, the selector uses NEON maxima to skip blocks that cannot improve the runner-up. It reads the
  same F32 rows, with the same scalar comparisons in token-id order for blocks that may change the result.
- Voiceour's separate `qwen3_generate_guided` API restricts greedy choices to a trie of caller-supplied token
  sequences. EOS is available only at candidate ends. This is a Voiceour experiment, not a llama.cpp guarantee
  about the meaning of candidates. Stepwise and batched execution both stay in the trie. The latter feeds
  forced tokens together, so logits at later branches can differ slightly with evaluation batch size.
- Voiceour's separate `qwen3_generate_with_hint` API borrows one bounded, plain-text draft and proposes
  continuations when it matches the current greedy token or re-aligns with the last two output tokens.
  It uses the same causal batch evaluation and full-vocabulary verification as `qwen3_generate`, with
  n-gram/greedy fallback, and reports external draft tokens fed, compared, and accepted.

Removed upstream features (not reachable from this API): batching several sequences, sampling, LoRA, fused
QKV and bias tensors, rerank/embedding heads, RoPE scaling (YaRN, linear factor != 1), quantized KV types,
state save/load, the chat template, and llama.cpp's first-match FIM/EOT/EOM auto-detection texts (for
`cleanup-1-q8_0.gguf` every such text is already a CONTROL token or absent).

## Model-format expectations

`qwen3_init_from_file` accepts a GGUF only when all of the following hold:

- `general.architecture` = `qwen3`; U32 `qwen3.{block_count, context_length, embedding_length,
  feed_forward_length, attention.head_count}`, optional U32 `qwen3.attention.{head_count_kv, key_length,
  value_length}` and `qwen3.rope.dimension_count` (all three equal), F32 `qwen3.attention.layer_norm_rms_epsilon`,
  optional F32 `qwen3.rope.freq_base`; no RoPE scaling.
- Tokenizer: `tokenizer.ggml.model` = `gpt2`, `tokenizer.ggml.pre` = `qwen2`; string array `tokenizer.ggml.tokens`
  with one entry per `token_embd` row; INT32 `tokenizer.ggml.token_type` of the same length (types 1-6); string
  array `tokenizer.ggml.merges`; U32 `tokenizer.ggml.eos_token_id` inside the vocabulary.
- Tensors: exactly `token_embd.weight`, `output_norm.weight`, optional `output.weight`, and per layer
  `blk.N.{attn_norm, attn_q, attn_k, attn_v, attn_output, attn_q_norm, attn_k_norm, ffn_norm, ffn_gate, ffn_up,
  ffn_down}.weight`, with llama.cpp's shapes. Matrices may be F32, F16, BF16, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q4_K,
  Q5_K or Q6_K; norms are F32.
