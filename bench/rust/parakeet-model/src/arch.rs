//! The architecture table `parakeet_model_load` builds: hyperparameters
//! (Vendor/parakeet/src/parakeet-arch.h `PARAKEET_HPARAM_*`), every tensor family
//! (`enum parakeet_tensor`, `PARAKEET_TENSOR_NAMES`, `PARAKEET_TENSOR_INFO`) and the
//! ggml extents the loader creates for each one (parakeet.cpp L2682-L2897).

use std::fmt;

use crate::dtype::ftype_to_ggml_type;

/// Hyperparameters exactly as `parakeet_model_load` reads them (parakeet.cpp L2203-L2233), in
/// file order, plus `eps`, the one `parakeet_hparams` value not stored in the file (`arch` is
/// always `PARAKEET_ARCH_TDT`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HParams {
    /// Vocabulary size without the blank (8192). Blank id is the vocab section's piece count.
    pub n_vocab: i32,
    /// Maximum mel frames per encoder pass (5000); the state reserves for it.
    pub n_audio_ctx: i32,
    /// Encoder width d_model (1024).
    pub n_audio_state: i32,
    /// Attention heads (8); head width = `n_audio_state / n_audio_head` (128).
    pub n_audio_head: i32,
    /// Conformer layers (24 in the pinned file).
    pub n_audio_layer: i32,
    /// Mel bins (128).
    pub n_mels: i32,
    /// Raw on-disk `ftype` (model.hparams keeps the raw value; the loader derives `wtype`
    /// from `ftype % 1000`, L2235-L2245). 1 = mostly f16 for the pinned file.
    pub ftype: i32,
    /// FFT size of the mel frontend (512).
    pub n_fft: i32,
    /// Encoder time subsampling (8).
    pub subsampling_factor: i32,
    /// Conv-subsampling channels (256).
    pub n_subsampling_channels: i32,
    /// Depthwise conv kernel of the conformer conv module (9).
    pub n_conv_kernel: i32,
    /// Prediction-network (LSTM) and joint hidden width (640).
    pub n_pred_dim: i32,
    /// LSTM layers (2).
    pub n_pred_layers: i32,
    /// TDT duration slots (5); 0 marks a plain RNN-T decoder.
    pub n_tdt_durations: i32,
    /// Maximum symbols emitted per encoder frame before a forced advance (10).
    pub n_max_tokens: i32,
    /// LayerNorm epsilon: `parakeet_hparams::eps` default 1e-5 (L313). Not stored in the file.
    pub eps: f32,
}

impl HParams {
    /// `ftype / GGML_QNT_VERSION_FACTOR` (quantization version).
    pub fn qntvr(&self) -> i32 {
        self.ftype / GGML_QNT_VERSION_FACTOR
    }

    /// The ggml type id of the nominal weight type `wtype` (`ggml_ftype_to_ggml_type(ftype %
    /// 1000)`). Only the legacy non-seekable loader uses it for tensor types; the seekable file
    /// loader takes every matrix weight's type from its record.
    pub fn wtype(&self) -> Option<i32> {
        ftype_to_ggml_type(self.ftype % GGML_QNT_VERSION_FACTOR)
    }

    /// Attention head width `n_audio_state / n_audio_head` (128).
    pub fn head_dim(&self) -> i32 {
        self.n_audio_state / self.n_audio_head
    }

    /// Rows of the prediction embedding: `n_vocab + 1` (vocabulary plus blank).
    pub fn n_pred_embed(&self) -> i32 {
        self.n_vocab + 1
    }

    /// Packed LSTM gate rows: `4 * n_pred_dim`.
    pub fn n_lstm_gates(&self) -> i32 {
        4 * self.n_pred_dim
    }

    /// Joint output width: `n_vocab + n_tdt_durations + 1` (vocab, blank, durations).
    pub fn n_joint_out(&self) -> i32 {
        self.n_vocab + self.n_tdt_durations + 1
    }

    /// The value of hyperparameter `which`.
    pub fn get(&self, which: HParam) -> i32 {
        match which {
            HParam::NVocab => self.n_vocab,
            HParam::NAudioCtx => self.n_audio_ctx,
            HParam::NAudioState => self.n_audio_state,
            HParam::NAudioHead => self.n_audio_head,
            HParam::NAudioLayer => self.n_audio_layer,
            HParam::NMels => self.n_mels,
            HParam::NFft => self.n_fft,
            HParam::SubsamplingFactor => self.subsampling_factor,
            HParam::NSubsamplingChannels => self.n_subsampling_channels,
            HParam::NConvKernel => self.n_conv_kernel,
            HParam::NPredDim => self.n_pred_dim,
            HParam::NPredLayers => self.n_pred_layers,
            HParam::NTdtDurations => self.n_tdt_durations,
            HParam::NMaxTokens => self.n_max_tokens,
        }
    }
}

