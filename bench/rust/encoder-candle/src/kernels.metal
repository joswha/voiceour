// Custom Metal kernels for the candle FastConformer encoder (bench/rust/encoder-candle).
//
// Line references are to Vendor/parakeet/src/parakeet.cpp (`parakeet_build_graph_encode`).
// Every kernel accumulates in float whatever the storage type `T` (float, half, bfloat).
// Compiled at engine start (kernels.rs) with a pinned Metal Shading Language version (3.2 unless
// CANDLE_METAL_LANGUAGE_VERSION says otherwise) and fast math, the option set candle gives its own
// libraries. ggml-metal compiles its library with default options (ggml-metal-device.m L229).

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------------------------
// Subsampling (dw_striding, L3538-L3620)
// ---------------------------------------------------------------------------------------------

// conv.0: 3x3 / stride 2 / pad 1, 1 -> C channels, + bias, ReLU (L3556-L3566).
// `ggml_im2col` writes the mel taps into an f16 destination, so each mel value is rounded to
// half before the multiply; the conv weights stay f32 and the 9-tap dot product (ne00 = 9 <
// 64, so ggml's mul_mv path) runs in float.
//   mel: [n_t][n_f] float, frame-major as the dump stores it
//   w:   [C][3 (time tap)][3 (freq tap)] float, b: [C] float
//   out: [C][oh][ow], channel planes, time rows, frequency fastest (ggml [freq, time, chan])
template <typename T>
kernel void sub_conv0(
    device const float *mel [[buffer(0)]],
    device const float *w   [[buffer(1)]],
    device const float *b   [[buffer(2)]],
    device T           *out [[buffer(3)]],
    constant int       *p   [[buffer(4)]],
    uint3 gid [[thread_position_in_grid]])
{
    const int n_t = p[0], n_f = p[1], oh_n = p[2], ow_n = p[3];
    const int ow = gid.x, oh = gid.y, c = gid.z;
    if (ow >= ow_n || oh >= oh_n) {
        return;
    }
    device const float *wc = w + c * 9;
    float acc = 0.0f;
    for (int kt = 0; kt < 3; ++kt) {
        const int t = 2 * oh + kt - 1;
        if (t < 0 || t >= n_t) {
            continue;
        }
        for (int kf = 0; kf < 3; ++kf) {
            const int f = 2 * ow + kf - 1;
            if (f < 0 || f >= n_f) {
                continue;
            }
            acc += float(half(mel[t * n_f + f])) * wc[kt * 3 + kf];
        }
    }
    out[((size_t)c * oh_n + oh) * ow_n + ow] = T(max(acc + b[c], 0.0f));
}

// conv.2 / conv.5: depthwise 3x3 / stride 2 / pad 1 + bias (`ggml_conv_2d_dw_direct` in f32,
// then `ggml_add`, L3569-L3594).
//   x: [C][h][w], wt: [C][3][3] float, b: [C] float, out: [C][oh][ow]
template <typename T>
kernel void sub_dw_s2(
    device const T     *x   [[buffer(0)]],
    device const float *wt  [[buffer(1)]],
    device const float *b   [[buffer(2)]],
    device T           *out [[buffer(3)]],
    constant int       *p   [[buffer(4)]],
    uint3 gid [[thread_position_in_grid]])
{
    const int h = p[0], w = p[1], oh_n = p[2], ow_n = p[3];
    const int ow = gid.x, oh = gid.y, c = gid.z;
    if (ow >= ow_n || oh >= oh_n) {
        return;
    }
    device const T *xc = x + (size_t)c * h * w;
    device const float *wc = wt + c * 9;
    float acc = 0.0f;
    for (int kt = 0; kt < 3; ++kt) {
        const int ih = 2 * oh + kt - 1;
        if (ih < 0 || ih >= h) {
            continue;
        }
        for (int kf = 0; kf < 3; ++kf) {
            const int iw = 2 * ow + kf - 1;
            if (iw < 0 || iw >= w) {
                continue;
            }
            acc += float(xc[ih * w + iw]) * wc[kt * 3 + kf];
        }
    }
    out[((size_t)c * oh_n + oh) * ow_n + ow] = T(acc + b[c]);
}

// ---------------------------------------------------------------------------------------------
// Conv module (L4008-L4081)
// ---------------------------------------------------------------------------------------------

