// C11 control for bet B1: the `best` design of the Rust TDT tail (fp16 weights widened in NEON
// kernels, encoder projection precomputed, raw-logit token argmax, products split over a
// persistent spin-then-park pool, optional speculative frame windows, deferred p/plog), written
// independently of the Rust code but operation for operation the same arithmetic, so its output
// is bit-identical to the Rust arm (checked by the crate's tests and by tail-bench).
//
// Built by build.rs with the `cc` crate: -std=c11 -O3 -ffp-contract=off, no -march/-mcpu flags
// (the default arm64-apple-macos target). -ffp-contract=off keeps every a*b+c a separate
// multiply and add, exactly like Rust; fused multiply-adds appear only as explicit vfmaq_f32.

#include <arm_neon.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "vt_c.h"

// os_sync_wait_on_address (macOS 14.4+), declared here to avoid availability attributes.
extern int os_sync_wait_on_address(void *addr, uint64_t value, size_t size, uint32_t flags);
extern int os_sync_wake_by_address_all(void *addr, size_t size, uint32_t flags);
extern int pthread_set_qos_class_self_np(unsigned int qos_class, int relative_priority);
#define VTC_QOS_USER_INTERACTIVE 0x21u

// ----- constants (bit-identical to src/simd.rs `k`) ------------------------------------------

#define LOG2E 0x1.715476p+0f
#define LN2_HI 0x1.63p-1f
#define LN2_LO -0x1.bd0106p-13f
#define EXP_LO -104.0f
#define EXP_HI 89.0f
#define EXP_C2 0x1p-1f
#define EXP_C3 0x1.555556p-3f
#define EXP_C4 0x1.555556p-5f
#define EXP_C5 0x1.111112p-7f
#define EXP_C6 0x1.6c16c2p-10f
#define EXP_C7 0x1.a01a02p-13f
#define LOG_C3 0x1.555556p-2f
#define LOG_C5 0x1.99999ap-3f
#define LOG_C7 0x1.24924ap-3f
#define LOG_C9 0x1.c71c72p-4f
#define LOG_C11 0x1.745d18p-4f
#define SQRT2 0x1.6a09e6p+0f
#define TANH_P0 -0x1.75e1d4p-8f
#define TANH_P1 0x1.52269cp-6f
#define TANH_P2 -0x1.b83c5ap-5f
#define TANH_P3 0x1.110726p-3f
#define TANH_P4 -0x1.555532p-2f
#define TANH_SMALL 0x1.4p-1f

// ----- vector math (src/simd.rs) ---------------------------------------------------------------

static inline float32x4_t exp4(float32x4_t x) {
    x = vminq_f32(vmaxq_f32(x, vdupq_n_f32(EXP_LO)), vdupq_n_f32(EXP_HI));
    float32x4_t n = vrndnq_f32(vmulq_f32(x, vdupq_n_f32(LOG2E)));
    float32x4_t r = vfmsq_f32(x, n, vdupq_n_f32(LN2_HI));
    r = vfmsq_f32(r, n, vdupq_n_f32(LN2_LO));
    float32x4_t p = vfmaq_f32(vdupq_n_f32(EXP_C6), r, vdupq_n_f32(EXP_C7));
    p = vfmaq_f32(vdupq_n_f32(EXP_C5), r, p);
    p = vfmaq_f32(vdupq_n_f32(EXP_C4), r, p);
    p = vfmaq_f32(vdupq_n_f32(EXP_C3), r, p);
    p = vfmaq_f32(vdupq_n_f32(EXP_C2), r, p);
    p = vfmaq_f32(vdupq_n_f32(1.0f), r, p);
    p = vfmaq_f32(vdupq_n_f32(1.0f), r, p);
    int32x4_t ni = vcvtq_s32_f32(n);
    int32x4_t n1 = vshrq_n_s32(ni, 1);
    int32x4_t n2 = vsubq_s32(ni, n1);
    int32x4_t bias = vdupq_n_s32(127);
    float32x4_t s1 = vreinterpretq_f32_s32(vshlq_n_s32(vaddq_s32(n1, bias), 23));
    float32x4_t s2 = vreinterpretq_f32_s32(vshlq_n_s32(vaddq_s32(n2, bias), 23));
    return vmulq_f32(vmulq_f32(p, s1), s2);
}

