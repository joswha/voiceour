// qwen3-impl.h — internal types shared by the CQwen3 translation units.
//
// Adapted from llama.cpp (MIT, Copyright (c) 2023-2026 The ggml authors) b12606 at
// e412c6f468b7b9e0f16f2540244236f8ad68e9ae: src/llama-hparams.h (hyperparameters), src/llama-model.h (layer
// weight slots), src/llama-kv-cache.h (per-layer K/V tensors). See Vendor/qwen3/LICENSE and
// Vendor/qwen3/NOTICE.md.
#ifndef QWEN3_IMPL_H
#define QWEN3_IMPL_H

#include "qwen3.h"

#include "ggml-backend.h"
#include "ggml.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

struct gguf_context;

namespace qwen3 {

void log(qwen3_log_level level, const char * fmt, ...) __attribute__((format(printf, 2, 3)));

// Architecture hyperparameters read from the GGUF (llama_hparams, the subset qwen3 uses).
struct HParams {
    int32_t n_layer     = 0;
    int32_t n_embd      = 0;
    int32_t n_ff        = 0;
    int32_t n_head      = 0;
    int32_t n_head_kv   = 0;
    int32_t n_embd_head = 0;  // key_length == value_length == rope dimension count
    int32_t n_ctx_train = 0;  // qwen3.context_length: RoPE's n_ctx_orig
    int32_t n_vocab     = 0;  // token_embd rows
    float   rms_eps     = 0.0f;
    float   rope_base   = 10000.0f;
};

struct Layer {
    ggml_tensor * attn_norm   = nullptr;
    ggml_tensor * wq          = nullptr;
    ggml_tensor * wk          = nullptr;
    ggml_tensor * wv          = nullptr;
    ggml_tensor * wo          = nullptr;
    ggml_tensor * attn_q_norm = nullptr;
    ggml_tensor * attn_k_norm = nullptr;
    ggml_tensor * ffn_norm    = nullptr;
    ggml_tensor * ffn_gate    = nullptr;
    ggml_tensor * ffn_up      = nullptr;
    ggml_tensor * ffn_down    = nullptr;
};

struct Weights {
    ggml_tensor *      tok_embd    = nullptr;
    ggml_tensor *      output_norm = nullptr;
    ggml_tensor *      output      = nullptr;  // tok_embd when the GGUF has no output.weight (tied embeddings)
    std::vector<Layer> layers;
};

// Vocabulary as stored, plus the types after llama.cpp's end-of-generation override.
struct Vocab {
    std::vector<std::string> pieces;
    std::vector<int32_t>     types;
    std::vector<std::string> merges;
    int32_t                  eos_id = -1;
};

// Validates every key the forward pass depends on; logs and returns false on the first violation.
bool read_hparams(const gguf_context * gguf, HParams & hp);

// Binds and validates all tensors (names, types, shapes, exact count) and fills hp.n_vocab.
bool bind_weights(const gguf_context * gguf, ggml_context * ctx_meta, HParams & hp, Weights & w);

// Loads tokenizer.ggml.{model,pre,tokens,token_type,merges,eos_token_id}.
bool load_vocab(const gguf_context * gguf, Vocab & vocab);

// One F16 K and V tensor per layer, [n_embd_head * n_head_kv, n_ctx]; cell i holds position i.
struct KVCache {
    std::vector<ggml_tensor *> k;
    std::vector<ggml_tensor *> v;
    int32_t                    n_ctx = 0;
};

// A built graph and its inputs. Rebuilt whenever (n_tokens, n_outputs, n_kv) changes; otherwise only the
// inputs are rewritten, as llama.cpp reuses an unchanged graph.
struct Graph {
    ggml_cgraph * gf       = nullptr;
    ggml_tensor * tokens   = nullptr;  // I32 [n_tokens]
    ggml_tensor * pos      = nullptr;  // I32 [n_tokens]
    ggml_tensor * kv_idxs  = nullptr;  // I64 [n_tokens], the cache cells written (== positions)
    ggml_tensor * kq_mask  = nullptr;  // F16 [n_kv, n_tokens]
    ggml_tensor * out_ids  = nullptr;  // I32 [n_outputs]; NULL when n_outputs == 0
    ggml_tensor * logits   = nullptr;  // F32 [n_vocab, n_outputs]; NULL when n_outputs == 0
    int32_t       n_tokens  = 0;
    int32_t       n_outputs = 0;
    int32_t       n_kv      = 0;
};

// Size of the no_alloc metadata context a graph is built in.
size_t graph_context_size();

// Builds the qwen3 forward pass for n_tokens tokens attending to the first n_kv cache cells, storing their K/V,
// producing logits for n_outputs rows selected by out_ids (none, and no output head, when n_outputs == 0).
bool build_graph(ggml_context * ctx, const HParams & hp, const Weights & w, const KVCache & kv, int32_t n_tokens,
                 int32_t n_outputs, int32_t n_kv, Graph & out);

}  // namespace qwen3

#endif  // QWEN3_IMPL_H
