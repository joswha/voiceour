//! The tail's weights in the representation an arm computes with, copied out of the
//! memory-mapped model once at engine creation (never timed).

use parakeet_model::{DType, Model, TensorView, f16_to_f32};

use crate::kernels::Q8_BLOCK;

/// Storage format of the seven 2-D matmul weights (`weight_ih_l{0,1}`, `weight_hh_l{0,1}`,
/// `joint.pred.weight`, `joint.enc.weight`, `joint.joint_net.2.weight`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    /// Widened to f32 at load (exact).
    F32,
    /// The file's fp16 payload, widened in the kernels.
    F16,
    /// Native `VOICEOUR_TAIL_QUANT=q8_0` repack: fp16 → f32 → `quantize_row_q8_0_ref` per row.
    Q8,
}

pub enum MatData {
    F32(Vec<f32>),
    F16(Vec<u16>),
    Q8(Vec<u8>),
}

/// Row-major `W[rows][k]` (ggml `ne = [k, rows]`).
pub struct Mat {
    pub rows: usize,
    pub k: usize,
    pub data: MatData,
}

impl Mat {
    fn from_view(v: &TensorView<'_>, format: Format) -> Result<Mat, String> {
        if v.dtype != DType::F16 || v.n_dims != 2 {
            return Err(format!(
                "{}: expected a 2-D f16 matrix, found {:?} {}-D",
                v.name, v.dtype, v.n_dims
            ));
        }
        let (k, rows) = (v.row_len(), v.n_rows());
        if k % 32 != 0 {
            return Err(format!(
                "{}: row length {k} is not a multiple of 32",
                v.name
            ));
        }
        let data = match format {
            Format::F32 => MatData::F32(v.to_f32_vec()),
            Format::F16 => MatData::F16(v.f16_slice().map_err(|e| e.to_string())?.into_owned()),
            Format::Q8 => MatData::Q8(v.requantize_q8_0().map_err(|e| e.to_string())?),
        };
        Ok(Mat { rows, k, data })
    }

    /// Builds a matrix from f32 values in a given format (tests and synthetic models).
    pub fn from_f32(rows: usize, k: usize, values: &[f32], format: Format) -> Mat {
        assert_eq!(values.len(), rows * k);
        assert_eq!(k % 32, 0, "k must be a multiple of 32");
        let data = match format {
            Format::F32 => MatData::F32(values.to_vec()),
            Format::F16 => MatData::F16(
                values
                    .iter()
                    .map(|&v| parakeet_model::f32_to_f16(v))
                    .collect(),
            ),
            Format::Q8 => {
                let mut out = vec![0u8; rows * k / 32 * Q8_BLOCK];
                parakeet_model::quantize_row_q8_0(values, &mut out);
                MatData::Q8(out)
            }
        };
        Mat { rows, k, data }
    }

    pub fn format(&self) -> Format {
        match self.data {
            MatData::F32(_) => Format::F32,
            MatData::F16(_) => Format::F16,
            MatData::Q8(_) => Format::Q8,
        }
    }

    /// The matrix widened to f32 (the Accelerate arm's operand).
    pub fn to_f32(&self) -> Vec<f32> {
        match &self.data {
            MatData::F32(v) => v.clone(),
            MatData::F16(v) => v.iter().map(|&h| f16_to_f32(h)).collect(),
            MatData::Q8(v) => {
                let mut out = vec![0.0; self.rows * self.k];
                parakeet_model::dequantize_row_q8_0(v, &mut out);
                out
            }
        }
    }
}

/// Fixed shapes and constants of the tail.
#[derive(Clone, Debug)]
pub struct Dims {
    /// Prediction / joint hidden width `P` (640).
    pub p: usize,
    /// Encoder state width (1024).
    pub s: usize,
    /// Token slots scanned by the greedy argmax: pieces plus blank (8193).
    pub n_tok: usize,
    /// Blank id (8192).
    pub blank: usize,
    /// Joint output width (8198).
    pub n_out: usize,
    /// TDT duration values (`[0, 1, 2, 3, 4]`).
    pub durations: Vec<i32>,
    /// `n_max_tokens` (10): symbols per frame before a forced advance.
    pub max_symbols: usize,
    /// LSTM layers (2).
    pub n_layers: usize,
}