/// `GGML_QNT_VERSION_FACTOR` (ggml.h L220).
pub const GGML_QNT_VERSION_FACTOR: i32 = 1000;

/// The validated hyperparameters (`enum parakeet_hparam`, parakeet-arch.h L93).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HParam {
    NVocab,
    NAudioCtx,
    NAudioState,
    NAudioHead,
    NAudioLayer,
    NMels,
    NFft,
    SubsamplingFactor,
    NSubsamplingChannels,
    NConvKernel,
    NPredDim,
    NPredLayers,
    NTdtDurations,
    NMaxTokens,
}

impl HParam {
    /// All validated hyperparameters in `PARAKEET_HPARAM_MODEL_VALUES` order.
    pub const ALL: [HParam; 14] = [
        HParam::NVocab,
        HParam::NAudioCtx,
        HParam::NAudioState,
        HParam::NAudioHead,
        HParam::NAudioLayer,
        HParam::NMels,
        HParam::NFft,
        HParam::SubsamplingFactor,
        HParam::NSubsamplingChannels,
        HParam::NConvKernel,
        HParam::NPredDim,
        HParam::NPredLayers,
        HParam::NTdtDurations,
        HParam::NMaxTokens,
    ];

    /// `PARAKEET_HPARAM_NAMES`.
    pub const fn name(self) -> &'static str {
        match self {
            HParam::NVocab => "n_vocab",
            HParam::NAudioCtx => "n_audio_ctx",
            HParam::NAudioState => "n_audio_state",
            HParam::NAudioHead => "n_audio_head",
            HParam::NAudioLayer => "n_audio_layer",
            HParam::NMels => "n_mels",
            HParam::NFft => "n_fft",
            HParam::SubsamplingFactor => "subsampling_factor",
            HParam::NSubsamplingChannels => "n_subsampling_channels",
            HParam::NConvKernel => "n_conv_kernel",
            HParam::NPredDim => "n_pred_dim",
            HParam::NPredLayers => "n_pred_layers",
            HParam::NTdtDurations => "n_tdt_durations",
            HParam::NMaxTokens => "n_max_tokens",
        }
    }

    /// `PARAKEET_HPARAM_MODEL_VALUES` (parakeet-arch.h L285): the upper bound the loader
    /// accepts and the "standard" value it warns against. `n_audio_layer` is 42 because of
    /// the Voiceour patch for 1.1b checkpoints; the pinned 0.6b file has 24.
    pub const fn model_value(self) -> i32 {
        match self {
            HParam::NVocab => 8192,
            HParam::NAudioCtx => 5000,
            HParam::NAudioState => 1024,
            HParam::NAudioHead => 8,
            HParam::NAudioLayer => 42,
            HParam::NMels => 128,
            HParam::NFft => 512,
            HParam::SubsamplingFactor => 8,
            HParam::NSubsamplingChannels => 256,
            HParam::NConvKernel => 9,
            HParam::NPredDim => 640,
            HParam::NPredLayers => 2,
            HParam::NTdtDurations => 5,
            HParam::NMaxTokens => 10,
        }
    }
}

/// `parakeet_validate_hparams` (parakeet.cpp L1246): every value must be in
/// `(0, model_value]` (`n_tdt_durations` may also be 0, the plain RNN-T marker). Returns the
/// warnings the native loader logs for accepted non-standard values.
pub(crate) fn validate_hparams(hparams: &HParams) -> Result<Vec<String>, String> {
    let mut warnings = Vec::new();
    for which in HParam::ALL {
        let actual = hparams.get(which);
        let expected = which.model_value();
        let rnnt_zero_durations = which == HParam::NTdtDurations && actual == 0;
        if (!rnnt_zero_durations && actual <= 0) || actual > expected {
            return Err(format!(
                "invalid Parakeet metadata: {} = {actual}, expected <= {expected}",
                which.name()
            ));
        }
        if actual != expected {
            warnings.push(format!(
                "non-standard Parakeet metadata: {} = {actual}, expected {expected}",
                which.name()
            ));
        }
    }
    Ok(warnings)
}

/// The ggml op a tensor feeds (`PARAKEET_TENSOR_INFO`, parakeet-arch.h L191).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GgmlOp {
    MulMat,
    Add,
    Mul,
    Sub,
    Div,
    Im2col,
    GetRows,
    None,
}

/// Which layer index a tensor name carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Scope {
    /// One tensor per file.
    Global,
    /// One per conformer layer (`encoder.layers.%d.*`), `n_audio_layer` of them.
    AudioLayer,
    /// One per LSTM layer (`decoder.prediction.dec_rnn.lstm.*_l%d`), `n_pred_layers` of them.
    PredLayer,
}

