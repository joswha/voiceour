//! Builds small model files in the native format and checks that `Model::open` accepts and
//! rejects exactly what `parakeet_model_load` does, and that every accessor reads back the
//! bytes that were written.

use std::borrow::Cow;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use parakeet_model::{
    DType, Error, Family, HParam, Model, OptionalFamily, QK8_0, Scope, TensorKind,
    dequantize_row_q8_0, f16_to_f32, f32_to_f16, quantize_row_q8_0,
};

/// Synthetic hyperparameters in file order (ftype is the 7th value).
const HPARAMS: [i32; 15] = [
    8,   // n_vocab
    100, // n_audio_ctx
    64,  // n_audio_state
    2,   // n_audio_head
    2,   // n_audio_layer
    16,  // n_mels
    1,   // ftype
    16,  // n_fft
    8,   // subsampling_factor
    4,   // n_subsampling_channels
    3,   // n_conv_kernel
    32,  // n_pred_dim
    1,   // n_pred_layers
    5,   // n_tdt_durations
    10,  // n_max_tokens
];

#[derive(Clone)]
struct Rec {
    name: Vec<u8>,
    n_dims: i32,
    ne: Vec<i32>,
    type_id: i32,
    payload: Vec<u8>,
}

#[derive(Clone)]
struct Builder {
    magic: u32,
    hparams: [i32; 15],
    filters: (i32, i32, Vec<f32>),
    window: Vec<f32>,
    durations: Vec<u32>,
    vocab: Vec<Vec<u8>>,
    records: Vec<Rec>,
}

fn value(seed: usize, i: usize) -> f32 {
    ((seed * 7919 + i * 104_729) % 2001) as f32 / 1000.0 - 1.0
}

/// Parsed hparams for shape computation (mirrors the library's arch table independently).
struct Hp {
    s: i32,
    h: i32,
    c: i32,
    k: i32,
    p: i32,
    v: i32,
    d: i32,
    layers: i32,
    pred_layers: i32,
    pre: i32,
}

impl Hp {
    fn from(hp: &[i32; 15]) -> Hp {
        Hp {
            s: hp[2],
            h: hp[3],
            c: hp[9],
            k: hp[10],
            p: hp[11],
            v: hp[0],
            d: hp[13],
            layers: hp[4],
            pred_layers: hp[12],
            pre: hp[5] / hp[8] * hp[9],
        }
    }
}

/// Hand-written shape table (independent of `TensorKind::arch_shape`), from parakeet.cpp's
/// create_tensor calls. Returns `None` for kinds this helper is not asked about.
fn shape(kind: TensorKind, hp: &Hp) -> Vec<i32> {
    use TensorKind as K;
    let (s, c, p) = (hp.s, hp.c, hp.p);
    match kind {
        K::EncPreOutWeight => vec![hp.pre, s],
        K::EncPreConv0Weight | K::EncPreConv2Weight | K::EncPreConv5Weight => vec![3, 3, 1, c],
        K::EncPreConv3Weight | K::EncPreConv6Weight => vec![1, 1, c, c],
        K::EncPreConv0Bias
        | K::EncPreConv2Bias
        | K::EncPreConv3Bias
        | K::EncPreConv5Bias
        | K::EncPreConv6Bias => vec![1, 1, c, 1],
        K::EncFf1Linear1Weight | K::EncFf2Linear1Weight => vec![s, 4 * s],
        K::EncFf1Linear2Weight | K::EncFf2Linear2Weight => vec![4 * s, s],
        K::EncFf1Linear1Bias | K::EncFf2Linear1Bias => vec![4 * s],
        K::EncConvPw1Weight => vec![s, 2 * s],
        K::EncConvPw1Bias => vec![2 * s],
        K::EncConvDwWeight => vec![hp.k, s],
        K::EncConvBnNumBatches => vec![1],
        K::EncAttnPosBiasU | K::EncAttnPosBiasV => vec![s / hp.h, hp.h],
        K::EncConvPw2Weight
        | K::EncAttnQWeight
        | K::EncAttnKWeight
        | K::EncAttnVWeight
        | K::EncAttnOutWeight
        | K::EncAttnPosWeight
        | K::SpkFf1Weight
        | K::SpkFf2Weight
        | K::BgSpkFf1Weight
        | K::BgSpkFf2Weight => vec![s, s],
        K::PredEmbedWeight => vec![p, hp.v + 1],
        K::PredLstmWeightIh | K::PredLstmWeightHh => vec![p, 4 * p],
        K::PredLstmBiasH => vec![4 * p],
        K::JointPredWeight => vec![p, p],
        K::JointPredBias | K::JointEncBias => vec![p],
        K::JointEncWeight => vec![s, p],
        K::JointNetWeight => vec![p, hp.v + hp.d + 1],
        K::JointNetBias => vec![hp.v + hp.d + 1],
        _ => vec![s],
    }
}

