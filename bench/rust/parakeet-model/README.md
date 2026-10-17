# parakeet-model

Benchmark-only Rust reader for the pinned `ggml-parakeet-tdt-0.6b-v3-f16.bin`. It memory-maps the
file and exposes exactly what Voiceour's `parakeet_model_load`
(`Vendor/parakeet/src/parakeet.cpp` L2180–L3446) reads, validated the same way, plus "as-loaded"
views for the TDT tail, the mel frontend and the encoder engines. Nothing in the app depends on it.

Line references are to `Vendor/parakeet/src/parakeet.cpp` unless another file is named.

## Build, run, test

```sh
cd bench/rust/parakeet-model
cargo build --release
cargo test --release      # dtype unit tests, synthetic-file tests, pinned-file tests
./target/release/parakeet-model-info \
  ~/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin --verify
```

The pinned-file tests skip themselves (note on stderr) when the model is not at
`pin::default_model_path()`. `parakeet-model-info` exits 0 when everything passes, 1 when
`--verify` fails and 2 on a usage or load error. `--verify` hashes the whole 1.26 GB file; that
took about 4.5 s wall time on a shared machine.

From another bench crate: `parakeet-model = { path = "../parakeet-model" }`.

## API

```rust
// Opening and file-level data
impl Model {
    pub fn open(path: impl AsRef<Path>) -> Result<Model>;          // mmap + full native validation
    pub fn path(&self) -> &Path;
    pub fn bytes(&self) -> &[u8];                                  // the whole mapping
    pub fn file_len(&self) -> usize;
    pub fn layout(&self) -> FileLayout;                            // section offsets
    pub fn hparams(&self) -> &HParams;
    pub fn hparam_warnings(&self) -> &[String];                    // native "non-standard" warnings
    pub fn variant(&self) -> Variant;                              // optional families present
    pub fn n_pre_enc_features(&self) -> i64;                       // 4096
    pub fn vocab(&self) -> Vocab<'_>;
    pub fn tdt_durations(&self) -> &[u32];                         // [0, 1, 2, 3, 4]
    pub fn tensor_count(&self) -> usize;                           // 721
    pub fn tensor(&self, name: &str) -> Option<TensorView<'_>>;
    pub fn tensor_of(&self, kind: TensorKind, layer: usize) -> Option<TensorView<'_>>;
    pub fn tensors(&self) -> impl ExactSizeIterator<Item = TensorView<'_>> + '_;   // file order
    pub fn family_counts(&self) -> Vec<FamilyCount>;
    pub fn architecture_mismatches(&self) -> Vec<String>;          // empty = matches the loader
    // As-loaded semantic views (views.rs)
    pub fn preprocessor(&self) -> Preprocessor<'_>;
    pub fn subsampling(&self) -> Subsampling<'_>;
    pub fn encoder_layer(&self, index: usize) -> Option<EncoderLayer<'_>>;
    pub fn encoder_layers(&self) -> impl ExactSizeIterator<Item = EncoderLayer<'_>> + '_;
    pub fn speaker_kernel(&self) -> Option<SpeakerKernel<'_>>;    // None for the pinned file
    pub fn prediction(&self) -> Prediction<'_>;
    pub fn joint(&self) -> Joint<'_>;
}

#[derive(Clone, Copy)]
pub struct TensorView<'a> {
    pub name: &'a str, pub kind: TensorKind, pub layer: Option<usize>, pub dtype: DType,
    pub ne: [i64; 4], pub n_dims: usize, pub data: &'a [u8], pub file_offset: usize,
}
impl<'a> TensorView<'a> {
    pub fn n_elements(&self) -> usize;
    pub fn row_len(&self) -> usize;                                // ne[0]
    pub fn n_rows(&self) -> usize;                                 // ne[1] * ne[2] * ne[3]
    pub fn row_bytes(&self) -> usize;
    pub fn row(&self, i: usize) -> &'a [u8];
    pub fn row_to_f32(&self, i: usize, out: &mut [f32]);           // e.g. one embedding row
    pub fn to_f32_vec(&self) -> Vec<f32>;                          // any dtype, dequantized
    pub fn f32_slice(&self) -> Result<Cow<'a, [f32]>>;             // borrowed if 4-aligned
    pub fn f16_slice(&self) -> Result<Cow<'a, [u16]>>;             // fp16 bits; borrowed if 2-aligned
    pub fn q8_0_blocks(&self) -> Result<Cow<'a, [BlockQ8_0]>>;     // borrowed if 2-aligned
    pub fn as_i32(&self) -> Result<i32>;                           // num_batches_tracked as loaded
    pub fn requantize_q8_0(&self) -> Result<Vec<u8>>;              // the opt-in CPU-tail repack
}

impl<'a> Vocab<'a> {
    pub fn len(&self) -> usize;                                    // 8192 file pieces
    pub fn is_empty(&self) -> bool;
    pub fn n_vocab(&self) -> i32;
    pub fn blank_id(&self) -> i32;                                 // 8192
    pub fn unk_id(&self) -> i32;                                   // 0
    pub fn bos_id(&self) -> i32;                                   // 4
    pub fn eos_id(&self) -> i32;                                   // 3
    pub fn piece(&self, id: i32) -> Option<&'a [u8]>;              // blank -> b"[BLANK]"
    pub fn piece_str(&self, id: i32) -> Option<&'a str>;
    pub fn id_of(&self, piece: &[u8]) -> Option<i32>;
    pub fn max_piece_len(&self) -> usize;
    pub fn iter(&self) -> impl ExactSizeIterator<Item = (i32, &'a [u8])> + 'a;
}

pub struct HParams {                       // all i32 except eps; file order
    pub n_vocab, pub n_audio_ctx, pub n_audio_state, pub n_audio_head, pub n_audio_layer,
    pub n_mels, pub ftype, pub n_fft, pub subsampling_factor, pub n_subsampling_channels,
    pub n_conv_kernel, pub n_pred_dim, pub n_pred_layers, pub n_tdt_durations,
    pub n_max_tokens, pub eps: f32,
}
impl HParams {
    pub fn qntvr(&self) -> i32; pub fn wtype(&self) -> Option<i32>; pub fn head_dim(&self) -> i32;
    pub fn n_pred_embed(&self) -> i32; pub fn n_lstm_gates(&self) -> i32; pub fn n_joint_out(&self) -> i32;
    pub fn get(&self, which: HParam) -> i32;
}

// Semantic views: every field is a TensorView (or Option for optional families).
pub struct Preprocessor<'a> { pub n_fft, pub n_mels, pub n_fb, pub filterbank: Cow<'a, [f32]>,
                              pub window: Cow<'a, [f32]>, pub normalize_per_feature: bool }
impl Preprocessor<'_> { pub fn window_pad_left(&self) -> usize; pub fn n_frames(&self, n_samples: usize) -> usize; }
pub struct Subsampling<'a> { conv0_w, conv0_b, conv2_w, conv2_b, conv3_w, conv3_b, conv5_w, conv5_b,
                             conv6_w, conv6_b, out_w, out_b, n_channels, n_freq_out, causal }
impl Subsampling<'_> { pub fn n_out_frames(&self, n_mel_frames: usize) -> usize; }
pub struct EncoderLayer<'a> { index, norm_ff1_{w,b}, ff1_linear{1,2}_{w,b?}, norm_attn_{w,b},
    attn_{q,k,v,out}_{w,b?}, attn_pos_w, attn_pos_bias_{u,v}, norm_conv_{w,b}, conv_pw1_{w,b?},
    conv_dw_{w,b?}, conv_bn_{w,b}, conv_bn_{mean,var,num_batches}?, conv_pw2_{w,b?},
    norm_ff2_{w,b}, ff2_linear{1,2}_{w,b?}, norm_out_{w,b} }
impl EncoderLayer<'_> { pub fn conv_bn_var_as_loaded(&self) -> Option<Vec<f32>>; }
pub struct LstmLayer<'a> { pub index: usize, pub w_ih, pub w_hh, pub b_h }
pub struct Prediction<'a> { pub embed, pub layers: Vec<LstmLayer<'a>>, pub n_hidden: usize, pub blank_id: i32 }
pub struct Joint<'a> { pub enc_w, pub enc_b, pub pred_w, pub pred_b, pub net_w, pub net_b,
                       pub n_vocab: usize, pub n_durations: usize, pub blank_id: i32 }
impl Joint<'_> { pub fn n_out(&self) -> usize; pub fn token_slots(&self) -> Range<usize>;
                 pub fn duration_slots(&self) -> Range<usize>; }
pub struct SpeakerKernel<'a> { ff1_w, ff1_b, ff2_w, ff2_b, bg_ff1_w, bg_ff1_b, bg_ff2_w, bg_ff2_b }

// Bit-exact ggml conversions
pub fn f16_to_f32(h: u16) -> f32;               // ggml_compute_fp16_to_fp32 (ggml-impl.h L384)
pub fn f32_to_f16(f: f32) -> u16;               // ggml_compute_fp32_to_fp16 (ggml-impl.h L407), RNE
pub fn f16_slice_to_f32(src: &[u16], dst: &mut [f32]);
pub fn f32_slice_to_f16(src: &[f32], dst: &mut [u16]);
pub fn quantize_row_q8_0(x: &[f32], y: &mut [u8]);       // quantize_row_q8_0_ref (ggml-quants.c L276)
pub fn dequantize_row_q8_0(x: &[u8], y: &mut [f32]);     // dequantize_row_q8_0 (ggml-quants.c L553)
pub fn dequantize_row_q4_k(x: &[u8], y: &mut [f32]);
pub fn dequantize_row_q6_k(x: &[u8], y: &mut [f32]);
#[repr(C)] pub struct BlockQ8_0 { pub d: u16, pub qs: [i8; 32] }   // 34 bytes, ggml block_q8_0
pub enum DType { F32, F16, Q8_0, Q4_K, Q6_K }   // exactly the record types the loader accepts

// Architecture table and pin
pub enum TensorKind { /* the 70 parakeet_tensor slots */ }  // pattern(), name(layer), scope(), op(),
    // uses_record_type(), loaded_as_i32(), optional_family(), family(),
    // is_tail_q8_repack_candidate(), arch_shape(&HParams, n_pre_enc_features)
pub enum HParam { /* 14 validated hparams */ }               // name(), model_value()
pub mod pin { SIZE, SHA256_HEX, FILE_NAME, CACHE_DIR, fn default_model_path() -> PathBuf,
              fn sha256_hex(bytes: &[u8]) -> String }
pub type Result<T, E = Error> = std::result::Result<T, E>;
```