/// The three all-or-none optional record families of the Voiceour loader
/// (`parakeet_scan_tensor_records`, parakeet.cpp L1180-L1207).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OptionalFamily {
    /// 11 per-layer linear/conv biases of the bias-variant (1.1b) Conformer checkpoints.
    EncoderBias,
    /// BatchNorm running mean / var / num_batches_tracked (absent in conv-LayerNorm files).
    BatchNormStats,
    /// The 8 multitalker speaker-kernel records (`spk_kernels.*`, `bg_spk_kernels.*`).
    SpeakerKernel,
}

/// Reporting groups for `--verify` and [`crate::Model::family_counts`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Family {
    /// `encoder.pre_encode.*` (12).
    PreEncode,
    /// Mandatory per-layer encoder tensors (26 per layer).
    EncoderLayer,
    /// Optional per-layer BatchNorm running statistics (3 per layer).
    BatchNormStats,
    /// Optional per-layer bias-variant biases (11 per layer).
    EncoderBias,
    /// Optional speaker kernel (8).
    SpeakerKernel,
    /// `decoder.prediction.embed.weight` (1).
    PredictionEmbed,
    /// LSTM weights and folded bias (3 per LSTM layer).
    PredictionLstm,
    /// `joint.*` (6).
    Joint,
}

impl Family {
    /// All families in report order.
    pub const ALL: [Family; 8] = [
        Family::PreEncode,
        Family::EncoderLayer,
        Family::BatchNormStats,
        Family::EncoderBias,
        Family::SpeakerKernel,
        Family::PredictionEmbed,
        Family::PredictionLstm,
        Family::Joint,
    ];

    /// Human-readable label.
    pub const fn label(self) -> &'static str {
        match self {
            Family::PreEncode => "encoder.pre_encode",
            Family::EncoderLayer => "encoder.layers (mandatory)",
            Family::BatchNormStats => "encoder.layers batch-norm stats (optional)",
            Family::EncoderBias => "encoder.layers linear/conv biases (optional)",
            Family::SpeakerKernel => "speaker kernels (optional)",
            Family::PredictionEmbed => "decoder.prediction.embed",
            Family::PredictionLstm => "decoder.prediction.dec_rnn.lstm",
            Family::Joint => "joint",
        }
    }

    /// Records the family holds when present, for the given hyperparameters.
    pub fn count_when_present(self, hparams: &HParams) -> usize {
        let layers = hparams.n_audio_layer.max(0) as usize;
        let pred_layers = hparams.n_pred_layers.max(0) as usize;
        match self {
            Family::PreEncode => 12,
            Family::EncoderLayer => 26 * layers,
            Family::BatchNormStats => 3 * layers,
            Family::EncoderBias => 11 * layers,
            Family::SpeakerKernel => 8,
            Family::PredictionEmbed => 1,
            Family::PredictionLstm => 3 * pred_layers,
            Family::Joint => 6,
        }
    }

    /// The optional family this reporting group corresponds to, if any.
    pub const fn optional(self) -> Option<OptionalFamily> {
        match self {
            Family::BatchNormStats => Some(OptionalFamily::BatchNormStats),
            Family::EncoderBias => Some(OptionalFamily::EncoderBias),
            Family::SpeakerKernel => Some(OptionalFamily::SpeakerKernel),
            _ => None,
        }
    }
}

impl fmt::Display for Family {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}

/// Every architecture tensor, in `enum parakeet_tensor` order (parakeet-arch.h L7).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum TensorKind {
    EncPreOutWeight,
    EncPreOutBias,
    EncPreConv0Weight,
    EncPreConv0Bias,
    EncPreConv2Weight,
    EncPreConv2Bias,
    EncPreConv3Weight,
    EncPreConv3Bias,
    EncPreConv5Weight,
    EncPreConv5Bias,
    EncPreConv6Weight,
    EncPreConv6Bias,
    EncNormFf1Weight,
    EncNormFf1Bias,
    EncFf1Linear1Weight,
    EncFf1Linear1Bias,
    EncFf1Linear2Weight,
    EncFf1Linear2Bias,
    EncNormConvWeight,
    EncNormConvBias,
    EncConvPw1Weight,
    EncConvPw1Bias,
    EncConvDwWeight,
    EncConvDwBias,
    EncConvBnWeight,
    EncConvBnBias,
    EncConvBnMean,
    EncConvBnVar,
    EncConvBnNumBatches,
    EncConvPw2Weight,
    EncConvPw2Bias,
    EncNormAttnWeight,
    EncNormAttnBias,
    EncAttnPosBiasU,
    EncAttnPosBiasV,
    EncAttnQWeight,
    EncAttnQBias,
    EncAttnKWeight,
    EncAttnKBias,
    EncAttnVWeight,
    EncAttnVBias,
    EncAttnOutWeight,
    EncAttnOutBias,
    EncAttnPosWeight,
    EncNormFf2Weight,
    EncNormFf2Bias,
    EncFf2Linear1Weight,
    EncFf2Linear1Bias,
    EncFf2Linear2Weight,
    EncFf2Linear2Bias,
    EncNormOutWeight,
    EncNormOutBias,
    SpkFf1Weight,
    SpkFf1Bias,
    SpkFf2Weight,
    SpkFf2Bias,
    BgSpkFf1Weight,
    BgSpkFf1Bias,
    BgSpkFf2Weight,
    BgSpkFf2Bias,
    PredEmbedWeight,
    PredLstmWeightIh,
    PredLstmWeightHh,
    PredLstmBiasH,
    JointPredWeight,
    JointPredBias,
    JointEncWeight,
    JointEncBias,
    JointNetWeight,
    JointNetBias,
}