// Depthwise conv over time, K = 9, zero padding 4 frames each side (`ggml_pad` + `ggml_roll`
// then `ggml_ssm_conv`, L4043-L4048): y[t][c] = sum_k w[c][k] * x[t + k - 4][c], accumulated
// in tap order like kernel_ssm_conv_f32_f32.
//   x: [n_t][C], wt: [C][9] float, out: [n_t][C]
template <typename T>
kernel void dwconv9(
    device const T     *x   [[buffer(0)]],
    device const float *wt  [[buffer(1)]],
    device T           *out [[buffer(2)]],
    constant int       *p   [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    const int n_t = p[0], n_c = p[1];
    const int c = gid.x, t = gid.y;
    if (c >= n_c || t >= n_t) {
        return;
    }
    device const float *wc = wt + c * 9;
    float acc = 0.0f;
    for (int k = 0; k < 9; ++k) {
        const int tt = t + k - 4;
        if (tt < 0 || tt >= n_t) {
            continue;
        }
        acc += float(x[(size_t)tt * n_c + c]) * wc[k];
    }
    out[(size_t)t * n_c + c] = T(acc);
}

// Fused variant: GLU + depthwise conv + BatchNorm + SiLU in one pass (L4020-L4069).
//   pw1: [n_t][2C], the pointwise_conv1 output; GLU = pw1[:, :C] * sigmoid(pw1[:, C:])
//   bn:  [4][C] float rows: running_mean, sqrt(running_var), gamma, beta
//   out: [n_t][C] = silu(((dw(glu) - mean) / sqrt(var)) * gamma + beta)
template <typename T>
kernel void glu_dwconv9_bn_silu(
    device const T     *pw1 [[buffer(0)]],
    device const float *wt  [[buffer(1)]],
    device const float *bn  [[buffer(2)]],
    device T           *out [[buffer(3)]],
    constant int       *p   [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    const int n_t = p[0], n_c = p[1];
    const int c = gid.x, t = gid.y;
    if (c >= n_c || t >= n_t) {
        return;
    }
    device const float *wc = wt + c * 9;
    float acc = 0.0f;
    for (int k = 0; k < 9; ++k) {
        const int tt = t + k - 4;
        if (tt < 0 || tt >= n_t) {
            continue;
        }
        device const T *row = pw1 + (size_t)tt * 2 * n_c;
        // GLU rounds to T like the materialised `ggml_mul(signal, sigmoid(gate))`.
        const float g = float(row[n_c + c]);
        const T glu = T(float(row[c]) * (1.0f / (1.0f + exp(-g))));
        acc += float(glu) * wc[k];
    }
    const float y = (acc - bn[c]) / bn[n_c + c] * bn[2 * n_c + c] + bn[3 * n_c + c];
    out[(size_t)t * n_c + c] = T(y / (1.0f + exp(-y)));
}

// ---------------------------------------------------------------------------------------------
// Fused residual + LayerNorm
// ---------------------------------------------------------------------------------------------

// One threadgroup per frame (row of n = 1024). Computes r = x + alpha * h (the residual update
// `ggml_add(residual, ggml_scale(cur, alpha))`), optionally writes r, then y = LN(r) * gamma +
// beta with ggml_norm's two-pass mean / variance (eps inside the sqrt).
//   x, h: [n_t][n]; ln: [2][n] float (gamma, beta); r_out, y_out: [n_t][n]
//   p: n, has_h (0: r = x and h is ignored), write_r (0: r_out is not written)
//   alpha: float scale for h
#define LN_THREADS 256

template <typename T>
kernel void add_ln(
    device const T     *x     [[buffer(0)]],
    device const T     *h     [[buffer(1)]],
    device const float *ln    [[buffer(2)]],
    device T           *r_out [[buffer(3)]],
    device T           *y_out [[buffer(4)]],
    constant int       *p     [[buffer(5)]],
    constant float     &alpha [[buffer(6)]],
    uint row [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint lane [[thread_index_in_simdgroup]],
    uint sg [[simdgroup_index_in_threadgroup]])
{
    const int n = p[0];
    const bool has_h = p[1] != 0;
    const bool write_r = p[2] != 0;
    threadgroup float partial[LN_THREADS / 32];

    // n = 1024 and LN_THREADS = 256: four values per thread, kept in registers.
    float v[4];
    float sum = 0.0f;
    for (int j = 0; j < 4; ++j) {
        const int i = tid + j * LN_THREADS;
        float r = float(x[(size_t)row * n + i]);
        if (has_h) {
            r = float(T(r + alpha * float(h[(size_t)row * n + i])));
        }
        v[j] = r;
        sum += r;
        if (write_r) {
            r_out[(size_t)row * n + i] = T(r);
        }
    }
    sum = simd_sum(sum);
    if (lane == 0) {
        partial[sg] = sum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float total = 0.0f;
    for (int s = 0; s < LN_THREADS / 32; ++s) {
        total += partial[s];
    }
    const float mean = total / float(n);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float sq = 0.0f;
    for (int j = 0; j < 4; ++j) {
        v[j] -= mean;
        sq += v[j] * v[j];
    }
    sq = simd_sum(sq);
    if (lane == 0) {
        partial[sg] = sq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float var = 0.0f;
    for (int s = 0; s < LN_THREADS / 32; ++s) {
        var += partial[s];
    }
    const float scale = 1.0f / sqrt(var / float(n) + 1e-5f);
    for (int j = 0; j < 4; ++j) {
        const int i = tid + j * LN_THREADS;
        y_out[(size_t)row * n + i] = T(v[j] * scale * ln[i] + ln[n + i]);
    }
}

// ---------------------------------------------------------------------------------------------
// Relative-position attention helpers (dense branch, L3885-L3991)
// ---------------------------------------------------------------------------------------------

// Splits the fused QKV projection [n_t][3][H][D] into the head-major operands the attention
// matmuls take: q_u = Q + pos_bias_u, q_v = (Q + pos_bias_v) * scale (the score scale folded
// into the position term), all [H][n_t][D].
//   uv: [2][H][D] float (pos_bias_u, pos_bias_v)
template <typename T>
kernel void split_qkv(
    device const T     *qkv [[buffer(0)]],
    device const float *uv  [[buffer(1)]],
    device T           *q_u [[buffer(2)]],
    device T           *q_v [[buffer(3)]],
    constant int       *p   [[buffer(4)]],
    constant float     &scale [[buffer(5)]],
    uint3 gid [[thread_position_in_grid]])
{
    const int n_t = p[0], n_h = p[1], d = p[2];
    const int i = gid.x, h = gid.y, t = gid.z;
    if (i >= d || t >= n_t) {
        return;
    }
    const float q = float(qkv[(size_t)t * 3 * n_h * d + h * d + i]);
    const size_t o = ((size_t)h * n_t + t) * d + i;
    q_u[o] = T(q + uv[h * d + i]);
    q_v[o] = T(T(q + uv[n_h * d + h * d + i]) * scale);
}

// The relative shift (L3906-L3973) as a gather: mask[h][q][k] = bd[h][q][(n_t - 1) + k - q],
// bd = q_v . P^T of shape [H][n_t][2 n_t - 1]. Position p holds relative distance
// n_t - 1 - p, so the gathered element pairs query q with key k at distance q - k.
template <typename T>
kernel void rel_shift(
    device const T *bd   [[buffer(0)]],
    device T       *mask [[buffer(1)]],
    constant int   *p    [[buffer(2)]],
    uint3 gid [[thread_position_in_grid]])
{
    const int n_t = p[0];
    const int k = gid.x, q = gid.y, h = gid.z;
    if (k >= n_t || q >= n_t) {
        return;
    }
    const int w = 2 * n_t - 1;
    mask[((size_t)h * n_t + q) * n_t + k] = bd[((size_t)h * n_t + q) * w + (n_t - 1) + k - q];
}

#define INSTANTIATE(NAME, SUFFIX, T) \
    template [[host_name(#NAME "_" #SUFFIX)]] [[kernel]] decltype(NAME<T>) NAME<T>;

#define INSTANTIATE_ALL(NAME) \
    INSTANTIATE(NAME, f32, float) \
    INSTANTIATE(NAME, f16, half) \
    INSTANTIATE(NAME, bf16, bfloat)

INSTANTIATE_ALL(sub_conv0)
INSTANTIATE_ALL(sub_dw_s2)
INSTANTIATE_ALL(dwconv9)
INSTANTIATE_ALL(glu_dwconv9_bn_silu)
INSTANTIATE_ALL(add_ln)
INSTANTIATE_ALL(split_qkv)
INSTANTIATE_ALL(rel_shift)
