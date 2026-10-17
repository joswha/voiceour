//! The FastConformer encoder of the pinned parakeet-tdt-0.6b-v3 model as one lazy MLX graph.
//!
//! Mirrors `parakeet_build_graph_encode` (Vendor/parakeet/src/parakeet.cpp L3520-L4116) for the
//! pinned file: dw_striding subsampling, the in-graph sinusoidal relative positional encoding,
//! 24 conformer blocks (macaron FFN x0.5, rel-pos MHSA with pos_bias_u/v, conv module with GLU,
//! depthwise k=9 and BatchNorm without epsilon, SiLU) and each block's output LayerNorm. Weights
//! come as loaded by `parakeet_model_load` (bench/rust/parakeet-model): nothing is folded,
//! transposed on the host or re-quantized; f16 matrices are either kept (f16 arms) or widened
//! exactly to f32 (f32 arms). One `eval` per utterance.

use std::cell::RefCell;
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};

use mlx_rs::error::Exception;
use mlx_rs::transforms::compile::compile;
use mlx_rs::{Array, Dtype, fast, ops, transforms};
use parakeet_model::{DType, Model, TensorView};

type MlxResult<T> = std::result::Result<T, Exception>;
type Fused = Box<dyn FnMut(&[Array]) -> MlxResult<Vec<Array>>>;

/// mlx-rs 0.32.0 -> mlx-sys 0.6.0 -> mlx-c pinned to MLX `v0.32.2` (CMake `GIT_TAG`), commit
/// `1f8e74e3f12f31365464a6867c6579f0e9b29d85` (checked in the fetched `_deps/mlx-src`).
pub const MLX_VERSION: &str = "v0.32.2";
pub const MLX_COMMIT: &str = "1f8e74e3f12f31365464a6867c6579f0e9b29d85";
pub const MLX_RS_VERSION: &str = "0.32.0";

pub const N_MELS: usize = 128;
pub const N_STATE: usize = 1024;
const N_HEAD: i32 = 8;
const D_HEAD: i32 = 128;
const N_LAYER: usize = 24;
const N_FFN: i32 = 4096;
const SUB_CHANNELS: i32 = 256;
const CONV_KERNEL: i32 = 9;
/// `hparams.eps` (struct default, L313).
const EPS: f32 = 1e-5;
/// `PARAKEET_LOCAL_ATTN_THRESHOLD` (L149): above it the native graph switches to chunked local
/// attention, which this engine does not implement.
const LOCAL_ATTN_THRESHOLD: usize = 8192;

/// Arithmetic precision of an arm.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Precision {
    /// Weights widened exactly to f32 at load, every activation and product in f32.
    F32,
    /// As `F32`, but every matmul operand is rounded to f16 exactly where ggml-metal rounds it:
    /// `kernel_mul_mm_{f16,f32}_f32` stages both operands as `half` (ggml-metal.metal
    /// L10760-L10763) whenever `ne00 >= 64 && ne11 > 8` (ggml-metal-ops.cpp L2436-L2440), and
    /// the subsampling's im2col / 1x1 casts produce f16 (parakeet.cpp L3472, L3499). Products
    /// of two halves are exact in f32 and accumulate in f32, so only summation order differs.
    F32Mm16,
    /// Weights kept as the file's f16, every activation in f16. MLX accumulates matmuls,
    /// LayerNorm statistics and (precise) softmax in f32 internally.
    F16,
}

impl Precision {
    fn dtype(self) -> Dtype {
        match self {
            Precision::F32 | Precision::F32Mm16 => Dtype::Float32,
            Precision::F16 => Dtype::Float16,
        }
    }

    fn rounds_operands(self) -> bool {
        self == Precision::F32Mm16
    }
}

/// How the relative-position attention is evaluated.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Attention {
    /// The native op sequence: `softmax(((Q+u)·Kᵀ + shift((Q+v)·Pᵀ)) · 1/√d) · V`.
    Manual,
    /// `fast::scaled_dot_product_attention(Q+u, K, V, 1/√d, mask)` with the shifted positional
    /// term `shift(((Q+v)·1/√d)·Pᵀ)` as the additive mask (a strided view, never materialized).
    Sdpa,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Arm {
    pub name: &'static str,
    pub precision: Precision,
    pub attention: Attention,
    /// Elementwise chains go through `mlx_rs::transforms::compile::compile` (shapeless), which
    /// fuses each chain into one generated Metal kernel.
    pub compiled: bool,
}

impl Arm {
    pub const ALL: [Arm; 8] = [
        Arm {
            name: "f32",
            precision: Precision::F32,
            attention: Attention::Manual,
            compiled: false,
        },
        Arm {
            name: "f16",
            precision: Precision::F16,
            attention: Attention::Sdpa,
            compiled: false,
        },
        Arm {
            name: "compiled-f32",
            precision: Precision::F32,
            attention: Attention::Manual,
            compiled: true,
        },
        Arm {
            name: "compiled-f16",
            precision: Precision::F16,
            attention: Attention::Sdpa,
            compiled: true,
        },
        Arm {
            name: "f32-mm16",
            precision: Precision::F32Mm16,
            attention: Attention::Manual,
            compiled: false,
        },
        Arm {
            name: "compiled-f32-mm16",
            precision: Precision::F32Mm16,
            attention: Attention::Manual,
            compiled: true,
        },
        Arm {
            name: "f32-sdpa",
            precision: Precision::F32,
            attention: Attention::Sdpa,
            compiled: false,
        },
        Arm {
            name: "f16-manual",
            precision: Precision::F16,
            attention: Attention::Manual,
            compiled: false,
        },
    ];

