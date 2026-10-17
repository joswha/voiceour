//! Matrix-vector kernels for row-major weights `W[rows][k]` (ggml `ne = [k, rows]`).
//!
//! # The canonical dot product
//!
//! Every exact arm computes each output element `y[r] = Σ_k W[r][k]·x[k]` in one fixed order:
//! two `float32x4_t` accumulators walk the row in 8-element chunks, `a += W[8m..8m+4]·x[8m..8m+4]`
//! and `b += W[8m+4..8m+8]·x[8m+4..8m+8]` with fused multiply-adds, chunk after chunk; the result
//! is `vaddvq_f32(a + b)`. Kernels that compute several rows ([`dot_rows`]) or several columns
//! ([`dot_rows_cols`]) keep one accumulator pair per output element, so every element sees the
//! same operation sequence as the single-row kernel — the bit-identity the `precompute` GEMM and
//! the `spec` batch rely on. fp16 weights are widened exactly, so f16 and f32 storage of the same
//! weights give bit-identical results too.
//!
//! `k` must be a multiple of 8 (640 and 1024 are).
#![allow(unused_unsafe)]

use core::arch::aarch64::*;
use std::ops::Range;

use crate::simd::Weight;

/// `R` rows `w + r·ld`, one column `x`, length `k`.
///
/// # Safety
/// Every row and `x` must be valid for `k` elements; `k % 8 == 0`.
#[inline(always)]
pub unsafe fn dot_rows<T: Weight, const R: usize>(
    w: *const T,
    ld: usize,
    x: *const f32,
    k: usize,
) -> [f32; R] {
    unsafe {
        let mut a = [vdupq_n_f32(0.0); R];
        let mut b = [vdupq_n_f32(0.0); R];
        let mut i = 0;
        while i < k {
            let x0 = vld1q_f32(x.add(i));
            let x1 = vld1q_f32(x.add(i + 4));
            for r in 0..R {
                let (w0, w1) = T::load8(w.add(r * ld + i));
                a[r] = vfmaq_f32(a[r], w0, x0);
                b[r] = vfmaq_f32(b[r], w1, x1);
            }
            i += 8;
        }
        let mut out = [0.0f32; R];
        for r in 0..R {
            out[r] = vaddvq_f32(vaddq_f32(a[r], b[r]));
        }
        out
    }
}

/// `R` rows times `C` columns `xs[c]`, each element in the canonical order.
///
/// # Safety
/// As [`dot_rows`], for every column.
#[inline(always)]
pub unsafe fn dot_rows_cols<T: Weight, const R: usize, const C: usize>(
    w: *const T,
    ld: usize,
    xs: [*const f32; C],
    k: usize,
) -> [[f32; C]; R] {
    unsafe {
        let mut a = [[vdupq_n_f32(0.0); C]; R];
        let mut b = [[vdupq_n_f32(0.0); C]; R];
        let mut i = 0;
        while i < k {
            let mut wl = [(vdupq_n_f32(0.0), vdupq_n_f32(0.0)); R];
            for r in 0..R {
                wl[r] = T::load8(w.add(r * ld + i));
            }
            for c in 0..C {
                let x0 = vld1q_f32(xs[c].add(i));
                let x1 = vld1q_f32(xs[c].add(i + 4));
                for r in 0..R {
                    a[r][c] = vfmaq_f32(a[r][c], wl[r].0, x0);
                    b[r][c] = vfmaq_f32(b[r][c], wl[r].1, x1);
                }
            }
            i += 8;
        }
        let mut out = [[0.0f32; C]; R];
        for r in 0..R {
            for c in 0..C {
                out[r][c] = vaddvq_f32(vaddq_f32(a[r][c], b[r][c]));
            }
        }
        out
    }
}

