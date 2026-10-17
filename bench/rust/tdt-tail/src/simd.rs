//! NEON building blocks every arm shares: fp16 widening, the vectorised transcendental
//! functions (`exp4`, `log4`, `sigmoid4`, `tanh4`), the canonical log-softmax and the
//! native first-max argmax.
//!
//! Every function here is a fixed sequence of IEEE single-precision operations (no fast-math,
//! no implicit contraction), so its results are a pure function of its inputs. The C control
//! (`c/vt_c.c`) repeats each sequence with the same `arm_neon.h` intrinsics and the same
//! constants (bit patterns below), which is what makes `c-best` bit-identical to `best`.
//!
//! Accuracy against Apple's libm (`f32::exp`, `f32::ln`, `f32::tanh`) is pinned by unit tests:
//! see `tests` at the bottom of this file.
#![allow(unused_unsafe)]

use core::arch::aarch64::*;

/// Single-precision constants as bit patterns (shared verbatim with `c/vt_c.c`).
pub mod k {
    pub const LOG2E: u32 = 0x3fb8_aa3b; // log2(e)
    pub const LN2_HI: u32 = 0x3f31_8000; // 0.693359375 (Cody-Waite high part, 10 significant bits)
    pub const LN2_LO: u32 = 0xb95e_8083; // ln(2) - LN2_HI
    pub const EXP_LO: u32 = 0xc2d0_0000; // -104: exp underflows to +0 below
    pub const EXP_HI: u32 = 0x42b2_0000; // 89: exp overflows to +inf above
    pub const EXP_C2: u32 = 0x3f00_0000; // 1/2!
    pub const EXP_C3: u32 = 0x3e2a_aaab; // 1/3!
    pub const EXP_C4: u32 = 0x3d2a_aaab; // 1/4!
    pub const EXP_C5: u32 = 0x3c08_8889; // 1/5!
    pub const EXP_C6: u32 = 0x3ab6_0b61; // 1/6!
    pub const EXP_C7: u32 = 0x3950_0d01; // 1/7!
    pub const LOG_C3: u32 = 0x3eaa_aaab; // 1/3
    pub const LOG_C5: u32 = 0x3e4c_cccd; // 1/5
    pub const LOG_C7: u32 = 0x3e12_4925; // 1/7
    pub const LOG_C9: u32 = 0x3de3_8e39; // 1/9
    pub const LOG_C11: u32 = 0x3dba_2e8c; // 1/11
    pub const SQRT2: u32 = 0x3fb5_04f3; // sqrt(2)
    pub const TANH_P0: u32 = 0xbbba_f0ea; // Cephes tanhf, |x| < 0.625
    pub const TANH_P1: u32 = 0x3ca9_134e;
    pub const TANH_P2: u32 = 0xbd5c_1e2d;
    pub const TANH_P3: u32 = 0x3e08_8393;
    pub const TANH_P4: u32 = 0xbeaa_aa99;
    pub const TANH_SMALL: u32 = 0x3f20_0000; // 0.625
}

#[inline(always)]
fn splat(bits: u32) -> float32x4_t {
    unsafe { vdupq_n_f32(f32::from_bits(bits)) }
}

/// Eight consecutive weights widened to f32: elements `[0, 4)` and `[4, 8)`.
pub trait Weight: Copy + Send + Sync + 'static {
    /// # Safety
    /// `p` must be valid for reading 8 elements.
    unsafe fn load8(p: *const Self) -> (float32x4_t, float32x4_t);
}

impl Weight for f32 {
    #[inline(always)]
    unsafe fn load8(p: *const f32) -> (float32x4_t, float32x4_t) {
        unsafe { (vld1q_f32(p), vld1q_f32(p.add(4))) }
    }
}