Constants `SAMPLE_RATE` (16000), `HOP_LENGTH` (160), `PREEMPHASIS` (0.97), `LOG_GUARD`
(2^-24) and `NORMALIZE_EPS` (1e-5) are the frontend values the native code hard-codes.

## File format

Every field is little-endian. There is no padding, so payload alignment is arbitrary.

| pinned offset | content |
|---|---|
| 0 | `u32` magic `0x67676d6c` (L2193) |
| 4 | 15 × `i32`: n_vocab, n_audio_ctx, n_audio_state, n_audio_head, n_audio_layer, n_mels, **ftype**, n_fft, subsampling_factor, n_subsampling_channels, n_conv_kernel, n_pred_dim, n_pred_layers, n_tdt_durations, n_max_tokens (L2203–L2233) |
| 64 | `i32` n_mel, `i32` n_fb, then `f32[n_mel·n_fb]` row-major `[n_mel][n_fb]` (L2270) |
| 131656 | `i32` n_window, then `f32[n_window]` (L2282) |
| 133260 | `u32[n_tdt_durations]`, with no count prefix (L2299) |
| 133280 | `i32` piece count, then for each piece `u32 len` + bytes (L2312) |
| 211938 | tensor records to EOF: `i32 n_dims, i32 name_len, i32 ggml_type, i32 ne[n_dims], name, payload` (L963) |

