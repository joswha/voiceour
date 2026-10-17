//! The model file: parsing and validation that mirror `parakeet_model_load`
//! (Vendor/parakeet/src/parakeet.cpp L2180-L3446), and zero-copy views into the mapping.

use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;
use std::fs::File;
use std::path::{Path, PathBuf};

use memmap2::Mmap;

use crate::arch::{
    self, Family, HParams, JOINT_CREATION_ORDER, LAYER_CREATION_ORDER, OptionalFamily,
    PRE_ENCODE_CREATION_ORDER, SPEAKER_CREATION_ORDER, Scope, TensorKind,
};
use crate::dtype::{self, BLOCK_Q8_0_BYTES, BlockQ8_0, DType, QK8_0};
use crate::error::{Error, Result};

/// `GGML_FILE_MAGIC` (ggml.h L216): the little-endian `u32` at offset 0 (bytes `lmgg`).
pub const GGML_FILE_MAGIC: u32 = 0x6767_6d6c;
/// `GGML_MAX_NAME` (ggml.h L229): tensor names must be shorter than this.
pub const GGML_MAX_NAME: usize = 64;
/// The piece the loader assigns to the blank id (`id_to_token[blank_id]`, L2342).
pub const BLANK_PIECE: &[u8] = b"[BLANK]";

/// Byte offsets of the file's sections. The format has no alignment padding anywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileLayout {
    /// Total file size.
    pub file_len: usize,
    /// Offset of the 15 `i32` hyperparameters (right after the magic).
    pub hparams_offset: usize,
    /// Offset of `filters.n_mel`, `filters.n_fb`, then `n_mel * n_fb` f32.
    pub filters_offset: usize,
    /// Offset of `n_window` (`i32`), then `n_window` f32.
    pub window_offset: usize,
    /// Offset of the `n_tdt_durations` little-endian `u32` duration values.
    pub tdt_durations_offset: usize,
    /// Offset of the vocab section (`i32` count, then `u32 len` + bytes per piece).
    pub vocab_offset: usize,
    /// Offset of the first tensor record; records run back to back to end of file.
    pub records_offset: usize,
}

/// Which optional all-or-none record families the file carries (they select graph variants).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Variant {
    /// 11 per-layer linear/conv biases (bias-variant 1.1b checkpoints). Also turns on the
    /// load-time BatchNorm-eps fold (see [`crate::EncoderLayer::conv_bn_var_as_loaded`]).
    pub encoder_biases: bool,
    /// BatchNorm running mean/var/num_batches_tracked. When absent the conv module normalizes
    /// with `ggml_norm` (LayerNorm) instead (L4056-L4064).
    pub batch_norm_stats: bool,
    /// Multitalker speaker kernel: selects causal subsampling, causal depthwise conv,
    /// chunked attention and disables per-feature mel normalization.
    pub speaker_kernel: bool,
}

impl Variant {
    /// Whether `family` is present.
    pub fn has(&self, family: OptionalFamily) -> bool {
        match family {
            OptionalFamily::EncoderBias => self.encoder_biases,
            OptionalFamily::BatchNormStats => self.batch_norm_stats,
            OptionalFamily::SpeakerKernel => self.speaker_kernel,
        }
    }
}

/// Count of records in one reporting family against what the loader expects for this file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FamilyCount {
    /// The family.
    pub family: Family,
    /// Records the native loader creates for it given the hyperparameters and the optional
    /// families present (0 for an absent optional family).
    pub expected: usize,
    /// Records of the family actually in the file.
    pub actual: usize,
    /// Payload bytes of those records.
    pub payload_bytes: usize,
}

#[derive(Clone, Debug)]
struct Record {
    name: String,
    kind: TensorKind,
    layer: Option<usize>,
    n_dims: usize,
    ne: [i64; 4],
    dtype: DType,
    payload_offset: usize,
    payload_bytes: usize,
}

#[derive(Clone, Copy, Debug)]
struct SpecialIds {
    blank: i32,
    unk: i32,
    bos: i32,
    eos: i32,
}

/// A memory-mapped, fully validated parakeet model file.
///
/// [`Model::open`] accepts exactly the files `parakeet_model_load` accepts through the seekable
/// file loader (`parakeet_init_from_file_with_params`) and rejects the rest with the native
/// loader's reason. All tensor payloads stay in the mapping; nothing is copied at open.
pub struct Model {
    path: PathBuf,
    map: Mmap,
    layout: FileLayout,
    hparams: HParams,
    hparam_warnings: Vec<String>,
    filters_n_mel: usize,
    filters_n_fb: usize,
    n_window: usize,
    tdt_durations: Vec<u32>,
    pieces: Vec<(usize, usize)>,
    special: SpecialIds,
    records: Vec<Record>,
    by_name: HashMap<String, usize>,
    by_kind: HashMap<(TensorKind, usize), usize>,
    variant: Variant,
    n_pre_enc_features: i64,
}

impl fmt::Debug for Model {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Model")
            .field("path", &self.path)
            .field("file_len", &self.layout.file_len)
            .field("hparams", &self.hparams)
            .field("variant", &self.variant)
            .field("tensors", &self.records.len())
            .finish_non_exhaustive()
    }
}