    /// Comma-separated `Arm::ALL` names (the `ve_arms` string).
    pub const NAMES: &'static str =
        "f32,f16,compiled-f32,compiled-f16,f32-mm16,compiled-f32-mm16,f32-sdpa,f16-manual";

    pub fn parse(name: &str) -> Option<Arm> {
        Arm::ALL.iter().copied().find(|arm| arm.name == name)
    }
}

/// Encoder frames for `n_mel_frames`: three stride-2, pad-1, k=3 stages, `ceil(T / 8)`
/// (`parakeet_encoder_frame_count`, L1350, non-causal files).
pub fn n_enc_frames(n_mel_frames: usize) -> usize {
    let mut t = n_mel_frames;
    for _ in 0..3 {
        t = t.div_ceil(2);
    }
    t
}

fn mlx_err(error: Exception) -> String {
    format!("mlx: {}", error.what())
}

// ---------------------------------------------------------------------------------------------
// Weights

struct SubsamplingWeights {
    conv0_w: Array, // [256, 3 (time), 3 (freq), 1]
    conv0_b: Array, // [256]
    conv2_w: Array, // depthwise [256, 3, 3, 1]
    conv2_b: Array,
    conv3_w: Array, // pointwise W[out][in] [256, 256]
    /// `conv3_w` rounded to f16 (kernel_mul_mm stages the f32 weight as half), for F32Mm16.
    conv3_w_r16: Array,
    conv3_b: Array,
    conv5_w: Array,
    conv5_b: Array,
    conv6_w: Array,
    conv6_w_r16: Array,
    conv6_b: Array,
    out_w: Array, // W[1024][4096], input index c * 16 + f
    out_b: Array, // [1024]
}

struct LayerWeights {
    norm_ff1: (Array, Array),
    ff1_w1: Array, // [4096, 1024]
    ff1_w2: Array, // [1024, 4096]
    norm_attn: (Array, Array),
    q_w: Array, // [1024, 1024], output feature h * 128 + d
    k_w: Array,
    v_w: Array,
    out_w: Array,
    pos_bias_u: Array, // [8, 128]
    pos_bias_v: Array, // [8, 128]
    norm_conv: (Array, Array),
    pw1_w: Array, // [2048, 1024]
    dw_w: Array,  // [1024, 9, 1]
    bn_mean: Array,
    bn_std: Array, // sqrt(running_var as loaded), no epsilon (L4056-L4059)
    bn_w: Array,
    bn_b: Array,
    pw2_w: Array, // [1024, 1024]
    norm_ff2: (Array, Array),
    ff2_w1: Array,
    ff2_w2: Array,
    norm_out: (Array, Array),
}

pub struct Weights {
    dtype: Dtype,
    sub: SubsamplingWeights,
    layers: Vec<LayerWeights>,
    /// Every layer's `linear_pos` stacked by layer: `[24 * 1024 (out), 1024 (in)]`, so the 24
    /// position projections are one matmul per utterance (same products as 24 separate ones).
    pos_w_all: Array,
    /// `freq[k] = expf(-(float(2k) * logf(10000) / 1024))`, `[1, 512]` f32 (L4217-L4228).
    pos_freqs: Array,
}

/// An f32 or f16 record as an MLX array of `shape` (row-major, same element order as the file)
/// converted to `dtype`.
fn tensor_array(view: &TensorView<'_>, shape: &[i32], dtype: Dtype) -> Result<Array, String> {
    let count: usize = shape.iter().map(|&d| d as usize).product();
    if count != view.n_elements() {
        return Err(format!(
            "{}: {} elements, expected shape {shape:?}",
            view.name,
            view.n_elements()
        ));
    }
    let base = match view.dtype {
        DType::F32 => {
            let data = view.f32_slice().map_err(|e| e.to_string())?;
            Array::from_slice(&data, shape)
        }
        DType::F16 => {
            let bits = view.f16_slice().map_err(|e| e.to_string())?;
            // SAFETY: `bits` holds exactly `count` fp16 values; MLX copies them.
            unsafe { Array::from_raw_data(bits.as_ptr().cast::<c_void>(), shape, Dtype::Float16) }
        }
        other => return Err(format!("{}: unsupported record type {other:?}", view.name)),
    };
    if base.dtype() == dtype {
        Ok(base)
    } else {
        base.as_dtype(dtype).map_err(mlx_err)
    }
}

/// A 2-D record with ggml `ne = [K, N]` as the row-major matrix `W[N][K]`.
fn matrix(view: &TensorView<'_>, rows: i32, cols: i32, dtype: Dtype) -> Result<Array, String> {
    if view.n_dims != 2 || view.ne[0] != i64::from(cols) || view.ne[1] != i64::from(rows) {
        return Err(format!(
            "{}: ne {:?}, expected [{cols}, {rows}]",
            view.name, view.ne
        ));
    }
    tensor_array(view, &[rows, cols], dtype)
}