use TensorKind as K;

impl TensorKind {
    /// Every kind, in enum order.
    pub const ALL: [TensorKind; 70] = [
        K::EncPreOutWeight,
        K::EncPreOutBias,
        K::EncPreConv0Weight,
        K::EncPreConv0Bias,
        K::EncPreConv2Weight,
        K::EncPreConv2Bias,
        K::EncPreConv3Weight,
        K::EncPreConv3Bias,
        K::EncPreConv5Weight,
        K::EncPreConv5Bias,
        K::EncPreConv6Weight,
        K::EncPreConv6Bias,
        K::EncNormFf1Weight,
        K::EncNormFf1Bias,
        K::EncFf1Linear1Weight,
        K::EncFf1Linear1Bias,
        K::EncFf1Linear2Weight,
        K::EncFf1Linear2Bias,
        K::EncNormConvWeight,
        K::EncNormConvBias,
        K::EncConvPw1Weight,
        K::EncConvPw1Bias,
        K::EncConvDwWeight,
        K::EncConvDwBias,
        K::EncConvBnWeight,
        K::EncConvBnBias,
        K::EncConvBnMean,
        K::EncConvBnVar,
        K::EncConvBnNumBatches,
        K::EncConvPw2Weight,
        K::EncConvPw2Bias,
        K::EncNormAttnWeight,
        K::EncNormAttnBias,
        K::EncAttnPosBiasU,
        K::EncAttnPosBiasV,
        K::EncAttnQWeight,
        K::EncAttnQBias,
        K::EncAttnKWeight,
        K::EncAttnKBias,
        K::EncAttnVWeight,
        K::EncAttnVBias,
        K::EncAttnOutWeight,
        K::EncAttnOutBias,
        K::EncAttnPosWeight,
        K::EncNormFf2Weight,
        K::EncNormFf2Bias,
        K::EncFf2Linear1Weight,
        K::EncFf2Linear1Bias,
        K::EncFf2Linear2Weight,
        K::EncFf2Linear2Bias,
        K::EncNormOutWeight,
        K::EncNormOutBias,
        K::SpkFf1Weight,
        K::SpkFf1Bias,
        K::SpkFf2Weight,
        K::SpkFf2Bias,
        K::BgSpkFf1Weight,
        K::BgSpkFf1Bias,
        K::BgSpkFf2Weight,
        K::BgSpkFf2Bias,
        K::PredEmbedWeight,
        K::PredLstmWeightIh,
        K::PredLstmWeightHh,
        K::PredLstmBiasH,
        K::JointPredWeight,
        K::JointPredBias,
        K::JointEncWeight,
        K::JointEncBias,
        K::JointNetWeight,
        K::JointNetBias,
    ];