The record parser accepts only f32, f16, q8_0, q4_K and q6_K (L793). Names must be strict UTF-8,
contain no NUL and be shorter than 64 bytes. Every name must belong to the architecture, and
`ne[0]` must be a whole number of blocks. The pinned file has 273 f16 records (1,252,565,760 B)
and 448 f32 records (3,077,240 B). Only 170 of the 273 f16 payloads are 2-byte aligned, so
`f16_slice()` borrows those and copies the rest. The filterbank and window are 4-byte aligned
and are always borrowed.

## Conventions (ggml `ne` order)

`ne[0]` is the contiguous (fastest) axis, and unused trailing axes are 1. A 2-D tensor with
`ne = [K, N]` is the row-major matrix `W[n][k] = data[n·K + k]`. `ggml_mul_mat(W, x)` with
`x.ne = [K, T]` produces `y.ne = [N, T]`, where `y[t][n] = Σ_k W[n][k]·x[t][k]`. So `ne[0]` is
the **input** dimension and `ne[1]` is the **output** dimension, which is PyTorch's
`nn.Linear.weight` `[out, in]` layout read row-major. Activations are frame-major in the same
way: mel is `[T][128]`, and encoder states are `[T_enc][1024]`.

## Tensor families (pinned file, 721 records)

| family | records | ne (ggml) | dtype | role, row-major math |
|---|---|---|---|---|
| `encoder.pre_encode.conv.{0,2,5}.weight` | 3 | [3, 3, 1, 256] | f32 | `w[oc][ic][kt][kf]`. conv0 is a 3×3, stride-2, pad-1, 1→256 conv. conv2 and conv5 are depthwise 3×3, stride 2, pad 1. |
| `encoder.pre_encode.conv.{3,6}.weight` | 2 | [1, 1, 256, 256] | f32 | pointwise `W[out][in]` |
| `encoder.pre_encode.conv.{0,2,3,5,6}.bias` | 5 | [1, 1, 256, 1] | f32 | per-channel bias |
| `encoder.pre_encode.out.weight` | 1 | [4096, 1024] | f16 | `W[1024][4096]`, with input index `c·16 + f` |
| `encoder.pre_encode.out.bias` | 1 | [1024] | f32 | |
| `encoder.layers.N.norm_{feed_forward1,self_att,conv,feed_forward2,out}.{weight,bias}` | 10 × 24 | [1024] | f32 | LayerNorm γ/β, eps 1e-5 |
| `….feed_forward{1,2}.linear1.weight` | 2 × 24 | [1024, 4096] | f16 | `W[4096][1024]`, then SiLU |
| `….feed_forward{1,2}.linear2.weight` | 2 × 24 | [4096, 1024] | f16 | `W[1024][4096]` |
| `….self_attn.linear_{q,k,v,out,pos}.weight` | 5 × 24 | [1024, 1024] | f16 | `W[out][in]`. Output feature `h·128 + d` is head `h`, lane `d`. |
| `….self_attn.pos_bias_{u,v}` | 2 × 24 | [128, 8] | f32 | `u[h][d]`, `v[h][d]` |
| `….conv.pointwise_conv1.weight` | 24 | [1024, 2048] | f16 | `W[2048][1024]`, then GLU `a·σ(b)` |
| `….conv.depthwise_conv.weight` | 24 | [9, 1024] | f32 | `w[c][k]` |
| `….conv.batch_norm.{weight,bias,running_mean,running_var}` | 4 × 24 | [1024] | f32 | `(x − μ)/√var · γ + β`, with **no eps** |
| `….conv.batch_norm.num_batches_tracked` | 24 | [1] | f32 tag | held as one i32 and never read |
| `….conv.pointwise_conv2.weight` | 24 | [1024, 1024] | f16 | `W[out][in]` |
| `decoder.prediction.embed.weight` | 1 | [640, 8193] | f16 | `E[token][640]`. Row 8192 (blank) is all zeros. |
| `decoder.prediction.dec_rnn.lstm.weight_ih_l{0,1}` | 2 | [640, 2560] | f16 | `W_ih[2560][640]`, with gate blocks `[i, f, o, c]` |
| `decoder.prediction.dec_rnn.lstm.weight_hh_l{0,1}` | 2 | [640, 2560] | f16 | `W_hh[2560][640]`, same gate order |
| `decoder.prediction.dec_rnn.lstm.bias_h_l{0,1}` | 2 | [2560] | f32 | folded `b_ih + b_hh` |
| `joint.enc.weight` / `joint.enc.bias` | 2 | [1024, 640] / [640] | f16 / f32 | `W[640][1024]` |
| `joint.pred.weight` / `joint.pred.bias` | 2 | [640, 640] / [640] | f16 / f32 | `W[640][640]` |
| `joint.joint_net.2.weight` / `.bias` | 2 | [640, 8198] / [8198] | f16 / f32 | `W[8198][640]`. Slots are pieces 0–8191, blank 8192, then durations 8193–8197. |
| *absent:* 11 per-layer biases (bias variant), 8 `spk_kernels`/`bg_spk_kernels` | 0 | | | optional families |

