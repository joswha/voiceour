//! The FastConformer encoder of the pinned parakeet-tdt-0.6b-v3 on candle-metal.
//!
//! Mirrors `parakeet_build_graph_encode` (Vendor/parakeet/src/parakeet.cpp L3520-L4116) for
//! the pinned 0.6b checkpoint: dense attention (T_enc <= 8192), BatchNorm conv module, no
//! biases, no speaker kernel. Line references below are to that file.

use std::cell::RefCell;
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use candle_core::quantized::{GgmlDType, QTensor, ggml_file::qtensor_from_ggml};
use candle_core::{D, DType, Device, IndexOp, Result, Tensor, bail};
use parakeet_model::{EncoderLayer, Model, TensorView};

use crate::arm::{Arm, Precision};
use crate::kernels::{Kernels, LN_WIDTH, SdpaFrameMajor};

/// `hparams.eps` (L313): every encoder LayerNorm.
const EPS: f32 = 1e-5;
/// Dense attention only; longer inputs take the native local-attention branch (L3650).
pub const MAX_ENC_FRAMES: usize = 8192;

/// A matrix `W[n][k]` applied as `y = x · Wᵀ` to frame-major activations `x[t][k]`.
enum Linear {
    /// `[n, k]` in the activation dtype; candle `matmul` (MLX gemm) against the transposed view.
    Dense(Tensor),
    /// ggml-layout `QTensor` (`F16` or `Q8_0`), applied with candle's Metal `mul_mm` kernels.
    Quant(Arc<QTensor>),
}

impl Linear {
    fn fwd(&self, x: &Tensor) -> Result<Tensor> {
        match self {
            Linear::Dense(w) => x.matmul(&w.t()?),
            Linear::Quant(w) => {
                // candle 0.11's QMetalStorage::fwd (mm path) rebuilds the input layout from the
                // shape alone and so reads from buffer offset 0; a view that starts elsewhere
                // must be copied first. The op sets below hand it offset-0 tensors.
                if x.layout().start_offset() != 0 || !x.is_contiguous() {
                    x.force_contiguous()?.apply_op1_no_bwd(w.as_ref())
                } else {
                    x.apply_op1_no_bwd(w.as_ref())
                }
            }
        }
    }
}

/// LayerNorm parameters in both layouts the op sets take.
struct Norm {
    /// γ, β `[n]` in the activation dtype (`candle_nn::ops::layer_norm`).
    gamma: Tensor,
    beta: Tensor,
    /// `[2, n]` f32 rows γ, β (fused `add_ln`).
    packed: Tensor,
}

/// `linear_pos` per arm: dense weights are kept head-major `[H, D, S]` so one batched matmul
/// produces the head-major projection directly.
enum PosLinear {
    Dense(Tensor),
    Quant(Linear),
}

struct Layer {
    ln_ff1: Norm,
    ff1_up: Linear,
    ff1_down: Linear,
    ln_att: Norm,
    /// Q, K, V rows concatenated: `[3S, S]`.
    qkv: Linear,
    out: Linear,
    pos: PosLinear,
    /// pos_bias_u / pos_bias_v as `[H, 1, D]` in the activation dtype (stock).
    bias_u: Tensor,
    bias_v: Tensor,
    /// `[2, H, D]` f32 (fused `split_qkv`).
    bias_uv: Tensor,
    ln_conv: Norm,
    pw1: Linear,
    /// Depthwise taps `[S, 9]` f32.
    dw: Tensor,
    /// BatchNorm vectors `[S]` in the activation dtype (stock): mean, sqrt(var), γ, β.
    bn_mean: Tensor,
    bn_std: Tensor,
    bn_gamma: Tensor,
    bn_beta: Tensor,
    /// `[4, S]` f32 rows mean, sqrt(var), γ, β (fused).
    bn_packed: Tensor,
    pw2: Linear,
    ln_ff2: Norm,
    ff2_up: Linear,
    ff2_down: Linear,
    ln_out: Norm,
}

