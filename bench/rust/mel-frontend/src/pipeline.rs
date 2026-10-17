//! The restructured frontend behind `best`, `realfft` and `vdsp`.
//!
//! Same values as the native frontend, different work:
//! - no per-call allocation: each pool thread owns persistent scratch;
//! - no pre-emphasised/padded copy of the signal: each frame reads its 400 window samples straight
//!   from the input and applies the same `fmadd(x[t-1], -0.97f, x[t])` to them (the native
//!   backwards loop reads only unmodified `x[t-1]`, so each pre-emphasised sample is a pure function
//!   of two inputs) and zero outside the signal;
//! - the FFT is `ExactFft` (`best`) or a modern real FFT (`realfft`, `vdsp`);
//! - the sparse mel sum, four groups per NEON instruction (`mel_sparse_batched_guarded`);
//! - frames in contiguous chunks claimed by the pool's threads, then the per-feature z-score with
//!   32-bin column blocks on separate threads, frame-outer so each block's 32 accumulators run as
//!   independent vector lanes; every bin keeps the native frame order and operations.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicUsize, Ordering};

use parakeet_model::{HOP_LENGTH, NORMALIZE_EPS, PREEMPHASIS};

use crate::approx::{RealFft, RealFftScratch, VdspScratch};
use crate::exact::{ExactFft, ExactScratch};
use crate::frontend::Frontend;
use crate::kernels::{Rows, mel_sparse_batched_guarded};
use crate::pool::Pool;

/// Frames per claimed chunk.
const FRAME_CHUNK: usize = 8;
/// Mel bins per z-score block: 128 bytes of f32, one Apple-silicon cache line.
const BIN_BLOCK: usize = 32;

pub(crate) enum Fft {
    Exact(ExactFft),
    RealFft(RealFft),
    Vdsp,
}

enum FftScratch {
    Exact(ExactScratch),
    RealFft(RealFftScratch),
    Vdsp(VdspScratch),
}

struct Scratch {
    /// The `n_fft` frame: zeros around the window, which is the only part ever rewritten.
    frame: Vec<f32>,
    /// `n_fb` rounded up to whole vectors.
    power: Vec<f32>,
    /// The kept groups' float sums, four per batch.
    groups: Vec<f32>,
    fft: FftScratch,
}

/// One thread's scratch; thread `tid` of a pool job is the only user of cell `tid`.
struct Cell(UnsafeCell<Scratch>);

// SAFETY: see `Cell`; a job hands cell `tid` to thread `tid` only.
unsafe impl Sync for Cell {}

pub(crate) struct Fast {
    fft: Fft,
    cells: Vec<Cell>,
    pool: Option<Pool>,
}

impl Fast {
    /// `threads` total threads (1 = no pool).
    pub(crate) fn new(fe: &Frontend, fft: Fft, threads: usize) -> Result<Fast, String> {
        let pool = (threads > 1).then(|| Pool::new(threads));
        let n_threads = pool.as_ref().map_or(1, Pool::threads);
        let mut cells = Vec::with_capacity(n_threads);
        for _ in 0..n_threads {
            let fft_scratch = match &fft {
                Fft::Exact(exact) => FftScratch::Exact(exact.scratch()),
                Fft::RealFft(real) => FftScratch::RealFft(real.scratch()),
                Fft::Vdsp => FftScratch::Vdsp(VdspScratch::new(fe.n_fft)?),
            };
            cells.push(Cell(UnsafeCell::new(Scratch {
                frame: vec![0.0; fe.n_fft],
                power: vec![0.0; fe.n_fb.next_multiple_of(4)],
                groups: vec![0.0; 4 * fe.sparse.batch_k.len()],
                fft: fft_scratch,
            })));
        }
        Ok(Fast { fft, cells, pool })
    }

    pub(crate) fn threads(&self) -> usize {
        self.cells.len()
    }

    /// The whole frontend for `samples` into `out` (`n_frames * n_mels` values). Returns `n_frames`.
    pub(crate) fn compute(&mut self, fe: &Frontend, samples: &[f32], out: &mut [f32]) -> usize {
        let n_len = fe.n_frames(samples.len());
        let rows = Rows::new(out, n_len, fe.n_mels);
        let valid_frames = Frontend::valid_frames(samples.len());
        let n_frame_chunks = n_len.div_ceil(FRAME_CHUNK);
        let n_bin_blocks = fe.n_mels.div_ceil(BIN_BLOCK);
        let next_frames = AtomicUsize::new(0);
        let frames_done = AtomicUsize::new(0);
        let next_bins = AtomicUsize::new(0);
        let fft = &self.fft;
        let cells = &self.cells;

        let job = |tid: usize| {
            // SAFETY: thread `tid` is the only user of cell `tid` during this job.
            let scratch = unsafe { &mut *cells[tid].0.get() };
            loop {
                let chunk = next_frames.fetch_add(1, Ordering::Relaxed);
                if chunk >= n_frame_chunks {
                    break;
                }
                for i in chunk * FRAME_CHUNK..((chunk + 1) * FRAME_CHUNK).min(n_len) {
                    // SAFETY: chunks are disjoint, so row `i` is this thread's alone.
                    frame(fe, fft, samples, i, scratch, unsafe { rows.row(i) });
                }
                frames_done.fetch_add(1, Ordering::Release);
            }
            if !fe.normalize {
                return;
            }
            // The z-score needs every frame: wait for the chunks other threads still hold.
            while frames_done.load(Ordering::Acquire) < n_frame_chunks {
                std::hint::spin_loop();
            }
            loop {
                let block = next_bins.fetch_add(1, Ordering::Relaxed);
                if block >= n_bin_blocks {
                    break;
                }
                let j0 = block * BIN_BLOCK;
                // SAFETY: blocks are disjoint column ranges, and every frame is written.
                unsafe {
                    normalize_block(
                        rows,
                        n_len,
                        valid_frames,
                        j0,
                        (j0 + BIN_BLOCK).min(fe.n_mels),
                    )
                };
            }
        };
        match &self.pool {
            Some(pool) => pool.run(&job),
            None => job(0),
        }
        n_len
    }
}