Per-family counts as `--verify` prints them: pre_encode 12, mandatory layer tensors 624
(26 × 24), BatchNorm stats 72, biases 0, speaker kernel 0, embedding 1, LSTM 6, joint 6.

## Load-time transformations (`parakeet_model_load`)

`parakeet_model_load` does **not** reorder, transpose, permute, reshape, fold or convert any
payload of the pinned file in production. Matrix weights reach the graph as stored, and so do
vectors, conv kernels and the frontend tables. Everything the loader does to the data:

1. **Hyperparameters** (L2203–L2268). `parakeet_validate_hparams` (L1246) requires every value
   to lie in `(0, PARAKEET_HPARAM_MODEL_VALUES]`, except that `n_tdt_durations` may be 0. A value
   that is accepted but non-standard only logs a warning; the pinned file gets
   `n_audio_layer = 24, expected 42` because the cap is 42 for 1.1b files. `model.hparams`
   keeps the **raw** `ftype`, because it is assigned at L2235, before `ftype %= 1000` at L2239.
   `wtype = ggml_ftype_to_ggml_type(ftype % 1000)` is f16, and only the legacy non-seekable path
   uses it. `eps = 1e-5` is a struct default (L313) and is not stored in the file. The crate
   exposes these as `HParams { ftype (raw), eps }`, `qntvr()` and `wtype()`.