pub struct Weights {
    pub dims: Dims,
    /// Embedding `E[n_tok][P]`, fp16 bits (one row per prediction; widened exactly).
    pub embed: Vec<u16>,
    pub w_ih: Vec<Mat>,
    pub w_hh: Vec<Mat>,
    pub b_h: Vec<Vec<f32>>,
    pub pred_w: Mat,
    pub pred_b: Vec<f32>,
    pub enc_w: Mat,
    pub enc_b: Vec<f32>,
    pub net_w: Mat,
    pub net_b: Vec<f32>,
}

fn f32_vec(v: &TensorView<'_>) -> Result<Vec<f32>, String> {
    Ok(v.f32_slice().map_err(|e| e.to_string())?.into_owned())
}

impl Weights {
    /// The tail of an opened model in `format`.
    pub fn load(model: &Model, format: Format) -> Result<Weights, String> {
        let hp = model.hparams();
        let pred = model.prediction();
        let joint = model.joint();
        let p = pred.n_hidden;
        let dims = Dims {
            p,
            s: hp.n_audio_state as usize,
            n_tok: joint.blank_id as usize + 1,
            blank: joint.blank_id as usize,
            n_out: joint.n_out(),
            durations: model.tdt_durations().iter().map(|&d| d as i32).collect(),
            max_symbols: hp.n_max_tokens as usize,
            n_layers: pred.layers.len(),
        };
        if dims.durations.is_empty() {
            return Err("the TDT tail needs duration slots (plain RNNT is not supported)".into());
        }
        if pred.embed.dtype != DType::F16
            || pred.embed.row_len() != p
            || pred.embed.n_rows() != dims.n_tok
        {
            return Err(format!("unexpected embedding {:?}", pred.embed));
        }
        let w = Weights {
            embed: pred
                .embed
                .f16_slice()
                .map_err(|e| e.to_string())?
                .into_owned(),
            w_ih: pred
                .layers
                .iter()
                .map(|l| Mat::from_view(&l.w_ih, format))
                .collect::<Result<_, _>>()?,
            w_hh: pred
                .layers
                .iter()
                .map(|l| Mat::from_view(&l.w_hh, format))
                .collect::<Result<_, _>>()?,
            b_h: pred
                .layers
                .iter()
                .map(|l| f32_vec(&l.b_h))
                .collect::<Result<_, _>>()?,
            pred_w: Mat::from_view(&joint.pred_w, format)?,
            pred_b: f32_vec(&joint.pred_b)?,
            enc_w: Mat::from_view(&joint.enc_w, format)?,
            enc_b: f32_vec(&joint.enc_b)?,
            net_w: Mat::from_view(&joint.net_w, format)?,
            net_b: f32_vec(&joint.net_b)?,
            dims,
        };
        w.validate()?;
        Ok(w)
    }

    /// Shape checks shared by real and synthetic weights.
    pub fn validate(&self) -> Result<(), String> {
        let d = &self.dims;
        let ok = d.p % 32 == 0
            && d.s % 32 == 0
            && d.n_tok == d.blank + 1
            && d.n_out == d.n_tok + d.durations.len()
            && d.max_symbols > 0
            && self.embed.len() == d.n_tok * d.p
            && self.w_ih.len() == d.n_layers
            && self.w_hh.len() == d.n_layers
            && self.b_h.len() == d.n_layers
            && self
                .w_ih
                .iter()
                .chain(&self.w_hh)
                .all(|m| m.rows == 4 * d.p && m.k == d.p)
            && self.b_h.iter().all(|b| b.len() == 4 * d.p)
            && self.pred_w.rows == d.p
            && self.pred_w.k == d.p
            && self.pred_b.len() == d.p
            && self.enc_w.rows == d.p
            && self.enc_w.k == d.s
            && self.enc_b.len() == d.p
            && self.net_w.rows == d.n_out
            && self.net_w.k == d.p
            && self.net_b.len() == d.n_out;
        if ok {
            Ok(())
        } else {
            Err(format!("inconsistent tail shapes: {d:?}"))
        }
    }

    /// Format of the matmul weights (all seven share one).
    pub fn format(&self) -> Format {
        self.net_w.format()
    }

    /// Widened embedding row of `token` into `out` (exact; the blank row is all zeros).
    pub fn embed_row(&self, token: usize, out: &mut [f32]) {
        let p = self.dims.p;
        for (o, &h) in out.iter_mut().zip(&self.embed[token * p..(token + 1) * p]) {
            *o = f16_to_f32(h);
        }
    }
}
