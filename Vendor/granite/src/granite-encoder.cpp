// granite-encoder.cpp — the 16-block Granite Conformer encoder graph with block-local Shaw attention,
// self-conditioned CTC and the tied CTC head (single utterance).
//
// Adapted from transcribe.cpp (MIT, Copyright (c) 2026 The transcribe.cpp authors) at
// 5700f127e38dd53c4735ea23ef743b4b538eacd4: src/arch/granite5_ctc/encoder.cpp (pos rows, pad mask,
// conv module, pair pooling, graph), src/granite_conformer/shaw_attn.cpp (skew path) and
// src/conformer/conformer.cpp (layer_norm, feed_forward, macaron_ff_residual, rel_shift,
// conv_2d_dw_direct_f32, fused_batch_norm). See Vendor/granite/LICENSE and Vendor/granite/NOTICE.md.
#include "granite-impl.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace granite {

namespace {

// nn.LayerNorm default eps (not stored in the GGUF).
constexpr float kLayerNormEps = 1e-5f;

// Graph node capacity, as upstream.
constexpr size_t kGraphSize = 16384;

ggml_tensor * layer_norm(ggml_context * ctx, ggml_tensor * x, ggml_tensor * gamma, ggml_tensor * beta) {
    ggml_tensor * y = ggml_norm(ctx, x, kLayerNormEps);
    y               = ggml_mul(ctx, y, gamma);
    return ggml_add(ctx, y, beta);
}

ggml_tensor * linear(ggml_context * ctx, ggml_tensor * x, ggml_tensor * w, ggml_tensor * b) {
    ggml_tensor * y = ggml_mul_mat(ctx, w, x);
    return b != nullptr ? ggml_add(ctx, y, b) : y;
}

// Macaron half-residual feed-forward: x + 0.5 * Linear2(SiLU(Linear1(LN(x)))).
ggml_tensor * macaron_ff(ggml_context * ctx, ggml_tensor * x, ggml_tensor * norm_w, ggml_tensor * norm_b,
                         ggml_tensor * lin1_w, ggml_tensor * lin1_b, ggml_tensor * lin2_w, ggml_tensor * lin2_b) {
    ggml_tensor * y = layer_norm(ctx, x, norm_w, norm_b);
    y               = linear(ctx, y, lin1_w, lin1_b);
    y               = ggml_silu(ctx, y);
    y               = linear(ctx, y, lin2_w, lin2_b);
    y               = ggml_scale(ctx, y, 0.5f);
    return ggml_add(ctx, x, y);
}

// Relative-position skew on [pos_len, T_q, H, B]: out[k, q] = in[k - q + T_q - 1, q].
ggml_tensor * rel_shift(ggml_context * ctx, ggml_tensor * x) {
    const int64_t pos_len = x->ne[0];
    const int64_t t_q     = x->ne[1];
    const int64_t heads   = x->ne[2];
    const int64_t batch   = x->ne[3];

    ggml_tensor * zero_template = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, 1, t_q, heads, batch);
    ggml_tensor * zeros         = ggml_fill(ctx, zero_template, 0.0f);
    ggml_tensor * y             = ggml_concat(ctx, zeros, x, /*dim=*/0);
    y = ggml_reshape_4d(ctx, y, t_q, pos_len + 1, heads, batch);
    y = ggml_view_4d(ctx, y, t_q, pos_len, heads, batch, y->nb[1], y->nb[2], y->nb[3], /*offset=*/y->nb[1]);
    y = ggml_cont(ctx, y);
    return ggml_reshape_4d(ctx, y, pos_len, t_q, heads, batch);
}