    /// `PARAKEET_TENSOR_NAMES` pattern; `%d` is the layer index.
    pub const fn pattern(self) -> &'static str {
        match self {
            K::EncPreOutWeight => "encoder.pre_encode.out.weight",
            K::EncPreOutBias => "encoder.pre_encode.out.bias",
            K::EncPreConv0Weight => "encoder.pre_encode.conv.0.weight",
            K::EncPreConv0Bias => "encoder.pre_encode.conv.0.bias",
            K::EncPreConv2Weight => "encoder.pre_encode.conv.2.weight",
            K::EncPreConv2Bias => "encoder.pre_encode.conv.2.bias",
            K::EncPreConv3Weight => "encoder.pre_encode.conv.3.weight",
            K::EncPreConv3Bias => "encoder.pre_encode.conv.3.bias",
            K::EncPreConv5Weight => "encoder.pre_encode.conv.5.weight",
            K::EncPreConv5Bias => "encoder.pre_encode.conv.5.bias",
            K::EncPreConv6Weight => "encoder.pre_encode.conv.6.weight",
            K::EncPreConv6Bias => "encoder.pre_encode.conv.6.bias",
            K::EncNormFf1Weight => "encoder.layers.%d.norm_feed_forward1.weight",
            K::EncNormFf1Bias => "encoder.layers.%d.norm_feed_forward1.bias",
            K::EncFf1Linear1Weight => "encoder.layers.%d.feed_forward1.linear1.weight",
            K::EncFf1Linear1Bias => "encoder.layers.%d.feed_forward1.linear1.bias",
            K::EncFf1Linear2Weight => "encoder.layers.%d.feed_forward1.linear2.weight",
            K::EncFf1Linear2Bias => "encoder.layers.%d.feed_forward1.linear2.bias",
            K::EncNormConvWeight => "encoder.layers.%d.norm_conv.weight",
            K::EncNormConvBias => "encoder.layers.%d.norm_conv.bias",
            K::EncConvPw1Weight => "encoder.layers.%d.conv.pointwise_conv1.weight",
            K::EncConvPw1Bias => "encoder.layers.%d.conv.pointwise_conv1.bias",
            K::EncConvDwWeight => "encoder.layers.%d.conv.depthwise_conv.weight",
            K::EncConvDwBias => "encoder.layers.%d.conv.depthwise_conv.bias",
            K::EncConvBnWeight => "encoder.layers.%d.conv.batch_norm.weight",
            K::EncConvBnBias => "encoder.layers.%d.conv.batch_norm.bias",
            K::EncConvBnMean => "encoder.layers.%d.conv.batch_norm.running_mean",
            K::EncConvBnVar => "encoder.layers.%d.conv.batch_norm.running_var",
            K::EncConvBnNumBatches => "encoder.layers.%d.conv.batch_norm.num_batches_tracked",
            K::EncConvPw2Weight => "encoder.layers.%d.conv.pointwise_conv2.weight",
            K::EncConvPw2Bias => "encoder.layers.%d.conv.pointwise_conv2.bias",
            K::EncNormAttnWeight => "encoder.layers.%d.norm_self_att.weight",
            K::EncNormAttnBias => "encoder.layers.%d.norm_self_att.bias",
            K::EncAttnPosBiasU => "encoder.layers.%d.self_attn.pos_bias_u",
            K::EncAttnPosBiasV => "encoder.layers.%d.self_attn.pos_bias_v",
            K::EncAttnQWeight => "encoder.layers.%d.self_attn.linear_q.weight",
            K::EncAttnQBias => "encoder.layers.%d.self_attn.linear_q.bias",
            K::EncAttnKWeight => "encoder.layers.%d.self_attn.linear_k.weight",
            K::EncAttnKBias => "encoder.layers.%d.self_attn.linear_k.bias",
            K::EncAttnVWeight => "encoder.layers.%d.self_attn.linear_v.weight",
            K::EncAttnVBias => "encoder.layers.%d.self_attn.linear_v.bias",
            K::EncAttnOutWeight => "encoder.layers.%d.self_attn.linear_out.weight",
            K::EncAttnOutBias => "encoder.layers.%d.self_attn.linear_out.bias",
            K::EncAttnPosWeight => "encoder.layers.%d.self_attn.linear_pos.weight",
            K::EncNormFf2Weight => "encoder.layers.%d.norm_feed_forward2.weight",
            K::EncNormFf2Bias => "encoder.layers.%d.norm_feed_forward2.bias",
            K::EncFf2Linear1Weight => "encoder.layers.%d.feed_forward2.linear1.weight",
            K::EncFf2Linear1Bias => "encoder.layers.%d.feed_forward2.linear1.bias",
            K::EncFf2Linear2Weight => "encoder.layers.%d.feed_forward2.linear2.weight",
            K::EncFf2Linear2Bias => "encoder.layers.%d.feed_forward2.linear2.bias",
            K::EncNormOutWeight => "encoder.layers.%d.norm_out.weight",
            K::EncNormOutBias => "encoder.layers.%d.norm_out.bias",
            K::SpkFf1Weight => "spk_kernels.0.0.weight",
            K::SpkFf1Bias => "spk_kernels.0.0.bias",
            K::SpkFf2Weight => "spk_kernels.0.3.weight",
            K::SpkFf2Bias => "spk_kernels.0.3.bias",
            K::BgSpkFf1Weight => "bg_spk_kernels.0.0.weight",
            K::BgSpkFf1Bias => "bg_spk_kernels.0.0.bias",
            K::BgSpkFf2Weight => "bg_spk_kernels.0.3.weight",
            K::BgSpkFf2Bias => "bg_spk_kernels.0.3.bias",
            K::PredEmbedWeight => "decoder.prediction.embed.weight",
            K::PredLstmWeightIh => "decoder.prediction.dec_rnn.lstm.weight_ih_l%d",
            K::PredLstmWeightHh => "decoder.prediction.dec_rnn.lstm.weight_hh_l%d",
            K::PredLstmBiasH => "decoder.prediction.dec_rnn.lstm.bias_h_l%d",
            K::JointPredWeight => "joint.pred.weight",
            K::JointPredBias => "joint.pred.bias",
            K::JointEncWeight => "joint.enc.weight",
            K::JointEncBias => "joint.enc.bias",
            K::JointNetWeight => "joint.joint_net.2.weight",
            K::JointNetBias => "joint.joint_net.2.bias",
        }
    }

    /// The tensor name for `layer` (ignored for [`Scope::Global`] kinds).
    pub fn name(self, layer: usize) -> String {
        match self.scope() {
            Scope::Global => self.pattern().to_owned(),
            Scope::AudioLayer | Scope::PredLayer => {
                self.pattern().replacen("%d", &layer.to_string(), 1)
            }
        }
    }

    /// `parakeet_tensor_has_audio_layer` / `parakeet_tensor_has_prediction_layer`.
    pub fn scope(self) -> Scope {
        if (K::EncNormFf1Weight..=K::EncNormOutBias).contains(&self) {
            Scope::AudioLayer
        } else if (K::PredLstmWeightIh..=K::PredLstmBiasH).contains(&self) {
            Scope::PredLayer
        } else {
            Scope::Global
        }
    }

    /// `PARAKEET_TENSOR_INFO`.
    pub fn op(self) -> GgmlOp {
        match self {
            K::EncPreOutWeight
            | K::EncFf1Linear1Weight
            | K::EncFf1Linear2Weight
            | K::EncAttnQWeight
            | K::EncAttnKWeight
            | K::EncAttnVWeight
            | K::EncAttnOutWeight
            | K::EncAttnPosWeight
            | K::EncFf2Linear1Weight
            | K::EncFf2Linear2Weight
            | K::SpkFf1Weight
            | K::SpkFf2Weight
            | K::BgSpkFf1Weight
            | K::BgSpkFf2Weight
            | K::PredLstmWeightIh
            | K::PredLstmWeightHh
            | K::JointPredWeight
            | K::JointEncWeight
            | K::JointNetWeight => GgmlOp::MulMat,
            K::EncPreConv0Weight
            | K::EncPreConv2Weight
            | K::EncPreConv3Weight
            | K::EncPreConv5Weight
            | K::EncPreConv6Weight
            | K::EncConvPw1Weight
            | K::EncConvDwWeight
            | K::EncConvPw2Weight => GgmlOp::Im2col,
            K::EncNormFf1Weight
            | K::EncNormConvWeight
            | K::EncConvBnWeight
            | K::EncNormAttnWeight
            | K::EncNormFf2Weight
            | K::EncNormOutWeight => GgmlOp::Mul,
            K::EncConvBnMean => GgmlOp::Sub,
            K::EncConvBnVar => GgmlOp::Div,
            K::EncConvBnNumBatches => GgmlOp::None,
            K::PredEmbedWeight => GgmlOp::GetRows,
            _ => GgmlOp::Add,
        }
    }

    /// `parakeet_tensor_uses_record_type` (parakeet.cpp L1215): the record's own dtype is
    /// authoritative (it must be 2-D). Every other tensor is created with its legacy type
    /// (f32, or i32 for `num_batches_tracked`), so its record payload must have that byte size.
    pub fn uses_record_type(self) -> bool {
        matches!(
            self,
            K::EncPreOutWeight
                | K::EncFf1Linear1Weight
                | K::EncFf1Linear2Weight
                | K::EncConvPw1Weight
                | K::EncConvPw2Weight
                | K::EncAttnQWeight
                | K::EncAttnKWeight
                | K::EncAttnVWeight
                | K::EncAttnOutWeight
                | K::EncAttnPosWeight
                | K::EncFf2Linear1Weight
                | K::EncFf2Linear2Weight
                | K::SpkFf1Weight
                | K::SpkFf2Weight
                | K::BgSpkFf1Weight
                | K::BgSpkFf2Weight
                | K::PredEmbedWeight
                | K::PredLstmWeightIh
                | K::PredLstmWeightHh
                | K::JointPredWeight
                | K::JointEncWeight
                | K::JointNetWeight
        )
    }

    /// True only for `conv.batch_norm.num_batches_tracked`, which the loader creates as
    /// `GGML_TYPE_I32` (one element) and fills with the record's 4 payload bytes verbatim.
    pub fn loaded_as_i32(self) -> bool {
        self == K::EncConvBnNumBatches
    }

    /// The optional all-or-none family the kind belongs to.
    pub fn optional_family(self) -> Option<OptionalFamily> {
        match self {
            K::EncFf1Linear1Bias
            | K::EncFf1Linear2Bias
            | K::EncConvPw1Bias
            | K::EncConvDwBias
            | K::EncConvPw2Bias
            | K::EncAttnQBias
            | K::EncAttnKBias
            | K::EncAttnVBias
            | K::EncAttnOutBias
            | K::EncFf2Linear1Bias
            | K::EncFf2Linear2Bias => Some(OptionalFamily::EncoderBias),
            K::EncConvBnMean | K::EncConvBnVar | K::EncConvBnNumBatches => {
                Some(OptionalFamily::BatchNormStats)
            }
            K::SpkFf1Weight
            | K::SpkFf1Bias
            | K::SpkFf2Weight
            | K::SpkFf2Bias
            | K::BgSpkFf1Weight
            | K::BgSpkFf1Bias
            | K::BgSpkFf2Weight
            | K::BgSpkFf2Bias => Some(OptionalFamily::SpeakerKernel),
            _ => None,
        }
    }

    /// The reporting family.
    pub fn family(self) -> Family {
        match self.optional_family() {
            Some(OptionalFamily::EncoderBias) => Family::EncoderBias,
            Some(OptionalFamily::BatchNormStats) => Family::BatchNormStats,
            Some(OptionalFamily::SpeakerKernel) => Family::SpeakerKernel,
            None => match self.scope() {
                Scope::AudioLayer => Family::EncoderLayer,
                Scope::PredLayer => Family::PredictionLstm,
                Scope::Global => {
                    if self <= K::EncPreConv6Bias {
                        Family::PreEncode
                    } else if self == K::PredEmbedWeight {
                        Family::PredictionEmbed
                    } else {
                        Family::Joint
                    }
                }
            },
        }
    }

    /// True for the 2-D matmul weights of the prediction/joint tail that the opt-in CPU-tail
    /// q8_0 repack converts (`tail_matmul_2d`, parakeet.cpp L2551: kind >= embed, 2-D, MUL_MAT).
    /// The embedding (GET_ROWS) is excluded.
    pub fn is_tail_q8_repack_candidate(self) -> bool {
        self >= K::PredEmbedWeight && self.op() == GgmlOp::MulMat
    }

    /// The `(n_dims, ne)` the loader passes to `create_tensor` (parakeet.cpp L2682-L2897).
    /// `n_pre_enc_features` is `encoder.pre_encode.out.weight`'s record `ne[0]`
    /// (authoritative on seekable loads, L2685-L2692).
    pub fn arch_shape(self, hp: &HParams, n_pre_enc_features: i64) -> (usize, [i64; 4]) {
        let s = i64::from(hp.n_audio_state);
        let c = i64::from(hp.n_subsampling_channels);
        let k = i64::from(hp.n_conv_kernel);
        let h = i64::from(hp.n_audio_head);
        let d_head = i64::from(hp.n_audio_state / hp.n_audio_head);
        let p = i64::from(hp.n_pred_dim);
        let n_embed = i64::from(hp.n_vocab) + 1;
        let n_joint = i64::from(hp.n_vocab) + i64::from(hp.n_tdt_durations) + 1;
        let d1 = |n: i64| (1, [n, 1, 1, 1]);
        let d2 = |a: i64, b: i64| (2, [a, b, 1, 1]);
        let d4 = |a: i64, b: i64, c: i64, d: i64| (4, [a, b, c, d]);
        match self {
            K::EncPreOutWeight => d2(n_pre_enc_features, s),
            K::EncPreOutBias => d1(s),
            K::EncPreConv0Weight | K::EncPreConv2Weight | K::EncPreConv5Weight => d4(3, 3, 1, c),
            K::EncPreConv3Weight | K::EncPreConv6Weight => d4(1, 1, c, c),
            K::EncPreConv0Bias
            | K::EncPreConv2Bias
            | K::EncPreConv3Bias
            | K::EncPreConv5Bias
            | K::EncPreConv6Bias => d4(1, 1, c, 1),
            K::EncFf1Linear1Weight | K::EncFf2Linear1Weight => d2(s, 4 * s),
            K::EncFf1Linear2Weight | K::EncFf2Linear2Weight => d2(4 * s, s),
            K::EncFf1Linear1Bias | K::EncFf2Linear1Bias => d1(4 * s),
            K::EncConvPw1Weight => d2(s, 2 * s),
            K::EncConvPw1Bias => d1(2 * s),
            K::EncConvDwWeight => d2(k, s),
            K::EncConvBnNumBatches => d1(1),
            K::EncConvPw2Weight
            | K::EncAttnQWeight
            | K::EncAttnKWeight
            | K::EncAttnVWeight
            | K::EncAttnOutWeight
            | K::EncAttnPosWeight
            | K::SpkFf1Weight
            | K::SpkFf2Weight
            | K::BgSpkFf1Weight
            | K::BgSpkFf2Weight => d2(s, s),
            K::EncAttnPosBiasU | K::EncAttnPosBiasV => d2(d_head, h),
            K::EncNormFf1Weight
            | K::EncNormFf1Bias
            | K::EncFf1Linear2Bias
            | K::EncNormConvWeight
            | K::EncNormConvBias
            | K::EncConvDwBias
            | K::EncConvBnWeight
            | K::EncConvBnBias
            | K::EncConvBnMean
            | K::EncConvBnVar
            | K::EncConvPw2Bias
            | K::EncNormAttnWeight
            | K::EncNormAttnBias
            | K::EncAttnQBias
            | K::EncAttnKBias
            | K::EncAttnVBias
            | K::EncAttnOutBias
            | K::EncNormFf2Weight
            | K::EncNormFf2Bias
            | K::EncFf2Linear2Bias
            | K::EncNormOutWeight
            | K::EncNormOutBias
            | K::SpkFf1Bias
            | K::SpkFf2Bias
            | K::BgSpkFf1Bias
            | K::BgSpkFf2Bias => d1(s),
            K::PredEmbedWeight => d2(p, n_embed),
            K::PredLstmWeightIh | K::PredLstmWeightHh => d2(p, 4 * p),
            K::PredLstmBiasH => d1(4 * p),
            K::JointPredWeight => d2(p, p),
            K::JointPredBias | K::JointEncBias => d1(p),
            K::JointEncWeight => d2(s, p),
            K::JointNetWeight => d2(p, n_joint),
            K::JointNetBias => d1(n_joint),
        }
    }
}

