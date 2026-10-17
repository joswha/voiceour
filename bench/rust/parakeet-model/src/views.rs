//! "As-loaded" semantic accessors: the arrays the native code computes with, named by role.
//!
//! Conventions (see [`TensorView`]): `ne` is ggml order, `ne[0]` contiguous. A matrix with
//! `ne = [in, out]` is row-major `W[out][in]` and is applied as `y = W · x` (`ggml_mul_mat`).
//! Every matrix weight below is a record-typed tensor (f16 in the pinned file); every vector,
//! norm parameter, conv kernel and bias is f32. `parakeet_model_load` performs no reordering,
//! transposition or folding on these payloads: what the file holds is what the graphs use.
//! The only load-time value rewrites are (a) the BatchNorm-eps fold for bias-variant files
//! ([`EncoderLayer::conv_bn_var_as_loaded`]) and (b) the opt-in CPU-tail q8_0 repack
//! ([`TensorView::requantize_q8_0`]); neither applies to the pinned file in production.

use std::borrow::Cow;

use crate::arch::TensorKind as K;
use crate::model::{Model, TensorView, le_f32_slice};

/// `PARAKEET_SAMPLE_RATE` (parakeet.h L33).
pub const SAMPLE_RATE: u32 = 16_000;
/// `PARAKEET_HOP_LENGTH` (parakeet.h L34): mel frame step in samples.
pub const HOP_LENGTH: usize = 160;
/// Pre-emphasis coefficient applied before the STFT (`log_mel_spectrogram`, parakeet.cpp L5127).
pub const PREEMPHASIS: f32 = 0.97;
/// Guard added to every mel energy before `log` (2^-24, parakeet.cpp L5045), in double.
pub const LOG_GUARD: f64 = 5.960_464_477_539_063e-8;
/// Epsilon added to the per-feature standard deviation (parakeet.cpp L5179), in double.
pub const NORMALIZE_EPS: f64 = 1e-5;

/// Mel frontend data (`model.filters`, `mel_cache.window`) plus the constants
/// `log_mel_spectrogram` (parakeet.cpp L5104-L5221) combines them with.
#[derive(Clone, Debug)]
pub struct Preprocessor<'a> {
    /// FFT / frame size: `hparams.n_fft` (512).
    pub n_fft: usize,
    /// Mel bins: `filters.n_mel` (128) — the value `parakeet_pcm_to_mel` passes as `n_mel`.
    pub n_mels: usize,
    /// Frequency bins per filter row: `filters.n_fb` (257 = n_fft / 2 + 1).
    pub n_fb: usize,
    /// Filterbank, row-major `[n_mels][n_fb]`: `mel[j] = Σ_k power[k] · filterbank[j * n_fb + k]`.
    pub filterbank: Cow<'a, [f32]>,
    /// Analysis window from the file (400 samples, Parakeet's training window). Native code
    /// centres it in the `n_fft` frame at [`Preprocessor::window_pad_left`]; with an empty file
    /// window it would fall back to a periodic Hann window of `n_fft` (L5120-L5121) — the
    /// pinned file always has one.
    pub window: Cow<'a, [f32]>,
    /// Per-feature z-score normalization is on unless the file has a speaker kernel
    /// (`normalize: NA` multitalker checkpoints, parakeet.cpp L5783-L5784).
    pub normalize_per_feature: bool,
}

impl Preprocessor<'_> {
    /// Leading zeros before the window inside each `n_fft` frame: `(n_fft - window.len()) / 2`
    /// (56 for the pinned file). Frame `i` is
    /// `fft_in[pad + j] = window[j] * padded[i * HOP_LENGTH + pad + j]`, zeros elsewhere.
    pub fn window_pad_left(&self) -> usize {
        self.n_fft.saturating_sub(self.window.len()) / 2
    }

    /// Frames the native frontend emits for `n_samples` input samples: centred padding of
    /// `n_fft / 2` zeros each side, then `(n_samples + 2 * (n_fft / 2) - n_fft) / HOP_LENGTH + 1`.
    pub fn n_frames(&self, n_samples: usize) -> usize {
        (n_samples + 2 * (self.n_fft / 2) - self.n_fft) / HOP_LENGTH + 1
    }
}

