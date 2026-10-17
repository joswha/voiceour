//! An iterative, split-complex, NEON radix-2 FFT that performs exactly the native recursive
//! FFT's arithmetic.
//!
//! The recursive decimation-in-time FFT (`faithful::fft`) computes, for each sub-transform of
//! size `N` and each `k < N/2`, the butterfly of the even half's `E[k]` and the odd half's `O[k]`
//! with the table twiddle at `k * (n_fft / N)`. The iterative form over bit-reversed input visits
//! the same `(E[k], O[k], twiddle)` triples stage by stage, and each output is the same pair of
//! fused operations (`vfmaq_f32`/`vfmsq_f32` round once per lane, like scalar `fmadd`/`fmsub`), so
//! every value — signed zeros included — equals the native one. Only the order in which
//! independent butterflies run, and where their operands live, differ:
//! - stages 1 and 2 run together in registers, four size-4 blocks per step, reading their inputs
//!   with contiguous loads (blocks whose bit-reversed sources are adjacent) and storing each
//!   block's four outputs with one transposed store;
//! - the middle stages run in fused pairs (`h`, `2h`) whose four quarter-blocks stay in registers
//!   between the two butterflies;
//! - the last stage computes only the outputs the power spectrum reads (bins `0..=N/2`).

use std::arch::aarch64::*;

use crate::frontend::Frontend;

pub(crate) struct ExactFft {
    n: usize,
    /// `rev(r)` for `r in 0..n/4`: where the size-4 block whose first source is `frame[r]` lives
    /// after bit reversal (its sources are `frame[r + {0, n/2, n/4, 3n/4}]`).
    block_offset: Vec<u16>,
    /// Stage twiddles: the stage of half-size `h` uses `cos/sin[k * n/(2h)]` at `h - 1 + k`.
    tw_c: Vec<f32>,
    tw_s: Vec<f32>,
}

/// One thread's FFT buffers.
pub(crate) struct ExactScratch {
    re: Vec<f32>,
    im: Vec<f32>,
}

impl ExactFft {
    pub(crate) fn new(fe: &Frontend) -> ExactFft {
        let n = fe.n_fft;
        assert!(n >= 16 && n.is_power_of_two());
        let bits = n.trailing_zeros();
        let reverse = |q: usize| q.reverse_bits() >> (usize::BITS - bits);
        let block_offset = (0..n / 4).map(|r| reverse(r) as u16).collect();
        let mut tw_c = vec![0.0f32; n - 1];
        let mut tw_s = vec![0.0f32; n - 1];
        let mut h = 1;
        while h < n {
            let step = n / (2 * h);
            for k in 0..h {
                tw_c[h - 1 + k] = fe.cos[k * step];
                tw_s[h - 1 + k] = fe.sin[k * step];
            }
            h *= 2;
        }
        ExactFft {
            n,
            block_offset,
            tw_c,
            tw_s,
        }
    }

    pub(crate) fn scratch(&self) -> ExactScratch {
        ExactScratch {
            re: vec![0.0; self.n],
            im: vec![0.0; self.n],
        }
    }

    /// `power[k] = |X[k]|^2` for `k in 0..=n/2` of the real `frame[..n]`, computed as
    /// `fmadd(re, re, im*im)` from the native FFT's bins.
    pub(crate) fn power(&self, frame: &[f32], scratch: &mut ExactScratch, power: &mut [f32]) {
        let n = self.n;
        assert!(frame.len() >= n && power.len() > n / 2);
        assert!(scratch.re.len() == n && scratch.im.len() == n);
        // SAFETY: every access below stays inside `re`/`im` (`n` floats), `frame` (`n` floats),
        // the twiddle tables (`n - 1`) and `power` (`n/2 + 1`), as asserted above.
        unsafe {
            let re = scratch.re.as_mut_ptr();
            let im = scratch.im.as_mut_ptr();
            self.first_two_stages(frame.as_ptr(), re, im);
            let mut h = 4;
            while 2 * h < n / 2 {
                self.stage_pair(re, im, h);
                h *= 4;
            }
            if h < n / 2 {
                self.stage(re, im, h);
            }
            self.last_stage(re, im);
            let half = n / 2;
            let out = power.as_mut_ptr();
            let mut k = 0;
            while k < half {
                let r = vld1q_f32(re.add(k));
                let i = vld1q_f32(im.add(k));
                vst1q_f32(out.add(k), vfmaq_f32(vmulq_f32(i, i), r, r));
                k += 4;
            }
            let r = *re.add(half);
            let i = *im.add(half);
            *out.add(half) = r.mul_add(r, i * i);
        }
    }

