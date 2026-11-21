// qwen3-graph.cpp — the qwen3 forward graph over a position-indexed F16 KV cache with flash attention.
//
// Adapted from llama.cpp (MIT, Copyright (c) 2023-2026 The ggml authors) b12606 at
// e412c6f468b7b9e0f16f2540244236f8ad68e9ae: src/models/qwen3.cpp (backbone and head), src/llama-graph.cpp
// (build_norm, build_qkv, build_ffn, build_attn, build_attn_mha, build_inp_embd, build_inp_out_ids) and
// src/llama-kv-cache.cpp (get_k, get_v, cpy_k, cpy_v). See Vendor/qwen3/LICENSE and Vendor/qwen3/NOTICE.md.
#include "qwen3-impl.h"

#include <cmath>

namespace qwen3 {

namespace {

// llama.cpp's llama_model::graph_max_nodes floor; a qwen3 graph has about 35 nodes per layer plus the head.
constexpr int kGraphNodes = 4096;

ggml_tensor * rms_norm(ggml_context * ctx, ggml_tensor * cur, ggml_tensor * weight, float eps) {
    cur = ggml_rms_norm(ctx, cur, eps);
    return ggml_mul(ctx, cur, weight);
}

// NEOX RoPE, unscaled: ext_factor 0, attn_factor 1, beta_fast 32, beta_slow 1 (llama.cpp's defaults when no
// YaRN scaling is configured), n_ctx_orig = the training context.
ggml_tensor * rope(ggml_context * ctx, ggml_tensor * cur, ggml_tensor * pos, const HParams & hp) {
    return ggml_rope_ext(ctx, cur, pos, nullptr, hp.n_embd_head, GGML_ROPE_TYPE_NEOX, hp.n_ctx_train, hp.rope_base,
                         /*freq_scale=*/1.0f, /*ext_factor=*/0.0f, /*attn_factor=*/1.0f, /*beta_fast=*/32.0f,
                         /*beta_slow=*/1.0f);
}

// llama_kv_cache::get_k / get_v for one stream: [n_embd_head, n_head_kv, n_kv, 1] over the first n_kv cells.
ggml_tensor * cache_view(ggml_context * ctx, ggml_tensor * cache, const HParams & hp, int32_t n_kv) {
    const int64_t n_embd_gqa = static_cast<int64_t>(hp.n_embd_head) * hp.n_head_kv;
    return ggml_view_4d(ctx, cache, hp.n_embd_head, hp.n_head_kv, n_kv, 1, ggml_row_size(cache->type, hp.n_embd_head),
                        ggml_row_size(cache->type, n_embd_gqa), ggml_row_size(cache->type, n_embd_gqa * cache->ne[1]),
                        0);
}

// llama_kv_cache::cpy_k / cpy_v without V transposition (flash attention): merge head dims, set_rows by cell.
ggml_tensor * cache_store(ggml_context * ctx, ggml_tensor * cache, ggml_tensor * cur, ggml_tensor * idxs) {
    const int64_t n_embd_gqa = cur->ne[0] * cur->ne[1];
    cur                      = ggml_view_2d(ctx, cur, n_embd_gqa, cur->ne[2], cur->nb[2], 0);
    return ggml_set_rows(ctx, cache, cur, idxs);
}

}  // namespace

size_t graph_context_size() {
    return ggml_tensor_overhead() * kGraphNodes + ggml_graph_overhead_custom(kGraphNodes, false);
}

bool build_graph(ggml_context * ctx, const HParams & hp, const Weights & w, const KVCache & kv, int32_t n_tokens,
                 int32_t n_outputs, int32_t n_kv, Graph & out) {
    out           = Graph();
    out.n_tokens  = n_tokens;
    out.n_outputs = n_outputs;
    out.n_kv      = n_kv;
    out.gf        = ggml_new_graph_custom(ctx, kGraphNodes, false);
    ggml_cgraph * gf = out.gf;

    const int64_t n_embd_head = hp.n_embd_head;
    const float   kq_scale    = 1.0f / std::sqrt(static_cast<float>(n_embd_head));

    // build_inp_embd: token rows of the embedding table, ordered first in the graph.
    out.tokens = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, n_tokens);
    ggml_set_name(out.tokens, "inp_tokens");
    ggml_set_input(out.tokens);
    ggml_tensor * inpL = ggml_get_rows(ctx, w.tok_embd, out.tokens);
    ggml_build_forward_expand(gf, inpL);