struct Subsampling {
    /// conv.0 `[C, 9]`, bias `[C]` (f32).
    w0: Tensor,
    b0: Tensor,
    /// conv.2 / conv.5 depthwise `[C, 9]`, bias `[C]` (f32).
    w2: Tensor,
    b2: Tensor,
    w5: Tensor,
    b5: Tensor,
    /// conv.3 / conv.6 pointwise `[C_out, C_in]` and bias `[C, 1]` in the activation dtype.
    w3: Tensor,
    b3: Tensor,
    w6: Tensor,
    b6: Tensor,
    /// `out` linear `[S, C·F]` (input index `c·F + f`), bias `[S]` in the activation dtype.
    out: Linear,
    out_b: Tensor,
    channels: usize,
    n_freq_out: usize,
}

pub struct Encoder {
    arm: Arm,
    device: Device,
    kernels: Kernels,
    sub: Subsampling,
    layers: Vec<Layer>,
    /// `freq[k] = expf(-(2k · logf(10000) / S))`, `[1, S/2]` f32 (L4217-L4228).
    pos_freq: Tensor,
    n_mels: usize,
    n_state: usize,
    n_head: usize,
    d_head: usize,
    profile: RefCell<Option<Profile>>,
}

struct Profile {
    last: Instant,
    stages: Vec<(&'static str, f64, usize)>,
}

fn err<E: std::fmt::Display>(e: E) -> candle_core::Error {
    candle_core::Error::Msg(e.to_string())
}

fn u16_bytes(v: &[u16]) -> &[u8] {
    // SAFETY: u8 has no alignment requirement and every bit pattern is valid.
    unsafe { std::slice::from_raw_parts(v.as_ptr().cast::<u8>(), std::mem::size_of_val(v)) }
}

/// f32 vector (any 1-element-per-row record) as a host Vec.
fn vec_f32(view: &TensorView<'_>) -> Result<Vec<f32>> {
    Ok(view.f32_slice().map_err(err)?.into_owned())
}

impl Encoder {
    pub fn open(model_path: impl AsRef<Path>, arm: Arm) -> Result<Encoder> {
        let model = Model::open(model_path).map_err(err)?;
        let mismatches = model.architecture_mismatches();
        if !mismatches.is_empty() {
            bail!(
                "model does not match the pinned architecture: {}",
                mismatches.join("; ")
            );
        }
        let hp = model.hparams();
        if model.subsampling().causal || model.speaker_kernel().is_some() {
            bail!("speaker-kernel (multitalker) checkpoints are not supported");
        }
        let device = Device::new_metal(0)?;
        let metal = match &device {
            Device::Metal(m) => m.clone(),
            _ => bail!("no Metal device"),
        };
        let kernels = Kernels::new(&metal)?;
        let n_state = hp.n_audio_state as usize;
        let n_head = hp.n_audio_head as usize;
        let d_head = n_state / n_head;
        if n_state != LN_WIDTH {
            bail!("fused LayerNorm assumes n_state {LN_WIDTH}, model has {n_state}");
        }
        let loader = Loader {
            arm,
            device: &device,
        };
        let sub = loader.subsampling(&model)?;
        let mut layers = Vec::with_capacity(hp.n_audio_layer as usize);
        for layer in model.encoder_layers() {
            layers.push(loader.layer(&layer, n_head, d_head)?);
        }
        let log_10000 = 10000f32.ln();
        let d_half = n_state / 2;
        let freq: Vec<f32> = (0..d_half)
            .map(|k| (-(((k * 2) as f32) * log_10000 / n_state as f32)).exp())
            .collect();
        let pos_freq = Tensor::from_slice(&freq, (1, d_half), &device)?;
        // Make the uploads and conversions resident before the first encode is timed.
        device.synchronize()?;
        Ok(Encoder {
            arm,
            device,
            kernels,
            sub,
            layers,
            pos_freq,
            n_mels: hp.n_mels as usize,
            n_state,
            n_head,
            d_head,
            profile: RefCell::new(None),
        })
    }

    pub fn arm(&self) -> Arm {
        self.arm
    }

    pub fn n_mels(&self) -> usize {
        self.n_mels
    }

    pub fn n_state(&self) -> usize {
        self.n_state
    }