// Pre-LN block-local Shaw attention (active skew path). x: [hidden, t_len, 1]. Returns [hidden, t_len, 1]
// without the residual.
ggml_tensor * shaw_block_attn(ggml_context * ctx, ggml_tensor * x, const AttnStage & stage, ggml_tensor * pos_rows,
                              const Block & b, int n_heads, int head_dim, int context_size) {
    const int64_t inner      = static_cast<int64_t>(n_heads) * head_dim;
    const int64_t t_len      = stage.t_len;
    const int64_t t_pad      = static_cast<int64_t>(context_size) * stage.n_blocks;
    const int64_t batch      = x->ne[2];
    const int64_t num_blocks = static_cast<int64_t>(stage.n_blocks) * batch;
    const float   scale      = 1.0f / std::sqrt(static_cast<float>(head_dim));

    ggml_tensor * h = layer_norm(ctx, x, b.norm_attn_w, b.norm_attn_b);
    if (t_pad > t_len) {
        h = ggml_concat(ctx, h, stage.zero_pad, /*dim=*/1);
    }

    ggml_tensor * q  = ggml_mul_mat(ctx, b.attn_q_w, h);   // [inner, t_pad]
    ggml_tensor * kv = ggml_mul_mat(ctx, b.attn_kv_w, h);  // [2*inner, t_pad], K rows first
    ggml_tensor * k  = ggml_cont(ctx, ggml_view_3d(ctx, kv, inner, kv->ne[1], kv->ne[2], kv->nb[1], kv->nb[2], 0));
    ggml_tensor * v  = ggml_cont(ctx, ggml_view_3d(ctx, kv, inner, kv->ne[1], kv->ne[2], kv->nb[1], kv->nb[2],
                                                   static_cast<size_t>(inner) * ggml_element_size(kv)));

    // [head_dim, context, heads, blocks]: every 128-frame block is an independent attention batch.
    auto to_blocks = [&](ggml_tensor * t) {
        ggml_tensor * r = ggml_reshape_4d(ctx, t, head_dim, n_heads, context_size, num_blocks);
        return ggml_cont(ctx, ggml_permute(ctx, r, 0, 2, 1, 3));
    };
    q = to_blocks(q);
    k = to_blocks(k);
    v = to_blocks(v);

    ggml_tensor * kq = ggml_mul_mat(ctx, k, q);  // [key, query, heads, blocks]

    // Shaw bias for (key k, query q) uses offset clamp(q - k, -S, S): 2S-1 rows, one matmul, then skew.
    ggml_tensor * e_sub    = ggml_get_rows(ctx, b.attn_rel_pos, pos_rows);
    ggml_tensor * pos_attn = ggml_mul_mat(ctx, e_sub, q);
    pos_attn               = rel_shift(ctx, pos_attn);
    pos_attn = ggml_view_4d(ctx, pos_attn, context_size, context_size, n_heads, num_blocks, pos_attn->nb[1],
                            pos_attn->nb[2], pos_attn->nb[3], 0);

    ggml_tensor * scores = ggml_add(ctx, kq, pos_attn);
    scores               = ggml_scale(ctx, scores, scale);
    ggml_tensor * mask4  = ggml_reshape_4d(ctx, stage.pad_mask, context_size, context_size, 1, num_blocks);
    scores               = ggml_add(ctx, scores, mask4);
    ggml_tensor * attn   = ggml_soft_max(ctx, scores);

    ggml_tensor * v_t = ggml_cont(ctx, ggml_permute(ctx, v, 1, 0, 2, 3));
    ggml_tensor * out = ggml_mul_mat(ctx, v_t, attn);  // [head_dim, query, heads, blocks]
    out               = ggml_cont(ctx, ggml_permute(ctx, out, 0, 2, 1, 3));
    out               = ggml_reshape_3d(ctx, out, inner, t_pad, batch);
    if (t_pad > t_len) {
        // Drop pad rows before the output projection.
        out = ggml_cont(ctx, ggml_view_3d(ctx, out, inner, t_len, batch, out->nb[1], out->nb[2], 0));
    }
    return linear(ctx, out, b.attn_out_w, b.attn_out_b);
}

// LN -> pointwise1 -> GLU -> depthwise (SAME, stride) -> fused BN -> SiLU -> pointwise2.
ggml_tensor * conv_module(ggml_context * ctx, ggml_tensor * x, const Block & b, int conv_kernel, int inner,
                          int stride) {
    const int64_t batch = x->ne[2];
    const int64_t t_len = x->ne[1];

    x = layer_norm(ctx, x, b.norm_conv_w, b.norm_conv_b);
    x = linear(ctx, x, b.conv_pointwise1_w, b.conv_pointwise1_b);  // [2*inner, T]
    {
        // GLU: first half * sigmoid(second half).
        ggml_tensor * gate  = ggml_view_3d(ctx, x, inner, t_len, batch, x->nb[1], x->nb[2], 0);
        ggml_tensor * value = ggml_view_3d(ctx, x, inner, t_len, batch, x->nb[1], x->nb[2],
                                           static_cast<size_t>(inner) * ggml_element_size(x));
        x = ggml_mul(ctx, gate, ggml_sigmoid(ctx, value));
    }

    x = ggml_cont(ctx, ggml_permute(ctx, x, 1, 0, 2, 3));  // [T, inner]
    {
        ggml_tensor * knl = ggml_reshape_4d(ctx, b.conv_depthwise_w, conv_kernel, 1, 1, inner);
        if (knl->type != GGML_TYPE_F32) {
            knl = ggml_cast(ctx, knl, GGML_TYPE_F32);  // the direct depthwise op wants an F32 kernel
        }
        ggml_tensor * img = ggml_reshape_4d(ctx, x, t_len, 1, inner, batch);
        x = ggml_conv_2d_dw_direct(ctx, knl, img, /*s0=*/stride, /*s1=*/1, /*p0=*/(conv_kernel - 1) / 2, /*p1=*/0,
                                   /*d0=*/1, /*d1=*/1);
        x = ggml_reshape_3d(ctx, x, x->ne[0], inner, batch);
    }

    x = ggml_mul(ctx, x, ggml_reshape_4d(ctx, b.bn_scale, 1, inner, 1, 1));
    x = ggml_add(ctx, x, ggml_reshape_4d(ctx, b.bn_bias, 1, inner, 1, 1));
    x = ggml_silu(ctx, x);
    x = ggml_cont(ctx, ggml_permute(ctx, x, 1, 0, 2, 3));  // [inner, T_out]
    return linear(ctx, x, b.conv_pointwise2_w, b.conv_pointwise2_b);
}