fn payload_for(type_id: i32, n: usize, seed: usize) -> Vec<u8> {
    let vals: Vec<f32> = (0..n).map(|i| value(seed, i)).collect();
    match type_id {
        0 => vals.iter().flat_map(|v| v.to_le_bytes()).collect(),
        1 => vals
            .iter()
            .flat_map(|&v| f32_to_f16(v).to_le_bytes())
            .collect(),
        8 => {
            let mut out = vec![0u8; n / QK8_0 * 34];
            quantize_row_q8_0(&vals, &mut out);
            out
        }
        _ => unreachable!(),
    }
}

impl Builder {
    fn with(biases: bool, bn_stats: bool, speaker: bool) -> Builder {
        let hp = Hp::from(&HPARAMS);
        let mut records = Vec::new();
        let mut seed = 0;
        for kind in TensorKind::ALL {
            match kind.optional_family() {
                Some(OptionalFamily::EncoderBias) if !biases => continue,
                Some(OptionalFamily::BatchNormStats) if !bn_stats => continue,
                Some(OptionalFamily::SpeakerKernel) if !speaker => continue,
                _ => {}
            }
            let layers = match kind.scope() {
                Scope::Global => 1,
                Scope::AudioLayer => hp.layers,
                Scope::PredLayer => hp.pred_layers,
            };
            for layer in 0..layers {
                let ne = shape(kind, &hp);
                // Matrix weights f16, except one q8_0 record; everything else f32.
                let type_id = if kind == TensorKind::JointEncWeight {
                    8
                } else if kind.uses_record_type() {
                    1
                } else {
                    0
                };
                let n: usize = ne.iter().map(|&x| x as usize).product();
                seed += 1;
                records.push(Rec {
                    name: kind.name(layer as usize).into_bytes(),
                    n_dims: ne.len() as i32,
                    ne,
                    type_id,
                    payload: payload_for(type_id, n, seed),
                });
            }
        }
        let n_fb = HPARAMS[7] / 2 + 1;
        Builder {
            magic: 0x6767_6d6c,
            hparams: HPARAMS,
            filters: (
                16,
                n_fb,
                (0..16 * n_fb as usize).map(|i| value(1000, i)).collect(),
            ),
            window: (0..12).map(|i| value(2000, i)).collect(),
            durations: vec![0, 1, 2, 3, 4],
            vocab: [
                &b"<pad>"[..],
                b"<unk>",
                b"<s>",
                b"</s>",
                b"\xE2\x96\x81the",
                b"<unk>",
                b"a",
                b"",
            ]
            .iter()
            .map(|p| p.to_vec())
            .collect(),
            records,
        }
    }

    fn standard() -> Builder {
        Builder::with(false, true, false)
    }