/// A zero-copy view of one tensor record's payload.
///
/// `ne` uses ggml order: `ne[0]` is the contiguous (fastest) axis. A 2-D tensor with
/// `ne = [K, N]` is the row-major matrix `w[n][k] = data[n * K + k]` (N rows of K elements),
/// and `ggml_mul_mat(w, x)` computes `y[t][n] = Σ_k w[n][k] · x[t][k]`: `ne[0]` is the input
/// dimension, `ne[1]` the output dimension, exactly PyTorch's `nn.Linear.weight` layout.
#[derive(Clone, Copy)]
pub struct TensorView<'a> {
    /// Record name, e.g. `encoder.layers.0.feed_forward1.linear1.weight`.
    pub name: &'a str,
    /// Architecture slot of the record.
    pub kind: TensorKind,
    /// Layer index for per-layer kinds (conformer or LSTM layer), `None` for global ones.
    pub layer: Option<usize>,
    /// Element type of the payload as recorded. This is also the type the native loader holds
    /// the tensor in, except `conv.batch_norm.num_batches_tracked`, which it loads as one
    /// `GGML_TYPE_I32` element (use [`TensorView::as_i32`]).
    pub dtype: DType,
    /// ggml extents, unused trailing axes are 1.
    pub ne: [i64; 4],
    /// Number of dimensions in the record header.
    pub n_dims: usize,
    /// Raw little-endian payload (`ggml_nbytes` bytes), borrowed from the mapping.
    pub data: &'a [u8],
    /// Absolute file offset of `data` (payloads are not aligned by the format).
    pub file_offset: usize,
}

impl fmt::Debug for TensorView<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TensorView")
            .field("name", &self.name)
            .field("dtype", &self.dtype)
            .field("ne", &self.ne)
            .field("n_dims", &self.n_dims)
            .field("bytes", &self.data.len())
            .field("file_offset", &self.file_offset)
            .finish()
    }
}

impl<'a> TensorView<'a> {
    /// Total element count.
    pub fn n_elements(&self) -> usize {
        self.ne.iter().map(|&n| n as usize).product()
    }

    /// Elements per row (`ne[0]`).
    pub fn row_len(&self) -> usize {
        self.ne[0] as usize
    }

    /// Number of rows (`ne[1] * ne[2] * ne[3]`).
    pub fn n_rows(&self) -> usize {
        (self.ne[1] * self.ne[2] * self.ne[3]) as usize
    }

    /// Bytes per row (`ggml_row_size(dtype, ne[0])`).
    pub fn row_bytes(&self) -> usize {
        self.data.len() / self.n_rows()
    }

    /// Raw bytes of row `i` (rows enumerate `ne[1]`, then `ne[2]`, then `ne[3]`).
    /// Panics when `i >= n_rows()`.
    pub fn row(&self, i: usize) -> &'a [u8] {
        assert!(i < self.n_rows(), "{}: row {i} out of range", self.name);
        let rb = self.row_bytes();
        &self.data[i * rb..(i + 1) * rb]
    }

    /// Dequantizes row `i` into `out` (`out.len() == ne[0]`), e.g. one embedding row exactly as
    /// `ggml_get_rows` yields it.
    pub fn row_to_f32(&self, i: usize, out: &mut [f32]) {
        assert_eq!(
            out.len(),
            self.row_len(),
            "{}: output row length",
            self.name
        );
        dtype::dequantize_into(self.dtype, self.row(i), out);
    }

    /// The whole tensor as f32 (dequantizing / widening as ggml's CPU `to_float` does).
    pub fn to_f32_vec(&self) -> Vec<f32> {
        let mut out = vec![0.0f32; self.n_elements()];
        dtype::dequantize_into(self.dtype, self.data, &mut out);
        out
    }

    /// The payload as f32: borrowed when 4-byte aligned, copied otherwise. Errors unless F32.
    pub fn f32_slice(&self) -> Result<Cow<'a, [f32]>> {
        self.expect_dtype(DType::F32)?;
        Ok(le_f32_slice(self.data))
    }

    /// The payload as fp16 bit patterns: borrowed when 2-byte aligned, copied otherwise.
    /// Errors unless F16. Convert with [`crate::f16_to_f32`].
    pub fn f16_slice(&self) -> Result<Cow<'a, [u16]>> {
        self.expect_dtype(DType::F16)?;
        Ok(le_u16_slice(self.data))
    }

    /// The payload as q8_0 blocks (row-major; each row holds `ne[0] / 32` blocks): borrowed
    /// when 2-byte aligned, copied otherwise. Errors unless Q8_0.
    pub fn q8_0_blocks(&self) -> Result<Cow<'a, [BlockQ8_0]>> {
        self.expect_dtype(DType::Q8_0)?;
        #[cfg(target_endian = "little")]
        {
            // SAFETY: BlockQ8_0 is repr(C) { u16, [i8; 32] } (34 bytes, align 2), valid for
            // every bit pattern; align_to only hands out the correctly aligned middle part.
            let (pre, mid, post) = unsafe { self.data.align_to::<BlockQ8_0>() };
            if pre.is_empty() && post.is_empty() {
                return Ok(Cow::Borrowed(mid));
            }
        }
        Ok(Cow::Owned(
            self.data
                .chunks_exact(BLOCK_Q8_0_BYTES)
                .map(|b| BlockQ8_0::from_bytes(b.try_into().expect("34-byte chunk")))
                .collect(),
        ))
    }

    /// The single `GGML_TYPE_I32` element the loader holds for `num_batches_tracked`
    /// (the record's 4 payload bytes reinterpreted). Errors for any other 4-byte-less tensor.
    pub fn as_i32(&self) -> Result<i32> {
        if self.data.len() != 4 {
            return Err(Error::DType {
                tensor: self.name.to_owned(),
                expected: "a single 4-byte element",
                actual: self.dtype,
            });
        }
        Ok(i32::from_le_bytes([
            self.data[0],
            self.data[1],
            self.data[2],
            self.data[3],
        ]))
    }

    /// Reproduces the opt-in CPU-tail load-time repack (`tail_backend_cpu && tail_quant_q8`,
    /// parakeet.cpp L2551-L2564, L3195-L3251): the f16 payload widened with
    /// `ggml_fp16_to_fp32_row` and quantized row by row with `quantize_row_q8_0_ref`. Returns
    /// the q8_0 bytes the native CPU tail then computes with. Errors unless the tensor is F16,
    /// 2-D, and `ne[0]` is a multiple of 32 — the native eligibility rule; the native loader
    /// applies it only to [`TensorKind::is_tail_q8_repack_candidate`] kinds.
    pub fn requantize_q8_0(&self) -> Result<Vec<u8>> {
        self.expect_dtype(DType::F16)?;
        if self.n_dims != 2 || self.row_len() % QK8_0 != 0 {
            return Err(Error::DType {
                tensor: self.name.to_owned(),
                expected: "a 2-D f16 tensor with ne[0] % 32 == 0",
                actual: self.dtype,
            });
        }
        let widened = self.to_f32_vec();
        let mut out = vec![0u8; widened.len() / QK8_0 * BLOCK_Q8_0_BYTES];
        dtype::quantize_row_q8_0(&widened, &mut out);
        Ok(out)
    }

    fn expect_dtype(&self, expected: DType) -> Result<()> {
        if self.dtype == expected {
            Ok(())
        } else {
            Err(Error::DType {
                tensor: self.name.to_owned(),
                expected: expected.name(),
                actual: self.dtype,
            })
        }
    }
}

