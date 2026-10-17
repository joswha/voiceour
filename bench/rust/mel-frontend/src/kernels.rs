//! Per-frame mel sums shared by the arms, and the output row handle the threads write through.

use parakeet_model::LOG_GUARD;

use crate::frontend::Frontend;

/// Frame-major `[n_rows][width]` output written row-by-row from several threads.
#[derive(Clone, Copy)]
pub(crate) struct Rows {
    ptr: *mut f32,
    n_rows: usize,
    width: usize,
}

// SAFETY: `Rows` only hands out rows through `row`, whose callers guarantee that every row is
// owned by one thread at a time; the buffer outlives every call that uses the handle.
unsafe impl Send for Rows {}
unsafe impl Sync for Rows {}

impl Rows {
    pub(crate) fn new(out: &mut [f32], n_rows: usize, width: usize) -> Rows {
        assert!(
            out.len() >= n_rows * width,
            "output holds {} values, need {n_rows} x {width}",
            out.len()
        );
        Rows {
            ptr: out.as_mut_ptr(),
            n_rows,
            width,
        }
    }

    /// # Safety
    /// No other live reference may cover row `i` while the returned slice is used.
    #[allow(clippy::mut_from_ref)]
    pub(crate) unsafe fn row(&self, i: usize) -> &mut [f32] {
        assert!(i < self.n_rows);
        // SAFETY: in bounds by the assert and the constructor; exclusivity is the caller's.
        unsafe { std::slice::from_raw_parts_mut(self.ptr.add(i * self.width), self.width) }
    }

    pub(crate) fn ptr(&self) -> *mut f32 {
        self.ptr
    }

    pub(crate) fn width(&self) -> usize {
        self.width
    }
}

/// The native dense mel sum (L5075–L5092) of one frame's `power[..n_fb]` into `row[..n_mels]`.
pub(crate) fn mel_dense(fe: &Frontend, power: &[f32], row: &mut [f32]) {
    let n_fb = fe.n_fb;
    for (j, out) in row[..fe.n_mels].iter_mut().enumerate() {
        let filter = &fe.filters[j * n_fb..(j + 1) * n_fb];
        let mut sum = 0.0f64;
        let mut k = 0usize;
        while (k as isize) < n_fb as isize - 3 {
            let group = power[k + 3].mul_add(
                filter[k + 3],
                power[k + 2].mul_add(
                    filter[k + 2],
                    power[k].mul_add(filter[k], power[k + 1] * filter[k + 1]),
                ),
            );
            sum += group as f64;
            k += 4;
        }
        while k < n_fb {
            sum += (power[k] * filter[k]) as f64;
            k += 1;
        }
        *out = (sum + LOG_GUARD).ln() as f32;
    }
}

/// The same sum over the filterbank's non-zero groups only (see `SparseFilters`), in the dense
/// loop's order and grouping.
#[inline]
pub(crate) fn mel_sparse(fe: &Frontend, power: &[f32], row: &mut [f32]) {
    let sparse = &fe.sparse;
    let power = &power[..fe.n_fb];
    for (j, out) in row[..fe.n_mels].iter_mut().enumerate() {
        let (first, end) = sparse.group_range[j];
        let mut sum = 0.0f64;
        for g in first as usize..end as usize {
            let k = sparse.group_k[g] as usize;
            let w = sparse.group_w[g];
            let p = &power[k..k + 4];
            let group = p[3].mul_add(w[3], p[2].mul_add(w[2], p[0].mul_add(w[0], p[1] * w[1])));
            sum += group as f64;
        }
        let (first, end) = sparse.tail_range[j];
        for t in first as usize..end as usize {
            sum += (power[sparse.tail_k[t] as usize] * sparse.tail_w[t]) as f64;
        }
        *out = (sum + LOG_GUARD).ln() as f32;
    }
}

/// `mel_sparse` when every power value is finite, else the dense loop (whose `inf * 0` and NaN
/// products a skipped group would have hidden).
#[inline]
pub(crate) fn mel_sparse_guarded(fe: &Frontend, power: &[f32], row: &mut [f32]) {
    if all_finite(&power[..fe.n_fb]) {
        mel_sparse(fe, power, row);
    } else {
        mel_dense(fe, power, row);
    }
}

