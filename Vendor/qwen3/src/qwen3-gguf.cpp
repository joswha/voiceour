// qwen3-gguf.cpp — GGUF metadata, tensor catalog and vocabulary validation for qwen3.
//
// Adapted from llama.cpp (MIT, Copyright (c) 2023-2026 The ggml authors) b12606 at
// e412c6f468b7b9e0f16f2540244236f8ad68e9ae: src/llama-model.cpp (generic hyperparameter keys and defaults),
// src/models/qwen3.cpp (qwen3 hyperparameters and tensor catalog), src/llama-arch.cpp (key and tensor names)
// and src/llama-vocab.cpp (BPE vocabulary load, end-of-generation token override).
// See Vendor/qwen3/LICENSE and Vendor/qwen3/NOTICE.md.
#include "qwen3-impl.h"

#include "gguf.h"

#include <cstdio>
#include <cstring>
#include <initializer_list>

namespace qwen3 {

namespace {

constexpr const char * kArchitecture = "qwen3";

constexpr int32_t kTokenNormal  = 1;
constexpr int32_t kTokenControl = 3;
constexpr int32_t kTokenByte    = 6;

int64_t find_key(const gguf_context * gguf, const char * key, gguf_type type, bool required) {
    const int64_t id = gguf_find_key(gguf, key);
    if (id < 0) {
        if (required) {
            log(QWEN3_LOG_ERROR, "missing GGUF key \"%s\"", key);
        }
        return -1;
    }
    if (gguf_get_kv_type(gguf, id) != type) {
        log(QWEN3_LOG_ERROR, "GGUF key \"%s\" has type %s, expected %s", key,
            gguf_type_name(gguf_get_kv_type(gguf, id)), gguf_type_name(type));
        return -2;
    }
    return id;
}

// U32 key into a positive int32. Optional keys keep `out` when absent.
bool read_u32(const gguf_context * gguf, const char * key, bool required, int32_t & out) {
    const int64_t id = find_key(gguf, key, GGUF_TYPE_UINT32, required);
    if (id == -1 && !required) {
        return true;
    }
    if (id < 0) {
        return false;
    }
    const uint32_t v = gguf_get_val_u32(gguf, id);
    if (v == 0 || v > static_cast<uint32_t>(INT32_MAX)) {
        log(QWEN3_LOG_ERROR, "GGUF key \"%s\" value %u out of range", key, v);
        return false;
    }
    out = static_cast<int32_t>(v);
    return true;
}

bool read_f32(const gguf_context * gguf, const char * key, bool required, float & out) {
    const int64_t id = find_key(gguf, key, GGUF_TYPE_FLOAT32, required);
    if (id == -1 && !required) {
        return true;
    }
    if (id < 0) {
        return false;
    }
    out = gguf_get_val_f32(gguf, id);
    return true;
}

bool expect_string(const gguf_context * gguf, const char * key, const char * expected) {
    const int64_t id = find_key(gguf, key, GGUF_TYPE_STRING, true);
    if (id < 0) {
        return false;
    }
    const char * value = gguf_get_val_str(gguf, id);
    if (std::strcmp(value, expected) != 0) {
        log(QWEN3_LOG_ERROR, "unsupported %s \"%s\" (expected \"%s\")", key, value, expected);
        return false;
    }
    return true;
}

}  // namespace

bool read_hparams(const gguf_context * gguf, HParams & hp) {
    if (!expect_string(gguf, "general.architecture", kArchitecture)) {
        return false;
    }
    if (!read_u32(gguf, "qwen3.block_count", true, hp.n_layer) ||
        !read_u32(gguf, "qwen3.context_length", true, hp.n_ctx_train) ||
        !read_u32(gguf, "qwen3.embedding_length", true, hp.n_embd) ||
        !read_u32(gguf, "qwen3.feed_forward_length", true, hp.n_ff) ||
        !read_u32(gguf, "qwen3.attention.head_count", true, hp.n_head)) {
        return false;
    }
    // llama_model::load_hparams: head_count_kv defaults to head_count, key/value length to n_embd / n_head,
    // the rope dimension count to the key length.
    hp.n_head_kv = hp.n_head;
    if (!read_u32(gguf, "qwen3.attention.head_count_kv", false, hp.n_head_kv)) {
        return false;
    }
    if (hp.n_embd % hp.n_head != 0) {
        log(QWEN3_LOG_ERROR, "embedding_length %d is not a multiple of head_count %d", hp.n_embd, hp.n_head);
        return false;
    }
    int32_t key_length   = hp.n_embd / hp.n_head;
    int32_t value_length = key_length;
    if (!read_u32(gguf, "qwen3.attention.key_length", false, key_length) ||
        !read_u32(gguf, "qwen3.attention.value_length", false, value_length)) {
        return false;
    }
    int32_t n_rot = key_length;
    if (!read_u32(gguf, "qwen3.rope.dimension_count", false, n_rot)) {
        return false;
    }
    // The qwen3 graph asserts n_embd_head_k == n_embd_head_v == n_rot.
    if (key_length != value_length || key_length != n_rot) {
        log(QWEN3_LOG_ERROR, "key_length %d, value_length %d and rope dimension %d must be equal", key_length,
            value_length, n_rot);
        return false;
    }
    hp.n_embd_head = key_length;
    if (hp.n_head % hp.n_head_kv != 0) {
        log(QWEN3_LOG_ERROR, "head_count %d is not a multiple of head_count_kv %d", hp.n_head, hp.n_head_kv);
        return false;
    }
    if (!read_f32(gguf, "qwen3.attention.layer_norm_rms_epsilon", true, hp.rms_eps) ||
        !read_f32(gguf, "qwen3.rope.freq_base", false, hp.rope_base)) {
        return false;
    }
    if (!(hp.rms_eps > 0.0f) || !(hp.rope_base > 0.0f)) {
        log(QWEN3_LOG_ERROR, "layer_norm_rms_epsilon and rope.freq_base must be positive");
        return false;
    }
    // Only unscaled RoPE is ported: llama.cpp's YaRN and linear-scaling paths are not.
    const int64_t scaling = gguf_find_key(gguf, "qwen3.rope.scaling.type");
    if (scaling >= 0) {
        if (gguf_get_kv_type(gguf, scaling) != GGUF_TYPE_STRING ||
            (std::strcmp(gguf_get_val_str(gguf, scaling), "none") != 0 &&
             std::strcmp(gguf_get_val_str(gguf, scaling), "linear") != 0)) {
            log(QWEN3_LOG_ERROR, "unsupported qwen3.rope.scaling.type");
            return false;
        }
    }
    const int64_t factor = gguf_find_key(gguf, "qwen3.rope.scaling.factor");
    if (factor >= 0 && (gguf_get_kv_type(gguf, factor) != GGUF_TYPE_FLOAT32 ||
                        (gguf_get_val_f32(gguf, factor) != 0.0f && gguf_get_val_f32(gguf, factor) != 1.0f))) {
        log(QWEN3_LOG_ERROR, "unsupported qwen3.rope.scaling.factor");
        return false;
    }
    return true;
}

namespace {

enum class Storage { F32, Matrix };

bool type_allowed(Storage storage, ggml_type type) {
    if (storage == Storage::F32) {
        return type == GGML_TYPE_F32;
    }
    switch (type) {
        case GGML_TYPE_F32:
        case GGML_TYPE_F16:
        case GGML_TYPE_BF16:
        case GGML_TYPE_Q4_0:
        case GGML_TYPE_Q4_1:
        case GGML_TYPE_Q5_0:
        case GGML_TYPE_Q5_1:
        case GGML_TYPE_Q8_0:
        case GGML_TYPE_Q4_K:
        case GGML_TYPE_Q5_K:
        case GGML_TYPE_Q6_K:
            return true;
        default:
            return false;
    }
}

// llama_model_loader::create_tensor: name lookup, type allowlist, exact shape, trailing dims == 1.
class Binder {
public:
    explicit Binder(ggml_context * ctx_meta) : ctx_(ctx_meta) {}