/// Little-endian f32 payload: borrowed when aligned (little-endian host), copied otherwise.
pub(crate) fn le_f32_slice(bytes: &[u8]) -> Cow<'_, [f32]> {
    debug_assert!(bytes.len() % 4 == 0);
    #[cfg(target_endian = "little")]
    {
        // SAFETY: every bit pattern is a valid f32; align_to only yields aligned elements.
        let (pre, mid, post) = unsafe { bytes.align_to::<f32>() };
        if pre.is_empty() && post.is_empty() {
            return Cow::Borrowed(mid);
        }
    }
    Cow::Owned(
        bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect(),
    )
}

/// Little-endian u16 payload: borrowed when aligned (little-endian host), copied otherwise.
pub(crate) fn le_u16_slice(bytes: &[u8]) -> Cow<'_, [u16]> {
    debug_assert!(bytes.len() % 2 == 0);
    #[cfg(target_endian = "little")]
    {
        // SAFETY: every bit pattern is a valid u16; align_to only yields aligned elements.
        let (pre, mid, post) = unsafe { bytes.align_to::<u16>() };
        if pre.is_empty() && post.is_empty() {
            return Cow::Borrowed(mid);
        }
    }
    Cow::Owned(
        bytes
            .chunks_exact(2)
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
            .collect(),
    )
}

/// The vocabulary as the loader builds it (L2312-L2373): `id_to_token` for ids
/// `0..len()` from the file, plus the blank at id `len()` mapped to `"[BLANK]"`.
#[derive(Clone, Copy)]
pub struct Vocab<'a> {
    bytes: &'a [u8],
    pieces: &'a [(usize, usize)],
    n_vocab: i32,
    special: SpecialIds,
}

impl fmt::Debug for Vocab<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Vocab")
            .field("pieces", &self.pieces.len())
            .field("blank_id", &self.special.blank)
            .field("unk_id", &self.special.unk)
            .field("bos_id", &self.special.bos)
            .field("eos_id", &self.special.eos)
            .finish()
    }
}

impl<'a> Vocab<'a> {
    /// Pieces stored in the file (ids `0..len()`); the blank is not counted.
    pub fn len(&self) -> usize {
        self.pieces.len()
    }

    /// True when the file stores no pieces.
    pub fn is_empty(&self) -> bool {
        self.pieces.is_empty()
    }

    /// `vocab.n_vocab`, which the loader sets to `hparams.n_vocab` (L2369).
    pub fn n_vocab(&self) -> i32 {
        self.n_vocab
    }

    /// Blank id = the file's piece count (8192 pinned, L2340). Joint logit slot of the blank.
    pub fn blank_id(&self) -> i32 {
        self.special.blank
    }

    /// Last id whose piece is `<unk>`, else 0 (L2347-L2351).
    pub fn unk_id(&self) -> i32 {
        self.special.unk
    }

    /// Last id of `<s>`, else of `<|startoftranscript|>`, else 0 (L2353-L2359).
    pub fn bos_id(&self) -> i32 {
        self.special.bos
    }

    /// Last id of `</s>`, else of `<|endoftext|>`, else 0 (L2361-L2367).
    pub fn eos_id(&self) -> i32 {
        self.special.eos
    }