/// fp16 bit patterns, widened exactly (`fcvtl`/`fcvtl2`).
impl Weight for u16 {
    #[inline(always)]
    unsafe fn load8(p: *const u16) -> (float32x4_t, float32x4_t) {
        unsafe {
            let h = vreinterpretq_f16_u16(vld1q_u16(p));
            (vcvt_f32_f16(vget_low_f16(h)), vcvt_high_f32_f16(h))
        }
    }
}

/// `e^x` per lane. `x` is clamped to [-104, 89] (beyond both ends the result is already +0 or
/// +inf in f32); `x = n·ln2 + r`, `|r| <= ~ln2/2`, degree-7 Taylor polynomial for `e^r`, then
/// `2^n` applied as two exact power-of-two factors so subnormal results round once.
#[inline(always)]
pub fn exp4(x: float32x4_t) -> float32x4_t {
    unsafe {
        let x = vminq_f32(vmaxq_f32(x, splat(k::EXP_LO)), splat(k::EXP_HI));
        let n = vrndnq_f32(vmulq_f32(x, splat(k::LOG2E)));
        let r = vfmsq_f32(x, n, splat(k::LN2_HI));
        let r = vfmsq_f32(r, n, splat(k::LN2_LO));
        let mut p = vfmaq_f32(splat(k::EXP_C6), r, splat(k::EXP_C7));
        p = vfmaq_f32(splat(k::EXP_C5), r, p);
        p = vfmaq_f32(splat(k::EXP_C4), r, p);
        p = vfmaq_f32(splat(k::EXP_C3), r, p);
        p = vfmaq_f32(splat(k::EXP_C2), r, p);
        p = vfmaq_f32(vdupq_n_f32(1.0), r, p);
        p = vfmaq_f32(vdupq_n_f32(1.0), r, p);
        let ni = vcvtq_s32_f32(n);
        let n1 = vshrq_n_s32::<1>(ni);
        let n2 = vsubq_s32(ni, n1);
        let bias = vdupq_n_s32(127);
        let s1 = vreinterpretq_f32_s32(vshlq_n_s32::<23>(vaddq_s32(n1, bias)));
        let s2 = vreinterpretq_f32_s32(vshlq_n_s32::<23>(vaddq_s32(n2, bias)));
        vmulq_f32(vmulq_f32(p, s1), s2)
    }
}

/// Natural log per lane for `x >= 0` (`log(0) = -inf`, `log(+inf) = +inf`, negative or NaN
/// gives NaN). `x = m·2^e`, `m` in (sqrt(1/2), sqrt(2)], `log(m) = 2·atanh(s)` with
/// `s = (m-1)/(m+1)`, odd series to `s^11`.
#[inline(always)]
pub fn log4(x: float32x4_t) -> float32x4_t {
    unsafe {
        let tiny = vcltq_f32(x, vdupq_n_f32(f32::MIN_POSITIVE));
        let xs = vbslq_f32(tiny, vmulq_f32(x, vdupq_n_f32(8_388_608.0)), x);
        let eadj = vandq_s32(vreinterpretq_s32_u32(tiny), vdupq_n_s32(-23));
        let bits = vreinterpretq_s32_f32(xs);
        let e = vaddq_s32(vsubq_s32(vshrq_n_s32::<23>(bits), vdupq_n_s32(127)), eadj);
        let m = vreinterpretq_f32_s32(vorrq_s32(
            vandq_s32(bits, vdupq_n_s32(0x007f_ffff)),
            vdupq_n_s32(0x3f80_0000),
        ));
        let big = vcgtq_f32(m, splat(k::SQRT2));
        let m = vbslq_f32(big, vmulq_f32(m, vdupq_n_f32(0.5)), m);
        let e = vsubq_s32(e, vreinterpretq_s32_u32(big));
        let f = vsubq_f32(m, vdupq_n_f32(1.0));
        let s = vdivq_f32(f, vaddq_f32(f, vdupq_n_f32(2.0)));
        let z = vmulq_f32(s, s);
        let mut r = vfmaq_f32(splat(k::LOG_C9), z, splat(k::LOG_C11));
        r = vfmaq_f32(splat(k::LOG_C7), z, r);
        r = vfmaq_f32(splat(k::LOG_C5), z, r);
        r = vfmaq_f32(splat(k::LOG_C3), z, r);
        r = vmulq_f32(z, r);
        let t = vaddq_f32(s, s);
        let l1p = vfmaq_f32(t, t, r);
        let ef = vcvtq_f32_s32(e);
        let mut res = vfmaq_f32(vfmaq_f32(l1p, ef, splat(k::LN2_LO)), ef, splat(k::LN2_HI));
        res = vbslq_f32(vceqzq_f32(x), vdupq_n_f32(f32::NEG_INFINITY), res);
        res = vbslq_f32(vceqq_f32(x, vdupq_n_f32(f32::INFINITY)), x, res);
        // !(x >= 0): negative or NaN.
        res = vbslq_f32(vmvnq_u32(vcgezq_f32(x)), vdupq_n_f32(f32::NAN), res);
        res
    }
}