    fn bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend(self.magic.to_le_bytes());
        for v in self.hparams {
            out.extend(v.to_le_bytes());
        }
        out.extend(self.filters.0.to_le_bytes());
        out.extend(self.filters.1.to_le_bytes());
        for v in &self.filters.2 {
            out.extend(v.to_le_bytes());
        }
        out.extend((self.window.len() as i32).to_le_bytes());
        for v in &self.window {
            out.extend(v.to_le_bytes());
        }
        for d in &self.durations {
            out.extend(d.to_le_bytes());
        }
        out.extend((self.vocab.len() as i32).to_le_bytes());
        for piece in &self.vocab {
            out.extend((piece.len() as u32).to_le_bytes());
            out.extend(piece);
        }
        for r in &self.records {
            out.extend(r.n_dims.to_le_bytes());
            out.extend((r.name.len() as i32).to_le_bytes());
            out.extend(r.type_id.to_le_bytes());
            for &n in &r.ne {
                out.extend(n.to_le_bytes());
            }
            out.extend(&r.name);
            out.extend(&r.payload);
        }
        out
    }

    fn record_mut(&mut self, name: &str) -> &mut Rec {
        self.records
            .iter_mut()
            .find(|r| r.name == name.as_bytes())
            .unwrap_or_else(|| panic!("no record {name}"))
    }

    fn remove(&mut self, name: &str) -> Rec {
        let i = self
            .records
            .iter()
            .position(|r| r.name == name.as_bytes())
            .unwrap_or_else(|| panic!("no record {name}"));
        self.records.remove(i)
    }
}

/// A temporary file removed on drop.
struct TempModel(PathBuf);