    /// `id_to_token[id]`: the raw piece bytes (SentencePiece pieces use U+2581 for spaces),
    /// `"[BLANK]"` for the blank id, `None` outside `0..=blank_id`.
    pub fn piece(&self, id: i32) -> Option<&'a [u8]> {
        if id == self.special.blank {
            return Some(BLANK_PIECE);
        }
        let (offset, len) = *self.pieces.get(usize::try_from(id).ok()?)?;
        Some(&self.bytes[offset..offset + len])
    }

    /// [`Vocab::piece`] as UTF-8 (`None` for invalid UTF-8; the loader does not validate).
    pub fn piece_str(&self, id: i32) -> Option<&'a str> {
        std::str::from_utf8(self.piece(id)?).ok()
    }

    /// `token_to_id[piece]`: `"[BLANK]"` maps to the blank id, duplicates resolve to the last
    /// id (the loader's map assignment overwrites).
    pub fn id_of(&self, piece: &[u8]) -> Option<i32> {
        if piece == BLANK_PIECE {
            return Some(self.special.blank);
        }
        last_index_of(self.bytes, self.pieces, piece)
    }

    /// `vocab.max_token_length` over the file pieces.
    pub fn max_piece_len(&self) -> usize {
        self.pieces.iter().map(|&(_, len)| len).max().unwrap_or(0)
    }

    /// File pieces in id order (the blank is not included).
    pub fn iter(&self) -> impl ExactSizeIterator<Item = (i32, &'a [u8])> + 'a {
        let bytes = self.bytes;
        self.pieces
            .iter()
            .enumerate()
            .map(move |(id, &(offset, len))| (id as i32, &bytes[offset..offset + len]))
    }
}