/// Convolutional subsampling (`encoder.pre_encode.*`), graph at parakeet.cpp L3538-L3620.
///
/// Input is the mel tensor `ne = [n_mels, T, 1, 1]` (row-major `mel[t][f]`, exactly the
/// frame-major dump layout): ggml's conv2d width axis is frequency and height axis is time.
/// Pinned (non-causal) order: `conv0` (3x3, stride 2, pad 1, 1→C) → ReLU → `conv2` (depthwise
/// 3x3, stride 2, pad 1) + bias → `conv3` (pointwise C→C) → ReLU → `conv5` (depthwise 3x3,
/// stride 2, pad 1) + bias → `conv6` (pointwise) → ReLU → flatten → `out`. Each stride-2 stage
/// maps a length `L` to `ceil(L / 2)`: 128 mel bins → 16, `T` frames → `ceil(T / 8)`.
#[derive(Clone, Copy, Debug)]
pub struct Subsampling<'a> {
    /// `conv.0.weight`, ne `[3 (kw: freq), 3 (kh: time), 1 (in ch), C (out ch)]`: row-major
    /// `w[oc][ic][kt][kf]`, PyTorch `Conv2d.weight` `[C, 1, 3, 3]` over `[B, 1, T, F]`.
    /// Applied through `ggml_im2col` with an f16 destination: the mel input is rounded to f16.
    pub conv0_w: TensorView<'a>,
    /// `conv.0.bias`, ne `[1, 1, C, 1]`: one f32 per output channel.
    pub conv0_b: TensorView<'a>,
    /// `conv.2.weight` (depthwise), ne `[3, 3, 1, C]`: row-major `w[c][0][kt][kf]`;
    /// `ggml_conv_2d_dw_direct` in f32.
    pub conv2_w: TensorView<'a>,
    /// `conv.2.bias`, ne `[1, 1, C, 1]`.
    pub conv2_b: TensorView<'a>,
    /// `conv.3.weight` (pointwise), ne `[1, 1, C (in), C (out)]`: row-major `W[out][in]`.
    /// The 1x1 fast path casts the activations to f16 before the matmul (L3493-L3499).
    pub conv3_w: TensorView<'a>,
    /// `conv.3.bias`, ne `[1, 1, C, 1]`.
    pub conv3_b: TensorView<'a>,
    /// `conv.5.weight` (depthwise), ne `[3, 3, 1, C]`.
    pub conv5_w: TensorView<'a>,
    /// `conv.5.bias`, ne `[1, 1, C, 1]`.
    pub conv5_b: TensorView<'a>,
    /// `conv.6.weight` (pointwise), ne `[1, 1, C, C]`: row-major `W[out][in]`.
    pub conv6_w: TensorView<'a>,
    /// `conv.6.bias`, ne `[1, 1, C, 1]`.
    pub conv6_b: TensorView<'a>,
    /// `out.weight`, ne `[n_freq_out * C (in), n_state (out)]`: row-major `W[out][in]` with
    /// input feature index `c * n_freq_out + f` (channel-major, frequency fastest), matching
    /// the graph's permute `[freq, time, chan] → [freq, chan, time]` and flatten (L3606-L3615).
    pub out_w: TensorView<'a>,
    /// `out.bias`, ne `[n_state]`.
    pub out_b: TensorView<'a>,
    /// Subsampling channels `C` (256).
    pub n_channels: usize,
    /// Frequency cells after the three stride-2 stages: `n_pre_enc_features / C` (16).
    pub n_freq_out: usize,
    /// Causal dw-striding (speaker-kernel files only): zero-pad 2 leading / 1 trailing per axis
    /// and stride padding 0 instead of symmetric padding 1 (L3547-L3553).
    pub causal: bool,
}