    /// `parakeet_encoder_frame_count` for this (non-causal) file: `ceil(n / 8)`.
    pub fn enc_frames(n_mel_frames: usize) -> usize {
        n_mel_frames.div_ceil(2).div_ceil(2).div_ceil(2)
    }

    /// Host mel `[n_mel_frames][n_mels]` in, host states `[n_enc][n_state]` out (synchronized),
    /// with the arm's op set. Returns `n_enc`.
    pub fn encode(&self, mel: &[f32], n_mel_frames: usize, out: &mut [f32]) -> Result<usize> {
        self.encode_with(mel, n_mel_frames, out, self.arm.fused)
    }

    /// `encode` with an explicit op set: one loaded precision serves both `<p>` and `<p>+fused`.
    pub fn encode_with(
        &self,
        mel: &[f32],
        n_mel_frames: usize,
        out: &mut [f32],
        fused: bool,
    ) -> Result<usize> {
        if n_mel_frames == 0 {
            bail!("empty mel");
        }
        if mel.len() != n_mel_frames * self.n_mels {
            bail!(
                "mel has {} values, expected {} x {}",
                mel.len(),
                n_mel_frames,
                self.n_mels
            );
        }
        let n_enc = Self::enc_frames(n_mel_frames);
        if n_enc > MAX_ENC_FRAMES {
            bail!(
                "{n_enc} encoder frames need the local-attention branch, which is not implemented"
            );
        }
        if out.len() < n_enc * self.n_state {
            bail!(
                "output holds {} values, need {}",
                out.len(),
                n_enc * self.n_state
            );
        }
        let mel = Tensor::from_slice(mel, (n_mel_frames, self.n_mels), &self.device)?;
        let states = self.forward(&mel, fused)?;
        let states = states
            .to_dtype(DType::F32)?
            .flatten_all()?
            .to_vec1::<f32>()?;
        self.mark("readback");
        out[..states.len()].copy_from_slice(&states);
        Ok(n_enc)
    }

    /// mel `[n_t, n_mels]` f32 → encoder states `[T_enc, S]` in the activation dtype.
    pub fn forward(&self, mel: &Tensor, fused: bool) -> Result<Tensor> {
        let (mut x, n_t) = self.subsample(mel)?;
        let pos = self.pos_emb(n_t)?;
        self.mark("pos_emb");
        for layer in &self.layers {
            x = if fused {
                self.layer_fused(layer, &x, &pos, n_t)?
            } else {
                self.layer_stock(layer, &x, &pos, n_t)?
            };
        }
        Ok(x)
    }

    /// Stage profiling: when enabled, every `mark` synchronizes the device and charges the wall
    /// time since the previous mark to its label. Serializes the GPU; for attribution only.
    pub fn set_profiling(&self, enabled: bool) {
        *self.profile.borrow_mut() = enabled.then(|| Profile {
            last: Instant::now(),
            stages: Vec::new(),
        });
    }

    /// Restarts the profile clock (call right before the profiled encode).
    pub fn profile_start(&self) {
        if let Some(p) = self.profile.borrow_mut().as_mut() {
            let _ = self.device.synchronize();
            p.last = Instant::now();
        }
    }

    /// Accumulated `(label, seconds, count)` since `set_profiling(true)`.
    pub fn profile_stages(&self) -> Vec<(&'static str, f64, usize)> {
        self.profile
            .borrow()
            .as_ref()
            .map(|p| p.stages.clone())
            .unwrap_or_default()
    }

    fn mark(&self, label: &'static str) {
        let mut guard = self.profile.borrow_mut();
        let Some(p) = guard.as_mut() else { return };
        let _ = self.device.synchronize();
        let now = Instant::now();
        let dt = (now - p.last).as_secs_f64();
        p.last = now;
        match p.stages.iter_mut().find(|(l, _, _)| *l == label) {
            Some(entry) => {
                entry.1 += dt;
                entry.2 += 1;
            }
            None => p.stages.push((label, dt, 1)),
        }
    }