fn last_index_of(bytes: &[u8], pieces: &[(usize, usize)], piece: &[u8]) -> Option<i32> {
    pieces
        .iter()
        .rposition(|&(offset, len)| &bytes[offset..offset + len] == piece)
        .map(|i| i as i32)
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize, what: &str) -> Result<&'a [u8]> {
        if self.bytes.len() - self.pos < n {
            return Err(Error::Format(format!(
                "truncated {what} at offset {} (needs {n} bytes, {} left)",
                self.pos,
                self.bytes.len() - self.pos
            )));
        }
        let out = &self.bytes[self.pos..self.pos + n];
        self.pos += n;
        Ok(out)
    }

    fn i32(&mut self, what: &str) -> Result<i32> {
        let b = self.take(4, what)?;
        Ok(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn u32(&mut self, what: &str) -> Result<u32> {
        let b = self.take(4, what)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
}

fn count_of(value: i32, what: &str) -> Result<usize> {
    usize::try_from(value).map_err(|_| Error::Format(format!("negative {what} ({value})")))
}

/// `parakeet_is_valid_tensor_name` (L831): strict UTF-8 without NUL bytes.
fn valid_tensor_name(bytes: &[u8]) -> Option<&str> {
    if bytes.is_empty() || bytes.contains(&0) {
        return None;
    }
    std::str::from_utf8(bytes).ok()
}

impl Model {
    /// Maps `path` read-only and validates it exactly as `parakeet_model_load` does on the
    /// seekable file loader. The file must not be truncated or rewritten while mapped.
    pub fn open(path: impl AsRef<Path>) -> Result<Model> {
        let path = path.as_ref();
        let io = |source| Error::Io {
            path: path.to_path_buf(),
            source,
        };
        let file = File::open(path).map_err(io)?;
        // SAFETY: read-only private mapping of a model file; callers must not truncate or
        // rewrite the file while the Model is alive (documented on `open`).
        let map = unsafe { Mmap::map(&file) }.map_err(io)?;
        Model::parse(path.to_path_buf(), map)
    }

    fn parse(path: PathBuf, map: Mmap) -> Result<Model> {
        let bytes: &[u8] = &map;
        let mut r = Reader { bytes, pos: 0 };

        // verify magic (L2193-L2201)
        let magic = r.u32("magic")?;
        if magic != GGML_FILE_MAGIC {
            return Err(Error::Format(format!(
                "invalid model data (bad magic {magic:#010x}, expected {GGML_FILE_MAGIC:#010x})"
            )));
        }

        // hparams (L2203-L2268), file order with ftype between n_mels and n_fft
        let hparams_offset = r.pos;
        let n_vocab = r.i32("hparams")?;
        let n_audio_ctx = r.i32("hparams")?;
        let n_audio_state = r.i32("hparams")?;
        let n_audio_head = r.i32("hparams")?;
        let n_audio_layer = r.i32("hparams")?;
        let n_mels = r.i32("hparams")?;
        let ftype = r.i32("hparams")?;
        let n_fft = r.i32("hparams")?;
        let subsampling_factor = r.i32("hparams")?;
        let n_subsampling_channels = r.i32("hparams")?;
        let n_conv_kernel = r.i32("hparams")?;
        let n_pred_dim = r.i32("hparams")?;
        let n_pred_layers = r.i32("hparams")?;
        let n_tdt_durations = r.i32("hparams")?;
        let n_max_tokens = r.i32("hparams")?;
        let hparams = HParams {
            n_vocab,
            n_audio_ctx,
            n_audio_state,
            n_audio_head,
            n_audio_layer,
            n_mels,
            ftype,
            n_fft,
            subsampling_factor,
            n_subsampling_channels,
            n_conv_kernel,
            n_pred_dim,
            n_pred_layers,
            n_tdt_durations,
            n_max_tokens,
            eps: 1e-5,
        };
        let hparam_warnings = arch::validate_hparams(&hparams).map_err(Error::HParams)?;
        if hparams.wtype().is_none() {
            return Err(Error::HParams(format!(
                "invalid model (bad ftype value {ftype})"
            )));
        }

        // mel filters (L2270-L2280): [n_mel][n_fb] f32, row-major
        let filters_offset = r.pos;
        let filters_n_mel = count_of(r.i32("filters.n_mel")?, "filters.n_mel")?;
        let filters_n_fb = count_of(r.i32("filters.n_fb")?, "filters.n_fb")?;
        let filter_values = filters_n_mel
            .checked_mul(filters_n_fb)
            .and_then(|n| n.checked_mul(4))
            .ok_or_else(|| Error::Format("mel filterbank size overflows".into()))?;
        r.take(filter_values, "mel filterbank")?;

        // window function (L2282-L2297)
        let window_offset = r.pos;
        let n_window = count_of(r.i32("n_window")?, "n_window")?;
        r.take(n_window * 4, "window function")?;

        // TDT durations (L2299-L2310): n_tdt_durations u32, no count prefix
        let tdt_durations_offset = r.pos;
        let mut tdt_durations = Vec::with_capacity(n_tdt_durations as usize);
        for _ in 0..n_tdt_durations {
            tdt_durations.push(r.u32("tdt durations")?);
        }

        // vocab (L2312-L2373)
        let vocab_offset = r.pos;
        let n_pieces = count_of(r.i32("vocab size")?, "vocab size")?;
        let mut pieces = Vec::with_capacity(n_pieces);
        for _ in 0..n_pieces {
            let len = r.u32("vocab piece length")? as usize;
            let offset = r.pos;
            r.take(len, "vocab piece")?;
            pieces.push((offset, len));
        }
        let first_of = |candidates: &[&[u8]]| {
            candidates
                .iter()
                .find_map(|c| last_index_of(bytes, &pieces, c))
                .unwrap_or(0)
        };
        let special = SpecialIds {
            blank: i32::try_from(n_pieces)
                .map_err(|_| Error::Format("vocab size exceeds i32".into()))?,
            unk: first_of(&[b"<unk>"]),
            bos: first_of(&[b"<s>", b"<|startoftranscript|>"]),
            eos: first_of(&[b"</s>", b"<|endoftext|>"]),
        };

        // tensor records (parakeet_scan_tensor_records, L1093-L1213)
        let records_offset = r.pos;
        let expected = expected_names(&hparams)?;
        let records = scan_records(bytes, records_offset, &expected, &hparams)?;
        let mut by_name = HashMap::with_capacity(records.len());
        let mut by_kind = HashMap::with_capacity(records.len());
        for (i, rec) in records.iter().enumerate() {
            by_name.insert(rec.name.clone(), i);
            by_kind.insert((rec.kind, rec.layer.unwrap_or(0)), i);
        }

        // create_tensor pass (L2682-L2910)
        let (variant, n_pre_enc_features) = validate_architecture(&hparams, &records, &by_name)?;

        let layout = FileLayout {
            file_len: bytes.len(),
            hparams_offset,
            filters_offset,
            window_offset,
            tdt_durations_offset,
            vocab_offset,
            records_offset,
        };
        Ok(Model {
            path,
            map,
            layout,
            hparams,
            hparam_warnings,
            filters_n_mel,
            filters_n_fb,
            n_window,
            tdt_durations,
            pieces,
            special,
            records,
            by_name,
            by_kind,
            variant,
            n_pre_enc_features,
        })
    }

    /// Path the model was opened from.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The whole mapped file.
    pub fn bytes(&self) -> &[u8] {
        &self.map
    }

    /// File size in bytes.
    pub fn file_len(&self) -> usize {
        self.layout.file_len
    }

    /// Section offsets.
    pub fn layout(&self) -> FileLayout {
        self.layout
    }

    /// Hyperparameters as read (plus `eps`, which is not stored).
    pub fn hparams(&self) -> &HParams {
        &self.hparams
    }

    /// The `non-standard Parakeet metadata` warnings the native loader logs for this file
    /// (the pinned file draws one: `n_audio_layer = 24, expected 42`).
    pub fn hparam_warnings(&self) -> &[String] {
        &self.hparam_warnings
    }

    /// Optional record families present.
    pub fn variant(&self) -> Variant {
        self.variant
    }

    /// Flattened input width of `encoder.pre_encode.out` (its record `ne[0]`, 4096 pinned).
    pub fn n_pre_enc_features(&self) -> i64 {
        self.n_pre_enc_features
    }

    /// The vocabulary.
    pub fn vocab(&self) -> Vocab<'_> {
        Vocab {
            bytes: &self.map,
            pieces: &self.pieces,
            n_vocab: self.hparams.n_vocab,
            special: self.special,
        }
    }

    /// `model.tdt_durations`: frames advanced per TDT duration slot ([0, 1, 2, 3, 4] pinned);
    /// joint logit `n_vocab + 1 + i` scores `tdt_durations()[i]`.
    pub fn tdt_durations(&self) -> &[u32] {
        &self.tdt_durations
    }

    /// Number of tensor records.
    pub fn tensor_count(&self) -> usize {
        self.records.len()
    }

    /// The record named `name`.
    pub fn tensor(&self, name: &str) -> Option<TensorView<'_>> {
        self.by_name.get(name).map(|&i| self.view(i))
    }

    /// The record for architecture slot `kind` (layer ignored for global kinds).
    pub fn tensor_of(&self, kind: TensorKind, layer: usize) -> Option<TensorView<'_>> {
        let layer = if kind.scope() == Scope::Global {
            0
        } else {
            layer
        };
        self.by_kind.get(&(kind, layer)).map(|&i| self.view(i))
    }

    /// Every record in file order.
    pub fn tensors(&self) -> impl ExactSizeIterator<Item = TensorView<'_>> + '_ {
        (0..self.records.len()).map(move |i| self.view(i))
    }

    /// Record counts per reporting family against the loader's expectation for this file.
    pub fn family_counts(&self) -> Vec<FamilyCount> {
        Family::ALL
            .iter()
            .map(|&family| {
                let present = family.optional().is_none_or(|o| self.variant.has(o));
                let expected = if present {
                    family.count_when_present(&self.hparams)
                } else {
                    0
                };
                let (actual, payload_bytes) = self
                    .records
                    .iter()
                    .filter(|r| r.kind.family() == family)
                    .fold((0, 0), |(n, b), r| (n + 1, b + r.payload_bytes));
                FamilyCount {
                    family,
                    expected,
                    actual,
                    payload_bytes,
                }
            })
            .collect()
    }

    /// Re-derives the full expected tensor table (name, extents, payload size) from the
    /// hyperparameters and the optional families, independently of the record directory,
    /// and compares it with the records. Returns one message per mismatch (empty = match).
    pub fn architecture_mismatches(&self) -> Vec<String> {
        let mut problems = Vec::new();
        let mut expected_names = Vec::new();
        for kind in TensorKind::ALL {
            if let Some(family) = kind.optional_family()
                && !self.variant.has(family)
            {
                continue;
            }
            let layers = match kind.scope() {
                Scope::Global => 1,
                Scope::AudioLayer => self.hparams.n_audio_layer as usize,
                Scope::PredLayer => self.hparams.n_pred_layers as usize,
            };
            for layer in 0..layers {
                let name = kind.name(layer);
                let (n_dims, ne) = kind.arch_shape(&self.hparams, self.n_pre_enc_features);
                match self.tensor(&name) {
                    None => problems.push(format!("{name}: missing")),
                    Some(t) => {
                        if t.ne != ne {
                            problems.push(format!("{name}: ne {:?}, expected {ne:?}", t.ne));
                        }
                        let bytes = if kind.uses_record_type() {
                            if t.n_dims != 2 || n_dims != 2 {
                                problems.push(format!("{name}: not a 2-D record"));
                            }
                            t.dtype.payload_bytes(&ne)
                        } else {
                            if t.dtype != DType::F32 {
                                problems.push(format!("{name}: dtype {}, expected f32", t.dtype));
                            }
                            DType::F32.payload_bytes(&ne)
                        };
                        if bytes != Some(t.data.len()) {
                            problems.push(format!(
                                "{name}: payload {} bytes, expected {bytes:?}",
                                t.data.len()
                            ));
                        }
                    }
                }
                expected_names.push(name);
            }
        }
        if expected_names.len() != self.records.len() {
            problems.push(format!(
                "{} records, architecture expects {}",
                self.records.len(),
                expected_names.len()
            ));
        }
        problems
    }

    fn view(&self, i: usize) -> TensorView<'_> {
        let r = &self.records[i];
        TensorView {
            name: &r.name,
            kind: r.kind,
            layer: r.layer,
            dtype: r.dtype,
            ne: r.ne,
            n_dims: r.n_dims,
            data: &self.map[r.payload_offset..r.payload_offset + r.payload_bytes],
            file_offset: r.payload_offset,
        }
    }

    /// A tensor `open` guaranteed to exist.
    pub(crate) fn must(&self, kind: TensorKind, layer: usize) -> TensorView<'_> {
        self.tensor_of(kind, layer)
            .unwrap_or_else(|| panic!("validated model lacks {}", kind.name(layer)))
    }

    /// Mel filterbank payload `[n_mel][n_fb]`.
    pub(crate) fn filterbank_raw(&self) -> (&[u8], usize, usize) {
        let start = self.layout.filters_offset + 8;
        let len = self.filters_n_mel * self.filters_n_fb * 4;
        (
            &self.map[start..start + len],
            self.filters_n_mel,
            self.filters_n_fb,
        )
    }

    /// Window payload.
    pub(crate) fn window_raw(&self) -> &[u8] {
        let start = self.layout.window_offset + 4;
        &self.map[start..start + self.n_window * 4]
    }
}