static inline float32x4_t log4(float32x4_t x) {
    uint32x4_t tiny = vcltq_f32(x, vdupq_n_f32(0x1p-126f));
    float32x4_t xs = vbslq_f32(tiny, vmulq_f32(x, vdupq_n_f32(8388608.0f)), x);
    int32x4_t eadj = vandq_s32(vreinterpretq_s32_u32(tiny), vdupq_n_s32(-23));
    int32x4_t bits = vreinterpretq_s32_f32(xs);
    int32x4_t e = vaddq_s32(vsubq_s32(vshrq_n_s32(bits, 23), vdupq_n_s32(127)), eadj);
    float32x4_t m = vreinterpretq_f32_s32(vorrq_s32(vandq_s32(bits, vdupq_n_s32(0x007fffff)), vdupq_n_s32(0x3f800000)));
    uint32x4_t big = vcgtq_f32(m, vdupq_n_f32(SQRT2));
    m = vbslq_f32(big, vmulq_f32(m, vdupq_n_f32(0.5f)), m);
    e = vsubq_s32(e, vreinterpretq_s32_u32(big));
    float32x4_t f = vsubq_f32(m, vdupq_n_f32(1.0f));
    float32x4_t s = vdivq_f32(f, vaddq_f32(f, vdupq_n_f32(2.0f)));
    float32x4_t z = vmulq_f32(s, s);
    float32x4_t r = vfmaq_f32(vdupq_n_f32(LOG_C9), z, vdupq_n_f32(LOG_C11));
    r = vfmaq_f32(vdupq_n_f32(LOG_C7), z, r);
    r = vfmaq_f32(vdupq_n_f32(LOG_C5), z, r);
    r = vfmaq_f32(vdupq_n_f32(LOG_C3), z, r);
    r = vmulq_f32(z, r);
    float32x4_t t = vaddq_f32(s, s);
    float32x4_t l1p = vfmaq_f32(t, t, r);
    float32x4_t ef = vcvtq_f32_s32(e);
    float32x4_t res = vfmaq_f32(vfmaq_f32(l1p, ef, vdupq_n_f32(LN2_LO)), ef, vdupq_n_f32(LN2_HI));
    res = vbslq_f32(vceqzq_f32(x), vdupq_n_f32(-INFINITY), res);
    res = vbslq_f32(vceqq_f32(x, vdupq_n_f32(INFINITY)), x, res);
    res = vbslq_f32(vmvnq_u32(vcgezq_f32(x)), vdupq_n_f32(NAN), res);
    return res;
}

static inline float32x4_t sigmoid4(float32x4_t x) {
    float32x4_t one = vdupq_n_f32(1.0f);
    return vdivq_f32(one, vaddq_f32(one, exp4(vnegq_f32(x))));
}

static inline float32x4_t tanh4(float32x4_t x) {
    float32x4_t ax = vabsq_f32(x);
    float32x4_t s = vmulq_f32(x, x);
    float32x4_t p = vfmaq_f32(vdupq_n_f32(TANH_P1), vdupq_n_f32(TANH_P0), s);
    p = vfmaq_f32(vdupq_n_f32(TANH_P2), p, s);
    p = vfmaq_f32(vdupq_n_f32(TANH_P3), p, s);
    p = vfmaq_f32(vdupq_n_f32(TANH_P4), p, s);
    float32x4_t small = vfmaq_f32(x, vmulq_f32(p, s), x);
    float32x4_t e = exp4(vaddq_f32(ax, ax));
    float32x4_t one = vdupq_n_f32(1.0f);
    float32x4_t big = vsubq_f32(one, vdivq_f32(vdupq_n_f32(2.0f), vaddq_f32(e, one)));
    uint32x4_t sign = vandq_u32(vreinterpretq_u32_f32(x), vdupq_n_u32(0x80000000u));
    big = vreinterpretq_f32_u32(vorrq_u32(vreinterpretq_u32_f32(big), sign));
    return vbslq_f32(vcltq_f32(ax, vdupq_n_f32(TANH_SMALL)), small, big);
}

static inline float exp1(float x) { return vgetq_lane_f32(exp4(vdupq_n_f32(x)), 0); }

enum map_fn { MAP_SIGMOID, MAP_TANH, MAP_EXP_SUB, MAP_LOG_DIV };

static inline float32x4_t map_one(enum map_fn fn, float32x4_t v, float32x4_t arg) {
    switch (fn) {
    case MAP_SIGMOID: return sigmoid4(v);
    case MAP_TANH: return tanh4(v);
    case MAP_EXP_SUB: return exp4(vsubq_f32(v, arg));
    default: return log4(vdivq_f32(v, arg));
    }
}

static inline void map_in_place(float *x, size_t n, enum map_fn fn, float arg) {
    float32x4_t a = vdupq_n_f32(arg);
    size_t full = n / 4 * 4;
    for (size_t i = 0; i < full; i += 4) vst1q_f32(x + i, map_one(fn, vld1q_f32(x + i), a));
    if (full < n) {
        float tmp[4] = {0.0f, 0.0f, 0.0f, 0.0f};
        memcpy(tmp, x + full, (n - full) * sizeof(float));
        vst1q_f32(tmp, map_one(fn, vld1q_f32(tmp), a));
        memcpy(x + full, tmp, (n - full) * sizeof(float));
    }
}