/// `mel_sparse` with the group sums evaluated four groups per NEON instruction: lane `l` of
/// batch `b` computes group `4b + l` with the same `fmadd(f3,w3, fmadd(f2,w2, fmadd(f0,w0, f1*w1)))`
/// (one rounding per lane, as scalar), into `groups`; each mel bin then widens and adds its groups
/// in order. `power` must hold `n_fb` values rounded up to a multiple of 4 (each lane loads four
/// bins), and `groups` four values per batch.
#[inline]
pub(crate) fn mel_sparse_batched(
    fe: &Frontend,
    power: &[f32],
    groups: &mut [f32],
    row: &mut [f32],
) {
    use std::arch::aarch64::*;

    let sparse = &fe.sparse;
    assert!(power.len() >= fe.n_fb.next_multiple_of(4) && groups.len() >= 4 * sparse.batch_k.len());
    // SAFETY: every `k` is a group start `<= n_fb - 4` (or 0 for padding), so each 4-float load
    // stays inside `power`; each batch stores four floats inside `groups` (both asserted).
    unsafe {
        let p = power.as_ptr();
        for (b, (k, w)) in sparse.batch_k.iter().zip(&sparse.batch_w).enumerate() {
            let q0 = vld1q_f32(p.add(k[0] as usize));
            let q1 = vld1q_f32(p.add(k[1] as usize));
            let q2 = vld1q_f32(p.add(k[2] as usize));
            let q3 = vld1q_f32(p.add(k[3] as usize));
            // 4x4 transpose: `f_c[l] = q_l[c]`.
            let t0 = vreinterpretq_f64_f32(vtrn1q_f32(q0, q1));
            let t1 = vreinterpretq_f64_f32(vtrn2q_f32(q0, q1));
            let t2 = vreinterpretq_f64_f32(vtrn1q_f32(q2, q3));
            let t3 = vreinterpretq_f64_f32(vtrn2q_f32(q2, q3));
            let f0 = vreinterpretq_f32_f64(vtrn1q_f64(t0, t2));
            let f1 = vreinterpretq_f32_f64(vtrn1q_f64(t1, t3));
            let f2 = vreinterpretq_f32_f64(vtrn2q_f64(t0, t2));
            let f3 = vreinterpretq_f32_f64(vtrn2q_f64(t1, t3));
            let (w0, w1, w2, w3) = (
                vld1q_f32(w[0].as_ptr()),
                vld1q_f32(w[1].as_ptr()),
                vld1q_f32(w[2].as_ptr()),
                vld1q_f32(w[3].as_ptr()),
            );
            let group = vfmaq_f32(
                vfmaq_f32(vfmaq_f32(vmulq_f32(f1, w1), f0, w0), f2, w2),
                f3,
                w3,
            );
            vst1q_f32(groups.as_mut_ptr().add(4 * b), group);
        }
    }
    for (j, out) in row[..fe.n_mels].iter_mut().enumerate() {
        let (first, end) = sparse.group_range[j];
        let mut sum = 0.0f64;
        for &group in &groups[first as usize..end as usize] {
            sum += group as f64;
        }
        let (first, end) = sparse.tail_range[j];
        for t in first as usize..end as usize {
            sum += (power[sparse.tail_k[t] as usize] * sparse.tail_w[t]) as f64;
        }
        *out = (sum + LOG_GUARD).ln() as f32;
    }
}

/// `mel_sparse_batched` when every power value is finite, else the dense loop.
#[inline]
pub(crate) fn mel_sparse_batched_guarded(
    fe: &Frontend,
    power: &[f32],
    groups: &mut [f32],
    row: &mut [f32],
) {
    if all_finite(&power[..fe.n_fb]) {
        mel_sparse_batched(fe, power, groups, row);
    } else {
        mel_dense(fe, power, row);
    }
}

/// True when no value is ±inf or NaN.
#[inline]
pub(crate) fn all_finite(values: &[f32]) -> bool {
    // An integer max over the exponent fields: an associative reduction LLVM vectorizes.
    let mut exponent_max = 0u32;
    for &v in values {
        exponent_max = exponent_max.max(v.to_bits() & 0x7f80_0000);
    }
    exponent_max != 0x7f80_0000
}
