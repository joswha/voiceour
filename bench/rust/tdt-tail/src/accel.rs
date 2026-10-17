//! Accelerate BLAS (the `accel` arm): Apple's matrix path (AMX / SME behind `cblas_*`).

use std::ffi::c_int;

const ROW_MAJOR: c_int = 101;
const NO_TRANS: c_int = 111;
const TRANS: c_int = 112;

#[link(name = "Accelerate", kind = "framework")]
unsafe extern "C" {
    fn cblas_sgemv(
        order: c_int,
        trans: c_int,
        m: c_int,
        n: c_int,
        alpha: f32,
        a: *const f32,
        lda: c_int,
        x: *const f32,
        incx: c_int,
        beta: f32,
        y: *mut f32,
        incy: c_int,
    );
    fn cblas_sgemm(
        order: c_int,
        trans_a: c_int,
        trans_b: c_int,
        m: c_int,
        n: c_int,
        k: c_int,
        alpha: f32,
        a: *const f32,
        lda: c_int,
        b: *const f32,
        ldb: c_int,
        beta: f32,
        c: *mut f32,
        ldc: c_int,
    );
}

/// `y[i] = Σ_k a[i][k]·x[k]` for the `rows × k` row-major block at `a`.
///
/// # Safety
/// `a` holds `rows·k`, `x` holds `k`, `y` holds `rows` floats.
pub unsafe fn gemv(a: *const f32, rows: usize, k: usize, x: *const f32, y: *mut f32) {
    unsafe {
        cblas_sgemv(
            ROW_MAJOR,
            NO_TRANS,
            rows as c_int,
            k as c_int,
            1.0,
            a,
            k as c_int,
            x,
            1,
            0.0,
            y,
            1,
        );
    }
}

/// `c[t][j] = Σ_k a[t][k]·w[j][k]`: `a` is `m × k`, `w` is `n × k`, `c` is `m × n` (row-major).
///
/// # Safety
/// Buffers hold the stated sizes.
pub unsafe fn gemm_nt(a: *const f32, m: usize, w: *const f32, n: usize, k: usize, c: *mut f32) {
    unsafe {
        cblas_sgemm(
            ROW_MAJOR, NO_TRANS, TRANS, m as c_int, n as c_int, k as c_int, 1.0, a, k as c_int, w,
            k as c_int, 0.0, c, n as c_int,
        );
    }
}