static inline float max_of(const float *x, size_t n) {
    float32x4_t m0 = vdupq_n_f32(-INFINITY), m1 = vdupq_n_f32(-INFINITY);
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        m0 = vmaxq_f32(m0, vld1q_f32(x + i));
        m1 = vmaxq_f32(m1, vld1q_f32(x + i + 4));
    }
    float m = vmaxvq_f32(vmaxq_f32(m0, m1));
    for (; i < n; i++) {
        float v = x[i];
        m = (isnan(v) || isnan(m)) ? NAN : fmaxf(m, v);
    }
    return m;
}

static inline size_t first_index_of(const float *x, size_t n, float m) {
    float32x4_t mv = vdupq_n_f32(m);
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        uint32x4_t e0 = vceqq_f32(vld1q_f32(x + i), mv);
        uint32x4_t e1 = vceqq_f32(vld1q_f32(x + i + 4), mv);
        uint32x4_t e2 = vceqq_f32(vld1q_f32(x + i + 8), mv);
        uint32x4_t e3 = vceqq_f32(vld1q_f32(x + i + 12), mv);
        if (vmaxvq_u32(vorrq_u32(vorrq_u32(e0, e1), vorrq_u32(e2, e3))) != 0) break;
    }
    for (; i < n; i++)
        if (x[i] == m) return i;
    return 0; // unreachable for NaN-free input that contains m
}

typedef struct { size_t idx; float val; } partial_max;

static inline partial_max first_max(const float *x, size_t n) {
    float m = max_of(x, n);
    if (isnan(m)) return (partial_max){SIZE_MAX, NAN};
    return (partial_max){first_index_of(x, n, m), m};
}

static size_t argmax_native_scalar(const float *x, size_t n) {
    size_t best = 0;
    float max = -1e10f;
    for (size_t i = 0; i < n; i++)
        if (x[i] > max) { max = x[i]; best = i; }
    return best;
}

static inline size_t argmax_duration(const float *d, size_t n) {
    size_t best = 0;
    float v = d[0];
    for (size_t i = 1; i < n; i++)
        if (d[i] > v) { v = d[i]; best = i; }
    return best;
}

// Canonical sum: a over elements 8m..8m+4, b over 8m+4..8m+8, vaddvq(a + b), tail left to right.
static inline float sum_canonical(const float *v, size_t n, bool exp_terms) {
    float32x4_t a = vdupq_n_f32(0.0f), b = vdupq_n_f32(0.0f);
    size_t chunks = n / 8;
    for (size_t m = 0; m < chunks; m++) {
        float32x4_t x0 = vld1q_f32(v + 8 * m), x1 = vld1q_f32(v + 8 * m + 4);
        if (exp_terms) { x0 = exp4(x0); x1 = exp4(x1); }
        a = vaddq_f32(a, x0);
        b = vaddq_f32(b, x1);
    }
    float s = vaddvq_f32(vaddq_f32(a, b));
    for (size_t i = chunks * 8; i < n; i++) s += exp_terms ? exp1(v[i]) : v[i];
    return s;
}

static void log_softmax(const float *x, size_t n, float *lp) {
    float m = max_of(x, n);
    memcpy(lp, x, n * sizeof(float));
    map_in_place(lp, n, MAP_EXP_SUB, m);
    float s = sum_canonical(lp, n, false);
    map_in_place(lp, n, MAP_LOG_DIV, s);
}

static void token_p_plog(const float *logits, size_t n, size_t n_tok, size_t best, float *scratch, float *p, float *plog) {
    log_softmax(logits, n, scratch);
    float t = sum_canonical(scratch, n_tok, true);
    *p = exp1(scratch[best]) / t;
    *plog = scratch[best];
}

// ----- kernels (src/kernels.rs) ----------------------------------------------------------------

static inline void load8(const uint16_t *p, float32x4_t *w0, float32x4_t *w1) {
    float16x8_t h = vreinterpretq_f16_u16(vld1q_u16(p));
    *w0 = vcvt_f32_f16(vget_low_f16(h));
    *w1 = vcvt_high_f32_f16(h);
}