/// `1 / (1 + e^-x)` per lane (ggml's `sigmoid`).
#[inline(always)]
pub fn sigmoid4(x: float32x4_t) -> float32x4_t {
    unsafe {
        let one = vdupq_n_f32(1.0);
        vdivq_f32(one, vaddq_f32(one, exp4(vnegq_f32(x))))
    }
}

/// `tanh` per lane: Cephes `tanhf` (odd polynomial below 0.625, `1 - 2/(e^{2|x|} + 1)` above).
#[inline(always)]
pub fn tanh4(x: float32x4_t) -> float32x4_t {
    unsafe {
        let ax = vabsq_f32(x);
        let s = vmulq_f32(x, x);
        let mut p = vfmaq_f32(splat(k::TANH_P1), splat(k::TANH_P0), s);
        p = vfmaq_f32(splat(k::TANH_P2), p, s);
        p = vfmaq_f32(splat(k::TANH_P3), p, s);
        p = vfmaq_f32(splat(k::TANH_P4), p, s);
        let small = vfmaq_f32(x, vmulq_f32(p, s), x);
        let e = exp4(vaddq_f32(ax, ax));
        let one = vdupq_n_f32(1.0);
        let big = vsubq_f32(one, vdivq_f32(vdupq_n_f32(2.0), vaddq_f32(e, one)));
        let sign = vandq_u32(vreinterpretq_u32_f32(x), vdupq_n_u32(0x8000_0000));
        let big = vreinterpretq_f32_u32(vorrq_u32(vreinterpretq_u32_f32(big), sign));
        vbslq_f32(vcltq_f32(ax, splat(k::TANH_SMALL)), small, big)
    }
}

/// Scalar `exp4` (lane 0 of a broadcast): bit-identical to the vector lanes.
#[inline]
pub fn exp1(x: f32) -> f32 {
    unsafe { vgetq_lane_f32::<0>(exp4(vdupq_n_f32(x))) }
}

/// Applies a lane-wise vector function to `x` in place; the final partial vector goes through a
/// zero-padded temporary, so every element sees exactly the same operation sequence.
#[inline(always)]
fn map_in_place(x: &mut [f32], f: impl Fn(float32x4_t) -> float32x4_t) {
    let n = x.len();
    let full = n / 4 * 4;
    let p = x.as_mut_ptr();
    unsafe {
        let mut i = 0;
        while i < full {
            vst1q_f32(p.add(i), f(vld1q_f32(p.add(i))));
            i += 4;
        }
        if full < n {
            let mut tmp = [0.0f32; 4];
            tmp[..n - full].copy_from_slice(&x[full..]);
            let v = f(vld1q_f32(tmp.as_ptr()));
            vst1q_f32(tmp.as_mut_ptr(), v);
            x[full..].copy_from_slice(&tmp[..n - full]);
        }
    }
}