2. **Frontend tables** (L2270–L2297). These are copied verbatim into `model.filters` and
   `mel_cache.window`. After loading, `mel_cache.init(n_fft)` (L5626) builds sin/cos tables and
   a periodic Hann(n_fft) window. That Hann window is used only when the file window is empty
   (L5120), and the pinned file has a 400-sample window. Crate: `preprocessor()`.
3. **TDT durations** (L2299–L2310). These are `n_tdt_durations` × `u32`, copied verbatim.
   Crate: `tdt_durations()`.
4. **Vocabulary** (L2312–L2373).
   - Ids are file order. The loader fills a `std::map`, so a duplicated piece resolves to its
     last id.
   - The blank id is the file piece count (8192), with `id_to_token[blank] = "[BLANK]"`
     (L2340–L2343).
   - `unk` is `<unk>`, otherwise 0.
   - `bos` is `<s>`, then `<|startoftranscript|>`, otherwise 0.
   - `eos` is `</s>`, then `<|endoftext|>`, otherwise 0 (L2347–L2367).
   - `vocab.n_vocab = hparams.n_vocab` (L2369).
   - Pinned ids: unk 0, bos 4, eos 3, blank 8192.

   Crate: `vocab()`.
5. **Record directory** (`parakeet_scan_tensor_records` L1093–L1213, called at L2425). Records
   must tile the file to EOF with no duplicates. The missing names must form a union of whole
   optional families: biases (11 per layer), BatchNorm stats (3 per layer), or the speaker
   kernel (8) (L1180–L1207).
