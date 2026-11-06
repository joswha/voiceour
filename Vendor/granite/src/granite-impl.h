// granite-impl.h — internal types shared by the CGranite translation units.
//
// Adapted from transcribe.cpp (MIT, Copyright (c) 2026 The transcribe.cpp authors) at
// 5700f127e38dd53c4735ea23ef743b4b538eacd4: src/arch/granite5_ctc/{weights.h,granite5_ctc.h,encoder.h}.
// See Vendor/granite/LICENSE and Vendor/granite/NOTICE.md.
#ifndef GRANITE_IMPL_H
#define GRANITE_IMPL_H

#include "granite.h"

#include "ggml-backend.h"
#include "ggml.h"

#include <Accelerate/Accelerate.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

struct gguf_context;

namespace granite {

void log(granite_log_level level, const char * fmt, ...) __attribute__((format(printf, 2, 3)));

// Architecture and frontend hyperparameters read from the GGUF (upstream Granite5CtcHParams).
struct HParams {
    int32_t n_layers        = 0;
    int32_t hidden          = 0;
    int32_t n_heads         = 0;
    int32_t head_dim        = 0;
    int32_t intermediate    = 0;
    int32_t input_dim       = 0;
    int32_t output_dim      = 0;
    int32_t conv_kernel     = 0;
    int32_t conv_expansion  = 0;
    int32_t context_size    = 0;
    int32_t max_pos_emb     = 0;
    int32_t self_cond_layer = 0;
    int32_t blank_id        = 0;
    std::vector<int32_t> subsample_layers;  // sorted ascending

    int32_t sample_rate      = 0;
    int32_t num_mels         = 0;
    int32_t n_fft            = 0;
    int32_t win_length       = 0;
    int32_t hop_length       = 0;
    int32_t delta_win_length = 0;
    int32_t stack_factor     = 0;
    bool    deltas           = true;
};

struct Block {
    ggml_tensor * norm_ff1_w = nullptr;
    ggml_tensor * norm_ff1_b = nullptr;
    ggml_tensor * ff1_lin1_w = nullptr;
    ggml_tensor * ff1_lin1_b = nullptr;
    ggml_tensor * ff1_lin2_w = nullptr;
    ggml_tensor * ff1_lin2_b = nullptr;

    ggml_tensor * norm_attn_w  = nullptr;
    ggml_tensor * norm_attn_b  = nullptr;
    ggml_tensor * attn_q_w     = nullptr;
    ggml_tensor * attn_kv_w    = nullptr;
    ggml_tensor * attn_out_w   = nullptr;
    ggml_tensor * attn_out_b   = nullptr;
    ggml_tensor * attn_rel_pos = nullptr;

    ggml_tensor * norm_conv_w       = nullptr;
    ggml_tensor * norm_conv_b       = nullptr;
    ggml_tensor * conv_pointwise1_w = nullptr;
    ggml_tensor * conv_pointwise1_b = nullptr;
    ggml_tensor * conv_depthwise_w  = nullptr;
    ggml_tensor * conv_bn_w         = nullptr;
    ggml_tensor * conv_bn_b         = nullptr;
    ggml_tensor * conv_bn_mean      = nullptr;
    ggml_tensor * conv_bn_var       = nullptr;
    ggml_tensor * conv_pointwise2_w = nullptr;
    ggml_tensor * conv_pointwise2_b = nullptr;

    ggml_tensor * norm_ff2_w = nullptr;
    ggml_tensor * norm_ff2_b = nullptr;
    ggml_tensor * ff2_lin1_w = nullptr;
    ggml_tensor * ff2_lin1_b = nullptr;
    ggml_tensor * ff2_lin2_w = nullptr;
    ggml_tensor * ff2_lin2_b = nullptr;

    ggml_tensor * norm_out_w = nullptr;
    ggml_tensor * norm_out_b = nullptr;

    // Fused BatchNorm affine, created at load in a separate buffer (never in the mapped file).
    ggml_tensor * bn_scale = nullptr;
    ggml_tensor * bn_bias  = nullptr;
};

struct Weights {
    ggml_tensor * input_linear_w  = nullptr;
    ggml_tensor * input_linear_b  = nullptr;
    ggml_tensor * ctc_proj_w      = nullptr;  // tied: self-conditioning and final logits
    ggml_tensor * ctc_proj_b      = nullptr;
    ggml_tensor * ctc_bypass_w    = nullptr;
    ggml_tensor * ctc_bypass_b    = nullptr;
    ggml_tensor * mel_filterbank  = nullptr;
    ggml_tensor * window          = nullptr;
    std::vector<Block> blocks;
};

// Host frontend state built once per model (upstream MelFrontend, Granite configuration only).
struct Frontend {
    std::vector<double> window;      // n_fft, baked window centred at (n_fft - win_length) / 2
    std::vector<float>  filterbank;  // [num_mels, n_fft/2 + 1] row-major
    FFTSetupD           fft_setup = nullptr;
    int                 log2n     = 0;
};

// Vocabulary: every id's decoded bytes, precomputed at load, plus the raw pieces and BPE merges callers
// need to encode text into ids.
struct Vocab {
    std::vector<std::string> bytes;
    std::vector<std::string> pieces;
    std::vector<std::string> merges;
    std::vector<uint8_t>     special;
    int32_t                  nospeech_id = -1;
};

// Validates every key the forward depends on; logs and returns false on the first violation.
bool read_hparams(const gguf_context * gguf, HParams & hp);

// Binds and validates all tensors of the catalog (names, types, shapes, exact count).
bool bind_weights(const gguf_context * gguf, ggml_context * ctx_meta, const HParams & hp, Weights & w);

// Loads tokenizer.ggml.{model,tokens,token_type} into the decode table and the optional
// tokenizer.ggml.merges in rank order.
bool load_vocab(const gguf_context * gguf, Vocab & vocab);

// Frontend. Returns false (after logging) when the clip cannot produce a feature frame.
bool frontend_init(const HParams & hp, const float * filterbank, const float * window, Frontend & fe);
void frontend_free(Frontend & fe);
bool compute_features(const Frontend & fe, const HParams & hp, const float * pcm, int64_t n_samples, int n_threads,
                      std::vector<float> & feats, int & t_enc);

// Smallest sample count whose features survive both subsamplers with >= 1 encoder frame.
int64_t min_samples_for(const HParams & hp);

// Encoder-frame length after every subsampling block; 0 when the sequence collapses.
int64_t frames_after_subsampling(const HParams & hp, int64_t t_enc);

struct AttnStage {
    int           t_len    = 0;
    int           n_blocks = 0;
    ggml_tensor * pad_mask = nullptr;
    ggml_tensor * zero_pad = nullptr;
};

struct EncoderGraph {
    ggml_cgraph *          graph      = nullptr;
    ggml_tensor *          feats_in   = nullptr;
    ggml_tensor *          pos_rows   = nullptr;
    ggml_tensor *          ctc_logits = nullptr;
    std::vector<AttnStage> stages;
    int                    t_out      = 0;
};

bool build_encoder_graph(ggml_context * ctx, const Weights & w, const HParams & hp, int t_enc, EncoderGraph & out);
std::vector<int32_t> precompute_pos_rows(int context_size, int max_pos_emb);
std::vector<float>   precompute_pad_mask(int context_size, int t_len);

}  // namespace granite

#endif  // GRANITE_IMPL_H