    /// Conv subsampling (L3538-L3620): `[n_t, 128]` → `([T_enc, S], T_enc)`.
    fn subsample(&self, mel: &Tensor) -> Result<(Tensor, usize)> {
        let s = &self.sub;
        let c = s.channels;
        let act = self.arm.act_dtype();
        self.mark("upload");
        // [C, T/2, 64]
        let x = self.kernels.sub_conv0(mel, &s.w0, &s.b0, act)?;
        self.mark("sub.conv0");
        // [C, T/4, 32]
        let x = self.kernels.sub_dw_s2(&x, &s.w2, &s.b2)?;
        self.mark("sub.dw");
        let (_, h2, w2) = x.dims3()?;
        let x = s.w3.matmul(&x.reshape((c, h2 * w2))?)?;
        self.mark("sub.pw_matmul");
        let x = x.broadcast_add(&s.b3)?.relu()?;
        self.mark("sub.pw_bias_relu");
        // [C, T/8, 16]
        let x = self
            .kernels
            .sub_dw_s2(&x.reshape((c, h2, w2))?, &s.w5, &s.b5)?;
        self.mark("sub.dw");
        let (_, n_t, f) = x.dims3()?;
        debug_assert_eq!(f, s.n_freq_out);
        let x = s.w6.matmul(&x.reshape((c, n_t * f))?)?;
        self.mark("sub.pw_matmul");
        let x = x.broadcast_add(&s.b6)?.relu()?;
        self.mark("sub.pw_bias_relu");
        // [C, T, F] → [T, C, F] → [T, C·F] (L3606-L3615)
        let x = x
            .reshape((c, n_t, f))?
            .transpose(0, 1)?
            .contiguous()?
            .reshape((n_t, c * f))?;
        self.mark("sub.flatten");
        let x = s.out.fwd(&x)?;
        self.mark("sub.out_matmul");
        let x = x.broadcast_add(&s.out_b)?;
        self.mark("sub.out_bias");
        Ok((x, n_t))
    }

    /// Relative positional embedding (L3670-L3685, inputs L4217-L4246): `[2T-1, S]`,
    /// `pe[p][2k] = sin(freq[k]·(T-1-p))`, `pe[p][2k+1] = cos(…)`, sin/cos on the device.
    fn pos_emb(&self, n_t: usize) -> Result<Tensor> {
        let w = 2 * n_t - 1;
        let rel: Vec<f32> = (0..w).map(|p| (n_t - 1) as f32 - p as f32).collect();
        let rel = Tensor::from_slice(&rel, (w, 1), &self.device)?;
        let theta = self.pos_freq.broadcast_mul(&rel)?;
        let pe =
            Tensor::stack(&[theta.sin()?, theta.cos()?], D::Minus1)?.reshape((w, self.n_state))?;
        pe.to_dtype(self.arm.act_dtype())
    }

    /// `linear_pos · pos_emb`, head-major `[H, 2T-1, D]`.
    fn pos_proj(&self, layer: &Layer, pos: &Tensor) -> Result<Tensor> {
        let (w, s) = pos.dims2()?;
        let (h, d) = (self.n_head, self.d_head);
        match &layer.pos {
            PosLinear::Dense(w_hds) => pos
                .unsqueeze(0)?
                .broadcast_as((h, w, s))?
                .matmul(&w_hds.transpose(1, 2)?),
            PosLinear::Quant(lin) => lin
                .fwd(pos)?
                .reshape((w, h, d))?
                .transpose(0, 1)?
                .contiguous(),
        }
    }