6. **Tensor typing** (`create_tensor` L2485–L2604, called at L2682–L2897).
   - The 22 matrix kinds in `parakeet_tensor_uses_record_type` (L1215) take their dtype from
     the record, and the record must be 2-D (L2535).
   - Every other tensor is created as `GGML_TYPE_F32`, or `GGML_TYPE_I32` for
     `num_batches_tracked` (L2759). Its record payload must therefore be exactly 4 bytes per
     element.
   - Payloads are copied byte-for-byte (L3253, L3285).

   Consequence: `num_batches_tracked` is stored as f32 1056132.0 and held as the i32 bit
   pattern 1233185824. No graph reads it. Crate: `TensorView::dtype`, `as_i32()`.
7. **Pre-encode feature width** (L2685–L2692). The width comes from
   `encoder.pre_encode.out.weight`'s record `ne[0]`, which is 4096. Crate:
   `n_pre_enc_features()`, `Subsampling::n_freq_out` (16).
8. **Optional families** (L2798–L2857). These are all-or-none and select graph variants:
   - biases: added after each matmul when present;
   - BatchNorm stats: `ggml_norm` (LayerNorm) replaces BatchNorm when they are absent
     (L4056–L4064);
   - speaker kernel: causal subsampling and depthwise conv, chunked attention, and no
     per-feature mel normalization.

   The pinned file has BatchNorm stats and neither of the other two. Crate: `variant()`.
9. **Bias-variant BatchNorm-eps fold** (`fold_bias_variant_bn_eps` L3363–L3386). After reading,
   it sets `running_var += 1e-5f`, but only when the bias family is present. It is **not**
   applied to the pinned file. Crate: `EncoderLayer::conv_bn_var_as_loaded()`.
10. **Opt-in CPU-tail q8_0 repack** (selection L2546–L2564, conversion L3195–L3251).
    - Trigger: `VOICEOUR_TAIL_BACKEND=cpu` plus `VOICEOUR_TAIL_QUANT=q8_0`, which set
      `tail_backend_cpu && tail_quant_q8`. Both default to false (L5404).
    - It converts the 7 tail `MUL_MAT` weights: `weight_ih_l{0,1}`, `weight_hh_l{0,1}`,
      `joint.pred.weight`, `joint.enc.weight` and `joint.joint_net.2.weight`. The embedding is a
      `GET_ROWS` input and is excluded.
    - Method: `ggml_fp16_to_fp32_row`, then `quantize_row_q8_0_ref` per row.

    Crate: `TensorView::requantize_q8_0()` (bit-exact port) and
    `TensorKind::is_tail_q8_repack_candidate()`.
11. **Placement** has no effect on values. By default all weights go to the Metal buffer. A CPU
    tail puts the prediction/joint weights in the plain CPU buffer type (L2588), so neither
    production path uses ggml's repacking CPU "extra" buffer types. The file-backed weight arena
    caches the loaded image unchanged. Byte swaps compile out on arm64.

### Converter-time transforms (already in the file; the loader does nothing)

- LSTM gate blocks are ordered `[i, f, o, c]`, reordered from PyTorch's `[i, f, g, o]` (comment
  at L4354). The bias `b_h` is `b_ih + b_hh` (L383, L4342).