    /// Stages 1 and 2 for four size-4 blocks at a time. Block lane `l` takes `r = r0 + l`, so its
    /// sources `frame[r + {0, n/2, n/4, 3n/4}]` (positions `+0..+3` after bit reversal) load as four
    /// contiguous vectors; inputs are real (`im = +0`, as the native leaves set it).
    unsafe fn first_two_stages(&self, frame: *const f32, re: *mut f32, im: *mut f32) {
        let n = self.n;
        unsafe {
            let (c0, s0) = (vdupq_n_f32(self.tw_c[0]), vdupq_n_f32(self.tw_s[0]));
            let (ca, sa) = (vdupq_n_f32(self.tw_c[1]), vdupq_n_f32(self.tw_s[1]));
            let (cb, sb) = (vdupq_n_f32(self.tw_c[2]), vdupq_n_f32(self.tw_s[2]));
            let zero = vdupq_n_f32(0.0);
            let mut r0 = 0;
            while r0 < n / 4 {
                let x0 = vld1q_f32(frame.add(r0));
                let x1 = vld1q_f32(frame.add(r0 + n / 2));
                let x2 = vld1q_f32(frame.add(r0 + n / 4));
                let x3 = vld1q_f32(frame.add(r0 + 3 * n / 4));
                // Stage 1: pairs (+0, +1) and (+2, +3).
                let (y0r, y0i, y1r, y1i) = butterfly(x0, zero, x1, zero, c0, s0);
                let (y2r, y2i, y3r, y3i) = butterfly(x2, zero, x3, zero, c0, s0);
                // Stage 2: pairs (+0, +2) with k = 0 and (+1, +3) with k = 1.
                let (z0r, z0i, z2r, z2i) = butterfly(y0r, y0i, y2r, y2i, ca, sa);
                let (z1r, z1i, z3r, z3i) = butterfly(y1r, y1i, y3r, y3i, cb, sb);
                let offsets = &self.block_offset[r0..r0 + 4];
                store_blocks(re, offsets, transpose(z0r, z1r, z2r, z3r));
                store_blocks(im, offsets, transpose(z0i, z1i, z2i, z3i));
                r0 += 4;
            }
        }
    }

    /// Stages `h` and `2h` (`h >= 4`) on blocks of `4h`: quarter-blocks `A, B, C, D` take stage
    /// `h`'s butterflies `(A, B)` and `(C, D)`, then stage `2h`'s `(A, C)` at `k` and `(B, D)` at
    /// `h + k`, without leaving registers.
    unsafe fn stage_pair(&self, re: *mut f32, im: *mut f32, h: usize) {
        unsafe {
            let (tc1, ts1) = (self.tw_c.as_ptr().add(h - 1), self.tw_s.as_ptr().add(h - 1));
            let (tc2, ts2) = (
                self.tw_c.as_ptr().add(2 * h - 1),
                self.tw_s.as_ptr().add(2 * h - 1),
            );
            let mut b = 0;
            while b < self.n {
                let mut k = 0;
                while k < h {
                    let (pa, pb, pc, pd) = (b + k, b + h + k, b + 2 * h + k, b + 3 * h + k);
                    let (c1, s1) = (vld1q_f32(tc1.add(k)), vld1q_f32(ts1.add(k)));
                    let (ar, ai, br, bi) = butterfly(
                        vld1q_f32(re.add(pa)),
                        vld1q_f32(im.add(pa)),
                        vld1q_f32(re.add(pb)),
                        vld1q_f32(im.add(pb)),
                        c1,
                        s1,
                    );
                    let (cr, ci, dr, di) = butterfly(
                        vld1q_f32(re.add(pc)),
                        vld1q_f32(im.add(pc)),
                        vld1q_f32(re.add(pd)),
                        vld1q_f32(im.add(pd)),
                        c1,
                        s1,
                    );
                    let (ar, ai, cr, ci) =
                        butterfly(ar, ai, cr, ci, vld1q_f32(tc2.add(k)), vld1q_f32(ts2.add(k)));
                    let (br, bi, dr, di) = butterfly(
                        br,
                        bi,
                        dr,
                        di,
                        vld1q_f32(tc2.add(h + k)),
                        vld1q_f32(ts2.add(h + k)),
                    );
                    vst1q_f32(re.add(pa), ar);
                    vst1q_f32(im.add(pa), ai);
                    vst1q_f32(re.add(pb), br);
                    vst1q_f32(im.add(pb), bi);
                    vst1q_f32(re.add(pc), cr);
                    vst1q_f32(im.add(pc), ci);
                    vst1q_f32(re.add(pd), dr);
                    vst1q_f32(im.add(pd), di);
                    k += 4;
                }
                b += 4 * h;
            }
        }
    }