    /// One conformer block with candle's stock ops (L3687-L4105).
    fn layer_stock(&self, l: &Layer, x: &Tensor, pos: &Tensor, n_t: usize) -> Result<Tensor> {
        use candle_nn::ops::{layer_norm, sdpa, sigmoid};
        let (h, d, s) = (self.n_head, self.d_head, self.n_state);
        let scale = 1.0 / (d as f64).sqrt();
        let w = 2 * n_t - 1;

        // FFN1: x += 0.5 · W2 silu(W1 LN(x))
        let y = layer_norm(x, &l.ln_ff1.gamma, &l.ln_ff1.beta, EPS)?;
        self.mark("layernorm");
        let x = self.ffn(&l.ff1_up, &l.ff1_down, x, &y)?;

        // Rel-pos MHSA
        let y = layer_norm(&x, &l.ln_att.gamma, &l.ln_att.beta, EPS)?;
        self.mark("layernorm");
        let qkv = l.qkv.fwd(&y)?.reshape((n_t, 3, h, d))?;
        self.mark("attn.qkv_matmul");
        let q = qkv.i((.., 0))?.transpose(0, 1)?; // [H, T, D] view
        let k = qkv.i((.., 1))?.transpose(0, 1)?.unsqueeze(0)?;
        let v = qkv.i((.., 2))?.transpose(0, 1)?.unsqueeze(0)?;
        let q_u = q.broadcast_add(&l.bias_u)?.unsqueeze(0)?;
        // The 1/sqrt(D) score scale is folded into the position term here and into q inside
        // the attention kernel: softmax(scale · (q_u·k + shift(q_v·p))).
        let q_v = q.broadcast_add(&l.bias_v)?.affine(scale, 0.0)?;
        self.mark("attn.split_bias");
        let p = self.pos_proj(l, pos)?;
        self.mark("attn.pos_matmul");
        let bd = q_v.matmul(&p.t()?)?; // [H, T, 2T-1]
        self.mark("attn.bd_matmul");
        // rel_shift: mask[h][q][k] = bd[h][q][T-1+k-q] — flat offset T-1, row pitch 2T-2.
        let mask = bd
            .reshape((h, n_t * w))?
            .narrow(1, n_t - 1, n_t * (w - 1))?
            .reshape((h, n_t, w - 1))?
            .narrow(2, 0, n_t)?
            .unsqueeze(0)?;
        self.mark("attn.rel_shift");
        let att = sdpa(&q_u, &k, &v, Some(&mask), false, scale as f32, 1.0)?; // [1, H, T, D]
        self.mark("attn.sdpa");
        let att = att
            .squeeze(0)?
            .transpose(0, 1)?
            .contiguous()?
            .reshape((n_t, s))?;
        self.mark("attn.merge_heads");
        let o = l.out.fwd(&att)?;
        self.mark("attn.out_matmul");
        let x = (x + o)?;
        self.mark("residual");

        // Conv module
        let y = layer_norm(&x, &l.ln_conv.gamma, &l.ln_conv.beta, EPS)?;
        self.mark("layernorm");
        let y = l.pw1.fwd(&y)?;
        self.mark("conv.pw1_matmul");
        let glu = (y.narrow(1, 0, s)? * sigmoid(&y.narrow(1, s, s)?)?)?;
        self.mark("conv.glu");
        let y = self.kernels.dwconv9(&glu, &l.dw)?;
        self.mark("conv.depthwise");
        let y = y
            .broadcast_sub(&l.bn_mean)?
            .broadcast_div(&l.bn_std)?
            .broadcast_mul(&l.bn_gamma)?
            .broadcast_add(&l.bn_beta)?;
        self.mark("conv.batchnorm");
        let y = y.silu()?;
        self.mark("conv.silu");
        let y = l.pw2.fwd(&y)?;
        self.mark("conv.pw2_matmul");
        let x = (x + y)?;
        self.mark("residual");

        // FFN2
        let y = layer_norm(&x, &l.ln_ff2.gamma, &l.ln_ff2.beta, EPS)?;
        self.mark("layernorm");
        let x = self.ffn(&l.ff2_up, &l.ff2_down, &x, &y)?;

        let out = layer_norm(&x, &l.ln_out.gamma, &l.ln_out.beta, EPS)?;
        self.mark("layernorm");
        Ok(out)
    }

    /// Macaron half-step FFN with stock ops: `x + 0.5 · down(silu(up(y)))`.
    fn ffn(&self, up: &Linear, down: &Linear, x: &Tensor, y: &Tensor) -> Result<Tensor> {
        let y = up.fwd(y)?;
        self.mark("ffn.up_matmul");
        let y = y.silu()?;
        self.mark("ffn.silu");
        let y = down.fwd(&y)?;
        self.mark("ffn.down_matmul");
        let x = (x + y.affine(0.5, 0.0)?)?;
        self.mark("residual");
        Ok(x)
    }