    bool ok() const { return ok_; }
    int64_t count() const { return count_; }

    ggml_tensor * get(Storage storage, const char * name, std::initializer_list<int64_t> ne, bool required = true) {
        if (!ok_) {
            return nullptr;
        }
        ggml_tensor * t = ggml_get_tensor(ctx_, name);
        if (t == nullptr) {
            if (required) {
                log(QWEN3_LOG_ERROR, "missing tensor \"%s\"", name);
                return reject();
            }
            return nullptr;
        }
        if (!type_allowed(storage, t->type)) {
            log(QWEN3_LOG_ERROR, "tensor \"%s\" has unsupported type %s", name, ggml_type_name(t->type));
            return reject();
        }
        size_t i = 0;
        for (int64_t expected : ne) {
            if (t->ne[i] != expected) {
                log(QWEN3_LOG_ERROR, "tensor \"%s\" ne[%zu] = %lld, expected %lld", name, i,
                    static_cast<long long>(t->ne[i]), static_cast<long long>(expected));
                return reject();
            }
            ++i;
        }
        for (; i < GGML_MAX_DIMS; ++i) {
            if (t->ne[i] != 1) {
                log(QWEN3_LOG_ERROR, "tensor \"%s\" has unexpected ne[%zu] = %lld", name, i,
                    static_cast<long long>(t->ne[i]));
                return reject();
            }
        }
        ++count_;
        return t;
    }