/// `parakeet_expected_tensor_names` (L930): every architecture name, optional or not.
fn expected_names(hp: &HParams) -> Result<HashMap<String, (TensorKind, Option<usize>)>> {
    let mut names = HashMap::new();
    for kind in TensorKind::ALL {
        let layers = match kind.scope() {
            Scope::Global => None,
            Scope::AudioLayer => Some(hp.n_audio_layer as usize),
            Scope::PredLayer => Some(hp.n_pred_layers as usize),
        };
        let mut add = |name: String, layer: Option<usize>| {
            if name.is_empty() || name.len() >= GGML_MAX_NAME || names.contains_key(&name) {
                return Err(Error::Architecture(format!(
                    "invalid or duplicate architecture tensor name '{name}'"
                )));
            }
            names.insert(name, (kind, layer));
            Ok(())
        };
        match layers {
            None => add(kind.name(0), None)?,
            Some(n) => {
                for layer in 0..n {
                    add(kind.name(layer), Some(layer))?;
                }
            }
        }
    }
    if names.len() != arch::expected_name_count(hp) {
        return Err(Error::Architecture(
            "expected tensor-name count mismatch".into(),
        ));
    }
    Ok(names)
}

/// `parakeet_read_tensor_record` + `parakeet_scan_tensor_records` (L963-L1213).
fn scan_records(
    bytes: &[u8],
    records_offset: usize,
    expected: &HashMap<String, (TensorKind, Option<usize>)>,
    hp: &HParams,
) -> Result<Vec<Record>> {
    let file_len = bytes.len();
    let expected_count = expected.len();
    let max_record_metadata = 3 * 4 + 4 * 4 + (GGML_MAX_NAME - 1);
    let max_metadata = expected_count
        .checked_mul(max_record_metadata)
        .ok_or_else(|| Error::Format("tensor metadata cap overflows".into()))?;
    let mut records: Vec<Record> = Vec::with_capacity(expected_count);
    let mut seen: HashMap<&str, usize> = HashMap::with_capacity(expected_count);
    let mut total_metadata = 0usize;
    let mut r = Reader {
        bytes,
        pos: records_offset,
    };
    while r.pos != file_len {
        if records.len() >= expected_count {
            return Err(Error::Format(
                "too many tensor records in model file".into(),
            ));
        }
        let header_offset = r.pos;
        let fmt_err =
            |msg: &str| Error::Format(format!("{msg} (record at offset {header_offset})"));
        let (n_dims, name_len, type_id) = match (
            r.i32("tensor header"),
            r.i32("tensor header"),
            r.i32("tensor header"),
        ) {
            (Ok(a), Ok(b), Ok(c)) => (a, b, c),
            _ => return Err(fmt_err("truncated tensor header in model file")),
        };
        if !(0..=4).contains(&n_dims) || name_len <= 0 || name_len as usize >= GGML_MAX_NAME {
            return Err(fmt_err("invalid tensor header in model file"));
        }
        let n_dims = n_dims as usize;
        let name_len = name_len as usize;
        let metadata_bytes = 3 * 4 + 4 * n_dims + name_len;
        let dtype = DType::from_ggml_id(type_id)
            .ok_or_else(|| fmt_err(&format!("unsupported tensor type {type_id} in model file")))?;
        let mut ne = [1i64; 4];
        for n in ne.iter_mut().take(n_dims) {
            let v = r
                .i32("tensor dimensions")
                .map_err(|_| fmt_err("truncated tensor dimensions in model file"))?;
            if v <= 0 {
                return Err(fmt_err("invalid tensor dimensions in model file"));
            }
            *n = i64::from(v);
        }
        let name_bytes = r
            .take(name_len, "tensor name")
            .map_err(|_| fmt_err("truncated tensor name in model file"))?;
        let name = valid_tensor_name(name_bytes)
            .ok_or_else(|| fmt_err("invalid tensor name in model file"))?;
        let &(kind, layer) = expected
            .get(name)
            .ok_or_else(|| fmt_err(&format!("unknown tensor '{name}' in model file")))?;
        let payload_offset = r.pos;
        let payload_bytes = dtype.payload_bytes(&ne).ok_or_else(|| {
            fmt_err(&format!(
                "tensor '{name}' has an invalid block shape for type {type_id}"
            ))
        })?;
        if payload_bytes > file_len - payload_offset {
            return Err(fmt_err(&format!(
                "tensor '{name}' payload exceeds model bounds"
            )));
        }
        total_metadata += metadata_bytes;
        if total_metadata > max_metadata {
            return Err(fmt_err("tensor metadata exceeds bounded cap"));
        }
        if seen.insert(name, records.len()).is_some() {
            return Err(fmt_err(&format!("duplicate tensor '{name}' in model file")));
        }
        records.push(Record {
            name: name.to_owned(),
            kind,
            layer,
            n_dims,
            ne,
            dtype,
            payload_offset,
            payload_bytes,
        });
        r.pos = payload_offset + payload_bytes;
    }

    // Missing records must be a union of whole optional families (L1180-L1207).
    let missing = expected_count - records.len();
    let layers = hp.n_audio_layer as usize;
    let groups = [11 * layers, 3 * layers, 8];
    let valid = (0u32..8).any(|mask| {
        (0..3)
            .filter(|bit| mask & (1 << bit) != 0)
            .map(|bit| groups[bit])
            .sum::<usize>()
            == missing
    });
    if !valid {
        return Err(Error::Format(format!(
            "wrong tensor-record count: expected {expected_count}, got {} (missing {missing} is not optional families)",
            records.len()
        )));
    }
    Ok(records)
}