impl Drop for TempModel {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn write_temp(bytes: &[u8]) -> TempModel {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let path = std::env::temp_dir().join(format!(
        "parakeet-model-test-{}-{}.bin",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::write(&path, bytes).expect("write temp model");
    TempModel(path)
}

fn open(builder: &Builder) -> (TempModel, Result<Model, Error>) {
    let file = write_temp(&builder.bytes());
    let model = Model::open(&file.0);
    (file, model)
}

fn open_bytes(bytes: &[u8]) -> Result<Model, Error> {
    let file = write_temp(bytes);
    Model::open(&file.0)
}

#[track_caller]
fn expect_err(result: Result<Model, Error>, needle: &str) {
    match result {
        Ok(_) => panic!("expected an error containing {needle:?}, model opened"),
        Err(err) => {
            let text = err.to_string();
            assert!(text.contains(needle), "error {text:?} lacks {needle:?}");
        }
    }
}

#[test]
fn standard_file_reads_back_everything() {
    let builder = Builder::standard();
    let (_file, model) = open(&builder);
    let model = model.expect("standard synthetic model opens");

    let hp = model.hparams();
    assert_eq!(hp.n_audio_state, 64);
    assert_eq!(hp.ftype, 1);
    assert_eq!(hp.eps, 1e-5);
    // Every hparam differs from PARAKEET_HPARAM_MODEL_VALUES except n_tdt_durations/n_max_tokens
    // and subsampling_factor: one native warning each.
    let differing = HParam::ALL
        .iter()
        .filter(|h| model.hparams().get(**h) != h.model_value())
        .count();
    assert_eq!(model.hparam_warnings().len(), differing);

    // 12 pre-encode + 29 per layer (with BN stats) x 2 + embed + 3 LSTM + 6 joint.
    assert_eq!(model.tensor_count(), 12 + 29 * 2 + 1 + 3 + 6);
    assert_eq!(model.tensor_count(), builder.records.len());
    assert!(model.architecture_mismatches().is_empty());
    for count in model.family_counts() {
        assert_eq!(count.expected, count.actual, "{}", count.family);
    }
    let variant = model.variant();
    assert!(!variant.encoder_biases && variant.batch_norm_stats && !variant.speaker_kernel);
    assert_eq!(model.n_pre_enc_features(), 8);

    // Every payload reads back byte-identical, in file order.
    for (view, rec) in model.tensors().zip(&builder.records) {
        assert_eq!(view.name.as_bytes(), &rec.name[..]);
        assert_eq!(view.data, &rec.payload[..], "{}", view.name);
        assert_eq!(view.dtype.ggml_id(), rec.type_id);
        let mut ne = [1i64; 4];
        for (dst, &src) in ne.iter_mut().zip(&rec.ne) {
            *dst = i64::from(src);
        }
        assert_eq!(view.ne, ne);
        assert_eq!(view.n_dims, rec.ne.len());
    }

    // Typed accessors agree with the raw bytes.
    let w = model
        .tensor("encoder.layers.1.feed_forward1.linear1.weight")
        .unwrap();
    let bits = w.f16_slice().unwrap();
    let wide = w.to_f32_vec();
    assert_eq!(bits.len(), w.n_elements());
    for (b, f) in bits.iter().zip(&wide) {
        assert_eq!(f16_to_f32(*b).to_bits(), f.to_bits());
    }
    let mut row = vec![0.0f32; w.row_len()];
    w.row_to_f32(3, &mut row);
    assert_eq!(&row[..], &wide[3 * w.row_len()..4 * w.row_len()]);

    let q = model.joint().enc_w;
    assert_eq!(q.dtype, DType::Q8_0);
    let mut expected = vec![0.0f32; q.n_elements()];
    dequantize_row_q8_0(q.data, &mut expected);
    assert_eq!(q.to_f32_vec(), expected);
    let blocks = q.q8_0_blocks().unwrap();
    assert_eq!(blocks.len(), q.n_elements() / 32);
    assert_eq!(&blocks[1].to_bytes()[..], &q.data[34..68]);

    let norm = model.encoder_layer(0).unwrap().norm_ff1_w;
    let f = norm.f32_slice().unwrap();
    assert_eq!(f.len(), 64);
    assert_eq!(f[5], value(13, 5));
    assert!(norm.f16_slice().is_err());
    assert!(norm.q8_0_blocks().is_err());

    // Sections.
    assert_eq!(model.tdt_durations(), &[0, 1, 2, 3, 4]);
    let pre = model.preprocessor();
    assert_eq!((pre.n_fft, pre.n_mels, pre.n_fb), (16, 16, 9));
    assert_eq!(&pre.filterbank[..], &builder.filters.2[..]);
    assert_eq!(&pre.window[..], &builder.window[..]);
    assert_eq!(pre.window_pad_left(), 2);
    assert!(pre.normalize_per_feature);

    // Vocab: special ids follow the loader's lookups, duplicates resolve to the last id.
    let vocab = model.vocab();
    assert_eq!(vocab.len(), 8);
    assert_eq!(vocab.blank_id(), 8);
    assert_eq!(vocab.unk_id(), 5);
    assert_eq!(vocab.bos_id(), 2);
    assert_eq!(vocab.eos_id(), 3);
    assert_eq!(vocab.piece(8), Some(&b"[BLANK]"[..]));
    assert_eq!(vocab.piece_str(4), Some("\u{2581}the"));
    assert_eq!(vocab.piece(7), Some(&b""[..]));
    assert_eq!(vocab.piece(9), None);
    assert_eq!(vocab.piece(-1), None);
    assert_eq!(vocab.id_of(b"[BLANK]"), Some(8));
    assert_eq!(vocab.id_of(b"a"), Some(6));
    assert_eq!(vocab.max_piece_len(), 6);

    // Semantic accessors.
    let sub = model.subsampling();
    assert_eq!((sub.n_channels, sub.n_freq_out, sub.causal), (4, 2, false));
    assert_eq!(sub.n_out_frames(17), 3);
    assert_eq!(model.encoder_layers().len(), 2);
    assert!(model.encoder_layer(2).is_none());
    let layer = model.encoder_layer(1).unwrap();
    assert!(layer.ff1_linear1_b.is_none() && layer.attn_out_b.is_none());
    assert_eq!(
        layer.conv_bn_var_as_loaded().unwrap(),
        layer.conv_bn_var.unwrap().to_f32_vec()
    );
    assert_eq!(layer.conv_dw_w.ne, [3, 64, 1, 1]);
    assert_eq!(layer.attn_pos_bias_u.ne, [32, 2, 1, 1]);
    assert!(model.speaker_kernel().is_none());
    let pred = model.prediction();
    assert_eq!(pred.layers.len(), 1);
    assert_eq!(pred.embed.n_rows(), 9);
    assert_eq!(pred.blank_id, 8);
    let joint = model.joint();
    assert_eq!(joint.n_out(), 14);
    assert_eq!(joint.token_slots(), 0..9);
    assert_eq!(joint.duration_slots(), 9..14);
}

#[test]
fn requantize_q8_0_matches_reference_quantizer() {
    let (_file, model) = open(&Builder::standard());
    let model = model.unwrap();
    let w = model.prediction().layers[0].w_hh;
    assert!(w.kind.is_tail_q8_repack_candidate());
    let q = w.requantize_q8_0().unwrap();
    let mut expected = vec![0u8; w.n_elements() / 32 * 34];
    quantize_row_q8_0(&w.to_f32_vec(), &mut expected);
    assert_eq!(q, expected);
    assert!(!model.prediction().embed.kind.is_tail_q8_repack_candidate());
    assert!(model.joint().enc_b.requantize_q8_0().is_err());
}

#[test]
fn bias_variant_folds_batch_norm_eps() {
    let (_file, model) = open(&Builder::with(true, true, false));
    let model = model.expect("bias variant opens");
    assert!(model.variant().encoder_biases);
    assert_eq!(model.tensor_count(), 12 + 40 * 2 + 1 + 3 + 6);
    assert!(model.architecture_mismatches().is_empty());
    let layer = model.encoder_layer(0).unwrap();
    assert!(layer.ff1_linear1_b.is_some() && layer.conv_pw1_b.is_some());
    let stored = layer.conv_bn_var.unwrap().to_f32_vec();
    let folded = layer.conv_bn_var_as_loaded().unwrap();
    for (s, f) in stored.iter().zip(&folded) {
        assert_eq!(*f, *s + 1e-5f32);
    }
}

#[test]
fn layernorm_variant_without_running_stats_opens() {
    let (_file, model) = open(&Builder::with(false, false, false));
    let model = model.expect("conv-LayerNorm variant opens");
    assert!(!model.variant().batch_norm_stats);
    let layer = model.encoder_layer(1).unwrap();
    assert!(layer.conv_bn_mean.is_none() && layer.conv_bn_var_as_loaded().is_none());
    let counts = model.family_counts();
    let bn = counts
        .iter()
        .find(|c| c.family == Family::BatchNormStats)
        .unwrap();
    assert_eq!((bn.expected, bn.actual), (0, 0));
}

#[test]
fn speaker_variant_switches_frontend_and_subsampling() {
    let (_file, model) = open(&Builder::with(false, true, true));
    let model = model.expect("speaker variant opens");
    assert!(model.speaker_kernel().is_some());
    assert!(!model.preprocessor().normalize_per_feature);
    let sub = model.subsampling();
    assert!(sub.causal);
    assert_eq!(sub.n_out_frames(17), 3); // causal: 17/2+1 = 9, 9/2+1 = 5, 5/2+1 = 3
}

#[test]
fn misaligned_payloads_are_copied_not_misread() {
    // Lengthening one vocab piece by a byte shifts every payload after it by one, so the same
    // f16 tensor is 2-byte aligned in exactly one of the two files.
    let standard = Builder::standard();
    let mut shifted = standard.clone();
    shifted.vocab[6] = b"ab".to_vec();
    let (_a, a) = open(&standard);
    let (_b, b) = open(&shifted);
    let (a, b) = (a.unwrap(), b.unwrap());
    for name in [
        "joint.pred.weight",
        "encoder.layers.1.self_attn.linear_v.weight",
    ] {
        let ta = a.tensor(name).unwrap();
        let tb = b.tensor(name).unwrap();
        assert_eq!(tb.file_offset, ta.file_offset + 1);
        let (bits_a, bits_b) = (ta.f16_slice().unwrap(), tb.f16_slice().unwrap());
        assert_ne!(
            matches!(bits_a, Cow::Borrowed(_)),
            matches!(bits_b, Cow::Borrowed(_)),
            "{name}: exactly one layout borrows"
        );
        assert_eq!(bits_a, bits_b);
        for (i, chunk) in ta.data.chunks_exact(2).enumerate() {
            assert_eq!(bits_a[i], u16::from_le_bytes([chunk[0], chunk[1]]));
        }
    }
}

#[test]
fn rejects_what_the_native_loader_rejects() {
    let standard = Builder::standard();

    let mut b = standard.clone();
    b.magic = 0x6767_6d6d;
    expect_err(open(&b).1, "bad magic");

    let mut b = standard.clone();
    b.hparams[4] = 43; // n_audio_layer > 42
    expect_err(open(&b).1, "n_audio_layer = 43");

    let mut b = standard.clone();
    b.hparams[13] = 0; // the plain RNN-T marker passes hparam validation and reads no
    b.durations.clear(); // durations, but the joint width shrinks to n_vocab + 1 = 9.
    expect_err(
        open(&b).1,
        "joint.joint_net.2.weight has the wrong record dimensions",
    );

    let mut b = standard.clone();
    b.hparams[6] = 4; // GGML_FTYPE_MOSTLY_Q4_1_SOME_F16 makes ggml assert
    expect_err(open(&b).1, "bad ftype");

    let bytes = standard.bytes();
    expect_err(
        open_bytes(&bytes[..bytes.len() - 1]),
        "payload exceeds model bounds",
    );
    expect_err(open_bytes(&bytes[..40]), "truncated hparams");

    let mut b = standard.clone();
    b.record_mut("joint.pred.bias").name = b"joint.pred.bias2".to_vec();
    expect_err(open(&b).1, "unknown tensor 'joint.pred.bias2'");

    let mut b = standard.clone();
    b.record_mut("joint.pred.bias").name = b"joint.pred.b\0as".to_vec();
    expect_err(open(&b).1, "invalid tensor name");

    let mut b = standard.clone();
    b.record_mut("joint.pred.bias").type_id = 2; // q4_0
    expect_err(open(&b).1, "unsupported tensor type 2");

    let mut b = standard.clone();
    let dup = b.records[3].clone();
    b.records.push(dup);
    expect_err(open(&b).1, "duplicate tensor");

    let mut b = standard.clone();
    b.remove("encoder.layers.0.norm_out.bias");
    expect_err(open(&b).1, "wrong tensor-record count");

    // A partial optional family that still passes the record-count check: dropping 6 of the
    // 22 biases leaves 6 + 8 missing, the size of the BatchNorm and speaker families.
    let mut b = Builder::with(true, true, false);
    let bias_kinds: Vec<TensorKind> = TensorKind::ALL
        .into_iter()
        .filter(|k| k.optional_family() == Some(OptionalFamily::EncoderBias))
        .take(6)
        .collect();
    for kind in bias_kinds {
        b.remove(&kind.name(1));
    }
    expect_err(
        open(&b).1,
        "partial encoder bias set: 16 of 22 records present",
    );

    // Any missing count that is not a sum of whole optional families fails the scan.
    let mut b = standard.clone();
    b.remove("encoder.layers.1.conv.batch_norm.num_batches_tracked");
    expect_err(open(&b).1, "wrong tensor-record count");

    // Wrong shape.
    let mut b = standard.clone();
    let r = b.record_mut("encoder.layers.0.self_attn.pos_bias_u");
    r.ne = vec![2, 32];
    expect_err(open(&b).1, "wrong record dimensions");

    // A matrix weight stored with 4 dims (same extents) is not a 2-D record.
    let mut b = standard.clone();
    let r = b.record_mut("joint.pred.weight");
    r.n_dims = 4;
    r.ne = vec![32, 32, 1, 1];
    expect_err(open(&b).1, "not a 2-D quantizable weight record");

    // A legacy-f32 tensor stored as f16 has the wrong payload size for GGML_TYPE_F32.
    let mut b = standard.clone();
    let r = b.record_mut("encoder.layers.0.norm_out.weight");
    r.type_id = 1;
    r.payload = payload_for(1, 64, 7);
    expect_err(open(&b).1, "wrong record payload size");

    // q8_0 needs whole 32-element blocks per row.
    let mut b = standard.clone();
    let r = b.record_mut("encoder.pre_encode.out.weight");
    r.type_id = 8;
    expect_err(open(&b).1, "invalid block shape");

    // A partial speaker kernel.
    let mut b = Builder::with(false, true, true);
    b.remove("bg_spk_kernels.0.3.bias");
    expect_err(open(&b).1, "wrong tensor-record count");
}