// Mean of consecutive frame pairs: floor(T/2) frames, a trailing odd frame is dropped.
ggml_tensor * mean_pool_pairs(ggml_context * ctx, ggml_tensor * x) {
    const int64_t c      = x->ne[0];
    const int64_t t_half = x->ne[1] / 2;
    const int64_t batch  = x->ne[2];
    ggml_tensor * even   = ggml_cont(ctx, ggml_view_3d(ctx, x, c, t_half, batch, 2 * x->nb[1], x->nb[2], 0));
    ggml_tensor * odd    = ggml_cont(ctx, ggml_view_3d(ctx, x, c, t_half, batch, 2 * x->nb[1], x->nb[2], x->nb[1]));
    return ggml_scale(ctx, ggml_add(ctx, even, odd), 0.5f);
}

ggml_tensor * trim_time(ggml_context * ctx, ggml_tensor * x, int64_t t_keep) {
    if (x->ne[1] == t_keep) {
        return x;
    }
    return ggml_cont(ctx, ggml_view_3d(ctx, x, x->ne[0], t_keep, x->ne[2], x->nb[1], x->nb[2], 0));
}

bool is_subsample(const HParams & hp, int layer) {
    return std::find(hp.subsample_layers.begin(), hp.subsample_layers.end(), layer) != hp.subsample_layers.end();
}

}  // namespace

std::vector<int32_t> precompute_pos_rows(int context_size, int max_pos_emb) {
    const int            n = 2 * context_size - 1;
    std::vector<int32_t> rows(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        // rel_shift reads slot d = key - query + context - 1, which carries offset query - key = context - 1 - d.
        const int d = std::min(std::max(context_size - 1 - i, -context_size), context_size);
        rows[static_cast<size_t>(i)] = static_cast<int32_t>(d + max_pos_emb);
    }
    return rows;
}

std::vector<float> precompute_pad_mask(int context_size, int t_len) {
    const int    n_blocks = (t_len + context_size - 1) / context_size;
    const size_t per_blk  = static_cast<size_t>(context_size) * static_cast<size_t>(context_size);
    // Large finite negative (not -inf) on keys past the real length; queries are never masked.
    constexpr float    kMasked = -1e30f;
    std::vector<float> mask(per_blk * static_cast<size_t>(n_blocks), 0.0f);
    for (int blk = 0; blk < n_blocks; ++blk) {
        const int first_pad = std::max(0, std::min(context_size, t_len - blk * context_size));
        if (first_pad >= context_size) {
            continue;
        }
        const size_t base = static_cast<size_t>(blk) * per_blk;
        for (int q = 0; q < context_size; ++q) {
            for (int k = first_pad; k < context_size; ++k) {
                mask[base + static_cast<size_t>(q) * static_cast<size_t>(context_size) + static_cast<size_t>(k)] =
                    kMasked;
            }
        }
    }
    return mask;
}

