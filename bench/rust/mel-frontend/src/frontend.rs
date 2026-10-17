//! The tables `log_mel_spectrogram` computes with, built exactly as parakeet.cpp builds them.
//!
//! - `filters` and `window` are copied verbatim from the model file (`model.filters`,
//!   `mel_cache.window`, parakeet.cpp L2270–L2297).
//! - `sin`/`cos` are `parakeet_mel_cache::fill_sin_cos_table` (L562): `theta` in double, rounded to
//!   float, then one `__sincosf_stret` call per entry. Clang folds the source's `sinf`/`cosf` pair
//!   into that call (`fill_sin_cos_table` in the release `CParakeet.o`), so it is called here too.
//! - The periodic Hann window `mel_cache.init` also builds is only used when the file has no
//!   window (L5120); the pinned file has one, and an empty window is refused instead.

use std::f64::consts::PI;

use parakeet_model::{HOP_LENGTH, Model};

/// Frontend data for one model, shared by every arm.
#[derive(Debug)]
pub struct Frontend {
    /// FFT / frame size (`hparams.n_fft`, 512).
    pub n_fft: usize,
    /// Mel bins (`filters.n_mel`, 128).
    pub n_mels: usize,
    /// FFT bins per filter row (`filters.n_fb`, 257).
    pub n_fb: usize,
    /// Analysis window from the file (400 samples).
    pub window: Vec<f32>,
    /// `(n_fft - window.len()) / 2` (56): where the window sits in the frame.
    pub pad_left: usize,
    /// Row-major `[n_mels][n_fb]` filterbank from the file.
    pub filters: Vec<f32>,
    /// `mel_cache.sin_vals`, `n_fft` entries.
    pub sin: Vec<f32>,
    /// `mel_cache.cos_vals`, `n_fft` entries.
    pub cos: Vec<f32>,
    /// Per-feature z-score (on unless the file has a speaker kernel).
    pub normalize: bool,
    /// The filterbank's non-zero 4-bin groups, for the sparse arms.
    pub sparse: SparseFilters,
}

impl Frontend {
    /// Opens `path` with the full native validation and copies the frontend tables out, so the
    /// 1.26 GB mapping is released before any arm runs.
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Frontend, String> {
        let model = Model::open(path.as_ref())
            .map_err(|error| format!("{}: {error}", path.as_ref().display()))?;
        Self::from_model(&model)
    }

    pub fn from_model(model: &Model) -> Result<Frontend, String> {
        let pre = model.preprocessor();
        let n_fft = pre.n_fft;
        if n_fft < 16 || !n_fft.is_power_of_two() {
            // Native code would take its O(N^2) `dft` branch (L4984) for odd sub-sizes.
            return Err(format!(
                "n_fft {n_fft} is not a power of two >= 16; only radix-2 is ported"
            ));
        }
        if pre.n_fb != n_fft / 2 + 1 {
            return Err(format!(
                "n_fb {} != n_fft / 2 + 1 ({})",
                pre.n_fb,
                n_fft / 2 + 1
            ));
        }
        if pre.window.is_empty() || pre.window.len() > n_fft {
            return Err(format!(
                "window has {} samples; the ported path needs 1..={n_fft} (no Hann fallback)",
                pre.window.len()
            ));
        }
        if pre.n_mels == 0 || pre.filterbank.len() != pre.n_mels * pre.n_fb {
            return Err(format!(
                "filterbank has {} values for {} x {}",
                pre.filterbank.len(),
                pre.n_mels,
                pre.n_fb
            ));
        }
        let (sin, cos) = sin_cos_table(n_fft);
        let filters = pre.filterbank.to_vec();
        let sparse = SparseFilters::new(&filters, pre.n_mels, pre.n_fb);
        Ok(Frontend {
            n_fft,
            n_mels: pre.n_mels,
            n_fb: pre.n_fb,
            pad_left: (n_fft - pre.window.len()) / 2,
            window: pre.window.to_vec(),
            filters,
            sin,
            cos,
            normalize: pre.normalize_per_feature,
            sparse,
        })
    }

    /// `mel.n_len`: `(n_samples + 2 * (n_fft / 2) - n_fft) / HOP_LENGTH + 1` (L5139).
    pub fn n_frames(&self, n_samples: usize) -> usize {
        (n_samples + 2 * (self.n_fft / 2) - self.n_fft) / HOP_LENGTH + 1
    }

    /// `valid_frames = n_samples / frame_step` (L5180): the frames the z-score statistics use.
    pub fn valid_frames(n_samples: usize) -> usize {
        n_samples / HOP_LENGTH
    }
}

#[repr(C)]
struct SinCos {
    sin: f32,
    cos: f32,
}

unsafe extern "C" {
    /// libSystem's combined float sine/cosine (`{sin, cos}` returned in s0/s1).
    safe fn __sincosf_stret(x: f32) -> SinCos;
}