- Conv1d weights are squeezed to 2-D: `pointwise_conv1` [1024, 2048], `pointwise_conv2`
  [1024, 1024] and `depthwise_conv` [9, 1024]. Subsampling biases are stored 4-D [1, 1, 256, 1].
- Observed in the data: the blank embedding row is all zeros (NeMo `blank_as_pad`). The stored
  window is a symmetric 400-point Hann window, within 2e-7 of `0.5 − 0.5·cos(2πn/399)`.

## Graph-time ("lazy") transformations to replicate

These happen while the graph is built or runs, not at load time.

### Encoder (`parakeet_build_graph_encode` L3520–L4115)

- **Input**: mel `ne = [128, T]`, frame-major. The encoder runs on exactly `T = n_len` frames:
  L6410–L6416 for at most 5000 frames, and L6168 for the longer dynamic path. The pad mask
  (L4159) is then all zero, because `n_tokens_real = ceil(T/8) = T_enc`.
- **Subsampling** (L3538–L3620): conv0 → ReLU → conv2 + b → conv3 → ReLU → conv5 + b → conv6 → ReLU →
  permute `[f, t, c] → [f, c, t]` and flatten (L3606–L3615) → `out`. `T_enc = ceil(T/8)`.
  conv0 is computed through `ggml_im2col` with an **f16** destination (`itype`, L3472). The 1×1
  convs conv3 and conv6 transpose and **cast the activations to f16** (L3493–L3499). The
  depthwise convs run in f32 (`ggml_conv_2d_dw_direct`, L3569 and L3587).
- **Relative positional encoding** is computed in the graph, not stored.
  `freq[k] = expf(−2k·logf(10000)/1024)` (L4217–L4228), and `rel[p] = T_enc − 1 − p` for
  `p ∈ [0, 2T_enc − 1)` (L4230–L4246). The embedding is
  `pos_emb[p][2k] = sin(freq[k]·rel[p])`, `pos_emb[p][2k+1] = cos(…)`, with sin and cos taken on
  the device (L3678–L3685). Then `P = linear_pos · pos_emb`, with no bias.
- **Attention** (dense branch L3885–L3995):
  `score[h][q][k] = ((Q+u)_q·K_k + rel_shift((Q+v)·P)[q][k]) / √128 + mask`, followed by
  `softmax`, `·V` and `linear_out`. `rel_shift` selects relative distance `q − k`, through view
  offset `center = T_enc − 1` (L3939). The local-attention branch applies only when
  `T_enc > 8192` (L3650), which a dictation never reaches.
- **Conv module** (L4008–L4081): LN → pw1 → GLU, which is the first half × σ(second half)
  (L4021) → transpose → zero-pad (K−1)/2 = 4 frames on each side (L4043–L4045) →
  `ggml_ssm_conv`, i.e. `y[t][c] = Σ_k w[c][k]·x[t+k−4][c]` in f32 →
  BatchNorm `(x − mean)/sqrt(var)·γ + β`, with **no eps** (L4056–L4065) → SiLU → pw2 →
  residual.
- **Block order** (L3687–L4105): `x += 0.5·FFN1`, `x += MHSA`, `x += Conv`, `x += 0.5·FFN2`, then
  `x = LN_out(x)`. Every LN is `ggml_norm(eps 1e-5)·γ + β`. The last layer's `norm_out` output
  is `encoder_out` (L4107). **There is no separate encoder-output tensor.** `joint.enc`
  consumes these states directly.