/// The `create_tensor` pass of `parakeet_model_load` (L2682-L2910): every architecture tensor
/// in creation order is looked up, shape-checked, typed and size-checked; optional families
/// must be all-or-none; the record set must equal the created set.
fn validate_architecture(
    hp: &HParams,
    records: &[Record],
    by_name: &HashMap<String, usize>,
) -> Result<(Variant, i64)> {
    let n_pre_enc_features = by_name
        .get(TensorKind::EncPreOutWeight.pattern())
        .map(|&i| records[i].ne[0])
        .unwrap_or_else(|| {
            i64::from(hp.n_mels / hp.subsampling_factor) * i64::from(hp.n_subsampling_channels)
        });
    let mut check = ArchCheck {
        hp,
        records,
        by_name,
        n_pre_enc_features,
        created: vec![false; records.len()],
        n_created: 0,
    };

    for kind in PRE_ENCODE_CREATION_ORDER {
        check.create(kind, 0)?;
    }
    let mut bias_created = 0usize;
    let mut norm_stats_created = 0usize;
    for layer in 0..hp.n_audio_layer as usize {
        for kind in LAYER_CREATION_ORDER {
            match kind.optional_family() {
                None => check.create(kind, layer)?,
                Some(OptionalFamily::EncoderBias) => {
                    bias_created += usize::from(check.create_optional(kind, layer)?);
                }
                Some(OptionalFamily::BatchNormStats) => {
                    norm_stats_created += usize::from(check.create_optional(kind, layer)?);
                }
                Some(OptionalFamily::SpeakerKernel) => unreachable!("speaker kinds are global"),
            }
        }
    }
    let layers = hp.n_audio_layer as usize;
    if bias_created != 0 && bias_created != 11 * layers {
        return Err(Error::Architecture(format!(
            "partial encoder bias set: {bias_created} of {} records present",
            11 * layers
        )));
    }
    if norm_stats_created != 0 && norm_stats_created != 3 * layers {
        return Err(Error::Architecture(format!(
            "partial BatchNorm statistics set: {norm_stats_created} of {} records present",
            3 * layers
        )));
    }
    let speaker_records = SPEAKER_CREATION_ORDER
        .iter()
        .filter(|k| by_name.contains_key(k.pattern()))
        .count();
    if speaker_records != 0 && speaker_records != 8 {
        return Err(Error::Architecture(
            "partial speaker-kernel record set".into(),
        ));
    }
    if speaker_records == 8 {
        for kind in SPEAKER_CREATION_ORDER {
            check.create(kind, 0)?;
        }
    }
    check.create(TensorKind::PredEmbedWeight, 0)?;
    for layer in 0..hp.n_pred_layers as usize {
        check.create(TensorKind::PredLstmWeightIh, layer)?;
        check.create(TensorKind::PredLstmWeightHh, layer)?;
        check.create(TensorKind::PredLstmBiasH, layer)?;
    }
    for kind in JOINT_CREATION_ORDER {
        check.create(kind, 0)?;
    }
    if check.n_created != records.len() || check.created.iter().any(|&c| !c) {
        return Err(Error::Architecture(
            "tensor record names do not match the architecture".into(),
        ));
    }
    let variant = Variant {
        encoder_biases: bias_created != 0,
        batch_norm_stats: norm_stats_created != 0,
        speaker_kernel: speaker_records == 8,
    };
    Ok((variant, n_pre_enc_features))
}