bool build_encoder_graph(ggml_context * ctx, const Weights & w, const HParams & hp, int t_enc, EncoderGraph & out) {
    out = EncoderGraph{};

    const int64_t batch    = 1;
    const int     inner    = hp.hidden * hp.conv_expansion;
    const int     ctx_size = hp.context_size;
    const int     n_layers = static_cast<int>(w.blocks.size());

    // Attention runs at the length ENTERING each block; a subsampling block floor-halves it on the way out.
    std::vector<int> block_stage(static_cast<size_t>(n_layers), 0);
    {
        int t = t_enc;
        for (int i = 0; i < n_layers; ++i) {
            int stage = -1;
            for (size_t s = 0; s < out.stages.size(); ++s) {
                if (out.stages[s].t_len == t) {
                    stage = static_cast<int>(s);
                    break;
                }
            }
            if (stage < 0) {
                AttnStage st;
                st.t_len    = t;
                st.n_blocks = (t + ctx_size - 1) / ctx_size;
                out.stages.push_back(st);
                stage = static_cast<int>(out.stages.size()) - 1;
            }
            block_stage[static_cast<size_t>(i)] = stage;
            if (is_subsample(hp, i)) {
                t /= 2;
                if (t <= 0) {
                    log(GRANITE_LOG_ERROR, "encoder: sequence collapses to 0 frames at subsampling block %d (T_enc=%d)",
                        i, t_enc);
                    return false;
                }
            }
        }
        out.t_out = t;
    }

    out.feats_in = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, hp.input_dim, t_enc, batch);
    ggml_set_name(out.feats_in, "mel.in");
    ggml_set_input(out.feats_in);

    out.pos_rows = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, 2 * static_cast<int64_t>(ctx_size) - 1);
    ggml_set_name(out.pos_rows, "enc.pos_rows");
    ggml_set_input(out.pos_rows);

    for (size_t s = 0; s < out.stages.size(); ++s) {
        AttnStage & st    = out.stages[s];
        const int   t_pad = st.n_blocks * ctx_size;
        st.pad_mask       = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, ctx_size, ctx_size, st.n_blocks * batch);
        ggml_format_name(st.pad_mask, "enc.pad_mask.%zu", s);
        ggml_set_input(st.pad_mask);
        if (t_pad > st.t_len) {
            st.zero_pad = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, hp.hidden, t_pad - st.t_len, batch);
            ggml_format_name(st.zero_pad, "enc.zero_pad.%zu", s);
            ggml_set_input(st.zero_pad);
        }
    }

    ggml_tensor * x = linear(ctx, out.feats_in, w.input_linear_w, w.input_linear_b);

    for (int i = 0; i < n_layers; ++i) {
        const Block &     b     = w.blocks[static_cast<size_t>(i)];
        const AttnStage & stage = out.stages[static_cast<size_t>(block_stage[static_cast<size_t>(i)])];
        const bool        sub   = is_subsample(hp, i);

        x = macaron_ff(ctx, x, b.norm_ff1_w, b.norm_ff1_b, b.ff1_lin1_w, b.ff1_lin1_b, b.ff1_lin2_w, b.ff1_lin2_b);
        x = ggml_add(ctx, x, shaw_block_attn(ctx, x, stage, out.pos_rows, b, hp.n_heads, hp.head_dim, ctx_size));

        // A stride-2 conv emits ceil(T/2) frames; it is trimmed to the pooled residual's floor(T/2).
        ggml_tensor * conv_out = conv_module(ctx, x, b, hp.conv_kernel, inner, sub ? 2 : 1);
        if (sub) {
            ggml_tensor * pooled = mean_pool_pairs(ctx, x);
            x                    = ggml_add(ctx, pooled, trim_time(ctx, conv_out, pooled->ne[1]));
        } else {
            x = ggml_add(ctx, x, conv_out);
        }

        x = macaron_ff(ctx, x, b.norm_ff2_w, b.norm_ff2_b, b.ff2_lin1_w, b.ff2_lin1_b, b.ff2_lin2_w, b.ff2_lin2_b);
        x = layer_norm(ctx, x, b.norm_out_w, b.norm_out_b);

        // Self-conditioned CTC on the output of block (self_cond_layer - 1), through the tied head.
        if (i + 1 == hp.self_cond_layer) {
            ggml_tensor * mid_logits = linear(ctx, x, w.ctc_proj_w, w.ctc_proj_b);
            ggml_tensor * injection  = linear(ctx, ggml_soft_max(ctx, mid_logits), w.ctc_bypass_w, w.ctc_bypass_b);
            x                        = ggml_add(ctx, x, injection);
        }
    }

    out.ctc_logits = linear(ctx, x, w.ctc_proj_w, w.ctc_proj_b);
    ggml_set_name(out.ctc_logits, "enc.ctc_logits");
    ggml_set_output(out.ctc_logits);

    out.graph = ggml_new_graph_custom(ctx, kGraphSize, /*grads=*/false);
    if (out.graph == nullptr) {
        log(GRANITE_LOG_ERROR, "encoder: ggml_new_graph_custom failed");
        return false;
    }
    ggml_build_forward_expand(out.graph, out.ctc_logits);
    return true;
}

}  // namespace granite