    out.pos = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, n_tokens);
    ggml_set_name(out.pos, "inp_pos");
    ggml_set_input(out.pos);

    // build_attn_inp_kv: the cells written and the causal mask over the first n_kv cells (F16 for flash attention).
    out.kv_idxs = ggml_new_tensor_1d(ctx, GGML_TYPE_I64, n_tokens);
    ggml_set_name(out.kv_idxs, "attn_inp_kv_idxs");
    ggml_set_input(out.kv_idxs);
    out.kq_mask = ggml_new_tensor_4d(ctx, GGML_TYPE_F16, n_kv, n_tokens, 1, 1);
    ggml_set_name(out.kq_mask, "attn_inp_kq_mask");
    ggml_set_input(out.kq_mask);

    if (n_outputs > 0) {
        out.out_ids = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, n_outputs);
        ggml_set_name(out.out_ids, "out_ids");
        ggml_set_input(out.out_ids);
    }

    for (int il = 0; il < hp.n_layer; ++il) {
        const Layer & layer = w.layers[static_cast<size_t>(il)];
        const bool    last  = il == hp.n_layer - 1;
        ggml_tensor * inpSA = inpL;

        ggml_tensor * cur = rms_norm(ctx, inpL, layer.attn_norm, hp.rms_eps);

        // build_qkv, separate Q/K/V path.
        ggml_tensor * Qcur = ggml_mul_mat(ctx, layer.wq, cur);
        ggml_tensor * Kcur = ggml_mul_mat(ctx, layer.wk, cur);
        ggml_tensor * Vcur = ggml_mul_mat(ctx, layer.wv, cur);
        Qcur               = ggml_reshape_3d(ctx, Qcur, n_embd_head, hp.n_head, n_tokens);
        Kcur               = ggml_reshape_3d(ctx, Kcur, n_embd_head, hp.n_head_kv, n_tokens);
        Vcur               = ggml_reshape_3d(ctx, Vcur, n_embd_head, hp.n_head_kv, n_tokens);

        Qcur = rms_norm(ctx, Qcur, layer.attn_q_norm, hp.rms_eps);
        Qcur = rope(ctx, Qcur, out.pos, hp);
        Kcur = rms_norm(ctx, Kcur, layer.attn_k_norm, hp.rms_eps);
        Kcur = rope(ctx, Kcur, out.pos, hp);

        // build_attn: Q, V and K are expanded together, then stored, so the graph keeps upstream's node order.
        ggml_build_forward_expand(gf, Qcur);
        ggml_build_forward_expand(gf, Vcur);
        ggml_build_forward_expand(gf, Kcur);
        ggml_build_forward_expand(gf, cache_store(ctx, kv.k[static_cast<size_t>(il)], Kcur, out.kv_idxs));
        ggml_build_forward_expand(gf, cache_store(ctx, kv.v[static_cast<size_t>(il)], Vcur, out.kv_idxs));

        if (last && n_outputs == 0) {
            // A prompt batch whose logits nobody reads only needs the last layer's K/V.
            return true;
        }

        // build_attn_mha with flash attention, one stream.
        ggml_tensor * q = ggml_view_4d(ctx, Qcur, Qcur->ne[0], Qcur->ne[1], Qcur->ne[2], 1, Qcur->nb[1], Qcur->nb[2],
                                       Qcur->nb[2] * Qcur->ne[2], 0);
        q               = ggml_permute(ctx, q, 0, 2, 1, 3);
        ggml_tensor * k = ggml_permute(ctx, cache_view(ctx, kv.k[static_cast<size_t>(il)], hp, n_kv), 0, 2, 1, 3);
        ggml_tensor * v = ggml_permute(ctx, cache_view(ctx, kv.v[static_cast<size_t>(il)], hp, n_kv), 0, 2, 1, 3);
        cur             = ggml_flash_attn_ext(ctx, q, k, v, out.kq_mask, kq_scale, 0.0f, 0.0f);
        ggml_flash_attn_ext_set_prec(cur, GGML_PREC_F32);
        cur = ggml_reshape_2d(ctx, cur, cur->ne[0] * cur->ne[1], cur->ne[2] * cur->ne[3]);
        ggml_build_forward_expand(gf, cur);

        cur = ggml_mul_mat(ctx, layer.wo, cur);

        if (last) {
            cur   = ggml_get_rows(ctx, cur, out.out_ids);
            inpSA = ggml_get_rows(ctx, inpSA, out.out_ids);
        }
        ggml_tensor * ffn_inp = ggml_add(ctx, cur, inpSA);

        // build_ffn: SILU, parallel gate -> swiglu_split(gate, up), then down.
        cur               = rms_norm(ctx, ffn_inp, layer.ffn_norm, hp.rms_eps);
        ggml_tensor * tmp = ggml_mul_mat(ctx, layer.ffn_up, cur);
        cur               = ggml_mul_mat(ctx, layer.ffn_gate, cur);
        cur               = ggml_swiglu_split(ctx, cur, tmp);
        cur               = ggml_mul_mat(ctx, layer.ffn_down, cur);

        inpL = ggml_add(ctx, cur, ffn_inp);
    }

    ggml_tensor * cur = rms_norm(ctx, inpL, w.output_norm, hp.rms_eps);
    out.logits        = ggml_mul_mat(ctx, w.output, cur);
    ggml_set_name(out.logits, "result_output");
    ggml_set_output(out.logits);
    ggml_build_forward_expand(gf, out.logits);
    return true;
}

}  // namespace qwen3