impl Subsampling<'_> {
    /// `parakeet_encoder_frame_count` (parakeet.cpp L1350): encoder frames for `n_mel_frames`.
    pub fn n_out_frames(&self, n_mel_frames: usize) -> usize {
        if self.causal {
            (0..3).fold(n_mel_frames, |l, _| l / 2 + 1)
        } else {
            n_mel_frames.div_ceil(8)
        }
    }
}

/// One conformer layer (`encoder.layers.<index>.*`), graph at parakeet.cpp L3687-L4105.
///
/// Block order: `x += 0.5 · FFN1(LN(x))`; `x += MHSA(LN(x))`; `x += Conv(LN(x))`;
/// `x += 0.5 · FFN2(LN(x))`; `x = LN_out(x)`. Every LayerNorm is `ggml_norm(eps = 1e-5)`
/// followed by `* weight + bias`. `S = n_state` (1024), `H` heads (8), `D = S / H` (128).
/// The `*_b` options are the bias-variant (1.1b) biases: all `None` for the pinned file.
#[derive(Clone, Copy, Debug)]
pub struct EncoderLayer<'a> {
    /// Layer index.
    pub index: usize,
    /// FFN1 LayerNorm γ, ne `[S]`.
    pub norm_ff1_w: TensorView<'a>,
    /// FFN1 LayerNorm β, ne `[S]`.
    pub norm_ff1_b: TensorView<'a>,
    /// FFN1 up-projection, ne `[S (in), 4S (out)]`: row-major `W[4S][S]`; followed by SiLU.
    pub ff1_linear1_w: TensorView<'a>,
    /// Optional bias, ne `[4S]`.
    pub ff1_linear1_b: Option<TensorView<'a>>,
    /// FFN1 down-projection, ne `[4S (in), S (out)]`: row-major `W[S][4S]`.
    pub ff1_linear2_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub ff1_linear2_b: Option<TensorView<'a>>,
    /// Self-attention LayerNorm γ, ne `[S]`.
    pub norm_attn_w: TensorView<'a>,
    /// Self-attention LayerNorm β, ne `[S]`.
    pub norm_attn_b: TensorView<'a>,
    /// Query projection, ne `[S, S]`: row-major `W[out][in]`; output feature `h * D + d` is
    /// head `h`, lane `d` (reshaped to ne `[D, H, T]`).
    pub attn_q_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub attn_q_b: Option<TensorView<'a>>,
    /// Key projection, ne `[S, S]`, same layout as `attn_q_w`.
    pub attn_k_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub attn_k_b: Option<TensorView<'a>>,
    /// Value projection, ne `[S, S]`, same layout as `attn_q_w`.
    pub attn_v_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub attn_v_b: Option<TensorView<'a>>,
    /// Output projection, ne `[S (in: h * D + d), S (out)]`: row-major `W[out][in]`.
    pub attn_out_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub attn_out_b: Option<TensorView<'a>>,
    /// `linear_pos` (no bias), ne `[S, S]`: projects the in-graph sinusoidal relative position
    /// embedding `pos_emb[p]` (`p = 0..2T-1`, relative distance `T-1-p`) to ne `[D, H, 2T-1]`.
    pub attn_pos_w: TensorView<'a>,
    /// `pos_bias_u`, ne `[D, H]`: row-major `u[h][d]`; `Q_u[t][h][d] = Q[t][h][d] + u[h][d]`
    /// scores content (`Q_u · K`).
    pub attn_pos_bias_u: TensorView<'a>,
    /// `pos_bias_v`, ne `[D, H]`: row-major `v[h][d]`; `Q_v = Q + v` scores position.
    pub attn_pos_bias_v: TensorView<'a>,
    /// Conv-module LayerNorm γ, ne `[S]`.
    pub norm_conv_w: TensorView<'a>,
    /// Conv-module LayerNorm β, ne `[S]`.
    pub norm_conv_b: TensorView<'a>,
    /// Pointwise conv 1, ne `[S (in), 2S (out)]`: row-major `W[2S][S]` (PyTorch
    /// `Conv1d.weight [2S, S, 1]`). GLU: `out[0..S] * sigmoid(out[S..2S])`.
    pub conv_pw1_w: TensorView<'a>,
    /// Optional bias (before the GLU), ne `[2S]`.
    pub conv_pw1_b: Option<TensorView<'a>>,
    /// Depthwise conv taps, ne `[K (tap), S (channel)]`: row-major `w[c][k]` (PyTorch
    /// `[S, 1, K]`). `y[t][c] = Σ_k w[c][k] · x[t + k - (K-1)/2][c]`, zero padded (f32
    /// `ggml_ssm_conv`; the speaker-kernel variant is causal: all `K-1` pad zeros on the left).
    pub conv_dw_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub conv_dw_b: Option<TensorView<'a>>,
    /// BatchNorm γ (or conv-LayerNorm γ when the running stats are absent), ne `[S]`.
    pub conv_bn_w: TensorView<'a>,
    /// BatchNorm β, ne `[S]`.
    pub conv_bn_b: TensorView<'a>,
    /// BatchNorm running mean, ne `[S]`. The graph computes, lazily and with NO epsilon,
    /// `(x - mean) / sqrt(var) * γ + β` (L4056-L4065).
    pub conv_bn_mean: Option<TensorView<'a>>,
    /// BatchNorm running variance as stored in the file, ne `[S]`. Use
    /// [`EncoderLayer::conv_bn_var_as_loaded`] for the values the graph divides by.
    pub conv_bn_var: Option<TensorView<'a>>,
    /// `num_batches_tracked`: one element the loader holds as `GGML_TYPE_I32`; unused by the
    /// graph (see [`TensorView::as_i32`]).
    pub conv_bn_num_batches: Option<TensorView<'a>>,
    /// Pointwise conv 2, ne `[S, S]`: row-major `W[out][in]`; after SiLU.
    pub conv_pw2_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub conv_pw2_b: Option<TensorView<'a>>,
    /// FFN2 LayerNorm γ, ne `[S]`.
    pub norm_ff2_w: TensorView<'a>,
    /// FFN2 LayerNorm β, ne `[S]`.
    pub norm_ff2_b: TensorView<'a>,
    /// FFN2 up-projection, ne `[S, 4S]`: row-major `W[4S][S]`; followed by SiLU.
    pub ff2_linear1_w: TensorView<'a>,
    /// Optional bias, ne `[4S]`.
    pub ff2_linear1_b: Option<TensorView<'a>>,
    /// FFN2 down-projection, ne `[4S, S]`: row-major `W[S][4S]`.
    pub ff2_linear2_w: TensorView<'a>,
    /// Optional bias, ne `[S]`.
    pub ff2_linear2_b: Option<TensorView<'a>>,
    /// Output LayerNorm γ, ne `[S]`. The last layer's output is the encoder output.
    pub norm_out_w: TensorView<'a>,
    /// Output LayerNorm β, ne `[S]`.
    pub norm_out_b: TensorView<'a>,
    bias_variant: bool,
}