fn vector(view: &TensorView<'_>, len: i32, dtype: Dtype) -> Result<Array, String> {
    tensor_array(view, &[len], dtype)
}

fn norm(w: &TensorView<'_>, b: &TensorView<'_>, dtype: Dtype) -> Result<(Array, Array), String> {
    Ok((
        vector(w, N_STATE as i32, dtype)?,
        vector(b, N_STATE as i32, dtype)?,
    ))
}

/// `x` rounded to f16 and widened back (round-to-nearest-even, as Metal's float→half).
fn round16(x: &Array) -> MlxResult<Array> {
    x.as_dtype(Dtype::Float16)?.as_dtype(x.dtype())
}

impl Weights {
    fn load(model: &Model, dtype: Dtype) -> Result<Weights, String> {
        let hp = model.hparams();
        let expected = [
            ("n_audio_state", hp.n_audio_state, N_STATE as i32),
            ("n_audio_head", hp.n_audio_head, N_HEAD),
            ("n_audio_layer", hp.n_audio_layer, N_LAYER as i32),
            ("n_mels", hp.n_mels, N_MELS as i32),
            (
                "n_subsampling_channels",
                hp.n_subsampling_channels,
                SUB_CHANNELS,
            ),
            ("n_conv_kernel", hp.n_conv_kernel, CONV_KERNEL),
            ("subsampling_factor", hp.subsampling_factor, 8),
        ];
        for (name, got, want) in expected {
            if got != want {
                return Err(format!(
                    "hparam {name} = {got}, this engine implements {want}"
                ));
            }
        }
        if hp.eps != EPS {
            return Err(format!("hparam eps = {}, expected {EPS}", hp.eps));
        }
        let variant = model.variant();
        if variant.encoder_biases || !variant.batch_norm_stats || variant.speaker_kernel {
            return Err(format!(
                "unsupported model variant {variant:?} (pinned file: BN stats only)"
            ));
        }
        if model.n_pre_enc_features() != i64::from(SUB_CHANNELS * 16) {
            return Err(format!(
                "pre-encode features {}, expected 4096",
                model.n_pre_enc_features()
            ));
        }

        let s = model.subsampling();
        if s.causal || s.n_freq_out != 16 || s.n_channels != SUB_CHANNELS as usize {
            return Err("unsupported subsampling variant".to_owned());
        }
        let c = SUB_CHANNELS;
        let conv3_w = tensor_array(&s.conv3_w, &[c, c], dtype)?;
        let conv6_w = tensor_array(&s.conv6_w, &[c, c], dtype)?;
        let sub = SubsamplingWeights {
            conv0_w: tensor_array(&s.conv0_w, &[c, 3, 3, 1], dtype)?,
            conv0_b: vector(&s.conv0_b, c, dtype)?,
            conv2_w: tensor_array(&s.conv2_w, &[c, 3, 3, 1], dtype)?,
            conv2_b: vector(&s.conv2_b, c, dtype)?,
            conv3_w_r16: round16(&conv3_w).map_err(mlx_err)?,
            conv3_w,
            conv3_b: vector(&s.conv3_b, c, dtype)?,
            conv5_w: tensor_array(&s.conv5_w, &[c, 3, 3, 1], dtype)?,
            conv5_b: vector(&s.conv5_b, c, dtype)?,
            conv6_w_r16: round16(&conv6_w).map_err(mlx_err)?,
            conv6_w,
            conv6_b: vector(&s.conv6_b, c, dtype)?,
            out_w: matrix(&s.out_w, N_STATE as i32, c * 16, dtype)?,
            out_b: vector(&s.out_b, N_STATE as i32, dtype)?,
        };

        let n = N_STATE as i32;
        let mut layers = Vec::with_capacity(N_LAYER);
        let mut pos_bits: Vec<u16> = Vec::with_capacity(N_LAYER * N_STATE * N_STATE);
        for l in model.encoder_layers() {
            let mean = l.conv_bn_mean.ok_or("missing BatchNorm running_mean")?;
            let var = l
                .conv_bn_var_as_loaded()
                .ok_or("missing BatchNorm running_var")?;
            // ggml_sqrt on the as-loaded variance; IEEE sqrt is correctly rounded.
            let std: Vec<f32> = var.iter().map(|v| v.sqrt()).collect();
            if l.attn_pos_w.n_dims != 2
                || l.attn_pos_w.ne[0] != i64::from(n)
                || l.attn_pos_w.ne[1] != i64::from(n)
            {
                return Err(format!(
                    "{}: unexpected shape {:?}",
                    l.attn_pos_w.name, l.attn_pos_w.ne
                ));
            }
            pos_bits.extend_from_slice(&l.attn_pos_w.f16_slice().map_err(|e| e.to_string())?);
            layers.push(LayerWeights {
                norm_ff1: norm(&l.norm_ff1_w, &l.norm_ff1_b, dtype)?,
                ff1_w1: matrix(&l.ff1_linear1_w, N_FFN, n, dtype)?,
                ff1_w2: matrix(&l.ff1_linear2_w, n, N_FFN, dtype)?,
                norm_attn: norm(&l.norm_attn_w, &l.norm_attn_b, dtype)?,
                q_w: matrix(&l.attn_q_w, n, n, dtype)?,
                k_w: matrix(&l.attn_k_w, n, n, dtype)?,
                v_w: matrix(&l.attn_v_w, n, n, dtype)?,
                out_w: matrix(&l.attn_out_w, n, n, dtype)?,
                pos_bias_u: tensor_array(&l.attn_pos_bias_u, &[N_HEAD, D_HEAD], dtype)?,
                pos_bias_v: tensor_array(&l.attn_pos_bias_v, &[N_HEAD, D_HEAD], dtype)?,
                norm_conv: norm(&l.norm_conv_w, &l.norm_conv_b, dtype)?,
                pw1_w: matrix(&l.conv_pw1_w, 2 * n, n, dtype)?,
                dw_w: tensor_array(&l.conv_dw_w, &[n, CONV_KERNEL, 1], dtype)?,
                bn_mean: vector(&mean, n, dtype)?,
                bn_std: Array::from_slice(&std, &[n])
                    .as_dtype(dtype)
                    .map_err(mlx_err)?,
                bn_w: vector(&l.conv_bn_w, n, dtype)?,
                bn_b: vector(&l.conv_bn_b, n, dtype)?,
                pw2_w: matrix(&l.conv_pw2_w, n, n, dtype)?,
                norm_ff2: norm(&l.norm_ff2_w, &l.norm_ff2_b, dtype)?,
                ff2_w1: matrix(&l.ff2_linear1_w, N_FFN, n, dtype)?,
                ff2_w2: matrix(&l.ff2_linear2_w, n, N_FFN, dtype)?,
                norm_out: norm(&l.norm_out_w, &l.norm_out_b, dtype)?,
            });
        }
        if layers.len() != N_LAYER {
            return Err(format!(
                "{} encoder layers, expected {N_LAYER}",
                layers.len()
            ));
        }
        // SAFETY: `pos_bits` holds 24 * 1024 * 1024 fp16 values; MLX copies them.
        let pos_w_all = unsafe {
            Array::from_raw_data(
                pos_bits.as_ptr().cast::<c_void>(),
                &[N_LAYER as i32 * n, n],
                Dtype::Float16,
            )
        };
        let pos_w_all = if dtype == Dtype::Float16 {
            pos_w_all
        } else {
            pos_w_all.as_dtype(dtype).map_err(mlx_err)?
        };

        let d_half = N_STATE / 2;
        let log_10000 = 10000.0f32.ln();
        let freqs: Vec<f32> = (0..d_half)
            .map(|k| (-((k * 2) as f32 * log_10000 / N_STATE as f32)).exp())
            .collect();
        let pos_freqs = Array::from_slice(&freqs, &[1, d_half as i32]);

        let weights = Weights {
            dtype,
            sub,
            layers,
            pos_w_all,
            pos_freqs,
        };
        transforms::eval(weights.arrays()).map_err(mlx_err)?;
        Ok(weights)
    }