struct ArchCheck<'r> {
    hp: &'r HParams,
    records: &'r [Record],
    by_name: &'r HashMap<String, usize>,
    n_pre_enc_features: i64,
    created: Vec<bool>,
    n_created: usize,
}

impl ArchCheck<'_> {
    fn create(&mut self, kind: TensorKind, layer: usize) -> Result<()> {
        let name = kind.name(layer);
        let &index = self
            .by_name
            .get(&name)
            .ok_or_else(|| Error::Architecture(format!("missing parakeet tensor record {name}")))?;
        let rec = &self.records[index];
        let (n_dims, ne) = kind.arch_shape(self.hp, self.n_pre_enc_features);
        if rec.ne != ne {
            return Err(Error::Architecture(format!(
                "parakeet tensor {name} has the wrong record dimensions: record {:?}, architecture {ne:?}",
                rec.ne
            )));
        }
        let expected_bytes = if kind.uses_record_type() {
            if rec.n_dims != 2 || n_dims != 2 {
                return Err(Error::Architecture(format!(
                    "parakeet tensor {name} is not a 2-D quantizable weight record"
                )));
            }
            rec.dtype.payload_bytes(&ne)
        } else {
            // Legacy GGML_TYPE_F32 (or I32 for num_batches_tracked): 4 bytes per element.
            DType::F32.payload_bytes(&ne)
        };
        if expected_bytes != Some(rec.payload_bytes) {
            return Err(Error::Architecture(format!(
                "parakeet tensor {name} has the wrong record payload size: {} bytes as {}, loader expects {expected_bytes:?}",
                rec.payload_bytes, rec.dtype
            )));
        }
        if std::mem::replace(&mut self.created[index], true) {
            return Err(Error::Architecture(format!(
                "duplicate parakeet architecture tensor {name}"
            )));
        }
        self.n_created += 1;
        Ok(())
    }

    fn create_optional(&mut self, kind: TensorKind, layer: usize) -> Result<bool> {
        if self.by_name.contains_key(&kind.name(layer)) {
            self.create(kind, layer)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }
}