    /// `down(silu(up(y)))` (fused op set: the residual goes into `add_ln`).
    fn ffn_body(&self, up: &Linear, down: &Linear, y: &Tensor) -> Result<Tensor> {
        let y = up.fwd(y)?;
        self.mark("ffn.up_matmul");
        let y = y.silu()?;
        self.mark("ffn.silu");
        let y = down.fwd(&y)?;
        self.mark("ffn.down_matmul");
        Ok(y)
    }

    /// The same block with the fused custom kernels.
    fn layer_fused(&self, l: &Layer, x: &Tensor, pos: &Tensor, n_t: usize) -> Result<Tensor> {
        let (h, d) = (self.n_head, self.d_head);
        let scale = 1.0 / (d as f32).sqrt();
        let k = &self.kernels;

        let y = k.ln(x, &l.ln_ff1.packed)?;
        self.mark("layernorm");
        let f = self.ffn_body(&l.ff1_up, &l.ff1_down, &y)?;
        let (r, y) = k.add_ln(x, &f, 0.5, &l.ln_att.packed, true)?;
        let r = r.expect("residual kept");
        self.mark("residual+layernorm");

        let qkv = l.qkv.fwd(&y)?;
        self.mark("attn.qkv_matmul");
        let (q_u, q_v) = k.split_qkv(&qkv, &l.bias_uv, h, d, scale)?;
        self.mark("attn.split_bias");
        let qkv = qkv.reshape((n_t, 3, h, d))?;
        let kk = qkv.i((.., 1))?.transpose(0, 1)?.unsqueeze(0)?;
        let vv = qkv.i((.., 2))?.transpose(0, 1)?.unsqueeze(0)?;
        let p = self.pos_proj(l, pos)?;
        self.mark("attn.pos_matmul");
        let bd = q_v.matmul(&p.t()?)?;
        self.mark("attn.bd_matmul");
        let mask = k.rel_shift(&bd)?.unsqueeze(0)?;
        self.mark("attn.rel_shift");
        let att = q_u
            .unsqueeze(0)?
            .apply_op3_no_bwd(&kk, &vv, &SdpaFrameMajor { mask, scale })?;
        self.mark("attn.sdpa");
        let o = l.out.fwd(&att)?;
        self.mark("attn.out_matmul");
        let (r, y) = k.add_ln(&r, &o, 1.0, &l.ln_conv.packed, true)?;
        let r = r.expect("residual kept");
        self.mark("residual+layernorm");

        let c = l.pw1.fwd(&y)?;
        self.mark("conv.pw1_matmul");
        let c = k.glu_dwconv9_bn_silu(&c, &l.dw, &l.bn_packed)?;
        self.mark("conv.glu_depthwise_bn_silu");
        let c = l.pw2.fwd(&c)?;
        self.mark("conv.pw2_matmul");
        let (r, y) = k.add_ln(&r, &c, 1.0, &l.ln_ff2.packed, true)?;
        let r = r.expect("residual kept");
        self.mark("residual+layernorm");

        let f = self.ffn_body(&l.ff2_up, &l.ff2_down, &y)?;
        let (_, out) = k.add_ln(&r, &f, 0.5, &l.ln_out.packed, false)?;
        self.mark("residual+layernorm");
        Ok(out)
    }
}

/// Uploads one arm's weights.
struct Loader<'a> {
    arm: Arm,
    device: &'a Device,
}