/// `x[i] = sigmoid(x[i])`.
pub fn sigmoid_in_place(x: &mut [f32]) {
    map_in_place(x, sigmoid4);
}

/// `x[i] = tanh(x[i])`.
pub fn tanh_in_place(x: &mut [f32]) {
    map_in_place(x, tanh4);
}

/// The canonical reduction order every arm uses for a sum over `n` values `v(i)`: two vector
/// accumulators over 8-element chunks (`a` takes elements `8m..8m+4`, `b` takes `8m+4..8m+8`),
/// `vaddvq(a + b)`, then the remaining `n % 8` values added left to right. `load` yields 8
/// values of chunk `m` as two vectors.
#[inline(always)]
fn sum_canonical(
    n: usize,
    load: impl Fn(usize) -> (float32x4_t, float32x4_t),
    tail: impl Fn(usize) -> f32,
) -> f32 {
    unsafe {
        let mut a = vdupq_n_f32(0.0);
        let mut b = vdupq_n_f32(0.0);
        let chunks = n / 8;
        for m in 0..chunks {
            let (x0, x1) = load(m);
            a = vaddq_f32(a, x0);
            b = vaddq_f32(b, x1);
        }
        let mut s = vaddvq_f32(vaddq_f32(a, b));
        for i in chunks * 8..n {
            s += tail(i);
        }
        s
    }
}

/// Maximum over `x` (vector max tree; NaN propagates).
#[inline]
pub fn max_of(x: &[f32]) -> f32 {
    let n = x.len();
    let p = x.as_ptr();
    unsafe {
        let mut m0 = vdupq_n_f32(f32::NEG_INFINITY);
        let mut m1 = vdupq_n_f32(f32::NEG_INFINITY);
        let mut i = 0;
        while i + 8 <= n {
            m0 = vmaxq_f32(m0, vld1q_f32(p.add(i)));
            m1 = vmaxq_f32(m1, vld1q_f32(p.add(i + 4)));
            i += 8;
        }
        let mut m = vmaxvq_f32(vmaxq_f32(m0, m1));
        while i < n {
            let v = *p.add(i);
            m = if v.is_nan() || m.is_nan() {
                f32::NAN
            } else {
                m.max(v)
            };
            i += 1;
        }
        m
    }
}

/// Index of the first element equal to `m` (caller guarantees one exists).
#[inline]
pub fn first_index_of(x: &[f32], m: f32) -> usize {
    let n = x.len();
    let p = x.as_ptr();
    unsafe {
        let mv = vdupq_n_f32(m);
        let mut i = 0;
        while i + 16 <= n {
            let e0 = vceqq_f32(vld1q_f32(p.add(i)), mv);
            let e1 = vceqq_f32(vld1q_f32(p.add(i + 4)), mv);
            let e2 = vceqq_f32(vld1q_f32(p.add(i + 8)), mv);
            let e3 = vceqq_f32(vld1q_f32(p.add(i + 12)), mv);
            let any = vorrq_u32(vorrq_u32(e0, e1), vorrq_u32(e2, e3));
            if vmaxvq_u32(any) != 0 {
                break;
            }
            i += 16;
        }
        while i < n {
            if *p.add(i) == m {
                return i;
            }
            i += 1;
        }
    }
    unreachable!("first_index_of: {m} not present")
}

/// The native token argmax (`parakeet_decode`, parakeet.cpp L4829-L4836): `best = 0`,
/// `max = -1e10`, strict `>` scan, i.e. the first maximum. Returns `(index, value)`.
#[inline]
pub fn argmax_native(x: &[f32]) -> (usize, f32) {
    let m = max_of(x);
    if m.is_nan() {
        return argmax_native_scalar(x);
    }
    if m > -1e10 {
        (first_index_of(x, m), m)
    } else {
        (0, -1e10)
    }
}