static inline void dot_rows4(const uint16_t *w, size_t ld, const float *x, size_t k, float *out) {
    float32x4_t a0 = vdupq_n_f32(0.0f), a1 = a0, a2 = a0, a3 = a0;
    float32x4_t b0 = a0, b1 = a0, b2 = a0, b3 = a0;
    for (size_t i = 0; i < k; i += 8) {
        float32x4_t x0 = vld1q_f32(x + i), x1 = vld1q_f32(x + i + 4), w0, w1;
        load8(w + i, &w0, &w1);
        a0 = vfmaq_f32(a0, w0, x0); b0 = vfmaq_f32(b0, w1, x1);
        load8(w + ld + i, &w0, &w1);
        a1 = vfmaq_f32(a1, w0, x0); b1 = vfmaq_f32(b1, w1, x1);
        load8(w + 2 * ld + i, &w0, &w1);
        a2 = vfmaq_f32(a2, w0, x0); b2 = vfmaq_f32(b2, w1, x1);
        load8(w + 3 * ld + i, &w0, &w1);
        a3 = vfmaq_f32(a3, w0, x0); b3 = vfmaq_f32(b3, w1, x1);
    }
    out[0] = vaddvq_f32(vaddq_f32(a0, b0));
    out[1] = vaddvq_f32(vaddq_f32(a1, b1));
    out[2] = vaddvq_f32(vaddq_f32(a2, b2));
    out[3] = vaddvq_f32(vaddq_f32(a3, b3));
}

static inline float dot_row1(const uint16_t *w, const float *x, size_t k) {
    float32x4_t a = vdupq_n_f32(0.0f), b = a;
    for (size_t i = 0; i < k; i += 8) {
        float32x4_t w0, w1;
        load8(w + i, &w0, &w1);
        a = vfmaq_f32(a, w0, vld1q_f32(x + i));
        b = vfmaq_f32(b, w1, vld1q_f32(x + i + 4));
    }
    return vaddvq_f32(vaddq_f32(a, b));
}

// y[r - r0] = W[r] . x for r in [r0, r1)
static void matvec(const uint16_t *w, size_t k, const float *x, float *y, size_t r0, size_t r1) {
    size_t r = r0;
    for (; r + 4 <= r1; r += 4, y += 4) dot_rows4(w + r * k, k, x, k, y);
    for (; r < r1; r++, y++) *y = dot_row1(w + r * k, x, k);
}

// R rows x 4 columns, accumulators per (row, column).
static inline void dot_rows_cols(const uint16_t *w, size_t ld, int rows, const float *const xs[4], size_t k, float out[2][4]) {
    float32x4_t a[2][4], b[2][4];
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 4; c++) { a[r][c] = vdupq_n_f32(0.0f); b[r][c] = vdupq_n_f32(0.0f); }
    for (size_t i = 0; i < k; i += 8) {
        float32x4_t w0[2], w1[2];
        load8(w + i, &w0[0], &w1[0]);
        if (rows == 2) load8(w + ld + i, &w0[1], &w1[1]);
        for (int c = 0; c < 4; c++) {
            float32x4_t x0 = vld1q_f32(xs[c] + i), x1 = vld1q_f32(xs[c] + i + 4);
            a[0][c] = vfmaq_f32(a[0][c], w0[0], x0);
            b[0][c] = vfmaq_f32(b[0][c], w1[0], x1);
            if (rows == 2) {
                a[1][c] = vfmaq_f32(a[1][c], w0[1], x0);
                b[1][c] = vfmaq_f32(b[1][c], w1[1], x1);
            }
        }
    }
    for (int r = 0; r < rows; r++)
        for (int c = 0; c < 4; c++) out[r][c] = vaddvq_f32(vaddq_f32(a[r][c], b[r][c]));
}

// ys[c * y_stride + (r - r0)] = W[r] . xs[c * x_stride ..] for c < n_cols, r in [r0, r1)
static void matmul_cols(const uint16_t *w, size_t k, const float *xs, size_t x_stride, size_t n_cols,
                        float *ys, size_t y_stride, size_t r0, size_t r1) {
    size_t c = 0;
    for (; c + 4 <= n_cols; c += 4) {
        const float *cols[4] = {xs + c * x_stride, xs + (c + 1) * x_stride, xs + (c + 2) * x_stride, xs + (c + 3) * x_stride};
        float v[2][4];
        size_t r = r0;
        for (; r + 2 <= r1; r += 2) {
            dot_rows_cols(w + r * k, k, 2, cols, k, v);
            for (int dr = 0; dr < 2; dr++)
                for (int dc = 0; dc < 4; dc++) ys[(c + dc) * y_stride + (r + dr - r0)] = v[dr][dc];
        }
        if (r < r1) {
            dot_rows_cols(w + r * k, k, 1, cols, k, v);
            for (int dc = 0; dc < 4; dc++) ys[(c + dc) * y_stride + (r - r0)] = v[0][dc];
        }
    }
    for (; c < n_cols; c++) matvec(w, k, xs + c * x_stride, ys + c * y_stride, r0, r1);
}