impl fmt::Display for TensorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.pattern())
    }
}

/// `n_tensors` of `parakeet_model_load` (L2382-L2405): every expected name, optional or not:
/// `20 + 40 * n_audio_layer + 1 + 3 * n_pred_layers + 6`.
pub fn expected_name_count(hp: &HParams) -> usize {
    20 + 40 * hp.n_audio_layer.max(0) as usize + 1 + 3 * hp.n_pred_layers.max(0) as usize + 6
}

/// Per-layer creation order of `parakeet_model_load` (L2725-L2794). Kinds with an
/// [`TensorKind::optional_family`] are created only when their record exists.
pub(crate) const LAYER_CREATION_ORDER: [TensorKind; 40] = [
    K::EncNormFf1Weight,
    K::EncNormFf1Bias,
    K::EncFf1Linear1Weight,
    K::EncFf1Linear2Weight,
    K::EncFf1Linear1Bias,
    K::EncFf1Linear2Bias,
    K::EncNormConvWeight,
    K::EncNormConvBias,
    K::EncConvPw1Weight,
    K::EncConvDwWeight,
    K::EncConvBnWeight,
    K::EncConvBnBias,
    K::EncConvBnMean,
    K::EncConvBnVar,
    K::EncConvBnNumBatches,
    K::EncConvPw2Weight,
    K::EncConvPw1Bias,
    K::EncConvDwBias,
    K::EncConvPw2Bias,
    K::EncNormAttnWeight,
    K::EncNormAttnBias,
    K::EncAttnPosBiasU,
    K::EncAttnPosBiasV,
    K::EncAttnQWeight,
    K::EncAttnKWeight,
    K::EncAttnVWeight,
    K::EncAttnOutWeight,
    K::EncAttnPosWeight,
    K::EncAttnQBias,
    K::EncAttnKBias,
    K::EncAttnVBias,
    K::EncAttnOutBias,
    K::EncNormFf2Weight,
    K::EncNormFf2Bias,
    K::EncFf2Linear1Weight,
    K::EncFf2Linear2Weight,
    K::EncFf2Linear1Bias,
    K::EncFf2Linear2Bias,
    K::EncNormOutWeight,
    K::EncNormOutBias,
];

