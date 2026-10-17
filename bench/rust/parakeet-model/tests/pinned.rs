//! Tests against the real pinned model file. Each test is skipped (passes with a note on
//! stderr) when the file is not present at `pin::default_model_path()`.

use std::borrow::Cow;

use parakeet_model::{
    DType, Family, HParam, Model, TensorKind, dequantize_row_q8_0, f16_to_f32, pin,
};

fn pinned() -> Option<Model> {
    let path = pin::default_model_path();
    if !path.exists() {
        eprintln!("skipping: pinned model not found at {}", path.display());
        return None;
    }
    Some(Model::open(&path).expect("the pinned model opens"))
}

#[test]
fn hparams_equal_parakeet_arch_values_with_24_layers() {
    let Some(model) = pinned() else { return };
    let hp = model.hparams();
    // PARAKEET_HPARAM_MODEL_VALUES (parakeet-arch.h), except the 42-layer cap -> 24 layers.
    let expected = [
        (HParam::NVocab, 8192),
        (HParam::NAudioCtx, 5000),
        (HParam::NAudioState, 1024),
        (HParam::NAudioHead, 8),
        (HParam::NAudioLayer, 24),
        (HParam::NMels, 128),
        (HParam::NFft, 512),
        (HParam::SubsamplingFactor, 8),
        (HParam::NSubsamplingChannels, 256),
        (HParam::NConvKernel, 9),
        (HParam::NPredDim, 640),
        (HParam::NPredLayers, 2),
        (HParam::NTdtDurations, 5),
        (HParam::NMaxTokens, 10),
    ];
    for (which, value) in expected {
        assert_eq!(hp.get(which), value, "{}", which.name());
        if which != HParam::NAudioLayer {
            assert_eq!(hp.get(which), which.model_value(), "{}", which.name());
        }
    }
    assert_eq!(HParam::NAudioLayer.model_value(), 42);
    assert_eq!(hp.ftype, 1);
    assert_eq!(hp.qntvr(), 0);
    assert_eq!(hp.wtype(), Some(DType::F16.ggml_id()));
    assert_eq!(hp.eps, 1e-5);
    assert_eq!(
        model.hparam_warnings(),
        ["non-standard Parakeet metadata: n_audio_layer = 24, expected 42"]
    );
}

#[test]
fn tensor_set_counts_and_shapes() {
    let Some(model) = pinned() else { return };
    assert_eq!(model.file_len() as u64, pin::SIZE);
    // 12 pre-encode + 24 x 29 per layer (26 + BatchNorm stats) + embed + 2 x 3 LSTM + 6 joint.
    assert_eq!(model.tensor_count(), 721);
    let variant = model.variant();
    assert!(!variant.encoder_biases && variant.batch_norm_stats && !variant.speaker_kernel);
    assert!(model.architecture_mismatches().is_empty());
    for count in model.family_counts() {
        assert_eq!(count.expected, count.actual, "{}", count.family);
    }
    let encoder = model
        .family_counts()
        .into_iter()
        .find(|c| c.family == Family::EncoderLayer)
        .unwrap();
    assert_eq!(encoder.actual, 24 * 26);

    let f16_count = model.tensors().filter(|t| t.dtype == DType::F16).count();
    let f32_count = model.tensors().filter(|t| t.dtype == DType::F32).count();
    assert_eq!((f16_count, f32_count), (273, 448));
    for t in model.tensors() {
        assert_eq!(
            t.dtype == DType::F16,
            t.kind.uses_record_type(),
            "{}: matrix weights are f16, everything else f32",
            t.name
        );
    }

    let shapes: [(&str, DType, [i64; 4]); 14] = [
        (
            "encoder.pre_encode.out.weight",
            DType::F16,
            [4096, 1024, 1, 1],
        ),
        (
            "encoder.pre_encode.conv.0.weight",
            DType::F32,
            [3, 3, 1, 256],
        ),
        ("encoder.pre_encode.conv.0.bias", DType::F32, [1, 1, 256, 1]),
        (
            "encoder.pre_encode.conv.3.weight",
            DType::F32,
            [1, 1, 256, 256],
        ),
        (
            "encoder.layers.0.feed_forward1.linear1.weight",
            DType::F16,
            [1024, 4096, 1, 1],
        ),
        (
            "encoder.layers.23.feed_forward2.linear2.weight",
            DType::F16,
            [4096, 1024, 1, 1],
        ),
        (
            "encoder.layers.5.conv.depthwise_conv.weight",
            DType::F32,
            [9, 1024, 1, 1],
        ),
        (
            "encoder.layers.11.conv.pointwise_conv1.weight",
            DType::F16,
            [1024, 2048, 1, 1],
        ),
        (
            "encoder.layers.23.self_attn.pos_bias_u",
            DType::F32,
            [128, 8, 1, 1],
        ),
        (
            "decoder.prediction.embed.weight",
            DType::F16,
            [640, 8193, 1, 1],
        ),
        (
            "decoder.prediction.dec_rnn.lstm.weight_hh_l1",
            DType::F16,
            [640, 2560, 1, 1],
        ),
        (
            "decoder.prediction.dec_rnn.lstm.bias_h_l0",
            DType::F32,
            [2560, 1, 1, 1],
        ),
        ("joint.joint_net.2.weight", DType::F16, [640, 8198, 1, 1]),
        ("joint.enc.weight", DType::F16, [1024, 640, 1, 1]),
    ];
    for (name, dtype, ne) in shapes {
        let t = model
            .tensor(name)
            .unwrap_or_else(|| panic!("{name} missing"));
        assert_eq!((t.dtype, t.ne), (dtype, ne), "{name}");
        assert_eq!(t.data.len(), dtype.payload_bytes(&ne).unwrap(), "{name}");
    }
    let last = model.tensors().last().unwrap();
    assert_eq!(last.file_offset + last.data.len(), model.file_len());
}