impl EncoderLayer<'_> {
    /// The BatchNorm variance the graph divides by (`sqrt(var)`, no epsilon in the graph).
    /// For bias-variant files the loader adds `1e-5f` to every element after reading
    /// (`fold_bias_variant_bn_eps`, parakeet.cpp L3363-L3386); for every other file — the
    /// pinned one included — this is the stored array unchanged. `None` without BN stats.
    pub fn conv_bn_var_as_loaded(&self) -> Option<Vec<f32>> {
        let mut var = self.conv_bn_var?.to_f32_vec();
        if self.bias_variant {
            for v in &mut var {
                *v += 1e-5f32;
            }
        }
        Some(var)
    }
}

/// The optional multitalker speaker kernel (absent in the pinned file), graph at L3625-L3644:
/// `x += FF(x)` then `x += FF_bg(0 · x)`, each `FF = W2 · relu(W1 · x + b1) + b2`.
#[derive(Clone, Copy, Debug)]
pub struct SpeakerKernel<'a> {
    /// `spk_kernels.0.0.weight`, ne `[S, S]`.
    pub ff1_w: TensorView<'a>,
    /// `spk_kernels.0.0.bias`, ne `[S]`.
    pub ff1_b: TensorView<'a>,
    /// `spk_kernels.0.3.weight`, ne `[S, S]`.
    pub ff2_w: TensorView<'a>,
    /// `spk_kernels.0.3.bias`, ne `[S]`.
    pub ff2_b: TensorView<'a>,
    /// `bg_spk_kernels.0.0.weight`, ne `[S, S]`.
    pub bg_ff1_w: TensorView<'a>,
    /// `bg_spk_kernels.0.0.bias`, ne `[S]`.
    pub bg_ff1_b: TensorView<'a>,
    /// `bg_spk_kernels.0.3.weight`, ne `[S, S]`.
    pub bg_ff2_w: TensorView<'a>,
    /// `bg_spk_kernels.0.3.bias`, ne `[S]`.
    pub bg_ff2_b: TensorView<'a>,
}