/// Global creation order before the layers (L2694-L2723).
pub(crate) const PRE_ENCODE_CREATION_ORDER: [TensorKind; 12] = [
    K::EncPreOutWeight,
    K::EncPreOutBias,
    K::EncPreConv0Weight,
    K::EncPreConv0Bias,
    K::EncPreConv2Weight,
    K::EncPreConv2Bias,
    K::EncPreConv3Weight,
    K::EncPreConv3Bias,
    K::EncPreConv5Weight,
    K::EncPreConv5Bias,
    K::EncPreConv6Weight,
    K::EncPreConv6Bias,
];

/// Speaker-kernel creation order (L2840-L2857).
pub(crate) const SPEAKER_CREATION_ORDER: [TensorKind; 8] = [
    K::SpkFf1Weight,
    K::SpkFf1Bias,
    K::SpkFf2Weight,
    K::SpkFf2Bias,
    K::BgSpkFf1Weight,
    K::BgSpkFf1Bias,
    K::BgSpkFf2Weight,
    K::BgSpkFf2Bias,
];

/// Joint creation order (L2885-L2897).
pub(crate) const JOINT_CREATION_ORDER: [TensorKind; 6] = [
    K::JointPredWeight,
    K::JointPredBias,
    K::JointEncWeight,
    K::JointEncBias,
    K::JointNetWeight,
    K::JointNetBias,
];