#[test]
fn frontend_vocab_and_durations() {
    let Some(model) = pinned() else { return };
    assert_eq!(model.tdt_durations(), &[0, 1, 2, 3, 4]);

    let pre = model.preprocessor();
    assert_eq!((pre.n_fft, pre.n_mels, pre.n_fb), (512, 128, 257));
    assert_eq!(pre.filterbank.len(), 128 * 257);
    assert!(matches!(pre.filterbank, Cow::Borrowed(_)));
    assert_eq!(pre.window.len(), 400);
    assert_eq!(pre.window_pad_left(), 56);
    assert!(pre.normalize_per_feature);
    assert_eq!(pre.n_frames(16_000), 101);
    // The stored window is a symmetric 400-point Hann window (torch.hann_window(400,
    // periodic=False) in f32): within 2e-7 of 0.5 - 0.5 cos(2πn/399).
    for (n, &w) in pre.window.iter().enumerate() {
        let hann = 0.5 - 0.5 * (2.0 * std::f64::consts::PI * n as f64 / 399.0).cos();
        assert!((f64::from(w) - hann).abs() < 2e-7, "window[{n}] = {w}");
    }

    let vocab = model.vocab();
    assert_eq!(vocab.len(), 8192);
    assert_eq!(vocab.n_vocab(), 8192);
    assert_eq!(vocab.blank_id(), 8192);
    assert_eq!(vocab.unk_id(), 0);
    assert_eq!(vocab.bos_id(), 4);
    assert_eq!(vocab.eos_id(), 3);
    assert_eq!(vocab.piece_str(0), Some("<unk>"));
    assert_eq!(vocab.piece_str(3), Some("<|endoftext|>"));
    assert_eq!(vocab.piece_str(4), Some("<|startoftranscript|>"));
    assert_eq!(vocab.piece_str(8192), Some("[BLANK]"));
    assert_eq!(vocab.piece(8193), None);
    assert_eq!(vocab.id_of(b"<unk>"), Some(0));
    assert_eq!(vocab.id_of(b"[BLANK]"), Some(8192));
}