    fn arrays(&self) -> Vec<&Array> {
        let s = &self.sub;
        let mut out = vec![
            &s.conv0_w,
            &s.conv0_b,
            &s.conv2_w,
            &s.conv2_b,
            &s.conv3_w,
            &s.conv3_w_r16,
            &s.conv3_b,
            &s.conv5_w,
            &s.conv5_b,
            &s.conv6_w,
            &s.conv6_w_r16,
            &s.conv6_b,
            &s.out_w,
            &s.out_b,
            &self.pos_w_all,
            &self.pos_freqs,
        ];
        for l in &self.layers {
            out.extend([
                &l.norm_ff1.0,
                &l.norm_ff1.1,
                &l.ff1_w1,
                &l.ff1_w2,
                &l.norm_attn.0,
                &l.norm_attn.1,
                &l.q_w,
                &l.k_w,
                &l.v_w,
                &l.out_w,
                &l.pos_bias_u,
                &l.pos_bias_v,
                &l.norm_conv.0,
                &l.norm_conv.1,
                &l.pw1_w,
                &l.dw_w,
                &l.bn_mean,
                &l.bn_std,
                &l.bn_w,
                &l.bn_b,
                &l.pw2_w,
                &l.norm_ff2.0,
                &l.norm_ff2.1,
                &l.ff2_w1,
                &l.ff2_w2,
                &l.norm_out.0,
                &l.norm_out.1,
            ]);
        }
        out
    }
}

thread_local! {
    /// Engines of one dtype on one thread share one copy of the weights (read-only arrays).
    static WEIGHTS: RefCell<Vec<(PathBuf, Dtype, Weak<Weights>)>> = const { RefCell::new(Vec::new()) };
}