static inline void split(size_t n, size_t parts, size_t i, size_t align, size_t *start, size_t *end) {
    size_t units = (n + align - 1) / align;
    size_t base = units / parts, extra = units % parts;
    size_t s = (i * base + (i < extra ? i : extra)) * align;
    size_t e = ((i + 1) * base + (i + 1 < extra ? i + 1 : extra)) * align;
    *start = s < n ? s : n;
    *end = e < n ? e : n;
}

// ----- pool (src/pool.rs) ----------------------------------------------------------------------

typedef struct { _Alignas(128) _Atomic uint32_t v; char pad[124]; } padded_u32;
typedef struct { _Alignas(128) _Atomic bool v; char pad[127]; } padded_bool;

typedef void (*job_fn)(void *ctx, size_t part);

typedef struct vtc_pool {
    padded_u32 gen;
    padded_u32 sleepers;
    padded_bool idle;
    _Atomic bool quit;
    job_fn fn;
    void *ctx;
    padded_u32 *done; // threads - 1
    size_t threads;
    uint64_t spin_ns;
    pthread_t *handles;
    struct worker_arg { struct vtc_pool *pool; size_t part; } *args;
} vtc_pool;

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static uint32_t wait_for_job(vtc_pool *pool, uint32_t seen) {
    uint32_t spins = 0;
    uint64_t started = 0;
    for (;;) {
        uint32_t g = atomic_load_explicit(&pool->gen.v, memory_order_acquire);
        if (g != seen) return g;
        spins++;
        if (spins % 256 == 0) {
            bool expired = atomic_load_explicit(&pool->idle.v, memory_order_relaxed);
            if (!expired) {
                uint64_t now = now_ns();
                if (started == 0) started = now;
                else expired = now - started >= pool->spin_ns;
            }
            if (expired) {
                atomic_fetch_add(&pool->sleepers.v, 1);
                if (atomic_load(&pool->gen.v) == seen && !atomic_load(&pool->quit))
                    os_sync_wait_on_address((void *) &pool->gen.v, seen, 4, 0);
                atomic_fetch_sub(&pool->sleepers.v, 1);
                started = 0;
            }
        }
        __asm__ __volatile__("isb" ::: "memory");
    }
}

static void *worker_main(void *p) {
    struct worker_arg *arg = p;
    vtc_pool *pool = arg->pool;
    pthread_set_qos_class_self_np(VTC_QOS_USER_INTERACTIVE, 0);
    uint32_t seen = 0; // the construction value: a job published before this thread ran must still run
    for (;;) {
        seen = wait_for_job(pool, seen);
        if (atomic_load_explicit(&pool->quit, memory_order_acquire)) return NULL;
        pool->fn(pool->ctx, arg->part);
        atomic_store_explicit(&pool->done[arg->part - 1].v, seen, memory_order_release);
    }
}

static void pool_wake_all(vtc_pool *pool) { os_sync_wake_by_address_all((void *) &pool->gen.v, 4, 0); }

static void pool_free(vtc_pool *pool);

static vtc_pool *pool_new(size_t threads, uint64_t spin_ns) {
    vtc_pool *pool = aligned_alloc(128, (sizeof(vtc_pool) + 127) / 128 * 128);
    if (!pool) return NULL;
    memset(pool, 0, sizeof *pool);
    atomic_init(&pool->gen.v, 0);
    atomic_init(&pool->sleepers.v, 0);
    atomic_init(&pool->idle.v, true);
    atomic_init(&pool->quit, false);
    pool->threads = 1; // workers actually started + 1, for pool_free on a failed start
    pool->spin_ns = spin_ns;
    size_t workers = threads - 1;
    pool->done = workers ? aligned_alloc(128, workers * sizeof(padded_u32)) : NULL;
    pool->handles = workers ? calloc(workers, sizeof(pthread_t)) : NULL;
    pool->args = workers ? calloc(workers, sizeof(struct worker_arg)) : NULL;
    if (workers && (!pool->done || !pool->handles || !pool->args)) { pool_free(pool); return NULL; }
    for (size_t i = 0; i < workers; i++) atomic_init(&pool->done[i].v, 0);
    for (size_t i = 0; i < workers; i++) {
        pool->args[i] = (struct worker_arg){pool, i + 1};
        if (pthread_create(&pool->handles[i], NULL, worker_main, &pool->args[i]) != 0) { pool_free(pool); return NULL; }
        pool->threads = i + 2;
    }
    return pool;
}

static void pool_wake(vtc_pool *pool) {
    atomic_store(&pool->idle.v, false);
    if (atomic_load(&pool->sleepers.v) > 0) pool_wake_all(pool);
}