/// Literal scalar transcription of the native loop (reference for tests, NaN fallback).
pub fn argmax_native_scalar(x: &[f32]) -> (usize, f32) {
    let mut best = 0;
    let mut max = -1e10f32;
    for (i, &v) in x.iter().enumerate() {
        if v > max {
            max = v;
            best = i;
        }
    }
    (best, max)
}

/// First maximum of `x` without the native `-1e10` floor: `(index, value)`; NaN-free input.
/// Used for per-thread partial argmax; [`combine_partials`] restores the native semantics.
#[inline]
pub fn first_max(x: &[f32]) -> (usize, f32) {
    let m = max_of(x);
    if m.is_nan() {
        return (usize::MAX, f32::NAN);
    }
    (first_index_of(x, m), m)
}

/// Combines per-range `(global index, value)` first-maxima listed in range order into the
/// native argmax over the concatenation. Returns `None` when a range saw a NaN (the caller then
/// rescans with [`argmax_native_scalar`]).
#[inline]
pub fn combine_partials(parts: impl Iterator<Item = (usize, f32)>) -> Option<(usize, f32)> {
    let mut best = 0;
    let mut max = -1e10f32;
    for (i, v) in parts {
        if v.is_nan() {
            return None;
        }
        if v > max {
            max = v;
            best = i;
        }
    }
    Some((best, max))
}

/// The native duration argmax over raw duration logits (L4842-L4854): first maximum, starting
/// from slot 0.
#[inline]
pub fn argmax_duration(d: &[f32]) -> usize {
    let mut best = 0;
    let mut v = d[0];
    for (i, &x) in d.iter().enumerate().skip(1) {
        if x > v {
            v = x;
            best = i;
        }
    }
    best
}

/// Gap between the largest and second-largest value (by position, so equal maxima give 0).
pub fn top2_margin(x: &[f32]) -> f32 {
    let mut a = f32::NEG_INFINITY;
    let mut b = f32::NEG_INFINITY;
    for &v in x {
        if v > a {
            b = a;
            a = v;
        } else if v > b {
            b = v;
        }
    }
    a - b
}

/// Canonical log-softmax over the full logits row (`ggml_soft_max` then `ggml_log`,
/// parakeet.cpp L4518-L4519): `m = max(x)`, `e_i = exp(x_i - m)`, `S = Σ e_i` in the canonical
/// order, `lp_i = log(e_i / S)`. `lp` receives all `x.len()` log-probabilities.
pub fn log_softmax(x: &[f32], lp: &mut [f32]) {
    let n = x.len();
    assert_eq!(lp.len(), n);
    let m = max_of(x);
    let mv = unsafe { vdupq_n_f32(m) };
    lp.copy_from_slice(x);
    map_in_place(lp, |v| exp4(unsafe { vsubq_f32(v, mv) }));
    let e = lp.as_ptr();
    let s = sum_canonical(
        n,
        |c| unsafe { (vld1q_f32(e.add(8 * c)), vld1q_f32(e.add(8 * c + 4))) },
        |i| unsafe { *e.add(i) },
    );
    let sv = unsafe { vdupq_n_f32(s) };
    map_in_place(lp, |v| log4(unsafe { vdivq_f32(v, sv) }));
}

/// The token probability `create_token_data` reports (parakeet.cpp L4741-L4745):
/// `exp(lp[best]) / Σ_{i < n_tok} exp(lp[i])`, the sum in the canonical order.
pub fn token_p(lp: &[f32], n_tok: usize, best: usize) -> f32 {
    let p = lp.as_ptr();
    let t = sum_canonical(
        n_tok,
        |c| unsafe {
            (
                exp4(vld1q_f32(p.add(8 * c))),
                exp4(vld1q_f32(p.add(8 * c + 4))),
            )
        },
        |i| exp1(lp[i]),
    );
    exp1(lp[best]) / t
}