fn shared_weights(path: &Path, dtype: Dtype) -> Result<Rc<Weights>, String> {
    let canonical = path
        .canonicalize()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let cached = WEIGHTS.with(|cache| {
        let mut cache = cache.borrow_mut();
        cache.retain(|(_, _, weak)| weak.strong_count() > 0);
        cache
            .iter()
            .find(|(p, d, _)| *p == canonical && *d == dtype)
            .and_then(|(_, _, weak)| weak.upgrade())
    });
    if let Some(weights) = cached {
        return Ok(weights);
    }
    let model = Model::open(&canonical).map_err(|e| format!("{}: {e}", canonical.display()))?;
    let weights = Rc::new(Weights::load(&model, dtype)?);
    WEIGHTS.with(|cache| {
        cache
            .borrow_mut()
            .push((canonical, dtype, Rc::downgrade(&weights)))
    });
    Ok(weights)
}

// ---------------------------------------------------------------------------------------------
// Elementwise chains (eager, or fused by `compile`)

fn silu(x: &Array) -> MlxResult<Array> {
    x.multiply(ops::sigmoid(x)?)
}

fn ew_silu(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![silu(&a[0])?])
}

/// SiLU whose output is a matmul operand (F32Mm16).
fn ew_silu_r16(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![round16(&silu(&a[0])?)?])
}

fn ew_round16(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![round16(&a[0])?])
}

/// `round16(a + b)` (F32Mm16: `Q + u`, `Q + v`, conv2/conv5 + bias before the 1x1 casts).
fn ew_add_r16(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![round16(&a[0].add(&a[1])?)?])
}

/// `x + h * s` (FFN residual, `s = 0.5`).
fn ew_scaled_residual(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![a[0].add(a[1].multiply(&a[2])?)?])
}

/// `(a + b) * s` (attention scores; the SDPA arms' pre-scaled `Q + v`).
fn ew_add_scale(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![a[0].add(&a[1])?.multiply(&a[2])?])
}

/// GLU: `signal * sigmoid(gate)` (L4020-L4027).
fn ew_glu(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![a[0].multiply(ops::sigmoid(&a[1])?)?])
}

/// BatchNorm without epsilon, then SiLU: `y = (h - mean) / std * w + b; y * sigmoid(y)`
/// (L4056-L4068, same op order).
fn bn_silu(a: &[Array]) -> MlxResult<Array> {
    let y = a[0]
        .subtract(&a[1])?
        .divide(&a[2])?
        .multiply(&a[3])?
        .add(&a[4])?;
    silu(&y)
}

fn ew_bn_silu(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![bn_silu(a)?])
}

fn ew_bn_silu_r16(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![round16(&bn_silu(a)?)?])
}

/// `relu(x + b)` with `a[2]` the zero of the arm's dtype.
fn ew_bias_relu(a: &[Array]) -> MlxResult<Vec<Array>> {
    Ok(vec![ops::maximum(a[0].add(&a[1])?, &a[2])?])
}

struct Kernels {
    /// SiLU (rounded to f16 for F32Mm16: its output feeds `linear2`).
    silu: Fused,
    scaled_residual: Fused,
    add_scale: Fused,
    glu: Fused,
    /// BatchNorm + SiLU (rounded to f16 for F32Mm16: its output feeds `pointwise_conv2`).
    bn_silu: Fused,
    bias_relu: Fused,
    round16: Fused,
    add_r16: Fused,
}

impl Kernels {
    fn new(compiled: bool, round: bool) -> Kernels {
        fn make(f: fn(&[Array]) -> MlxResult<Vec<Array>>, compiled: bool) -> Fused {
            if compiled {
                Box::new(compile(f, true))
            } else {
                Box::new(f)
            }
        }
        Kernels {
            silu: make(if round { ew_silu_r16 } else { ew_silu }, compiled),
            scaled_residual: make(ew_scaled_residual, compiled),
            add_scale: make(ew_add_scale, compiled),
            glu: make(ew_glu, compiled),
            bn_silu: make(if round { ew_bn_silu_r16 } else { ew_bn_silu }, compiled),
            bias_relu: make(ew_bias_relu, compiled),
            round16: make(ew_round16, compiled),
            add_r16: make(ew_add_r16, compiled),
        }
    }
}

fn one(f: &mut Fused, args: &[Array]) -> MlxResult<Array> {
    let mut out = f(args)?;
    out.pop()
        .ok_or_else(|| Exception::custom("fused kernel returned no output"))
}

/// `y = x · Wᵀ` for `W[out][in]` (`ggml_mul_mat(W, x)`).
fn linear(x: &Array, w: &Array) -> MlxResult<Array> {
    x.matmul(w.t())
}

// ---------------------------------------------------------------------------------------------
// Engine

/// Wall-clock split of the last `Engine::encode` (µs): host mel upload and graph construction,
/// `eval` (GPU execution and synchronization), copy-out.
#[derive(Clone, Copy, Debug, Default)]
pub struct Profile {
    pub build_us: f64,
    pub eval_us: f64,
    pub copy_us: f64,
}

pub struct Engine {
    arm: Arm,
    weights: Rc<Weights>,
    kernels: Kernels,
    /// Scalars in the arm's dtype: 0, 0.5 (`fc_factor`), 1/√128.
    zero: Array,
    half: Array,
    scale: Array,
    last_profile: Profile,
}