/// `y[r - rows.start] = W[r]·x` for `r` in `rows` (no bias), four rows at a time.
///
/// # Safety
/// `w` holds at least `rows.end` rows of `k`; `x` has `k`; `y` has `rows.len()`.
#[inline]
pub unsafe fn matvec<T: Weight>(
    w: *const T,
    k: usize,
    x: *const f32,
    y: *mut f32,
    rows: Range<usize>,
) {
    unsafe {
        let mut r = rows.start;
        let mut o = y;
        while r + 4 <= rows.end {
            let v = dot_rows::<T, 4>(w.add(r * k), k, x, k);
            vst1q_f32(o, vld1q_f32(v.as_ptr()));
            r += 4;
            o = o.add(4);
        }
        while r < rows.end {
            *o = dot_rows::<T, 1>(w.add(r * k), k, x, k)[0];
            r += 1;
            o = o.add(1);
        }
    }
}

/// `y[c][r - rows.start] = W[r]·xs[c]` for `c < n_cols`, `r` in `rows`, every element in the
/// canonical order. `xs` and `ys` are column-major blocks with strides `x_stride` / `y_stride`.
/// Tiles of 2 rows × 4 columns, with exact-order tails.
///
/// # Safety
/// Bounds as [`matvec`], per column.
#[inline]
pub unsafe fn matmul_cols<T: Weight>(
    w: *const T,
    k: usize,
    xs: *const f32,
    x_stride: usize,
    n_cols: usize,
    ys: *mut f32,
    y_stride: usize,
    rows: Range<usize>,
) {
    unsafe {
        let mut c = 0;
        while c + 4 <= n_cols {
            let cols = [
                xs.add(c * x_stride),
                xs.add((c + 1) * x_stride),
                xs.add((c + 2) * x_stride),
                xs.add((c + 3) * x_stride),
            ];
            let mut r = rows.start;
            while r + 2 <= rows.end {
                let v = dot_rows_cols::<T, 2, 4>(w.add(r * k), k, cols, k);
                for (dr, row) in v.iter().enumerate() {
                    for (dc, &val) in row.iter().enumerate() {
                        *ys.add((c + dc) * y_stride + (r + dr - rows.start)) = val;
                    }
                }
                r += 2;
            }
            if r < rows.end {
                let v = dot_rows_cols::<T, 1, 4>(w.add(r * k), k, cols, k);
                for (dc, &val) in v[0].iter().enumerate() {
                    *ys.add((c + dc) * y_stride + (r - rows.start)) = val;
                }
            }
            c += 4;
        }
        while c < n_cols {
            let col = xs.add(c * x_stride);
            matvec(w, k, col, ys.add(c * y_stride), rows.clone());
            c += 1;
        }
    }
}

/// Splits `n` items into `parts` contiguous ranges whose boundaries are multiples of `align`
/// (except the last end), sizes as equal as that allows. Part `i`'s range.
pub fn split(n: usize, parts: usize, i: usize, align: usize) -> Range<usize> {
    let units = n.div_ceil(align);
    let base = units / parts;
    let extra = units % parts;
    let start = (i * base + i.min(extra)) * align;
    let end = ((i + 1) * base + (i + 1).min(extra)) * align;
    start.min(n)..end.min(n)
}

// ----- q8_0 (bet arm `q8`) ---------------------------------------------------------------------

/// Bytes per q8_0 block: fp16 scale + 32 × i8.
pub const Q8_BLOCK: usize = 34;

#[inline(always)]
unsafe fn sdot(acc: int32x4_t, a: int8x16_t, b: int8x16_t) -> int32x4_t {
    let mut acc = acc;
    // SAFETY: FEAT_DotProd is part of the aarch64-apple-darwin baseline (apple-m1); `vdotq_s32`
    // itself is still unstable in Rust 1.97, so the instruction is spelled out.
    unsafe {
        core::arch::asm!(
            "sdot {acc:v}.4s, {a:v}.16b, {b:v}.16b",
            acc = inout(vreg) acc,
            a = in(vreg) a,
            b = in(vreg) b,
            options(pure, nomem, nostack, preserves_flags)
        );
    }
    acc
}