/// `(p, plog)` of the token at `best` from one raw logits row: [`log_softmax`] into `scratch`,
/// then [`token_p`]. Bit-identical to what the naive arm derives from its per-step log-softmax.
pub fn token_p_plog(logits: &[f32], n_tok: usize, best: usize, scratch: &mut [f32]) -> (f32, f32) {
    log_softmax(logits, scratch);
    (token_p(scratch, n_tok, best), scratch[best])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ulp_diff(a: f32, b: f32) -> u32 {
        if a == b || (a.is_nan() && b.is_nan()) {
            return 0;
        }
        if a.is_nan() || b.is_nan() || a.is_sign_negative() != b.is_sign_negative() {
            return u32::MAX;
        }
        let (x, y) = (a.to_bits(), b.to_bits());
        x.abs_diff(y)
    }

    fn v1(f: fn(float32x4_t) -> float32x4_t, x: f32) -> f32 {
        unsafe { vgetq_lane_f32::<0>(f(vdupq_n_f32(x))) }
    }

    /// Every `step`-th f32 bit pattern in `[lo, hi]` (by value).
    fn sweep(lo: f32, hi: f32, n: usize) -> impl Iterator<Item = f32> {
        (0..=n).map(move |i| lo + (hi - lo) * (i as f32 / n as f32))
    }

    #[test]
    fn exp_matches_libm_within_two_ulp() {
        let mut worst = 0;
        for x in sweep(-87.0, 88.7, 2_000_000) {
            worst = worst.max(ulp_diff(v1(exp4, x), x.exp()));
        }
        assert!(worst <= 2, "exp4 worst {worst} ulp");
        // Subnormal results stay close in absolute terms and never flush to zero early.
        for x in sweep(-103.0, -87.5, 100_000) {
            let (a, b) = (v1(exp4, x), x.exp());
            assert!(
                (a - b).abs() <= 2.0 * f32::from_bits(1),
                "exp4({x}) = {a:e}, libm {b:e}"
            );
            assert!(a > 0.0, "exp4({x}) flushed to zero");
        }
        assert_eq!(v1(exp4, 0.0), 1.0);
        assert_eq!(v1(exp4, -200.0), 0.0);
        assert_eq!(v1(exp4, f32::NEG_INFINITY), 0.0);
        assert_eq!(v1(exp4, 200.0), f32::INFINITY);
        assert!(v1(exp4, 89.0).is_infinite());
        assert!(v1(exp4, f32::NAN).is_nan());
    }

    #[test]
    fn log_matches_libm_within_two_ulp() {
        let mut worst = 0;
        // Normal range, dense near 1 and across many binades.
        for x in sweep(0.25, 4.0, 1_000_000)
            .chain((0..200_000).map(|i| f32::from_bits(0x0080_0000 + i * 10_597)))
        {
            worst = worst.max(ulp_diff(v1(log4, x), x.ln()));
        }
        assert!(worst <= 2, "log4 worst {worst} ulp");
        for i in 1..100_000u32 {
            let x = f32::from_bits(i * 83); // subnormals
            assert!(ulp_diff(v1(log4, x), x.ln()) <= 2, "log4 subnormal {x:e}");
        }
        assert_eq!(v1(log4, 1.0), 0.0);
        assert_eq!(v1(log4, 0.0), f32::NEG_INFINITY);
        assert_eq!(v1(log4, f32::INFINITY), f32::INFINITY);
        assert!(v1(log4, -1.0).is_nan());
        assert!(v1(log4, f32::NAN).is_nan());
    }

    #[test]
    fn tanh_and_sigmoid_track_libm() {
        let mut worst_tanh = 0;
        let mut worst_sig = 0.0f64;
        for x in sweep(-12.0, 12.0, 2_000_000) {
            worst_tanh = worst_tanh.max(ulp_diff(v1(tanh4, x), x.tanh()));
            let reference = 1.0 / (1.0 + (-(x as f64)).exp());
            worst_sig = worst_sig.max((v1(sigmoid4, x) as f64 - reference).abs());
        }
        assert!(worst_tanh <= 4, "tanh4 worst {worst_tanh} ulp");
        assert!(worst_sig < 2e-7, "sigmoid4 worst abs {worst_sig:e}");
        assert_eq!(v1(tanh4, 0.0), 0.0);
        assert_eq!(v1(tanh4, 50.0), 1.0);
        assert_eq!(v1(tanh4, -50.0), -1.0);
        assert_eq!(v1(sigmoid4, -200.0), 0.0);
        assert_eq!(v1(sigmoid4, 200.0), 1.0);
    }

    #[test]
    fn argmax_takes_the_first_maximum() {
        // Ties inside a vector, across vectors, across the 16-wide scan blocks, and in the tail.
        for n in [1usize, 3, 8, 15, 16, 17, 33, 8193] {
            for first in 0..n.min(40) {
                for second in first..n.min(45) {
                    let mut x = vec![0.5f32; n];
                    x[first] = 2.0;
                    x[second] = 2.0;
                    assert_eq!(
                        argmax_native(&x),
                        (first, 2.0),
                        "n={n} first={first} second={second}"
                    );
                    assert_eq!(argmax_native(&x), argmax_native_scalar(&x));
                }
            }
        }
        // Signed zeros: the first of -0 / +0 wins, as with the scalar strict `>`.
        let x = [-1.0f32, -0.0, 0.0, -0.0];
        assert_eq!(argmax_native(&x).0, 1);
        assert_eq!(argmax_native_scalar(&x).0, 1);
        // Everything at or below the native floor keeps index 0.
        let x = [-2e10f32, -3e10, -1e10];
        assert_eq!(argmax_native(&x), (0, -1e10));
        assert_eq!(argmax_native_scalar(&x), (0, -1e10));
        // A NaN never wins.
        let x = [1.0f32, f32::NAN, 3.0, 3.0];
        assert_eq!(argmax_native(&x), (2, 3.0));
        // Partial maxima combine to the same first maximum.
        let x: Vec<f32> = (0..100).map(|i| ((i * 37) % 11) as f32).collect();
        for parts in [1usize, 2, 3, 7, 10] {
            let chunk = x.len().div_ceil(parts);
            let combined = combine_partials(x.chunks(chunk).enumerate().map(|(c, s)| {
                let (i, v) = first_max(s);
                (c * chunk + i, v)
            }));
            assert_eq!(combined, Some(argmax_native_scalar(&x)), "parts={parts}");
        }
        // Durations: first maximum from slot 0.
        assert_eq!(argmax_duration(&[1.0, 3.0, 3.0, 2.0, 3.0]), 1);
        assert_eq!(argmax_duration(&[4.0, 3.0, 4.0, 2.0, 1.0]), 0);
    }

    #[test]
    fn log_softmax_is_normalised_and_token_p_matches_definition() {
        let x: Vec<f32> = (0..8198)
            .map(|i| ((i * 7919) % 1000) as f32 * 0.037 - 20.0)
            .collect();
        let mut lp = vec![0.0; x.len()];
        log_softmax(&x, &mut lp);
        let total: f64 = lp.iter().map(|&v| (v as f64).exp()).sum();
        assert!((total - 1.0).abs() < 1e-5, "sum of probabilities {total}");
        let (best, _) = argmax_native(&x[..8193]);
        let (p, plog) = token_p_plog(&x, 8193, best, &mut lp.clone());
        assert_eq!(plog, lp[best]);
        let reference: f64 =
            (lp[best] as f64).exp() / lp[..8193].iter().map(|&v| (v as f64).exp()).sum::<f64>();
        assert!((p as f64 - reference).abs() < 1e-6, "p {p} vs {reference}");
    }
}
