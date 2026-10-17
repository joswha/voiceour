//! Literal port of `log_mel_spectrogram` (parakeet.cpp L5104–L5221), its worker (L5029–L5102)
//! and the recursive `fft` (L4976–L5018), with the native data layout, allocation pattern and
//! loop order. Used by the `faithful`, `faithful-spawn`, `faithful-mt` and `sparse` arms.
//!
//! Clang compiles parakeet.cpp with floating-point contraction on, and every `a*b + c` the
//! release `CParakeet.o` fuses is fused here with `mul_add` (Rust never contracts on its own):
//! - pre-emphasis: `fmadd(x[i-1], -0.97f, x[i])`;
//! - each FFT butterfly output: two chained `fmadd`/`fmsub` with the table's `cos`/`sin`;
//! - power: `fmadd(re, re, im*im)`;
//! - each 4-bin mel group: `fmadd(f3,w3, fmadd(f2,w2, fmadd(f0,w0, f1*w1)))` in float, then widened
//!   and added to the double sum (the remainder bins are a plain float product, widened);
//! - variance: `fmadd(d, d, sq)` in double.

use std::sync::atomic::{AtomicUsize, Ordering};

use parakeet_model::{HOP_LENGTH, LOG_GUARD, NORMALIZE_EPS, PREEMPHASIS};

use crate::frontend::Frontend;
use crate::kernels::{Rows, mel_dense, mel_sparse_guarded};
use crate::pool::Pool;

/// How the per-frame work of one call is spread over threads.
pub(crate) enum Schedule<'a> {
    /// The caller does every frame (`n_threads == 1`).
    Single,
    /// parakeet.cpp's own threading: `n - 1` `std::thread`s spawned and joined per call, thread
    /// `ith` taking frames `i ≡ ith (mod n)`.
    Spawn(usize),
    /// The same interleaved slices, claimed by the persistent pool's threads.
    PoolSlices(&'a Pool),
    /// Contiguous chunks of this many frames, claimed dynamically by the pool's threads.
    PoolChunks(&'a Pool, usize),
}

/// Which mel sum each frame uses.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum MelSum {
    Dense,
    Sparse,
}

/// Per-worker buffers, sized as the native worker sizes them (L5036–L5037).
pub(crate) struct FftBuffers {
    fft_in: Vec<f32>,
    fft_out: Vec<f32>,
}

impl FftBuffers {
    pub(crate) fn new(frame_size: usize) -> FftBuffers {
        FftBuffers {
            fft_in: vec![0.0; frame_size * 2],
            fft_out: vec![0.0; frame_size * 2 * 2 * 2],
        }
    }
}

/// `log_mel_spectrogram` for one call: copies and pre-emphasises the samples, pads them, runs the
/// frames under `schedule`, then the single-threaded per-feature z-score. Returns `n_len`.
pub(crate) fn log_mel(
    fe: &Frontend,
    samples: &[f32],
    out: &mut [f32],
    schedule: Schedule<'_>,
    mel: MelSum,
) -> usize {
    let n_samples = samples.len();
    let frame_size = fe.n_fft;
    let n_mel = fe.n_mels;

    let mut samples_preprocessed = samples.to_vec();
    for i in (1..n_samples).rev() {
        samples_preprocessed[i] =
            samples_preprocessed[i - 1].mul_add(-PREEMPHASIS, samples_preprocessed[i]);
    }

    let pad = frame_size / 2;
    let mut samples_padded = vec![0.0f32; n_samples + 2 * pad];
    samples_padded[pad..pad + n_samples].copy_from_slice(&samples_preprocessed);

    let n_len = (samples_padded.len() - frame_size) / HOP_LENGTH + 1;
    let out = &mut out[..n_len * n_mel];
    let rows = Rows::new(out, n_len, n_mel);
    let padded = samples_padded.as_slice();

    match schedule {
        Schedule::Single => worker(fe, padded, n_len, rows, 0, 1, mel),
        Schedule::Spawn(n_threads) => std::thread::scope(|scope| {
            for ith in 1..n_threads {
                scope.spawn(move || worker(fe, padded, n_len, rows, ith, n_threads, mel));
            }
            worker(fe, padded, n_len, rows, 0, n_threads, mel);
        }),
        Schedule::PoolSlices(pool) => {
            let n_threads = pool.threads();
            let next = AtomicUsize::new(0);
            pool.run(&|_tid| {
                loop {
                    let ith = next.fetch_add(1, Ordering::Relaxed);
                    if ith >= n_threads {
                        break;
                    }
                    worker(fe, padded, n_len, rows, ith, n_threads, mel);
                }
            });
        }
        Schedule::PoolChunks(pool, chunk) => {
            let computed = (padded.len() / HOP_LENGTH + 1).min(n_len);
            let n_chunks = n_len.div_ceil(chunk);
            let next = AtomicUsize::new(0);
            pool.run(&|_tid| {
                let mut buffers: Option<FftBuffers> = None;
                loop {
                    let c = next.fetch_add(1, Ordering::Relaxed);
                    if c >= n_chunks {
                        break;
                    }
                    let buffers = buffers.get_or_insert_with(|| FftBuffers::new(frame_size));
                    for i in c * chunk..((c + 1) * chunk).min(n_len) {
                        // SAFETY: chunks are disjoint, so row `i` belongs to this thread alone.
                        let row = unsafe { rows.row(i) };
                        if i < computed {
                            frame(fe, padded, i, buffers, row, mel);
                        } else {
                            row.fill(LOG_GUARD.ln() as f32);
                        }
                    }
                }
            });
        }
    }

    if fe.normalize {
        normalize(out, n_len, n_mel, n_samples);
    }
    n_len
}