/// The fp16 scale at `p` (unaligned, little-endian) widened exactly with `fcvtl`
/// (`GGML_CPU_FP16_TO_FP32` on arm64 is the same hardware conversion).
#[inline(always)]
fn f16_bits_at(p: *const u8) -> f32 {
    unsafe {
        let bits = u16::from_le_bytes([*p, *p.add(1)]);
        vgetq_lane_f32::<0>(vcvt_f32_f16(vreinterpret_f16_u16(vdup_n_u16(bits))))
    }
}

/// ggml's ARM `quantize_row_q8_0` (ggml-cpu/arch/arm/quants.c L41): per 32-block `amax`,
/// `d = amax / 127`, `id = d ? 1/d : 0`, scale stored as fp16 (RNE), `qs = vcvtnq(x·id)`.
pub fn quantize_act_q8_0(x: &[f32], out: &mut [u8]) {
    assert_eq!(x.len() % 32, 0);
    assert_eq!(out.len(), x.len() / 32 * Q8_BLOCK);
    for (blk, dst) in x.chunks_exact(32).zip(out.chunks_exact_mut(Q8_BLOCK)) {
        unsafe {
            let p = blk.as_ptr();
            let mut v = [vdupq_n_f32(0.0); 8];
            let mut amax = vdupq_n_f32(0.0);
            for j in 0..8 {
                v[j] = vld1q_f32(p.add(4 * j));
                amax = vmaxq_f32(amax, vabsq_f32(v[j]));
            }
            let amax = vmaxvq_f32(amax);
            let d = amax / 127.0;
            let id = if d != 0.0 { 1.0 / d } else { 0.0 };
            dst[..2].copy_from_slice(&parakeet_model::f32_to_f16(d).to_le_bytes());
            for j in 0..8 {
                let q = vcvtnq_s32_f32(vmulq_n_f32(v[j], id));
                for l in 0..4 {
                    let lane = match l {
                        0 => vgetq_lane_s32::<0>(q),
                        1 => vgetq_lane_s32::<1>(q),
                        2 => vgetq_lane_s32::<2>(q),
                        _ => vgetq_lane_s32::<3>(q),
                    };
                    dst[2 + 4 * j + l] = lane as i8 as u8;
                }
            }
        }
    }
}

/// `R` q8_0 rows (`w + r·row_bytes`) against one q8_0 activation, each row exactly ggml's NEON
/// `ggml_vec_dot_q8_0_q8_0` (no i8mm): even/odd blocks into two float accumulators with
/// `vmlaq_n_f32` (multiply, then add), then `vaddvq(sumv0) + vaddvq(sumv1)`. The rows share the
/// activation loads. `nb` (blocks) must be even.
///
/// # Safety
/// Every row and `xq` hold `nb` blocks.
#[inline(always)]
pub unsafe fn dot_q8_rows<const R: usize>(
    w: *const u8,
    row_bytes: usize,
    xq: *const u8,
    nb: usize,
) -> [f32; R] {
    unsafe {
        let mut s0 = [vdupq_n_f32(0.0); R];
        let mut s1 = [vdupq_n_f32(0.0); R];
        let z = vdupq_n_s32(0);
        let mut ib = 0;
        while ib + 1 < nb {
            let y0 = xq.add(ib * Q8_BLOCK);
            let y1 = y0.add(Q8_BLOCK);
            let (y0l, y0h) = (vld1q_s8(y0.add(2).cast()), vld1q_s8(y0.add(18).cast()));
            let (y1l, y1h) = (vld1q_s8(y1.add(2).cast()), vld1q_s8(y1.add(18).cast()));
            let (dy0, dy1) = (f16_bits_at(y0), f16_bits_at(y1));
            for r in 0..R {
                let x0 = w.add(r * row_bytes + ib * Q8_BLOCK);
                let x1 = x0.add(Q8_BLOCK);
                let p0 = vaddq_s32(
                    sdot(z, vld1q_s8(x0.add(2).cast()), y0l),
                    sdot(z, vld1q_s8(x0.add(18).cast()), y0h),
                );
                let p1 = vaddq_s32(
                    sdot(z, vld1q_s8(x1.add(2).cast()), y1l),
                    sdot(z, vld1q_s8(x1.add(18).cast()), y1h),
                );
                s0[r] = vmlaq_n_f32(s0[r], vcvtq_f32_s32(p0), f16_bits_at(x0) * dy0);
                s1[r] = vmlaq_n_f32(s1[r], vcvtq_f32_s32(p1), f16_bits_at(x1) * dy1);
            }
            ib += 2;
        }
        debug_assert_eq!(ib, nb, "dot_q8 needs an even block count");
        let mut out = [0.0f32; R];
        for r in 0..R {
            out[r] = vaddvq_f32(s0[r]) + vaddvq_f32(s1[r]);
        }
        out
    }
}