impl Engine {
    pub fn new(model_path: &Path, arm_name: &str) -> Result<Engine, String> {
        let arm = Arm::parse(arm_name)
            .ok_or_else(|| format!("unknown arm {arm_name:?}; known: {}", Arm::NAMES))?;
        let dtype = arm.precision.dtype();
        let weights = shared_weights(model_path, dtype)?;
        let scalar = |v: f32| Array::from_f32(v).as_dtype(dtype).map_err(mlx_err);
        let zero = scalar(0.0)?;
        let half = scalar(0.5)?;
        let scale = scalar(1.0 / (D_HEAD as f32).sqrt())?;
        transforms::eval([&zero, &half, &scale]).map_err(mlx_err)?;
        let kernels = Kernels::new(arm.compiled, arm.precision.rounds_operands());
        Ok(Engine {
            arm,
            weights,
            kernels,
            zero,
            half,
            scale,
            last_profile: Profile::default(),
        })
    }

    pub fn last_profile(&self) -> Profile {
        self.last_profile
    }

    /// Rounds a matmul operand to f16 in the F32Mm16 arms; identity otherwise.
    fn r16(&mut self, x: Array) -> MlxResult<Array> {
        if self.arm.precision.rounds_operands() {
            one(&mut self.kernels.round16, &[x])
        } else {
            Ok(x)
        }
    }

    /// `round16(a + b)` in the F32Mm16 arms, `a + b` otherwise.
    fn add_r16(&mut self, a: &Array, b: &Array) -> MlxResult<Array> {
        if self.arm.precision.rounds_operands() {
            one(&mut self.kernels.add_r16, &[a.clone(), b.clone()])
        } else {
            a.add(b)
        }
    }

    pub fn arm(&self) -> Arm {
        self.arm
    }

    /// Encodes one utterance. `mel` is frame-major `[n_mel_frames][128]`; `out` receives
    /// frame-major `[n_enc_frames][1024]` f32. Returns `n_enc_frames`.
    pub fn encode(
        &mut self,
        mel: &[f32],
        n_mel_frames: usize,
        out: &mut [f32],
    ) -> Result<usize, String> {
        if n_mel_frames == 0 {
            return Err("empty mel".to_owned());
        }
        if mel.len() != n_mel_frames * N_MELS {
            return Err(format!(
                "mel has {} values, expected {n_mel_frames} x {N_MELS}",
                mel.len()
            ));
        }
        let t_enc = n_enc_frames(n_mel_frames);
        if t_enc > LOCAL_ATTN_THRESHOLD {
            return Err(format!(
                "{t_enc} encoder frames need local attention (> {LOCAL_ATTN_THRESHOLD})"
            ));
        }
        if out.len() < t_enc * N_STATE {
            return Err(format!(
                "output holds {} values, need {t_enc} x {N_STATE}",
                out.len()
            ));
        }
        let start = std::time::Instant::now();
        let mel = Array::from_slice(mel, &[n_mel_frames as i32, N_MELS as i32]);
        let states = self.forward(&mel).map_err(mlx_err)?;
        let built = std::time::Instant::now();
        transforms::eval([&states]).map_err(mlx_err)?;
        let evaluated = std::time::Instant::now();
        if states.shape() != [t_enc as i32, N_STATE as i32] {
            return Err(format!(
                "graph produced shape {:?}, expected [{t_enc}, {N_STATE}]",
                states.shape()
            ));
        }
        let data = states
            .try_as_slice::<f32>()
            .map_err(|e| format!("mlx output: {e}"))?;
        out[..data.len()].copy_from_slice(data);
        let copied = std::time::Instant::now();
        self.last_profile = Profile {
            build_us: (built - start).as_secs_f64() * 1e6,
            eval_us: (evaluated - built).as_secs_f64() * 1e6,
            copy_us: (copied - evaluated).as_secs_f64() * 1e6,
        };
        Ok(t_enc)
    }

    /// The whole encoder as one lazy graph (nothing is evaluated here).
    fn forward(&mut self, mel: &Array) -> MlxResult<Array> {
        let weights = Rc::clone(&self.weights);
        let dtype = weights.dtype;
        let x = self.subsample(&weights.sub, mel, dtype)?;
        let t = x.shape()[0];

        // Relative positional encoding (L3670-L3685, inputs L4217-L4246), projected by every
        // layer's linear_pos at once: P_all = pos_emb · W_pos_allᵀ, [2T-1, 24 * 1024].
        let window = 2 * t - 1;
        let rel: Vec<f32> = (0..window).map(|p| (t - 1 - p) as f32).collect();
        let theta = Array::from_slice(&rel, &[window, 1]).multiply(&weights.pos_freqs)?;
        let pos_emb = ops::stack(&[ops::sin(&theta)?, ops::cos(&theta)?], -1)?
            .reshape(&[window, N_STATE as i32])?
            .as_dtype(dtype)?;
        let pos_emb = self.r16(pos_emb)?;
        let pos_all = linear(&pos_emb, &weights.pos_w_all)?;
        let pos_all = self.r16(pos_all)?;
        let pos = ops::split_equal(&pos_all, N_LAYER as i32, -1)?;

        let mut x = x;
        for (layer, pos_l) in weights.layers.iter().zip(&pos) {
            x = self.layer(layer, &x, pos_l, t)?;
        }
        x.as_dtype(Dtype::Float32)
    }