static void pool_sleep(vtc_pool *pool) { atomic_store(&pool->idle.v, true); }

static void pool_run(vtc_pool *pool, job_fn fn, void *ctx) {
    if (pool->threads == 1) { fn(ctx, 0); return; }
    pool->fn = fn;
    pool->ctx = ctx;
    uint32_t generation = atomic_fetch_add(&pool->gen.v, 1) + 1;
    if (atomic_load(&pool->sleepers.v) > 0) pool_wake_all(pool);
    fn(ctx, 0);
    for (size_t i = 0; i + 1 < pool->threads; i++)
        while (atomic_load_explicit(&pool->done[i].v, memory_order_acquire) != generation)
            __asm__ __volatile__("isb" ::: "memory");
}

static void pool_free(vtc_pool *pool) {
    if (!pool) return;
    atomic_store(&pool->quit, true);
    atomic_fetch_add(&pool->gen.v, 1);
    pool_wake_all(pool);
    for (size_t i = 0; i + 1 < pool->threads; i++)
        if (pool->handles && pool->handles[i]) pthread_join(pool->handles[i], NULL);
    free(pool->done);
    free(pool->handles);
    free(pool->args);
    free(pool);
}

// ----- engine ----------------------------------------------------------------------------------

struct vtc_engine {
    vtc_model m;
    size_t threads, kmax, spec_k, spec_k_token;
    vtc_pool *pool;
    float *encproj; size_t encproj_cap;
    float *h[VTC_MAX_LAYERS], *h_next[VTC_MAX_LAYERS], *c[VTC_MAX_LAYERS];
    float *x0, *gates, *gates_hh, *pred, *hidden, *logits, *lp_parts;
    partial_max *partial;
    float *tok_logits; size_t tok_logits_cap;
    vtc_token *tokens; size_t tokens_cap;
};

typedef struct {
    vtc_engine *e;
    // precompute
    const float *enc; size_t n_frames; _Atomic size_t next;
    // lstm
    size_t layer; const float *x;
    // joint
    size_t k;
    // probs
    size_t n_tokens;
} job_ctx;

static void job_precompute(void *p, size_t part) {
    (void) part;
    job_ctx *j = p;
    vtc_engine *e = j->e;
    size_t pdim = e->m.p, s = e->m.s;
    enum { BLOCK = 16 };
    for (;;) {
        size_t b = atomic_fetch_add_explicit(&j->next, 1, memory_order_relaxed);
        size_t r0 = b * BLOCK, r1 = r0 + BLOCK < pdim ? r0 + BLOCK : pdim;
        if (r0 >= pdim) break;
        matmul_cols(e->m.enc_w, s, j->enc, s, j->n_frames, e->encproj + r0, pdim, r0, r1);
        for (size_t t = 0; t < j->n_frames; t++)
            for (size_t r = r0; r < r1; r++) e->encproj[t * pdim + r] += e->m.enc_b[r];
    }
}

static void cell_update(float *gates, size_t p, size_t u0, size_t u1, float *c, float *h_next) {
    size_t n = u1 - u0;
    float *gi = gates + u0, *gf = gates + p + u0, *go = gates + 2 * p + u0, *gg = gates + 3 * p + u0;
    map_in_place(gi, n, MAP_SIGMOID, 0.0f);
    map_in_place(gf, n, MAP_SIGMOID, 0.0f);
    map_in_place(go, n, MAP_SIGMOID, 0.0f);
    map_in_place(gg, n, MAP_TANH, 0.0f);
    float *cc = c + u0, *h = h_next + u0;
    for (size_t u = 0; u < n; u++) {
        cc[u] = gf[u] * cc[u] + gi[u] * gg[u];
        h[u] = cc[u];
    }
    map_in_place(h, n, MAP_TANH, 0.0f);
    for (size_t u = 0; u < n; u++) h[u] = go[u] * h[u];
}

static void job_lstm(void *p, size_t part) {
    job_ctx *j = p;
    vtc_engine *e = j->e;
    size_t P = e->m.p, l = j->layer, u0, u1;
    split(P, e->threads, part, 4, &u0, &u1);
    if (u0 >= u1) return;
    const float *b = e->m.b_h[l];
    for (size_t g = 0; g < 4; g++) {
        size_t r0 = g * P + u0, r1 = g * P + u1;
        matvec(e->m.w_ih[l], P, j->x, e->gates + r0, r0, r1);
        matvec(e->m.w_hh[l], P, e->h[l], e->gates_hh + r0, r0, r1);
        for (size_t r = r0; r < r1; r++) e->gates[r] += e->gates_hh[r] + b[r];
    }
    cell_update(e->gates, P, u0, u1, e->c[l], e->h_next[l]);
}