/// One q8_0 row against a q8_0 activation (see [`dot_q8_rows`]).
///
/// # Safety
/// `w` and `xq` hold `nb` blocks each.
#[inline(always)]
pub unsafe fn dot_q8(w: *const u8, xq: *const u8, nb: usize) -> f32 {
    unsafe { dot_q8_rows::<1>(w, 0, xq, nb)[0] }
}

/// `y[r - rows.start] = W[r]·xq` for q8_0 rows of `nb` blocks, four rows at a time.
///
/// # Safety
/// `w` holds `rows.end` rows; `xq` holds `nb` blocks; `y` has `rows.len()`.
#[inline]
pub unsafe fn matvec_q8(w: *const u8, nb: usize, xq: *const u8, y: *mut f32, rows: Range<usize>) {
    unsafe {
        let row_bytes = nb * Q8_BLOCK;
        let mut r = rows.start;
        let mut o = y;
        while r + 4 <= rows.end {
            let v = dot_q8_rows::<4>(w.add(r * row_bytes), row_bytes, xq, nb);
            vst1q_f32(o, vld1q_f32(v.as_ptr()));
            r += 4;
            o = o.add(4);
        }
        while r < rows.end {
            *o = dot_q8(w.add(r * row_bytes), xq, nb);
            r += 1;
            o = o.add(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lcg(seed: &mut u64) -> f32 {
        *seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((*seed >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
    }

    #[test]
    fn row_and_column_tiles_are_bit_identical_to_the_single_dot() {
        let (rows, k, cols) = (37usize, 96usize, 7usize);
        let mut seed = 7;
        let w16: Vec<u16> = (0..rows * k)
            .map(|_| parakeet_model::f32_to_f16(lcg(&mut seed)))
            .collect();
        let w32: Vec<f32> = w16.iter().map(|&h| parakeet_model::f16_to_f32(h)).collect();
        let xs: Vec<f32> = (0..cols * k).map(|_| lcg(&mut seed) * 3.0).collect();
        let reference = |r: usize, c: usize| unsafe {
            dot_rows::<f32, 1>(w32.as_ptr().add(r * k), k, xs.as_ptr().add(c * k), k)[0]
        };
        for c in 0..cols {
            let mut y16 = vec![0.0; rows];
            let mut y32 = vec![0.0; rows];
            unsafe {
                matvec(
                    w16.as_ptr(),
                    k,
                    xs.as_ptr().add(c * k),
                    y16.as_mut_ptr(),
                    0..rows,
                );
                matvec(
                    w32.as_ptr(),
                    k,
                    xs.as_ptr().add(c * k),
                    y32.as_mut_ptr(),
                    0..rows,
                );
            }
            for r in 0..rows {
                assert_eq!(y16[r].to_bits(), reference(r, c).to_bits());
                assert_eq!(y32[r].to_bits(), reference(r, c).to_bits());
            }
        }
        for sub in [3..rows, 0..1, 5..6, 1..rows - 1] {
            let mut ys = vec![0.0; cols * sub.len()];
            unsafe {
                matmul_cols(
                    w16.as_ptr(),
                    k,
                    xs.as_ptr(),
                    k,
                    cols,
                    ys.as_mut_ptr(),
                    sub.len(),
                    sub.clone(),
                )
            };
            for c in 0..cols {
                for r in sub.clone() {
                    assert_eq!(
                        ys[c * sub.len() + r - sub.start].to_bits(),
                        reference(r, c).to_bits(),
                        "r={r} c={c}"
                    );
                }
            }
        }
    }

    #[test]
    fn split_covers_everything_in_aligned_parts() {
        for n in [1usize, 7, 640, 8198] {
            for parts in 1..12 {
                let mut next = 0;
                for i in 0..parts {
                    let r = split(n, parts, i, 4);
                    assert_eq!(r.start, next.min(n));
                    assert!(r.start % 4 == 0 || r.start == n);
                    next = r.end;
                }
                assert_eq!(next, n);
            }
        }
    }

    #[test]
    fn q8_dot_matches_scalar_block_sum() {
        let k = 640;
        let mut seed = 11;
        let x: Vec<f32> = (0..k).map(|_| lcg(&mut seed)).collect();
        let w: Vec<f32> = (0..k).map(|_| lcg(&mut seed) * 0.1).collect();
        let mut wq = vec![0u8; k / 32 * Q8_BLOCK];
        parakeet_model::quantize_row_q8_0(&w, &mut wq);
        let mut xq = vec![0u8; k / 32 * Q8_BLOCK];
        quantize_act_q8_0(&x, &mut xq);
        let got = unsafe { dot_q8(wq.as_ptr(), xq.as_ptr(), k / 32) } as f64;
        let mut want = 0.0f64;
        for b in 0..k / 32 {
            let (wb, xb) = (&wq[b * Q8_BLOCK..], &xq[b * Q8_BLOCK..]);
            let s: i32 = (0..32)
                .map(|j| (wb[2 + j] as i8 as i32) * (xb[2 + j] as i8 as i32))
                .sum();
            want += s as f64 * f16_bits_at(wb.as_ptr()) as f64 * f16_bits_at(xb.as_ptr()) as f64;
        }
        assert!(
            (got - want).abs() < 1e-4 * want.abs().max(1.0),
            "{got} vs {want}"
        );
        // Rounding to the nearest q8 step moves each operand by at most half its block scale:
        // |Δ(w·x)| <= |x|·dw/2 + |w|·dx/2 + dw·dx/4 per element (scales stored as fp16, so the
        // bound uses the stored scales plus a 1e-3 relative allowance for the fp16 rounding).
        let exact: f64 = w.iter().zip(&x).map(|(a, b)| *a as f64 * *b as f64).sum();
        let mut bound = 0.0f64;
        for b in 0..k / 32 {
            let dw = f16_bits_at(wq[b * Q8_BLOCK..].as_ptr()) as f64 * 1.001;
            let dx = f16_bits_at(xq[b * Q8_BLOCK..].as_ptr()) as f64 * 1.001;
            for j in b * 32..(b + 1) * 32 {
                bound +=
                    (x[j] as f64).abs() * dw / 2.0 + (w[j] as f64).abs() * dx / 2.0 + dw * dx / 4.0;
            }
        }
        assert!(
            (got - exact).abs() <= bound,
            "q8 {got} vs f32 {exact}, bound {bound}"
        );
        // Four-row tiles give each row the single-row result bit for bit.
        let rows = 7;
        let ws: Vec<f32> = (0..rows * k).map(|_| lcg(&mut seed) * 0.1).collect();
        let mut wsq = vec![0u8; rows * k / 32 * Q8_BLOCK];
        parakeet_model::quantize_row_q8_0(&ws, &mut wsq);
        let mut y = vec![0.0f32; rows];
        unsafe { matvec_q8(wsq.as_ptr(), k / 32, xq.as_ptr(), y.as_mut_ptr(), 0..rows) };
        for (r, &v) in y.iter().enumerate() {
            let one =
                unsafe { dot_q8(wsq.as_ptr().add(r * k / 32 * Q8_BLOCK), xq.as_ptr(), k / 32) };
            assert_eq!(v.to_bits(), one.to_bits(), "row {r}");
        }
    }
}
