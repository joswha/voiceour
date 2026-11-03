// granite-gguf.cpp — GGUF metadata, tensor catalog and vocabulary validation for granite_speech5_ctc.
//
// Adapted from transcribe.cpp (MIT, Copyright (c) 2026 The transcribe.cpp authors) at
// 5700f127e38dd53c4735ea23ef743b4b538eacd4: src/arch/granite5_ctc/weights.cpp,
// src/transcribe-weights-util.cpp, src/transcribe-meta.cpp (typed KV reads),
// src/transcribe-tokenizer.cpp (load + decode) and src/transcribe-unicode.cpp (GPT-2 byte map).
// See Vendor/granite/LICENSE and Vendor/granite/NOTICE.md.
#include "granite-impl.h"

#include "gguf.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <initializer_list>

namespace granite {

namespace {

constexpr const char * kArchitecture = "granite_speech5_ctc";

// Tokenizer token types (llama.cpp / transcribe.cpp numbering).
constexpr int32_t kTokenUnknown = 2;
constexpr int32_t kTokenControl = 3;
constexpr int32_t kTokenUser    = 4;

int64_t find_key(const gguf_context * gguf, const char * key, gguf_type type, bool required) {
    const int64_t id = gguf_find_key(gguf, key);
    if (id < 0) {
        if (required) {
            log(GRANITE_LOG_ERROR, "missing GGUF key \"%s\"", key);
        }
        return -1;
    }
    if (gguf_get_kv_type(gguf, id) != type) {
        log(GRANITE_LOG_ERROR, "GGUF key \"%s\" has type %s, expected %s", key,
            gguf_type_name(gguf_get_kv_type(gguf, id)), gguf_type_name(type));
        return -2;
    }
    return id;
}

bool read_u32(const gguf_context * gguf, const char * key, int32_t & out) {
    const int64_t id = find_key(gguf, key, GGUF_TYPE_UINT32, true);
    if (id < 0) {
        return false;
    }
    const uint32_t v = gguf_get_val_u32(gguf, id);
    if (v > static_cast<uint32_t>(INT32_MAX)) {
        log(GRANITE_LOG_ERROR, "GGUF key \"%s\" value %u out of range", key, v);
        return false;
    }
    out = static_cast<int32_t>(v);
    return true;
}

bool read_f32(const gguf_context * gguf, const char * key, float & out) {
    const int64_t id = find_key(gguf, key, GGUF_TYPE_FLOAT32, true);
    if (id < 0) {
        return false;
    }
    out = gguf_get_val_f32(gguf, id);
    return true;
}

bool read_string(const gguf_context * gguf, const char * key, bool required, const char * fallback, std::string & out) {
    const int64_t id = find_key(gguf, key, GGUF_TYPE_STRING, required);
    if (id == -1 && !required) {
        out = fallback;
        return true;
    }
    if (id < 0) {
        return false;
    }
    out = gguf_get_val_str(gguf, id);
    return true;
}

bool read_bool(const gguf_context * gguf, const char * key, bool fallback, bool & out) {
    const int64_t id = find_key(gguf, key, GGUF_TYPE_BOOL, false);
    if (id == -1) {
        out = fallback;
        return true;
    }
    if (id < 0) {
        return false;
    }
    out = gguf_get_val_bool(gguf, id);
    return true;
}

bool expect_string(const gguf_context * gguf, const char * key, const char * fallback, const char * expected) {
    std::string value;
    if (!read_string(gguf, key, fallback == nullptr, fallback, value)) {
        return false;
    }
    if (value != expected) {
        log(GRANITE_LOG_ERROR, "unsupported %s \"%s\" (expected \"%s\")", key, value.c_str(), expected);
        return false;
    }
    return true;
}

}  // namespace

bool read_hparams(const gguf_context * gguf, HParams & hp) {
    if (!expect_string(gguf, "general.architecture", nullptr, kArchitecture)) {
        return false;
    }

    const struct {
        const char * key;
        int32_t *    slot;
    } u32_fields[] = {
        { "stt.granite5_ctc.encoder.n_layers",         &hp.n_layers         },
        { "stt.granite5_ctc.encoder.hidden",           &hp.hidden           },
        { "stt.granite5_ctc.encoder.n_heads",          &hp.n_heads          },
        { "stt.granite5_ctc.encoder.head_dim",         &hp.head_dim         },
        { "stt.granite5_ctc.encoder.intermediate",     &hp.intermediate     },
        { "stt.granite5_ctc.encoder.input_dim",        &hp.input_dim        },
        { "stt.granite5_ctc.encoder.output_dim",       &hp.output_dim       },
        { "stt.granite5_ctc.encoder.conv_kernel_size", &hp.conv_kernel      },
        { "stt.granite5_ctc.encoder.conv_expansion",   &hp.conv_expansion   },
        { "stt.granite5_ctc.encoder.context_size",     &hp.context_size     },
        { "stt.granite5_ctc.encoder.max_pos_emb",      &hp.max_pos_emb      },
        { "stt.granite5_ctc.encoder.self_cond_layer",  &hp.self_cond_layer  },
        { "stt.granite5_ctc.blank_id",                 &hp.blank_id         },
        { "stt.frontend.sample_rate",                  &hp.sample_rate      },
        { "stt.frontend.num_mels",                     &hp.num_mels         },
        { "stt.frontend.n_fft",                        &hp.n_fft            },
        { "stt.frontend.win_length",                   &hp.win_length       },
        { "stt.frontend.hop_length",                   &hp.hop_length       },
        { "stt.frontend.delta_win_length",             &hp.delta_win_length },
        { "stt.frontend.stack_factor",                 &hp.stack_factor     },
    };
    for (const auto & f : u32_fields) {
        if (!read_u32(gguf, f.key, *f.slot)) {
            return false;
        }
    }

    // Optional INT32 array; absence means no in-block subsampling (upstream read_int32_array_kv).
    hp.subsample_layers.clear();
    {
        const char *  key = "stt.granite5_ctc.encoder.subsample_layers";
        const int64_t id  = find_key(gguf, key, GGUF_TYPE_ARRAY, false);
        if (id == -2) {
            return false;
        }
        if (id >= 0) {
            if (gguf_get_arr_type(gguf, id) != GGUF_TYPE_INT32) {
                log(GRANITE_LOG_ERROR, "GGUF key \"%s\" must be an INT32 array", key);
                return false;
            }
            const size_t    n    = gguf_get_arr_n(gguf, id);
            const int32_t * data = static_cast<const int32_t *>(gguf_get_arr_data(gguf, id));
            hp.subsample_layers.assign(data, data + n);
        }
    }
    std::sort(hp.subsample_layers.begin(), hp.subsample_layers.end());
    for (int32_t idx : hp.subsample_layers) {
        if (idx < 0 || idx >= hp.n_layers) {
            log(GRANITE_LOG_ERROR, "subsample_layers entry %d out of range [0, %d)", idx, hp.n_layers);
            return false;
        }
    }

    if (!expect_string(gguf, "stt.frontend.type", nullptr, "mel") ||
        !expect_string(gguf, "stt.frontend.window", nullptr, "hann_periodic") ||
        !expect_string(gguf, "stt.frontend.normalize", nullptr, "per_utterance") ||
        !expect_string(gguf, "stt.frontend.pad_mode", "reflect", "reflect") ||
        !expect_string(gguf, "stt.frontend.mel_norm", "htk", "htk")) {
        return false;
    }
    // Read for type validation; the frontend never dithers and hard-codes the 8 (log10) floor, as upstream.
    float dither = 0.0f;
    float floor_db = 0.0f;
    if (!read_f32(gguf, "stt.frontend.dither", dither) || !read_f32(gguf, "stt.frontend.logmel_floor_db", floor_db)) {
        return false;
    }
    if (!read_bool(gguf, "stt.frontend.deltas", true, hp.deltas)) {
        return false;
    }

    // Invariants: each is silently load-bearing, so fail at load rather than mis-transcribe.
    if (hp.stack_factor != 2) {
        log(GRANITE_LOG_ERROR, "unsupported frontend stack_factor %d (only 2)", hp.stack_factor);
        return false;
    }
    if (hp.delta_win_length != 3) {
        log(GRANITE_LOG_ERROR, "unsupported frontend delta_win_length %d (only 3)", hp.delta_win_length);
        return false;
    }
    if (hp.n_fft <= 0 || (hp.n_fft & (hp.n_fft - 1)) != 0) {
        log(GRANITE_LOG_ERROR, "frontend n_fft %d is not a power of two", hp.n_fft);
        return false;
    }
    if (hp.win_length <= 0 || hp.win_length > hp.n_fft || hp.hop_length <= 0 || hp.num_mels <= 0 ||
        hp.sample_rate <= 0) {
        log(GRANITE_LOG_ERROR, "invalid frontend geometry (win %d, hop %d, mels %d, rate %d)", hp.win_length,
            hp.hop_length, hp.num_mels, hp.sample_rate);
        return false;
    }
    {
        const int32_t mel_ch = hp.num_mels * (hp.deltas ? 2 : 1);
        if (mel_ch * hp.stack_factor != hp.input_dim) {
            log(GRANITE_LOG_ERROR, "frontend produces %d features but encoder.input_dim is %d",
                mel_ch * hp.stack_factor, hp.input_dim);
            return false;
        }
    }
    if (hp.conv_kernel % 2 == 0) {
        log(GRANITE_LOG_ERROR, "conv_kernel_size %d is even; SAME padding requires an odd kernel", hp.conv_kernel);
        return false;
    }
    if (hp.context_size <= 0 || hp.max_pos_emb < hp.context_size) {
        log(GRANITE_LOG_ERROR, "invalid attention geometry (context %d, max_pos_emb %d)", hp.context_size,
            hp.max_pos_emb);
        return false;
    }
    if (hp.n_layers <= 0 || hp.hidden <= 0 || hp.n_heads <= 0 || hp.head_dim <= 0 || hp.intermediate <= 0 ||
        hp.output_dim <= 0 || hp.conv_expansion <= 0) {
        log(GRANITE_LOG_ERROR, "invalid encoder dimensions");
        return false;
    }
    if (static_cast<int64_t>(hp.n_heads) * hp.head_dim != hp.hidden) {
        log(GRANITE_LOG_ERROR, "n_heads x head_dim (%d x %d) != hidden %d", hp.n_heads, hp.head_dim, hp.hidden);
        return false;
    }
    if (hp.self_cond_layer < 0 || hp.self_cond_layer > hp.n_layers) {
        log(GRANITE_LOG_ERROR, "self_cond_layer %d out of range [0, %d]", hp.self_cond_layer, hp.n_layers);
        return false;
    }
    if (hp.blank_id < 0 || hp.blank_id >= hp.output_dim) {
        log(GRANITE_LOG_ERROR, "blank_id %d out of range [0, %d)", hp.blank_id, hp.output_dim);
        return false;
    }
    return true;
}

namespace {

enum class Storage { F32, Linear, Conv };

bool type_allowed(Storage storage, ggml_type type) {
    switch (storage) {
        case Storage::F32:
            return type == GGML_TYPE_F32;
        case Storage::Conv:
            return type == GGML_TYPE_F32 || type == GGML_TYPE_F16;
        case Storage::Linear:
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
    return false;
}

// Upstream transcribe::weights::find_tensor: name lookup, dtype allowlist, exact shape, trailing dims == 1.
class Binder {
public:
    explicit Binder(ggml_context * ctx_meta) : ctx_(ctx_meta) {}

    bool ok() const { return ok_; }
    int64_t count() const { return count_; }

    ggml_tensor * get(Storage storage, const char * name, std::initializer_list<int64_t> ne) {
        if (!ok_) {
            return nullptr;
        }
        ggml_tensor * t = ggml_get_tensor(ctx_, name);
        if (t == nullptr) {
            log(GRANITE_LOG_ERROR, "missing tensor \"%s\"", name);
            return reject();
        }
        if (!type_allowed(storage, t->type)) {
            log(GRANITE_LOG_ERROR, "tensor \"%s\" has unsupported type %s", name, ggml_type_name(t->type));
            return reject();
        }
        size_t i = 0;
        for (int64_t expected : ne) {
            if (t->ne[i] != expected) {
                log(GRANITE_LOG_ERROR, "tensor \"%s\" ne[%zu] = %lld, expected %lld", name, i,
                    static_cast<long long>(t->ne[i]), static_cast<long long>(expected));
                return reject();
            }
            ++i;
        }
        for (; i < GGML_MAX_DIMS; ++i) {
            if (t->ne[i] != 1) {
                log(GRANITE_LOG_ERROR, "tensor \"%s\" has unexpected ne[%zu] = %lld", name, i,
                    static_cast<long long>(t->ne[i]));
                return reject();
            }
        }
        ++count_;
        return t;
    }

    ggml_tensor * block(Storage storage, int index, const char * suffix, std::initializer_list<int64_t> ne) {
        char name[GGML_MAX_NAME];
        std::snprintf(name, sizeof(name), "enc.blocks.%d.%s", index, suffix);
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

bool bind_weights(const gguf_context * gguf, ggml_context * ctx_meta, const HParams & hp, Weights & w) {
    const int64_t h          = hp.hidden;
    const int64_t in         = hp.input_dim;
    const int64_t vocab      = hp.output_dim;
    const int64_t inner      = static_cast<int64_t>(hp.n_heads) * hp.head_dim;
    const int64_t ffn        = hp.intermediate;
    const int64_t conv_inner = h * hp.conv_expansion;
    const int64_t conv_k     = hp.conv_kernel;
    const int64_t rel_len    = 2LL * hp.max_pos_emb + 1;
    const int64_t n_freq     = hp.n_fft / 2 + 1;

    Binder b(ctx_meta);
    w.input_linear_w = b.get(Storage::Linear, "enc.input_linear.weight", { in, h });
    w.input_linear_b = b.get(Storage::F32, "enc.input_linear.bias", { h });
    w.ctc_proj_w     = b.get(Storage::Linear, "enc.ctc_proj.weight", { h, vocab });
    w.ctc_proj_b     = b.get(Storage::F32, "enc.ctc_proj.bias", { vocab });
    w.ctc_bypass_w   = b.get(Storage::Linear, "enc.ctc_bypass.weight", { vocab, h });
    w.ctc_bypass_b   = b.get(Storage::F32, "enc.ctc_bypass.bias", { h });

    w.blocks.assign(static_cast<size_t>(hp.n_layers), Block{});
    for (int i = 0; i < hp.n_layers; ++i) {
        Block & k = w.blocks[static_cast<size_t>(i)];

        k.norm_ff1_w = b.block(Storage::F32, i, "norm_ff1.weight", { h });
        k.norm_ff1_b = b.block(Storage::F32, i, "norm_ff1.bias", { h });
        k.ff1_lin1_w = b.block(Storage::Linear, i, "ff1.linear1.weight", { h, ffn });
        k.ff1_lin1_b = b.block(Storage::F32, i, "ff1.linear1.bias", { ffn });
        k.ff1_lin2_w = b.block(Storage::Linear, i, "ff1.linear2.weight", { ffn, h });
        k.ff1_lin2_b = b.block(Storage::F32, i, "ff1.linear2.bias", { h });

        k.norm_attn_w  = b.block(Storage::F32, i, "norm_attn.weight", { h });
        k.norm_attn_b  = b.block(Storage::F32, i, "norm_attn.bias", { h });
        k.attn_q_w     = b.block(Storage::Linear, i, "attn.q.weight", { h, inner });
        k.attn_kv_w    = b.block(Storage::Linear, i, "attn.kv.weight", { h, 2 * inner });
        k.attn_out_w   = b.block(Storage::Linear, i, "attn.out.weight", { inner, h });
        k.attn_out_b   = b.block(Storage::F32, i, "attn.out.bias", { h });
        k.attn_rel_pos = b.block(Storage::Linear, i, "attn.rel_pos_emb.weight", { hp.head_dim, rel_len });

        k.norm_conv_w       = b.block(Storage::F32, i, "norm_conv.weight", { h });
        k.norm_conv_b       = b.block(Storage::F32, i, "norm_conv.bias", { h });
        k.conv_pointwise1_w = b.block(Storage::Linear, i, "conv.pointwise1.weight", { h, 2 * conv_inner });
        k.conv_pointwise1_b = b.block(Storage::F32, i, "conv.pointwise1.bias", { 2 * conv_inner });
        k.conv_depthwise_w  = b.block(Storage::Conv, i, "conv.depthwise.weight", { conv_k, 1, conv_inner });
        k.conv_bn_w         = b.block(Storage::F32, i, "conv.bn.weight", { conv_inner });
        k.conv_bn_b         = b.block(Storage::F32, i, "conv.bn.bias", { conv_inner });
        k.conv_bn_mean      = b.block(Storage::F32, i, "conv.bn.running_mean", { conv_inner });
        k.conv_bn_var       = b.block(Storage::F32, i, "conv.bn.running_var", { conv_inner });
        k.conv_pointwise2_w = b.block(Storage::Linear, i, "conv.pointwise2.weight", { conv_inner, h });
        k.conv_pointwise2_b = b.block(Storage::F32, i, "conv.pointwise2.bias", { h });

        k.norm_ff2_w = b.block(Storage::F32, i, "norm_ff2.weight", { h });
        k.norm_ff2_b = b.block(Storage::F32, i, "norm_ff2.bias", { h });
        k.ff2_lin1_w = b.block(Storage::Linear, i, "ff2.linear1.weight", { h, ffn });
        k.ff2_lin1_b = b.block(Storage::F32, i, "ff2.linear1.bias", { ffn });
        k.ff2_lin2_w = b.block(Storage::Linear, i, "ff2.linear2.weight", { ffn, h });
        k.ff2_lin2_b = b.block(Storage::F32, i, "ff2.linear2.bias", { h });

        k.norm_out_w = b.block(Storage::F32, i, "norm_out.weight", { h });
        k.norm_out_b = b.block(Storage::F32, i, "norm_out.bias", { h });
    }

    // Baked torchaudio HTK filterbank ([mel][freq] row-major) and periodic Hann window: required.
    w.mel_filterbank = b.get(Storage::F32, "frontend.mel_filterbank", { n_freq, hp.num_mels });
    w.window         = b.get(Storage::F32, "frontend.window", { hp.win_length });

    if (!b.ok()) {
        return false;
    }
    // Names are unique in a GGUF, so an equal count means the file holds exactly this catalog.
    const int64_t n_file = gguf_get_n_tensors(gguf);
    if (n_file != b.count()) {
        log(GRANITE_LOG_ERROR, "GGUF holds %lld tensors, expected exactly %lld", static_cast<long long>(n_file),
            static_cast<long long>(b.count()));
        return false;
    }
    return true;
}

namespace {

// Upstream transcribe::unicode byte map (GPT-2 bytes_to_unicode): inverse codepoint -> byte, -1 if unmapped.
struct Gpt2ByteMap {
    int16_t inverse[256 + 256];

    Gpt2ByteMap() {
        for (int16_t & v : inverse) {
            v = -1;
        }
        int n = 0;
        for (int b = 0; b < 256; ++b) {
            const bool visible = (b >= '!' && b <= '~') || (b >= 0xA1 && b <= 0xAC) || (b >= 0xAE && b <= 0xFF);
            if (visible) {
                inverse[b] = static_cast<int16_t>(b);
            } else {
                inverse[256 + n] = static_cast<int16_t>(b);
                ++n;
            }
        }
    }
};

// Upstream unicode::len_utf8: lead-byte classifier; continuation bytes advance by one.
size_t len_utf8(unsigned char c) {
    static const size_t lookup[16] = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 3, 4 };
    return lookup[c >> 4];
}

// Upstream unicode_to_byte(cpt_from_utf8(...)): -1 for malformed, multi-codepoint or unmapped input.
int gpt2_unicode_to_byte(const Gpt2ByteMap & map, const unsigned char * s, size_t n) {
    if (n == 0) {
        return -1;
    }
    uint32_t c    = 0;
    size_t   used = 0;
    const unsigned char b0 = s[0];
    auto cont = [&](size_t i) { return i < n && (s[i] & 0xC0u) == 0x80u; };
    if ((b0 & 0x80u) == 0) {
        c    = b0;
        used = 1;
    } else if ((b0 & 0xE0u) == 0xC0u) {
        if (!cont(1)) {
            return -1;
        }
        c    = (static_cast<uint32_t>(b0 & 0x1Fu) << 6) | (s[1] & 0x3Fu);
        used = 2;
    } else if ((b0 & 0xF0u) == 0xE0u) {
        if (!cont(1) || !cont(2)) {
            return -1;
        }
        c    = (static_cast<uint32_t>(b0 & 0x0Fu) << 12) | (static_cast<uint32_t>(s[1] & 0x3Fu) << 6) | (s[2] & 0x3Fu);
        used = 3;
    } else if ((b0 & 0xF8u) == 0xF0u) {
        if (!cont(1) || !cont(2) || !cont(3)) {
            return -1;
        }
        c = (static_cast<uint32_t>(b0 & 0x07u) << 18) | (static_cast<uint32_t>(s[1] & 0x3Fu) << 12) |
            (static_cast<uint32_t>(s[2] & 0x3Fu) << 6) | (s[3] & 0x3Fu);
        used = 4;
    } else {
        return -1;
    }
    if (used != n || c >= 512) {
        return -1;
    }
    return map.inverse[c];
}

std::string decode_gpt2_piece(const Gpt2ByteMap & map, const std::string & piece) {
    std::string out;
    out.reserve(piece.size());
    const auto * p = reinterpret_cast<const unsigned char *>(piece.data());
    size_t       j = 0;
    while (j < piece.size()) {
        const size_t w    = std::min(piece.size() - j, len_utf8(p[j]));
        const int    byte = gpt2_unicode_to_byte(map, p + j, w);
        if (byte >= 0) {
            out.push_back(static_cast<char>(byte));
        } else {
            out.append(piece, j, w);  // not a byte-level glyph: pass the raw UTF-8 through
        }
        j += w;
    }
    return out;
}

int hex_nibble(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'A' && c <= 'F') {
        return 10 + (c - 'A');
    }
    if (c >= 'a' && c <= 'f') {
        return 10 + (c - 'a');
    }
    return -1;
}

// Upstream decode_sentencepiece for one id: <0xHH> byte fallback, U+2581 -> ' ', other bytes verbatim.
std::string decode_sentencepiece_piece(const std::string & p) {
    if (p.size() == 6 && p[0] == '<' && p[1] == '0' && p[2] == 'x' && p[5] == '>') {
        const int hi = hex_nibble(p[3]);
        const int lo = hex_nibble(p[4]);
        if (hi >= 0 && lo >= 0) {
            return std::string(1, static_cast<char>((hi << 4) | lo));
        }
    }
    static const char kSpace[] = "\xE2\x96\x81";
    std::string       out;
    out.reserve(p.size());
    size_t j = 0;
    while (j < p.size()) {
        if (j + 3 <= p.size() && std::memcmp(p.data() + j, kSpace, 3) == 0) {
            out.push_back(' ');
            j += 3;
        } else {
            out.push_back(p[j]);
            ++j;
        }
    }
    return out;
}

}  // namespace

bool load_vocab(const gguf_context * gguf, Vocab & vocab) {
    std::string model;
    if (!read_string(gguf, "tokenizer.ggml.model", true, "", model)) {
        return false;
    }
    const bool gpt2 = (model == "gpt2");
    if (!gpt2 && model != "bpe") {
        log(GRANITE_LOG_ERROR, "unsupported tokenizer.ggml.model \"%s\" (expected \"bpe\" or \"gpt2\")", model.c_str());
        return false;
    }

    const int64_t tokens_id = find_key(gguf, "tokenizer.ggml.tokens", GGUF_TYPE_ARRAY, true);
    if (tokens_id < 0) {
        return false;
    }
    if (gguf_get_arr_type(gguf, tokens_id) != GGUF_TYPE_STRING || gguf_get_arr_n(gguf, tokens_id) == 0) {
        log(GRANITE_LOG_ERROR, "tokenizer.ggml.tokens must be a non-empty string array");
        return false;
    }
    const size_t n = gguf_get_arr_n(gguf, tokens_id);

    // Special-token classification needs the token types; they are part of the expected format.
    const int64_t types_id = find_key(gguf, "tokenizer.ggml.token_type", GGUF_TYPE_ARRAY, true);
    if (types_id < 0) {
        return false;
    }
    if (gguf_get_arr_type(gguf, types_id) != GGUF_TYPE_INT32 || gguf_get_arr_n(gguf, types_id) != n) {
        log(GRANITE_LOG_ERROR, "tokenizer.ggml.token_type must be an INT32 array with one entry per token");
        return false;
    }
    const int32_t * types = static_cast<const int32_t *>(gguf_get_arr_data(gguf, types_id));

    static const Gpt2ByteMap byte_map;
    vocab.bytes.assign(n, std::string());
    vocab.special.assign(n, 0);
    vocab.nospeech_id = -1;
    for (size_t i = 0; i < n; ++i) {
        const std::string piece = gguf_get_arr_str(gguf, tokens_id, i);
        vocab.bytes[i]   = gpt2 ? decode_gpt2_piece(byte_map, piece) : decode_sentencepiece_piece(piece);
        vocab.special[i] = (types[i] == kTokenUnknown || types[i] == kTokenControl || types[i] == kTokenUser) ? 1 : 0;
        if (vocab.nospeech_id < 0 && piece == "<|nospeech|>") {
            vocab.nospeech_id = static_cast<int32_t>(i);
        }
    }
    return true;
}

}  // namespace granite