    ggml_tensor * layer(Storage storage, int index, const char * suffix, std::initializer_list<int64_t> ne) {
        char name[GGML_MAX_NAME];
        std::snprintf(name, sizeof(name), "blk.%d.%s", index, suffix);
        return get(storage, name, ne);
    }

private:
    ggml_tensor * reject() {
        ok_ = false;
        return nullptr;
    }

    ggml_context * ctx_;
    bool           ok_    = true;
    int64_t        count_ = 0;
};

}  // namespace

bool bind_weights(const gguf_context * gguf, ggml_context * ctx_meta, HParams & hp, Weights & w) {
    ggml_tensor * embd = ggml_get_tensor(ctx_meta, "token_embd.weight");
    if (embd == nullptr) {
        log(QWEN3_LOG_ERROR, "missing tensor \"token_embd.weight\"");
        return false;
    }
    if (embd->ne[1] <= 0 || embd->ne[1] > INT32_MAX) {
        log(QWEN3_LOG_ERROR, "token_embd.weight has %lld rows", static_cast<long long>(embd->ne[1]));
        return false;
    }
    hp.n_vocab = static_cast<int32_t>(embd->ne[1]);

    const int64_t n_embd   = hp.n_embd;
    const int64_t n_vocab  = hp.n_vocab;
    const int64_t n_embd_q = static_cast<int64_t>(hp.n_embd_head) * hp.n_head;
    const int64_t n_embd_k = static_cast<int64_t>(hp.n_embd_head) * hp.n_head_kv;
    const int64_t n_ff     = hp.n_ff;

    Binder b(ctx_meta);
    w.tok_embd    = b.get(Storage::Matrix, "token_embd.weight", { n_embd, n_vocab });
    w.output_norm = b.get(Storage::F32, "output_norm.weight", { n_embd });
    w.output      = b.get(Storage::Matrix, "output.weight", { n_embd, n_vocab }, /*required=*/false);
    if (w.output == nullptr) {
        w.output = w.tok_embd;  // tied embeddings (TENSOR_DUPLICATED upstream; one mapped tensor here)
    }
    w.layers.assign(static_cast<size_t>(hp.n_layer), Layer());
    for (int i = 0; i < hp.n_layer && b.ok(); ++i) {
        Layer & l      = w.layers[static_cast<size_t>(i)];
        l.attn_norm    = b.layer(Storage::F32, i, "attn_norm.weight", { n_embd });
        l.wq           = b.layer(Storage::Matrix, i, "attn_q.weight", { n_embd, n_embd_q });
        l.wk           = b.layer(Storage::Matrix, i, "attn_k.weight", { n_embd, n_embd_k });
        l.wv           = b.layer(Storage::Matrix, i, "attn_v.weight", { n_embd, n_embd_k });
        l.wo           = b.layer(Storage::Matrix, i, "attn_output.weight", { n_embd_q, n_embd });
        l.attn_k_norm  = b.layer(Storage::F32, i, "attn_k_norm.weight", { hp.n_embd_head });
        l.attn_q_norm  = b.layer(Storage::F32, i, "attn_q_norm.weight", { hp.n_embd_head });
        l.ffn_norm     = b.layer(Storage::F32, i, "ffn_norm.weight", { n_embd });
        l.ffn_gate     = b.layer(Storage::Matrix, i, "ffn_gate.weight", { n_embd, n_ff });
        l.ffn_down     = b.layer(Storage::Matrix, i, "ffn_down.weight", { n_ff, n_embd });
        l.ffn_up       = b.layer(Storage::Matrix, i, "ffn_up.weight", { n_embd, n_ff });
    }
    if (!b.ok()) {
        return false;
    }
    // Fused QKV, biases, rerank/embedding heads and LoRA tensors are not ported: refuse any tensor not bound.
    const int64_t n_tensors = gguf_get_n_tensors(gguf);
    if (n_tensors != b.count()) {
        log(QWEN3_LOG_ERROR, "GGUF has %lld tensors, expected %lld", static_cast<long long>(n_tensors),
            static_cast<long long>(b.count()));
        return false;
    }
    return true;
}

namespace {

// llama_vocab::impl::load: texts that make a token end generation, and the CONTROL type such a token gets when
// the GGUF stored it as a non-control type. "</s>" stays a normal token when "<|tool_response>" or
// "<|plamo:eos|>" also ends generation.
const char * const kEndOfGenerationTexts[] = {
    "<|eot_id|>", "<|eot|>", "<|im_end|>", "<|end|>", "<|return|>", "<|call|>", "<|flush|>", "<|calls|>",
    "<end_of_turn>", "<|endoftext|>", "</s>", "<|eom_id|>", "<EOT>", "_<EOT>", "[EOT]", "[EOS]", "<|end_of_text|>",
    "<end_of_utterance>", "<eos>", "<turn|>", "<|tool_response>", "<｜end▁of▁sentence｜>", "[e~[",
    "<|ifm|im_end|>",
};

bool is_end_of_generation_text(const std::string & piece) {
    for (const char * text : kEndOfGenerationTexts) {
        if (piece == text) {
            return true;
        }
    }
    return false;
}

}  // namespace

bool load_vocab(const gguf_context * gguf, Vocab & vocab) {
    if (!expect_string(gguf, "tokenizer.ggml.model", "gpt2") || !expect_string(gguf, "tokenizer.ggml.pre", "qwen2")) {
        return false;
    }

    const int64_t tokens_id = find_key(gguf, "tokenizer.ggml.tokens", GGUF_TYPE_ARRAY, true);
    if (tokens_id < 0) {
        return false;
    }
    if (gguf_get_arr_type(gguf, tokens_id) != GGUF_TYPE_STRING || gguf_get_arr_n(gguf, tokens_id) == 0 ||
        gguf_get_arr_n(gguf, tokens_id) > static_cast<size_t>(INT32_MAX)) {
        log(QWEN3_LOG_ERROR, "tokenizer.ggml.tokens must be a non-empty string array");
        return false;
    }
    const size_t n = gguf_get_arr_n(gguf, tokens_id);

    const int64_t types_id = find_key(gguf, "tokenizer.ggml.token_type", GGUF_TYPE_ARRAY, true);
    if (types_id < 0) {
        return false;
    }
    if (gguf_get_arr_type(gguf, types_id) != GGUF_TYPE_INT32 || gguf_get_arr_n(gguf, types_id) != n) {
        log(QWEN3_LOG_ERROR, "tokenizer.ggml.token_type must be an INT32 array with one entry per token");
        return false;
    }
    const int32_t * types = static_cast<const int32_t *>(gguf_get_arr_data(gguf, types_id));

    vocab.pieces.assign(n, std::string());
    vocab.types.assign(n, 0);
    bool    s_marker = false;
    int64_t s_id     = -1;
    for (size_t i = 0; i < n; ++i) {
        vocab.pieces[i] = gguf_get_arr_str(gguf, tokens_id, i);
        const int32_t t = types[i];
        if (t < kTokenNormal || t > kTokenByte) {
            log(QWEN3_LOG_ERROR, "token %zu has unknown type %d", i, t);
            return false;
        }
        vocab.types[i] = t;
        if (is_end_of_generation_text(vocab.pieces[i])) {
            vocab.types[i] = kTokenControl;
            if (vocab.pieces[i] == "</s>") {
                s_id = static_cast<int64_t>(i);
            }
            if (vocab.pieces[i] == "<|tool_response>") {
                s_marker = true;
            }
        }
        if (vocab.pieces[i] == "<|plamo:eos|>") {
            s_marker = true;
        }
    }
    if (s_marker && s_id >= 0) {
        vocab.types[static_cast<size_t>(s_id)] = kTokenNormal;
    }

    const int64_t merges_id = find_key(gguf, "tokenizer.ggml.merges", GGUF_TYPE_ARRAY, true);
    if (merges_id < 0) {
        return false;
    }
    if (gguf_get_arr_type(gguf, merges_id) != GGUF_TYPE_STRING ||
        gguf_get_arr_n(gguf, merges_id) > static_cast<size_t>(INT32_MAX)) {
        log(QWEN3_LOG_ERROR, "tokenizer.ggml.merges must be a string array");
        return false;
    }
    const size_t n_merges = gguf_get_arr_n(gguf, merges_id);
    vocab.merges.clear();
    vocab.merges.reserve(n_merges);
    for (size_t i = 0; i < n_merges; ++i) {
        vocab.merges.emplace_back(gguf_get_arr_str(gguf, merges_id, i));
    }

    const int64_t eos_id = find_key(gguf, "tokenizer.ggml.eos_token_id", GGUF_TYPE_UINT32, true);
    if (eos_id < 0) {
        return false;
    }
    const uint32_t eos = gguf_get_val_u32(gguf, eos_id);
    if (eos >= n) {
        log(QWEN3_LOG_ERROR, "tokenizer.ggml.eos_token_id %u is outside the vocabulary", eos);
        return false;
    }
    vocab.eos_id = static_cast<int32_t>(eos);
    return true;
}

}  // namespace qwen3