    /// Conv subsampling (L3538-L3620), NHWC with H = time, W = freq.
    fn subsample(&mut self, s: &SubsamplingWeights, mel: &Array, dtype: Dtype) -> MlxResult<Array> {
        let round = self.arm.precision.rounds_operands();
        let t_mel = mel.shape()[0];
        let x = mel
            .as_dtype(dtype)?
            .reshape(&[1, t_mel, N_MELS as i32, 1])?;
        // conv0: 3x3, stride 2, pad 1, 1 -> 256, then ReLU. (ggml: im2col into f16, L3501.)
        let x = self.r16(x)?;
        let x = ops::conv2d(&x, &s.conv0_w, (2, 2), (1, 1), (1, 1), 1)?;
        let x = one(
            &mut self.kernels.bias_relu,
            &[x, s.conv0_b.clone(), self.zero.clone()],
        )?;
        // conv2: depthwise 3x3, stride 2, pad 1, + bias (f32 in ggml).
        let x = ops::conv2d(&x, &s.conv2_w, (2, 2), (1, 1), (1, 1), SUB_CHANNELS)?;
        let x = self.add_r16(&x, &s.conv2_b)?;
        // conv3: pointwise 256 -> 256 (ggml casts the activations to f16, L3499), + bias, ReLU.
        let (t2, f2) = (x.shape()[1], x.shape()[2]);
        let w3 = if round { &s.conv3_w_r16 } else { &s.conv3_w };
        let x = linear(&x.reshape(&[t2 * f2, SUB_CHANNELS])?, w3)?;
        let x = one(
            &mut self.kernels.bias_relu,
            &[x, s.conv3_b.clone(), self.zero.clone()],
        )?;
        let x = x.reshape(&[1, t2, f2, SUB_CHANNELS])?;
        // conv5: depthwise 3x3, stride 2, pad 1, + bias.
        let x = ops::conv2d(&x, &s.conv5_w, (2, 2), (1, 1), (1, 1), SUB_CHANNELS)?;
        let x = self.add_r16(&x, &s.conv5_b)?;
        // conv6: pointwise, + bias, ReLU.
        let (t3, f3) = (x.shape()[1], x.shape()[2]);
        let w6 = if round { &s.conv6_w_r16 } else { &s.conv6_w };
        let x = linear(&x.reshape(&[t3 * f3, SUB_CHANNELS])?, w6)?;
        let x = one(
            &mut self.kernels.bias_relu,
            &[x, s.conv6_b.clone(), self.zero.clone()],
        )?;
        // [t, f, c] -> [t, c, f] -> [t, c * 16 + f] (L3606-L3615), then the output projection.
        let x = x
            .reshape(&[t3, f3, SUB_CHANNELS])?
            .transpose_axes(&[0, 2, 1])?
            .reshape(&[t3, SUB_CHANNELS * f3])?;
        let x = self.r16(x)?;
        linear(&x, &s.out_w)?.add(&s.out_b)
    }

    /// One conformer block (L3687-L4105).
    fn layer(&mut self, l: &LayerWeights, x: &Array, pos: &Array, t: i32) -> MlxResult<Array> {
        let n = N_STATE as i32;

        // FFN1: x += 0.5 * W2 · silu(W1 · LN(x))
        let h = fast::layer_norm(x, &l.norm_ff1.0, &l.norm_ff1.1, EPS)?;
        let h = self.r16(h)?;
        let h = one(&mut self.kernels.silu, &[linear(&h, &l.ff1_w1)?])?;
        let h = linear(&h, &l.ff1_w2)?;
        let x = one(
            &mut self.kernels.scaled_residual,
            &[x.clone(), h, self.half.clone()],
        )?;

        // Self-attention with relative positions.
        let h = fast::layer_norm(&x, &l.norm_attn.0, &l.norm_attn.1, EPS)?;
        let h = self.r16(h)?;
        let attn = self.attention(l, &h, pos, t)?;
        let x = x.add(linear(&attn, &l.out_w)?)?;

        // Conv module.
        let h = fast::layer_norm(&x, &l.norm_conv.0, &l.norm_conv.1, EPS)?;
        let h = self.r16(h)?;
        let h = linear(&h, &l.pw1_w)?; // [T, 2048]
        let halves = ops::split_equal(&h, 2, -1)?;
        let h = one(
            &mut self.kernels.glu,
            &[halves[0].clone(), halves[1].clone()],
        )?; // [T, 1024]
        // Zero-pad (K-1)/2 = 4 frames on each side, then the depthwise k=9 conv:
        // y[t][c] = Σ_k w[c][k] · x[t + k - 4][c] (ggml_ssm_conv, L4029-L4048).
        let pad = (CONV_KERNEL - 1) / 2;
        let h = ops::pad(&h, &[(pad, pad), (0, 0)], None, None)?.reshape(&[1, t + 2 * pad, n])?;
        let h = ops::conv1d(&h, &l.dw_w, 1, 0, 1, n)?.reshape(&[t, n])?;
        let h = one(
            &mut self.kernels.bn_silu,
            &[
                h,
                l.bn_mean.clone(),
                l.bn_std.clone(),
                l.bn_w.clone(),
                l.bn_b.clone(),
            ],
        )?;
        let x = x.add(linear(&h, &l.pw2_w)?)?;

        // FFN2
        let h = fast::layer_norm(&x, &l.norm_ff2.0, &l.norm_ff2.1, EPS)?;
        let h = self.r16(h)?;
        let h = one(&mut self.kernels.silu, &[linear(&h, &l.ff2_w1)?])?;
        let h = linear(&h, &l.ff2_w2)?;
        let x = one(
            &mut self.kernels.scaled_residual,
            &[x, h, self.half.clone()],
        )?;

        fast::layer_norm(&x, &l.norm_out.0, &l.norm_out.1, EPS)
    }