#[test]
fn semantic_accessors_match_native_layouts() {
    let Some(model) = pinned() else { return };

    let sub = model.subsampling();
    assert_eq!(
        (sub.n_channels, sub.n_freq_out, sub.causal),
        (256, 16, false)
    );
    assert_eq!(sub.n_out_frames(1000), 125);
    assert_eq!(sub.n_out_frames(1001), 126);

    assert_eq!(model.encoder_layers().len(), 24);
    for layer in model.encoder_layers() {
        assert!(layer.ff1_linear1_b.is_none() && layer.attn_q_b.is_none());
        assert!(layer.conv_pw1_b.is_none() && layer.ff2_linear2_b.is_none());
        let var = layer.conv_bn_var.unwrap().to_f32_vec();
        // Not a bias variant: the graph divides by sqrt(stored var), unchanged.
        assert_eq!(layer.conv_bn_var_as_loaded().unwrap(), var);
        assert!(
            var.iter().all(|&v| v > 0.0),
            "layer {} has a non-positive variance",
            layer.index
        );
        // num_batches_tracked is tagged f32 on disk; the loader holds its bytes as one i32.
        let nb = layer.conv_bn_num_batches.unwrap();
        assert_eq!((nb.dtype, nb.ne), (DType::F32, [1, 1, 1, 1]));
        assert_eq!(
            nb.as_i32().unwrap(),
            i32::from_le_bytes(nb.data.try_into().unwrap())
        );
    }
    assert!(model.encoder_layer(24).is_none());
    assert!(model.speaker_kernel().is_none());

    let pred = model.prediction();
    assert_eq!(
        (pred.layers.len(), pred.n_hidden, pred.blank_id),
        (2, 640, 8192)
    );
    // NeMo's blank_as_pad embedding: the blank row (the start token) is all zeros.
    let mut row = vec![1.0f32; 640];
    pred.embed.row_to_f32(8192, &mut row);
    assert!(row.iter().all(|&v| v == 0.0));
    for layer in &pred.layers {
        assert_eq!(layer.w_ih.ne, [640, 2560, 1, 1]);
        assert_eq!(layer.w_hh.ne, [640, 2560, 1, 1]);
        assert_eq!(layer.b_h.ne, [2560, 1, 1, 1]);
    }

    let joint = model.joint();
    assert_eq!(joint.n_out(), 8198);
    assert_eq!(joint.token_slots(), 0..8193);
    assert_eq!(joint.duration_slots(), 8193..8198);
    assert_eq!(joint.net_b.n_elements(), 8198);
}

#[test]
fn f16_views_and_tail_requantization() {
    let Some(model) = pinned() else { return };
    let mut borrowed = 0;
    for t in model.tensors().filter(|t| t.dtype == DType::F16).take(40) {
        let bits = t.f16_slice().unwrap();
        borrowed += usize::from(matches!(bits, Cow::Borrowed(_)));
        assert_eq!(bits.len(), t.n_elements());
        // Spot-check rows against an independent little-endian decode.
        for i in [0, t.n_elements() / 2, t.n_elements() - 1] {
            let raw = u16::from_le_bytes([t.data[2 * i], t.data[2 * i + 1]]);
            assert_eq!(bits[i], raw, "{}[{i}]", t.name);
        }
    }
    assert!(borrowed > 0);

    // The seven CPU-tail repack candidates (LSTM 2 x {ih, hh}, joint pred/enc/net).
    let candidates: Vec<_> = model
        .tensors()
        .filter(|t| t.kind.is_tail_q8_repack_candidate())
        .map(|t| t.name.to_owned())
        .collect();
    assert_eq!(candidates.len(), 7, "{candidates:?}");
    assert!(!TensorKind::PredEmbedWeight.is_tail_q8_repack_candidate());

    let w = model.joint().pred_w;
    let q = w.requantize_q8_0().unwrap();
    assert_eq!(q.len(), 640 * 640 / 32 * 34);
    let mut back = vec![0.0f32; 640 * 640];
    dequantize_row_q8_0(&q, &mut back);
    let bits = w.f16_slice().unwrap();
    for (block, (src, dst)) in bits.chunks_exact(32).zip(back.chunks_exact(32)).enumerate() {
        let amax = src
            .iter()
            .map(|&b| f16_to_f32(b).abs())
            .fold(0.0f32, f32::max);
        for (&s, &d) in src.iter().zip(dst) {
            // Half a quantization step plus 127x the f16 rounding error of the block scale
            // (relative 2^-11 when normal, absolute 2^-25 when subnormal).
            let scale_err = (amax / 127.0 * 4.9e-4).max(3.0e-8);
            let bound = amax / 127.0 * 0.5 + 127.0 * scale_err + 1e-7;
            assert!((f16_to_f32(s) - d).abs() <= bound, "block {block}");
        }
    }
}