/// `fill_sin_cos_table`: `theta = (2 * M_PI * i) / n_fft` in double, then `sinf`/`cosf` of the
/// float-rounded theta.
fn sin_cos_table(n_fft: usize) -> (Vec<f32>, Vec<f32>) {
    let mut sin = vec![0.0f32; n_fft];
    let mut cos = vec![0.0f32; n_fft];
    for i in 0..n_fft {
        let theta = (2.0 * PI * i as f64) / n_fft as f64;
        let pair = __sincosf_stret(theta as f32);
        sin[i] = pair.sin;
        cos[i] = pair.cos;
    }
    (sin, cos)
}

/// The dense loop's 4-bin groups (`for (k = 0; k < n_fb - 3; k += 4)`, L5079) and remainder
/// bins, keeping only those with a non-zero weight.
///
/// Skipping the rest is exact for finite power spectra: every product in a skipped group is a
/// finite non-negative power times a `±0` weight, so the group's float sum is `±0`; widened to
/// double and added to the running sum it changes nothing, because that sum starts at `+0`, can
/// never become `-0` (an RNE sum is `-0` only when both addends are), and `x + ±0 == x` for every
/// other `x`. A frame whose power spectrum is not finite takes the dense loop instead, where
/// `inf * 0` must still produce the native NaN.
#[derive(Debug)]
pub struct SparseFilters {
    /// Per mel bin, the half-open range of its groups in `group_k`/`group_w`.
    pub group_range: Vec<(u32, u32)>,
    /// First FFT bin of each kept group.
    pub group_k: Vec<u32>,
    /// The kept group's four weights.
    pub group_w: Vec<[f32; 4]>,
    /// Per mel bin, the range of its kept remainder bins in `tail_k`/`tail_w`.
    pub tail_range: Vec<(u32, u32)>,
    pub tail_k: Vec<u32>,
    pub tail_w: Vec<f32>,
    /// The kept groups four at a time for NEON (lane `l` of batch `b` is group `4b + l`; the
    /// last batch is padded with zero-weight groups at bin 0): each lane's first bin, and the
    /// weights component-major, `batch_w[b][c][l] = group_w[4b + l][c]`.
    pub batch_k: Vec<[u32; 4]>,
    pub batch_w: Vec<[[f32; 4]; 4]>,
    /// Groups per frame the dense loop evaluates (`n_mels * groups per row`).
    pub dense_groups: usize,
    /// Remainder products per frame the dense loop evaluates.
    pub dense_tail: usize,
}

impl SparseFilters {
    fn new(filters: &[f32], n_mels: usize, n_fb: usize) -> SparseFilters {
        let mut starts = Vec::new();
        let mut k = 0usize;
        while (k as isize) < n_fb as isize - 3 {
            starts.push(k);
            k += 4;
        }
        let tail_start = k;
        let mut sparse = SparseFilters {
            group_range: Vec::with_capacity(n_mels),
            group_k: Vec::new(),
            group_w: Vec::new(),
            tail_range: Vec::with_capacity(n_mels),
            tail_k: Vec::new(),
            tail_w: Vec::new(),
            batch_k: Vec::new(),
            batch_w: Vec::new(),
            dense_groups: n_mels * starts.len(),
            dense_tail: n_mels * (n_fb - tail_start),
        };
        for j in 0..n_mels {
            let row = &filters[j * n_fb..(j + 1) * n_fb];
            let first = sparse.group_k.len() as u32;
            for &k in &starts {
                let w = [row[k], row[k + 1], row[k + 2], row[k + 3]];
                // `-0.0 != 0.0` is false: signed zeros are skipped too (the file has one).
                if w.iter().any(|&value| value != 0.0) {
                    sparse.group_k.push(k as u32);
                    sparse.group_w.push(w);
                }
            }
            sparse
                .group_range
                .push((first, sparse.group_k.len() as u32));
            let first = sparse.tail_k.len() as u32;
            for (k, &w) in row.iter().enumerate().skip(tail_start) {
                if w != 0.0 {
                    sparse.tail_k.push(k as u32);
                    sparse.tail_w.push(w);
                }
            }
            sparse.tail_range.push((first, sparse.tail_k.len() as u32));
        }
        for batch in 0..sparse.group_k.len().div_ceil(4) {
            let mut k = [0u32; 4];
            let mut w = [[0.0f32; 4]; 4];
            for lane in 0..4 {
                if let Some(&group_k) = sparse.group_k.get(4 * batch + lane) {
                    k[lane] = group_k;
                    for (c, weights) in w.iter_mut().enumerate() {
                        weights[lane] = sparse.group_w[4 * batch + lane][c];
                    }
                }
            }
            sparse.batch_k.push(k);
            sparse.batch_w.push(w);
        }
        sparse
    }

    /// Kept groups per frame.
    pub fn kept_groups(&self) -> usize {
        self.group_k.len()
    }
}