    /// Rel-pos MHSA (dense branch, L3720-L3992) up to, not including, `linear_out`.
    /// `h`: normalized input `[T, 1024]`; `pos`: this layer's `P = linear_pos(pos_emb)`,
    /// `[2T-1, 1024]` (row `p` is relative distance `T-1-p`). Returns `[T, 1024]`, the
    /// `linear_out` operand (rounded to f16 in the F32Mm16 arms).
    fn attention(&mut self, l: &LayerWeights, h: &Array, pos: &Array, t: i32) -> MlxResult<Array> {
        let n = N_STATE as i32;
        let window = 2 * t - 1;
        let q = linear(h, &l.q_w)?.reshape(&[t, N_HEAD, D_HEAD])?;
        let k = linear(h, &l.k_w)?.reshape(&[t, N_HEAD, D_HEAD])?;
        let v = linear(h, &l.v_w)?.reshape(&[t, N_HEAD, D_HEAD])?;
        // P as [H, D, 2T-1] (a strided view of the stacked projection).
        let p = pos
            .reshape(&[window, N_HEAD, D_HEAD])?
            .transpose_axes(&[1, 2, 0])?;

        // rel_shift: score[h][q][k] uses relative distance q - k, i.e. column T-1+k-q of the
        // [H, T, 2T-1] positional scores (patches 0004-0006: center = T-1). As a strided view:
        // offset T-1, query stride 2T-2, key stride 1.
        let shift_strides = |batch: &[i64]| -> Vec<i64> {
            let mut strides = batch.to_vec();
            strides.extend([i64::from(window) - 1, 1]);
            strides
        };
        let head_stride = i64::from(t) * i64::from(window);
        let shift_offset = (t - 1) as usize;

        match self.arm.attention {
            Attention::Manual => {
                let q_u = self
                    .add_r16(&q, &l.pos_bias_u)?
                    .transpose_axes(&[1, 0, 2])?; // [H, T, D]
                let q_v = self
                    .add_r16(&q, &l.pos_bias_v)?
                    .transpose_axes(&[1, 0, 2])?;
                let k = self.r16(k)?;
                let content = q_u.matmul(k.transpose_axes(&[1, 2, 0])?)?; // [H, T, T]
                let position = q_v.matmul(&p)?; // [H, T, 2T-1]
                let shifted = ops::as_strided(
                    &position,
                    &[N_HEAD, t, t],
                    &shift_strides(&[head_stride]),
                    shift_offset,
                )?;
                let scores = one(
                    &mut self.kernels.add_scale,
                    &[content, shifted, self.scale.clone()],
                )?;
                let probs = ops::softmax_axis(&scores, -1, true)?;
                // probs · V takes kernel_mul_mm (half operands) only when ne00 = T >= 64;
                // below that ggml-metal uses the f32 kernel_mul_mv.
                let (probs, v) = if t >= 64 {
                    (self.r16(probs)?, self.r16(v)?)
                } else {
                    (probs, v)
                };
                let o = probs.matmul(v.transpose_axes(&[1, 0, 2])?)?; // [H, T, D]
                self.r16(o.transpose_axes(&[1, 0, 2])?.reshape(&[t, n])?)
            }
            Attention::Sdpa => {
                let q_u = q
                    .add(&l.pos_bias_u)?
                    .reshape(&[1, t, N_HEAD, D_HEAD])?
                    .transpose_axes(&[0, 2, 1, 3])?;
                let q_v = one(
                    &mut self.kernels.add_scale,
                    &[q, l.pos_bias_v.clone(), self.scale.clone()],
                )?
                .transpose_axes(&[1, 0, 2])?;
                let position = q_v.matmul(&p)?; // [H, T, 2T-1], already · 1/√d
                let mask = ops::as_strided(
                    &position,
                    &[1, N_HEAD, t, t],
                    &shift_strides(&[i64::from(N_HEAD) * head_stride, head_stride]),
                    shift_offset,
                )?;
                let k = k
                    .reshape(&[1, t, N_HEAD, D_HEAD])?
                    .transpose_axes(&[0, 2, 1, 3])?;
                let v = v
                    .reshape(&[1, t, N_HEAD, D_HEAD])?
                    .transpose_axes(&[0, 2, 1, 3])?;
                let scale = 1.0 / (D_HEAD as f32).sqrt();
                let o = fast::scaled_dot_product_attention(&q_u, &k, &v, scale, &mask, None)?; // [1, H, T, D]
                o.transpose_axes(&[0, 2, 1, 3])?.reshape(&[t, n])
            }
        }
    }
}