/// One LSTM layer of the prediction network, step graph at parakeet.cpp L4323-L4389.
///
/// Gate rows are packed `[i, f, o, c]` (`P` rows each) and the bias is the folded
/// `b_ih + b_hh` — both done by the converter, so the file already holds this layout.
/// One step, in the native op order:
/// `gates = W_ih·x + (W_hh·h + b_h)`; `i, f, o = sigmoid(gates[0..3P])`;
/// `g = tanh(gates[3P..4P])`; `c' = f*c + i*g`; `h' = o * tanh(c')`.
#[derive(Clone, Copy, Debug)]
pub struct LstmLayer<'a> {
    /// LSTM layer index.
    pub index: usize,
    /// `weight_ih_l<index>`, ne `[P (in), 4P (gates)]`: row-major `W_ih[4P][P]`.
    pub w_ih: TensorView<'a>,
    /// `weight_hh_l<index>`, ne `[P (in: h), 4P (gates)]`: row-major `W_hh[4P][P]`.
    pub w_hh: TensorView<'a>,
    /// `bias_h_l<index>`, ne `[4P]`: folded `b_ih + b_hh`, gate order `[i, f, o, c]`.
    pub b_h: TensorView<'a>,
}

/// Prediction network (`decoder.prediction.*`), parakeet.cpp L4397-L4433.
#[derive(Clone, Debug)]
pub struct Prediction<'a> {
    /// `embed.weight`, ne `[P, n_vocab + 1]`: row-major `E[token][P]`; `ggml_get_rows` picks
    /// row `token`. The blank (id `blank_id`, the start token) is the last row.
    pub embed: TensorView<'a>,
    /// LSTM layers bottom-up; layer 0 consumes the embedding, layer `l` the `h` of `l - 1`.
    pub layers: Vec<LstmLayer<'a>>,
    /// Hidden width `P` (640).
    pub n_hidden: usize,
    /// Blank token id (8192), also the first token fed to the network.
    pub blank_id: i32,
}

/// Joint network (`joint.*`), step graph at parakeet.cpp L4474-L4528:
/// `logits = net_w · relu((enc_w · e_t + enc_b) + (pred_w · h_top + pred_b)) + net_b`.
#[derive(Clone, Copy, Debug)]
pub struct Joint<'a> {
    /// `enc.weight`, ne `[S (in: encoder frame), P (out)]`: row-major `W[P][S]`.
    pub enc_w: TensorView<'a>,
    /// `enc.bias`, ne `[P]`.
    pub enc_b: TensorView<'a>,
    /// `pred.weight`, ne `[P (in: top LSTM h), P (out)]`: row-major `W[P][P]`. Native code
    /// applies it inside the prediction subgraph and caches the result (`pstate.pred_out`).
    pub pred_w: TensorView<'a>,
    /// `pred.bias`, ne `[P]`.
    pub pred_b: TensorView<'a>,
    /// `joint_net.2.weight`, ne `[P (in), n_vocab + n_durations + 1 (out)]`: row-major
    /// `W[out][P]`. Output slots: `0..n_vocab` pieces, `n_vocab` blank, then one slot per
    /// TDT duration (`tdt_durations()[i]` at `n_vocab + 1 + i`).
    pub net_w: TensorView<'a>,
    /// `joint_net.2.bias`, ne `[n_vocab + n_durations + 1]`.
    pub net_b: TensorView<'a>,
    /// `hparams.n_vocab` (8192).
    pub n_vocab: usize,
    /// `hparams.n_tdt_durations` (5).
    pub n_durations: usize,
    /// Blank token id (8192).
    pub blank_id: i32,
}