static void job_pred(void *p, size_t part) {
    job_ctx *j = p;
    vtc_engine *e = j->e;
    size_t P = e->m.p, r0, r1;
    split(P, e->threads, part, 4, &r0, &r1);
    const float *top = e->h[e->m.n_layers - 1];
    matvec(e->m.pred_w, P, top, e->pred + r0, r0, r1);
    for (size_t r = r0; r < r1; r++) e->pred[r] += e->m.pred_b[r];
}

static void job_joint(void *p, size_t part) {
    job_ctx *j = p;
    vtc_engine *e = j->e;
    size_t P = e->m.p, n_out = e->m.n_out, n_tok = e->m.n_tok, r0, r1;
    split(n_out, e->threads, part, 4, &r0, &r1);
    matmul_cols(e->m.net_w, P, e->hidden, P, j->k, e->logits + r0, n_out, r0, r1);
    for (size_t c = 0; c < j->k; c++) {
        float *row = e->logits + c * n_out;
        for (size_t r = r0; r < r1; r++) row[r] += e->m.net_b[r];
        size_t t0 = r0 < n_tok ? r0 : n_tok, t1 = r1 < n_tok ? r1 : n_tok;
        partial_max pm = {0, -INFINITY};
        if (t0 < t1) {
            pm = first_max(row + t0, t1 - t0);
            if (pm.idx != SIZE_MAX) pm.idx += t0;
        }
        e->partial[part * e->kmax + c] = pm;
    }
}

static void job_probs(void *p, size_t part) {
    job_ctx *j = p;
    vtc_engine *e = j->e;
    size_t n_out = e->m.n_out;
    for (size_t i = part; i < j->n_tokens; i += e->threads) {
        vtc_token *t = &e->tokens[i];
        token_p_plog(e->tok_logits + i * n_out, n_out, e->m.n_tok, (size_t) t->id, e->lp_parts + part * n_out, &t->p, &t->plog);
    }
}

static bool grow(void **buf, size_t *cap, size_t need, size_t elem) {
    if (need <= *cap) return true;
    size_t n = *cap ? *cap : 64;
    while (n < need) n *= 2;
    void *q = realloc(*buf, n * elem);
    if (!q) return false;
    *buf = q;
    *cap = n;
    return true;
}

vtc_engine *vtc_engine_new(const vtc_model *m, size_t threads, size_t spec_k, size_t spec_k_token, uint64_t spin_us) {
    if (m->n_layers > VTC_MAX_LAYERS || threads < 1) return NULL;
    vtc_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->m = *m;
    e->threads = threads;
    e->spec_k = spec_k ? spec_k : 1;
    e->spec_k_token = spec_k_token ? spec_k_token : 1;
    e->kmax = e->spec_k > e->spec_k_token ? e->spec_k : e->spec_k_token;
    size_t P = m->p;
    bool ok = true;
    for (size_t l = 0; l < m->n_layers; l++) {
        ok &= (e->h[l] = calloc(P, sizeof(float))) != NULL;
        ok &= (e->h_next[l] = calloc(P, sizeof(float))) != NULL;
        ok &= (e->c[l] = calloc(P, sizeof(float))) != NULL;
    }
    ok &= (e->x0 = calloc(P, sizeof(float))) != NULL;
    ok &= (e->gates = calloc(4 * P, sizeof(float))) != NULL;
    ok &= (e->gates_hh = calloc(4 * P, sizeof(float))) != NULL;
    ok &= (e->pred = calloc(P, sizeof(float))) != NULL;
    ok &= (e->hidden = calloc(e->kmax * P, sizeof(float))) != NULL;
    ok &= (e->logits = calloc(e->kmax * m->n_out, sizeof(float))) != NULL;
    ok &= (e->lp_parts = calloc(threads * m->n_out, sizeof(float))) != NULL;
    ok &= (e->partial = calloc(threads * e->kmax, sizeof(partial_max))) != NULL;
    if (ok) ok = (e->pool = pool_new(threads, spin_us * 1000)) != NULL;
    if (!ok) { vtc_engine_free(e); return NULL; }
    return e;
}

void vtc_engine_free(vtc_engine *e) {
    if (!e) return;
    pool_free(e->pool);
    for (size_t l = 0; l < VTC_MAX_LAYERS; l++) { free(e->h[l]); free(e->h_next[l]); free(e->c[l]); }
    free(e->x0); free(e->gates); free(e->gates_hh); free(e->pred); free(e->hidden); free(e->logits);
    free(e->lp_parts); free(e->partial); free(e->encproj); free(e->tok_logits); free(e->tokens);
    free(e);
}