/// One frame: window the pre-emphasised input, FFT, power, sparse mel sum and log.
fn frame(fe: &Frontend, fft: &Fft, x: &[f32], i: usize, scratch: &mut Scratch, row: &mut [f32]) {
    window_frame(fe, x, i, &mut scratch.frame);
    let power = &mut scratch.power;
    match (fft, &mut scratch.fft) {
        (Fft::Exact(exact), FftScratch::Exact(s)) => exact.power(&scratch.frame, s, power),
        (Fft::RealFft(real), FftScratch::RealFft(s)) => real.power(&scratch.frame, s, power),
        (Fft::Vdsp, FftScratch::Vdsp(s)) => s.power(&scratch.frame, power),
        _ => unreachable!("scratch built for this FFT"),
    }
    mel_sparse_batched_guarded(fe, power, &mut scratch.groups, row);
}

/// `frame[pad_left + m] = window[m] * xp[t]` for `t = i*160 - n_fft/2 + pad_left + m`, where `xp`
/// is the pre-emphasised signal and zero outside `0..n`; the rest of `frame` stays zero.
fn window_frame(fe: &Frontend, x: &[f32], i: usize, frame: &mut [f32]) {
    let win = fe.window.len();
    let dst = &mut frame[fe.pad_left..fe.pad_left + win];
    let base = (i * HOP_LENGTH + fe.pad_left) as isize - (fe.n_fft / 2) as isize;
    let n = x.len() as isize;
    if base >= 1 && base + win as isize <= n {
        let b = base as usize;
        let cur = &x[b..b + win];
        let prev = &x[b - 1..b - 1 + win];
        for m in 0..win {
            dst[m] = fe.window[m] * prev[m].mul_add(-PREEMPHASIS, cur[m]);
        }
    } else {
        for m in 0..win {
            let t = base + m as isize;
            let v = if t < 0 || t >= n {
                0.0
            } else if t == 0 {
                x[0]
            } else {
                x[t as usize - 1].mul_add(-PREEMPHASIS, x[t as usize])
            };
            dst[m] = fe.window[m] * v;
        }
    }
}

/// The native z-score (L5182–L5205) of bins `j0..j1`, iterated frame-outer.
///
/// # Safety
/// `rows` must hold `n_len` written rows, and no other thread may touch bins `j0..j1`.
unsafe fn normalize_block(rows: Rows, n_len: usize, valid_frames: usize, j0: usize, j1: usize) {
    if j1 - j0 != BIN_BLOCK {
        for j in j0..j1 {
            // SAFETY: forwarded.
            unsafe { normalize_block_n::<1>(rows, n_len, valid_frames, j) };
        }
        return;
    }
    // SAFETY: forwarded.
    unsafe { normalize_block_n::<BIN_BLOCK>(rows, n_len, valid_frames, j0) }
}

#[inline(always)]
unsafe fn normalize_block_n<const W: usize>(
    rows: Rows,
    n_len: usize,
    valid_frames: usize,
    j0: usize,
) {
    let width = rows.width();
    // SAFETY (all raw accesses): `i < n_len` and `j0 + W <= width` index written rows inside the
    // output; the caller owns these bins.
    let at = |i: usize| unsafe { rows.ptr().add(i * width + j0) };

    let mut sum = [0.0f64; W];
    for i in 0..valid_frames {
        let src = at(i);
        for j in 0..W {
            sum[j] += unsafe { *src.add(j) } as f64;
        }
    }
    let mut mean = [0.0f64; W];
    for j in 0..W {
        mean[j] = sum[j] / valid_frames as f64;
    }

    let mut sq_diff_sum = [0.0f64; W];
    for i in 0..valid_frames {
        let src = at(i);
        for j in 0..W {
            let diff = unsafe { *src.add(j) } as f64 - mean[j];
            sq_diff_sum[j] = diff.mul_add(diff, sq_diff_sum[j]);
        }
    }
    let mut denominator = [0.0f64; W];
    for j in 0..W {
        denominator[j] = (sq_diff_sum[j] / (valid_frames as f64 - 1.0)).sqrt() + NORMALIZE_EPS;
    }

    for i in 0..n_len {
        let dst = at(i);
        for j in 0..W {
            unsafe {
                *dst.add(j) = ((*dst.add(j) as f64 - mean[j]) / denominator[j]) as f32;
            }
        }
    }
}