impl Joint<'_> {
    /// Width of the output row (8198).
    pub fn n_out(&self) -> usize {
        self.n_vocab + self.n_durations + 1
    }

    /// Token slots the greedy argmax scans: `0..=blank_id` (`n_vocab_logits`, L4773).
    pub fn token_slots(&self) -> std::ops::Range<usize> {
        0..self.blank_id as usize + 1
    }

    /// Duration slots: `n_vocab + 1 ..` (`duration_logits_raw` offset, L4652-L4666).
    pub fn duration_slots(&self) -> std::ops::Range<usize> {
        self.n_vocab + 1..self.n_vocab + 1 + self.n_durations
    }
}

impl Model {
    /// Mel frontend data and constants.
    pub fn preprocessor(&self) -> Preprocessor<'_> {
        let (fb, n_mels, n_fb) = self.filterbank_raw();
        Preprocessor {
            n_fft: self.hparams().n_fft as usize,
            n_mels,
            n_fb,
            filterbank: le_f32_slice(fb),
            window: le_f32_slice(self.window_raw()),
            normalize_per_feature: !self.variant().speaker_kernel,
        }
    }

    /// The conv-subsampling tensors.
    pub fn subsampling(&self) -> Subsampling<'_> {
        let n_channels = self.hparams().n_subsampling_channels as usize;
        Subsampling {
            conv0_w: self.must(K::EncPreConv0Weight, 0),
            conv0_b: self.must(K::EncPreConv0Bias, 0),
            conv2_w: self.must(K::EncPreConv2Weight, 0),
            conv2_b: self.must(K::EncPreConv2Bias, 0),
            conv3_w: self.must(K::EncPreConv3Weight, 0),
            conv3_b: self.must(K::EncPreConv3Bias, 0),
            conv5_w: self.must(K::EncPreConv5Weight, 0),
            conv5_b: self.must(K::EncPreConv5Bias, 0),
            conv6_w: self.must(K::EncPreConv6Weight, 0),
            conv6_b: self.must(K::EncPreConv6Bias, 0),
            out_w: self.must(K::EncPreOutWeight, 0),
            out_b: self.must(K::EncPreOutBias, 0),
            n_channels,
            n_freq_out: self.n_pre_enc_features() as usize / n_channels,
            causal: self.variant().speaker_kernel,
        }
    }

    /// Conformer layer `index`, or `None` past `n_audio_layer`.
    pub fn encoder_layer(&self, index: usize) -> Option<EncoderLayer<'_>> {
        if index >= self.hparams().n_audio_layer as usize {
            return None;
        }
        let m = |kind| self.must(kind, index);
        let o = |kind| self.tensor_of(kind, index);
        Some(EncoderLayer {
            index,
            norm_ff1_w: m(K::EncNormFf1Weight),
            norm_ff1_b: m(K::EncNormFf1Bias),
            ff1_linear1_w: m(K::EncFf1Linear1Weight),
            ff1_linear1_b: o(K::EncFf1Linear1Bias),
            ff1_linear2_w: m(K::EncFf1Linear2Weight),
            ff1_linear2_b: o(K::EncFf1Linear2Bias),
            norm_attn_w: m(K::EncNormAttnWeight),
            norm_attn_b: m(K::EncNormAttnBias),
            attn_q_w: m(K::EncAttnQWeight),
            attn_q_b: o(K::EncAttnQBias),
            attn_k_w: m(K::EncAttnKWeight),
            attn_k_b: o(K::EncAttnKBias),
            attn_v_w: m(K::EncAttnVWeight),
            attn_v_b: o(K::EncAttnVBias),
            attn_out_w: m(K::EncAttnOutWeight),
            attn_out_b: o(K::EncAttnOutBias),
            attn_pos_w: m(K::EncAttnPosWeight),
            attn_pos_bias_u: m(K::EncAttnPosBiasU),
            attn_pos_bias_v: m(K::EncAttnPosBiasV),
            norm_conv_w: m(K::EncNormConvWeight),
            norm_conv_b: m(K::EncNormConvBias),
            conv_pw1_w: m(K::EncConvPw1Weight),
            conv_pw1_b: o(K::EncConvPw1Bias),
            conv_dw_w: m(K::EncConvDwWeight),
            conv_dw_b: o(K::EncConvDwBias),
            conv_bn_w: m(K::EncConvBnWeight),
            conv_bn_b: m(K::EncConvBnBias),
            conv_bn_mean: o(K::EncConvBnMean),
            conv_bn_var: o(K::EncConvBnVar),
            conv_bn_num_batches: o(K::EncConvBnNumBatches),
            conv_pw2_w: m(K::EncConvPw2Weight),
            conv_pw2_b: o(K::EncConvPw2Bias),
            norm_ff2_w: m(K::EncNormFf2Weight),
            norm_ff2_b: m(K::EncNormFf2Bias),
            ff2_linear1_w: m(K::EncFf2Linear1Weight),
            ff2_linear1_b: o(K::EncFf2Linear1Bias),
            ff2_linear2_w: m(K::EncFf2Linear2Weight),
            ff2_linear2_b: o(K::EncFf2Linear2Bias),
            norm_out_w: m(K::EncNormOutWeight),
            norm_out_b: m(K::EncNormOutBias),
            bias_variant: self.variant().encoder_biases,
        })
    }

    /// All conformer layers in order.
    pub fn encoder_layers(&self) -> impl ExactSizeIterator<Item = EncoderLayer<'_>> + '_ {
        (0..self.hparams().n_audio_layer as usize).map(move |i| {
            self.encoder_layer(i)
                .expect("layer index below n_audio_layer")
        })
    }

    /// The multitalker speaker kernel, when the file has one.
    pub fn speaker_kernel(&self) -> Option<SpeakerKernel<'_>> {
        if !self.variant().speaker_kernel {
            return None;
        }
        Some(SpeakerKernel {
            ff1_w: self.must(K::SpkFf1Weight, 0),
            ff1_b: self.must(K::SpkFf1Bias, 0),
            ff2_w: self.must(K::SpkFf2Weight, 0),
            ff2_b: self.must(K::SpkFf2Bias, 0),
            bg_ff1_w: self.must(K::BgSpkFf1Weight, 0),
            bg_ff1_b: self.must(K::BgSpkFf1Bias, 0),
            bg_ff2_w: self.must(K::BgSpkFf2Weight, 0),
            bg_ff2_b: self.must(K::BgSpkFf2Bias, 0),
        })
    }

    /// The prediction network.
    pub fn prediction(&self) -> Prediction<'_> {
        Prediction {
            embed: self.must(K::PredEmbedWeight, 0),
            layers: (0..self.hparams().n_pred_layers as usize)
                .map(|index| LstmLayer {
                    index,
                    w_ih: self.must(K::PredLstmWeightIh, index),
                    w_hh: self.must(K::PredLstmWeightHh, index),
                    b_h: self.must(K::PredLstmBiasH, index),
                })
                .collect(),
            n_hidden: self.hparams().n_pred_dim as usize,
            blank_id: self.vocab().blank_id(),
        }
    }

    /// The joint network.
    pub fn joint(&self) -> Joint<'_> {
        Joint {
            enc_w: self.must(K::JointEncWeight, 0),
            enc_b: self.must(K::JointEncBias, 0),
            pred_w: self.must(K::JointPredWeight, 0),
            pred_b: self.must(K::JointPredBias, 0),
            net_w: self.must(K::JointNetWeight, 0),
            net_b: self.must(K::JointNetBias, 0),
            n_vocab: self.hparams().n_vocab as usize,
            n_durations: self.hparams().n_tdt_durations as usize,
            blank_id: self.vocab().blank_id(),
        }
    }
}