/// `log_mel_spectrogram_worker_thread`: frames `ith, ith + n_threads, …` with buffers allocated
/// per call, then `log(eps)` for frames past the padded signal (never reached: the padded length
/// always covers `n_len` frames).
fn worker(
    fe: &Frontend,
    padded: &[f32],
    n_len: usize,
    rows: Rows,
    ith: usize,
    n_threads: usize,
    mel: MelSum,
) {
    let mut buffers = FftBuffers::new(fe.n_fft);
    let mut i = ith;
    let computed = (padded.len() / HOP_LENGTH + 1).min(n_len);
    while i < computed {
        // SAFETY: frame `i` belongs to slice `ith` alone.
        frame(fe, padded, i, &mut buffers, unsafe { rows.row(i) }, mel);
        i += n_threads;
    }
    let empty_sum = LOG_GUARD.ln();
    while i < n_len {
        // SAFETY: as above.
        unsafe { rows.row(i) }.fill(empty_sum as f32);
        i += n_threads;
    }
}

/// One frame: window, FFT, power, mel sum and log (L5049–L5092).
pub(crate) fn frame(
    fe: &Frontend,
    padded: &[f32],
    i: usize,
    buffers: &mut FftBuffers,
    row: &mut [f32],
    mel: MelSum,
) {
    let frame_size = fe.n_fft;
    let window_size = fe.window.len();
    let n_fb = fe.n_fb;
    let FftBuffers { fft_in, fft_out } = buffers;

    let offset = i * HOP_LENGTH;
    let window_pad_left = (frame_size - window_size) / 2;
    fft_in[..window_pad_left].fill(0.0);
    let n_to_process = window_size.min(padded.len() - offset);
    for j in 0..n_to_process {
        fft_in[window_pad_left + j] = fe.window[j] * padded[offset + window_pad_left + j];
    }
    fft_in[window_pad_left + n_to_process..frame_size].fill(0.0);

    fft(fft_in, frame_size, fft_out, fe);

    for j in 0..n_fb {
        fft_out[j] =
            fft_out[2 * j].mul_add(fft_out[2 * j], fft_out[2 * j + 1] * fft_out[2 * j + 1]);
    }

    let power = &fft_out[..n_fb];
    match mel {
        MelSum::Dense => mel_dense(fe, power, row),
        MelSum::Sparse => mel_sparse_guarded(fe, power, row),
    }
}

/// The recursive radix-2 decimation-in-time FFT of a real `input[..n]` into interleaved complex
/// `out[..2n]`. `input[n..2n]` is the sub-sequence scratch and `out[2n..]` holds the halves'
/// spectra (`even` at `2n`, `odd` at `3n`), exactly as the native pointer arithmetic lays them out.
/// `n` is a power of two (checked when the tables were built), so the native odd-size `dft`
/// branch is unreachable.
fn fft(input: &mut [f32], n: usize, out: &mut [f32], fe: &Frontend) {
    if n == 1 {
        out[0] = input[0];
        out[1] = 0.0;
        return;
    }
    let half_n = n / 2;
    let (data, scratch) = input.split_at_mut(n);

    for i in 0..half_n {
        scratch[i] = data[2 * i];
    }
    fft(scratch, half_n, &mut out[2 * n..], fe);

    for i in 0..half_n {
        scratch[i] = data[2 * i + 1];
    }
    fft(scratch, half_n, &mut out[3 * n..], fe);

    let sin_cos_step = fe.n_fft / n;
    let (head, tail) = out.split_at_mut(2 * n);
    let (even_fft, odd_fft) = tail.split_at(n);
    for k in 0..half_n {
        let idx = k * sin_cos_step;
        let c = fe.cos[idx];
        let s = fe.sin[idx];
        let re_odd = odd_fft[2 * k];
        let im_odd = odd_fft[2 * k + 1];
        let re_even = even_fft[2 * k];
        let im_even = even_fft[2 * k + 1];
        // re = cos, im = -sin: `even + re*odd_re - im*odd_im`, …, each fused pairwise.
        head[2 * k] = s.mul_add(im_odd, c.mul_add(re_odd, re_even));
        head[2 * k + 1] = (-s).mul_add(re_odd, c.mul_add(im_odd, im_even));
        head[2 * (k + half_n)] = (-s).mul_add(im_odd, (-c).mul_add(re_odd, re_even));
        head[2 * (k + half_n) + 1] = s.mul_add(re_odd, (-c).mul_add(im_odd, im_even));
    }
}

/// The per-feature z-score in its native loop order (L5178–L5206): bin-outer, frame-inner,
/// statistics over `valid_frames = n_samples / 160` frames, applied to all `n_len` frames.
pub(crate) fn normalize(out: &mut [f32], n_len: usize, n_mel: usize, n_samples: usize) {
    let valid_frames = Frontend::valid_frames(n_samples);
    for j in 0..n_mel {
        let mut sum = 0.0f64;
        for i in 0..valid_frames {
            sum += out[i * n_mel + j] as f64;
        }
        let mean = sum / valid_frames as f64;

        let mut sq_diff_sum = 0.0f64;
        for i in 0..valid_frames {
            let diff = out[i * n_mel + j] as f64 - mean;
            sq_diff_sum = diff.mul_add(diff, sq_diff_sum);
        }

        let std_dev = (sq_diff_sum / (valid_frames as f64 - 1.0)).sqrt();
        let denominator = std_dev + NORMALIZE_EPS;
        for i in 0..n_len {
            out[i * n_mel + j] = ((out[i * n_mel + j] as f64 - mean) / denominator) as f32;
        }
    }
}