static void predict(vtc_engine *e, job_ctx *j, size_t token) {
    size_t P = e->m.p;
    for (size_t i = 0; i < P; i++) e->x0[i] = (float) ((const __fp16 *) e->m.embed)[token * P + i];
    for (size_t l = 0; l < e->m.n_layers; l++) {
        j->layer = l;
        j->x = l == 0 ? e->x0 : e->h_next[l - 1];
        pool_run(e->pool, job_lstm, j);
    }
    for (size_t l = 0; l < e->m.n_layers; l++) { float *t = e->h[l]; e->h[l] = e->h_next[l]; e->h_next[l] = t; }
    pool_run(e->pool, job_pred, j);
}

static size_t token_argmax(vtc_engine *e, size_t col) {
    size_t best = 0;
    float max = -1e10f;
    for (size_t part = 0; part < e->threads; part++) {
        partial_max pm = e->partial[part * e->kmax + col];
        if (isnan(pm.val)) return argmax_native_scalar(e->logits + col * e->m.n_out, e->m.n_tok);
        if (pm.val > max) { max = pm.val; best = pm.idx; }
    }
    return best;
}

int32_t vtc_decode(vtc_engine *e, const float *enc, size_t n_frames, const vtc_token **tokens, vtc_work *work) {
    const size_t P = e->m.p, n_out = e->m.n_out, n_tok = e->m.n_tok, blank = e->m.blank;
    memset(work, 0, sizeof *work);
    work->n_frames = n_frames;
    *tokens = e->tokens;
    if (!grow((void **) &e->encproj, &e->encproj_cap, n_frames * P, sizeof(float))) return -1;
    for (size_t l = 0; l < e->m.n_layers; l++) {
        memset(e->h[l], 0, P * sizeof(float));
        memset(e->c[l], 0, P * sizeof(float));
    }
    pool_wake(e->pool);
    job_ctx j = {.e = e, .enc = enc, .n_frames = n_frames};
    atomic_init(&j.next, 0);
    pool_run(e->pool, job_precompute, &j);

    size_t n_tokens = 0, t = 0, emitted = 0, last = blank, win_start = 0, win_len = 0;
    bool pending = true, fresh = true;
    int32_t rc = 0;
    while (t < n_frames) {
        if (pending) {
            predict(e, &j, last);
            work->n_pred++;
            pending = false;
            fresh = true;
            win_len = 0;
        }
        size_t col;
        if (t >= win_start && t < win_start + win_len) {
            col = t - win_start;
        } else {
            size_t k = fresh ? e->spec_k_token : e->spec_k;
            if (k > n_frames - t) k = n_frames - t;
            for (size_t c = 0; c < k; c++) {
                const float *ep = e->encproj + (t + c) * P;
                float *hv = e->hidden + c * P;
                for (size_t i = 0; i < P; i++) {
                    float v = ep[i] + e->pred[i];
                    hv[i] = v > 0.0f ? v : 0.0f;
                }
            }
            j.k = k;
            pool_run(e->pool, job_joint, &j);
            work->n_cols += k;
            win_start = t;
            win_len = k;
            col = 0;
        }
        fresh = false;
        work->n_steps++;
        const float *row = e->logits + col * n_out;
        size_t best = token_argmax(e, col);
        size_t dur_idx = argmax_duration(row + n_tok, n_out - n_tok);
        size_t duration = (size_t) e->m.durations[dur_idx];
        if (best == blank) {
            t += duration == 0 ? 1 : duration;
            emitted = 0;
            continue;
        }
        if (!grow((void **) &e->tok_logits, &e->tok_logits_cap, (n_tokens + 1) * n_out, sizeof(float)) ||
            !grow((void **) &e->tokens, &e->tokens_cap, n_tokens + 1, sizeof(vtc_token))) {
            rc = -1;
            break;
        }
        memcpy(e->tok_logits + n_tokens * n_out, row, n_out * sizeof(float));
        e->tokens[n_tokens++] = (vtc_token){(int32_t) best, (int32_t) t, (int32_t) dur_idx, (int32_t) duration, NAN, NAN};
        last = best;
        pending = true;
        if (duration > 0) {
            t += duration;
            emitted = 0;
        } else if (++emitted >= e->m.max_symbols) {
            t += 1;
            emitted = 0;
        }
    }
    if (rc == 0 && n_tokens > 0) {
        j.n_tokens = n_tokens;
        pool_run(e->pool, job_probs, &j);
    }
    pool_sleep(e->pool);
    *tokens = e->tokens;
    work->n_tokens = n_tokens;
    return rc == 0 ? (int32_t) n_tokens : -1;
}