impl Loader<'_> {
    fn act(&self) -> DType {
        self.arm.act_dtype()
    }

    /// f32 host values as a device tensor in the activation dtype.
    fn act_tensor(&self, values: &[f32], shape: &[usize]) -> Result<Tensor> {
        Tensor::from_slice(values, shape, self.device)?.to_dtype(self.act())
    }

    fn f32_tensor(&self, values: &[f32], shape: &[usize]) -> Result<Tensor> {
        Tensor::from_slice(values, shape, self.device)
    }

    fn norm(&self, gamma: &TensorView<'_>, beta: &TensorView<'_>) -> Result<Norm> {
        let g = vec_f32(gamma)?;
        let b = vec_f32(beta)?;
        let n = g.len();
        let packed: Vec<f32> = g.iter().chain(b.iter()).copied().collect();
        Ok(Norm {
            gamma: self.act_tensor(&g, &[n])?,
            beta: self.act_tensor(&b, &[n])?,
            packed: self.f32_tensor(&packed, &[2, n])?,
        })
    }

    /// Concatenates the rows of f16 matrices `W[n_i][k]` and uploads them per arm.
    fn linear(&self, views: &[&TensorView<'_>]) -> Result<Linear> {
        let k = views[0].row_len();
        let mut bits: Vec<u16> = Vec::new();
        let mut n = 0;
        for view in views {
            if view.row_len() != k {
                bail!("{}: row length {} != {k}", view.name, view.row_len());
            }
            bits.extend_from_slice(&view.f16_slice().map_err(err)?);
            n += view.n_rows();
        }
        let f16 = || Tensor::from_raw_buffer(u16_bytes(&bits), DType::F16, &[n, k], self.device);
        Ok(match self.arm.precision {
            Precision::F32 => Linear::Dense(f16()?.to_dtype(DType::F32)?),
            Precision::F16 => Linear::Dense(f16()?),
            Precision::Bf16 => Linear::Dense(f16()?.to_dtype(DType::BF16)?),
            Precision::F16w => Linear::Quant(Arc::new(qtensor_from_ggml(
                GgmlDType::F16,
                u16_bytes(&bits),
                vec![n, k],
                self.device,
            )?)),
            Precision::Q8_0 => {
                let row_bytes = k / parakeet_model::QK8_0 * parakeet_model::BLOCK_Q8_0_BYTES;
                // u16 backing keeps the blocks 2-byte aligned for candle's BlockQ8_0 view.
                let mut blocks = vec![0u16; (n * row_bytes).div_ceil(2)];
                // SAFETY: u8 view of the u16 buffer, same length in bytes rounded down to n·row_bytes.
                let bytes = unsafe {
                    std::slice::from_raw_parts_mut(blocks.as_mut_ptr().cast::<u8>(), n * row_bytes)
                };
                let mut row = vec![0f32; k];
                for (r, dst) in bits.chunks_exact(k).zip(bytes.chunks_exact_mut(row_bytes)) {
                    parakeet_model::f16_slice_to_f32(r, &mut row);
                    parakeet_model::quantize_row_q8_0(&row, dst);
                }
                let bytes = &u16_bytes(&blocks)[..n * row_bytes];
                Linear::Quant(Arc::new(qtensor_from_ggml(
                    GgmlDType::Q8_0,
                    bytes,
                    vec![n, k],
                    self.device,
                )?))
            }
        })
    }

    /// A 3x3 single-input-channel kernel record `[3, 3, 1, C]` as `[C, 9]` f32.
    fn taps(&self, view: &TensorView<'_>) -> Result<Tensor> {
        let w = vec_f32(view)?;
        let c = w.len() / 9;
        self.f32_tensor(&w, &[c, 9])
    }

    fn subsampling(&self, model: &Model) -> Result<Subsampling> {
        let v = model.subsampling();
        let c = v.n_channels;
        let pointwise = |w: &TensorView<'_>, b: &TensorView<'_>| -> Result<(Tensor, Tensor)> {
            Ok((
                self.act_tensor(&vec_f32(w)?, &[c, c])?,
                self.act_tensor(&vec_f32(b)?, &[c, 1])?,
            ))
        };
        let (w3, b3) = pointwise(&v.conv3_w, &v.conv3_b)?;
        let (w6, b6) = pointwise(&v.conv6_w, &v.conv6_b)?;
        let out_b = vec_f32(&v.out_b)?;
        Ok(Subsampling {
            w0: self.taps(&v.conv0_w)?,
            b0: self.f32_tensor(&vec_f32(&v.conv0_b)?, &[c])?,
            w2: self.taps(&v.conv2_w)?,
            b2: self.f32_tensor(&vec_f32(&v.conv2_b)?, &[c])?,
            w5: self.taps(&v.conv5_w)?,
            b5: self.f32_tensor(&vec_f32(&v.conv5_b)?, &[c])?,
            w3,
            b3,
            w6,
            b6,
            out: self.linear(&[&v.out_w])?,
            out_b: self.act_tensor(&out_b, &[out_b.len()])?,
            channels: c,
            n_freq_out: v.n_freq_out,
        })
    }

    fn layer(&self, l: &EncoderLayer<'_>, n_head: usize, d_head: usize) -> Result<Layer> {
        if l.ff1_linear1_b.is_some() || l.attn_q_b.is_some() || l.conv_pw1_b.is_some() {
            bail!("bias-variant checkpoints are not supported");
        }
        let (Some(mean), Some(var)) = (l.conv_bn_mean, l.conv_bn_var_as_loaded()) else {
            bail!("conv LayerNorm (no BatchNorm stats) checkpoints are not supported");
        };
        let s = n_head * d_head;
        let mean = vec_f32(&mean)?;
        // The graph divides by ggml_sqrt(running_var), no epsilon (L4056-L4059).
        let std: Vec<f32> = var.iter().map(|v| v.sqrt()).collect();
        let gamma = vec_f32(&l.conv_bn_w)?;
        let beta = vec_f32(&l.conv_bn_b)?;
        let bn_packed: Vec<f32> = mean
            .iter()
            .chain(&std)
            .chain(&gamma)
            .chain(&beta)
            .copied()
            .collect();
        let u = vec_f32(&l.attn_pos_bias_u)?;
        let v = vec_f32(&l.attn_pos_bias_v)?;
        let uv: Vec<f32> = u.iter().chain(&v).copied().collect();
        let pos = match self.arm.precision {
            Precision::F32 | Precision::F16 | Precision::Bf16 => {
                match self.linear(&[&l.attn_pos_w])? {
                    Linear::Dense(w) => PosLinear::Dense(w.reshape((n_head, d_head, s))?),
                    Linear::Quant(_) => unreachable!("dense precision"),
                }
            }
            Precision::F16w | Precision::Q8_0 => PosLinear::Quant(self.linear(&[&l.attn_pos_w])?),
        };
        // ggml_ssm_conv taps: record ne [9, S] is row-major w[c][k].
        let dw = vec_f32(&l.conv_dw_w)?;
        Ok(Layer {
            ln_ff1: self.norm(&l.norm_ff1_w, &l.norm_ff1_b)?,
            ff1_up: self.linear(&[&l.ff1_linear1_w])?,
            ff1_down: self.linear(&[&l.ff1_linear2_w])?,
            ln_att: self.norm(&l.norm_attn_w, &l.norm_attn_b)?,
            qkv: self.linear(&[&l.attn_q_w, &l.attn_k_w, &l.attn_v_w])?,
            out: self.linear(&[&l.attn_out_w])?,
            pos,
            bias_u: self.act_tensor(&u, &[n_head, 1, d_head])?,
            bias_v: self.act_tensor(&v, &[n_head, 1, d_head])?,
            bias_uv: self.f32_tensor(&uv, &[2, n_head, d_head])?,
            ln_conv: self.norm(&l.norm_conv_w, &l.norm_conv_b)?,
            pw1: self.linear(&[&l.conv_pw1_w])?,
            dw: self.f32_tensor(&dw, &[s, dw.len() / s])?,
            bn_mean: self.act_tensor(&mean, &[s])?,
            bn_std: self.act_tensor(&std, &[s])?,
            bn_gamma: self.act_tensor(&gamma, &[s])?,
            bn_beta: self.act_tensor(&beta, &[s])?,
            bn_packed: self.f32_tensor(&bn_packed, &[4, s])?,
            pw2: self.linear(&[&l.conv_pw2_w])?,
            ln_ff2: self.norm(&l.norm_ff2_w, &l.norm_ff2_b)?,
            ff2_up: self.linear(&[&l.ff2_linear1_w])?,
            ff2_down: self.linear(&[&l.ff2_linear2_w])?,
            ln_out: self.norm(&l.norm_out_w, &l.norm_out_b)?,
        })
    }
}