    /// One stage of half-size `h >= 4` (left over when the middle stages are odd in number).
    unsafe fn stage(&self, re: *mut f32, im: *mut f32, h: usize) {
        unsafe {
            let tc = self.tw_c.as_ptr().add(h - 1);
            let ts = self.tw_s.as_ptr().add(h - 1);
            let mut b = 0;
            while b < self.n {
                let mut k = 0;
                while k < h {
                    let e = b + k;
                    let o = e + h;
                    let (r0, i0, r1, i1) = butterfly(
                        vld1q_f32(re.add(e)),
                        vld1q_f32(im.add(e)),
                        vld1q_f32(re.add(o)),
                        vld1q_f32(im.add(o)),
                        vld1q_f32(tc.add(k)),
                        vld1q_f32(ts.add(k)),
                    );
                    vst1q_f32(re.add(e), r0);
                    vst1q_f32(im.add(e), i0);
                    vst1q_f32(re.add(o), r1);
                    vst1q_f32(im.add(o), i1);
                    k += 4;
                }
                b += 2 * h;
            }
        }
    }

    /// The final stage (`h = n/2`, one block): every first-half output, and the second-half
    /// output at `k = 0` (bin `n/2`); the other second-half bins are mirror images nobody reads.
    unsafe fn last_stage(&self, re: *mut f32, im: *mut f32) {
        let h = self.n / 2;
        unsafe {
            let tc = self.tw_c.as_ptr().add(h - 1);
            let ts = self.tw_s.as_ptr().add(h - 1);
            let (re_e0, im_e0, re_o0, im_o0) = (*re, *im, *re.add(h), *im.add(h));
            let mut k = 0;
            while k < h {
                let re_e = vld1q_f32(re.add(k));
                let im_e = vld1q_f32(im.add(k));
                let re_o = vld1q_f32(re.add(k + h));
                let im_o = vld1q_f32(im.add(k + h));
                let c = vld1q_f32(tc.add(k));
                let s = vld1q_f32(ts.add(k));
                vst1q_f32(re.add(k), vfmaq_f32(vfmaq_f32(re_e, c, re_o), s, im_o));
                vst1q_f32(im.add(k), vfmsq_f32(vfmaq_f32(im_e, c, im_o), s, re_o));
                k += 4;
            }
            let (c, s) = (*tc, *ts);
            *re.add(h) = (-s).mul_add(im_o0, (-c).mul_add(re_o0, re_e0));
            *im.add(h) = s.mul_add(re_o0, (-c).mul_add(im_o0, im_e0));
        }
    }
}

/// Four native butterflies: `E ± w·O` with `w = cos - i·sin`, each output two fused operations in
/// the native order (see `faithful::fft`).
#[inline(always)]
unsafe fn butterfly(
    re_e: float32x4_t,
    im_e: float32x4_t,
    re_o: float32x4_t,
    im_o: float32x4_t,
    c: float32x4_t,
    s: float32x4_t,
) -> (float32x4_t, float32x4_t, float32x4_t, float32x4_t) {
    unsafe {
        let r0 = vfmaq_f32(vfmaq_f32(re_e, c, re_o), s, im_o);
        let i0 = vfmsq_f32(vfmaq_f32(im_e, c, im_o), s, re_o);
        let r1 = vfmsq_f32(vfmsq_f32(re_e, c, re_o), s, im_o);
        let i1 = vfmaq_f32(vfmsq_f32(im_e, c, im_o), s, re_o);
        (r0, i0, r1, i1)
    }
}

/// `[a, b, c, d]` (lanes = blocks) to one vector per block: `out[l] = [a[l], b[l], c[l], d[l]]`.
#[inline(always)]
unsafe fn transpose(
    a: float32x4_t,
    b: float32x4_t,
    c: float32x4_t,
    d: float32x4_t,
) -> [float32x4_t; 4] {
    unsafe {
        let t0 = vreinterpretq_f64_f32(vtrn1q_f32(a, b));
        let t1 = vreinterpretq_f64_f32(vtrn2q_f32(a, b));
        let t2 = vreinterpretq_f64_f32(vtrn1q_f32(c, d));
        let t3 = vreinterpretq_f64_f32(vtrn2q_f32(c, d));
        [
            vreinterpretq_f32_f64(vtrn1q_f64(t0, t2)),
            vreinterpretq_f32_f64(vtrn1q_f64(t1, t3)),
            vreinterpretq_f32_f64(vtrn2q_f64(t0, t2)),
            vreinterpretq_f32_f64(vtrn2q_f64(t1, t3)),
        ]
    }
}

#[inline(always)]
unsafe fn store_blocks(base: *mut f32, offsets: &[u16], blocks: [float32x4_t; 4]) {
    unsafe {
        for (offset, block) in offsets.iter().zip(blocks) {
            vst1q_f32(base.add(*offset as usize), block);
        }
    }
}