- **Matmul precision on Metal**: `kernel_mul_mm_{f16,f32}_f32` convert *both* operands to
  `half` as they stage them in threadgroup memory, then accumulate in float
  (`Vendor/parakeet/ggml/src/ggml-metal/ggml-metal.metal` L10760–L10763 and L10289).
  `ggml-metal-ops.cpp` takes that path for non-transposed operands whenever
  `ne00 ≥ 64 && ne11 > 8` (L2331, L2436–L2440). That covers every encoder projection, since
  `ne00 ≥ 1024` and `ne11 = T_enc`. It also covers the f32 × f32 attention products whenever
  their shapes qualify (`d_head = 128`; `T_enc ≥ 64` for probs · V). Matmuls with `ne11 = 1`,
  such as the decode tail's, take `kernel_mul_mv_*`, which multiplies in float (L4316). A Rust
  or Metal encoder that keeps f32 operands will therefore not be bit-identical to ggml-metal.

### Tail (LSTM L4323–L4389, prediction L4397–L4434, step L4474–L4528, decode L4761)

- The LSTM state starts at zero (L1312). The first token is the blank, whose embedding is the
  zero row 8192.
- LSTM op order: `gates = W_ih·x + (W_hh·h + b_h)`, then `i, f, o = σ(gates[0:3P])`,
  `g = tanh(gates[3P:4P])`, `c' = f·c + i·g`, `h' = o·tanh(c')`.
- The prediction output is `pred = joint.pred_w · h_top + pred_b`, computed once per emitted
  token and cached.
- Joint: `logits = net_w · relu((enc_w·e_t + enc_b) + pred) + net_b`. Softmax runs over the
  full 8198-wide row, followed by `log` (L4518).
- Greedy argmax: tokens use strict `>` over the **log-probs** of slots 0–8192, and durations use
  the **raw** logits of slots 8193–8197 (L4652–L4666, L4773).
- CPU-tail matmuls round the f32 operand to f16 for f16 weights, or quantize it to q8_0 for
  q8_0 weights (`vec_dot_type`, `ggml-cpu/ggml-cpu.c` L221–L226, L271–L274).

### Mel frontend (`log_mel_spectrogram` L5104–L5221)

The preprocessing steps run in this order, with `n_fft = 512` and `HOP_LENGTH = 160`:

1. Pre-emphasis `x[i] −= 0.97·x[i−1]`, iterating i from n−1 down to 1 (L5127).
2. Centred zero padding of `n_fft/2` = 256 samples on each side.
3. Framing. There are `n_samples/160 + 1` frames. Each frame is `n_fft` = 512 long, with the
   400-sample window placed at `window_pad_left()` = 56.
4. A radix-2 FFT, then power `re² + im²` for 257 bins.
5. The mel energy for each bin is computed in double precision as `Σ_k power[k]·fb[j][k]` (the
   loop is 4-way unrolled). The result is stored as the float `log(sum + 2^-24)` (L5045).
6. Per-feature z-score in double: the mean and the unbiased std are taken over the first
   `n_samples/160` frames. The result `(x − mean)/(std + 1e-5)` is applied to all frames
   (L5178).

## Verified

All of the following was observed in this worktree:

- `cargo build --release`: no warnings. `cargo test --release`: 23 tests pass. That is 10
  dtype unit tests, 7 synthetic-file tests, 5 pinned-file tests (which ran, not skipped) and
  1 doctest.
  - The f16 conversions are checked against the AArch64 `fcvt` instruction for all 65,536
    fp16 patterns, and for every f16 rounding tie ±1 ulp plus a 1M-point f32 sweep.
  - The synthetic tests build files in the native format and cover rejection cases: bad magic,
    hparams out of range, a bad ftype, truncation, an unknown name, a NUL in a name, an
    unsupported type, a duplicate, a wrong count, a partial bias set, a wrong shape, a non-2-D
    matrix record, a wrong payload size, a bad block shape and a partial speaker kernel.
- `parakeet-model-info <pinned> --verify` prints `VERIFY OK`:
  - size 1,255,897,319 and SHA-256 `833bffc9…2a426f` match the pin;
  - 721 of 721 records match the re-derived architecture table, with 0 mismatches;
  - the record payloads end exactly at EOF.
