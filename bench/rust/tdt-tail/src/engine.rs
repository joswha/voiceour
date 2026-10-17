//! The greedy TDT decode (`parakeet_decode`, parakeet.cpp L4761-L4947) and its arms.
//!
//! One loop serves every Rust arm; a [`Config`] selects the weight format, where the products
//! run (NEON kernels or Accelerate), whether the encoder projection is hoisted out of the loop,
//! how the token argmax is taken, how many threads split the products, and how many frames one
//! pass over `joint_net` evaluates. `c-best` hands the same loop to the C11 control.

use std::ops::Range;
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::time::Duration;

use crate::kernels::{self, Q8_BLOCK, split};
use crate::pool::{Pool, SyncConst, SyncPtr};
use crate::simd;
use crate::weights::{Format, Mat, MatData, Weights};
use crate::{accel, cimpl};

/// Where the matrix products run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    /// The crate's NEON kernels (canonical summation order).
    Neon,
    /// `cblas_sgemv` / `cblas_sgemm` from Accelerate.
    Accelerate,
    /// The C11 control in `c/vt_c.c` (same algorithm as `best`).
    C,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub format: Format,
    pub backend: Backend,
    /// Encoder projection of every frame in one GEMM before the loop (else one matvec per step).
    pub precompute: bool,
    /// Token argmax over the raw logits (else over the log-softmax, every step).
    pub raw_argmax: bool,
    /// Participants in the products (caller included); 1 = no pool.
    pub threads: usize,
    /// Frames per `joint_net` pass when the window was opened by a blank (1 = no speculation).
    pub spec_k: usize,
    /// Frames per pass right after a prediction (the first step under a new predictor state).
    pub spec_k_token: usize,
    /// Worker spin before parking while a decode runs.
    pub spin_us: u64,
    /// `p`/`plog` computed after the loop from saved logits rows (in parallel), else in the loop.
    pub defer_probs: bool,
}

/// Arms advertised by `vt_arms` (order matters to the harness only for display).
pub const ARMS: &str = "naive,precompute,rawargmax,f16w,mt,spec,accel,q8,best,c-best";

/// The arm `best` aliases (see README "Choosing best").
pub const BEST: &str = "mt";

const SPIN_US: u64 = 2_000;

/// Performance cores (`hw.perflevel0.physicalcpu`), else the logical CPU count.
pub fn perf_cores() -> usize {
    unsafe extern "C" {
        fn sysctlbyname(
            name: *const std::ffi::c_char,
            oldp: *mut std::ffi::c_void,
            oldlenp: *mut usize,
            newp: *mut std::ffi::c_void,
            newlen: usize,
        ) -> std::ffi::c_int;
    }
    let mut v: i32 = 0;
    let mut len = std::mem::size_of::<i32>();
    let rc = unsafe {
        sysctlbyname(
            c"hw.perflevel0.physicalcpu".as_ptr(),
            (&raw mut v).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc == 0 && v > 0 {
        v as usize
    } else {
        std::thread::available_parallelism().map_or(1, |n| n.get())
    }
}

fn base_config(base: &str) -> Result<Config, String> {
    let naive = Config {
        format: Format::F32,
        backend: Backend::Neon,
        precompute: false,
        raw_argmax: false,
        threads: 1,
        spec_k: 1,
        spec_k_token: 1,
        spin_us: SPIN_US,
        defer_probs: false,
    };
    let precompute = Config {
        precompute: true,
        ..naive.clone()
    };
    let rawargmax = Config {
        raw_argmax: true,
        ..precompute.clone()
    };
    let f16w = Config {
        format: Format::F16,
        ..rawargmax.clone()
    };
    // One participant per performance core except one, which stays free for the caller's
    // process and the OS: on the shared M4 Pro (10 P-cores) a dev sweep measured 9 threads at
    // ~66 µs/step, 8 at ~71, 7 at ~79, and 10 erratic (76-94) from stragglers (README, "mt").
    let mt = Config {
        threads: perf_cores().saturating_sub(1).max(1),
        defer_probs: true,
        ..f16w.clone()
    };
    let spec = Config {
        spec_k: 4,
        spec_k_token: 1,
        ..mt.clone()
    };
    Ok(match base {
        "naive" => naive,
        "precompute" => precompute,
        "rawargmax" => rawargmax,
        "f16w" => f16w,
        "mt" => mt,
        "spec" => spec,
        "accel" => Config {
            backend: Backend::Accelerate,
            ..rawargmax
        },
        "best" => base_config(BEST)?,
        "q8" => Config {
            format: Format::Q8,
            ..base_config(BEST)?
        },
        "c-best" => Config {
            backend: Backend::C,
            ..base_config(BEST)?
        },
        _ => return Err(format!("unknown arm '{base}'; arms: {ARMS}")),
    })
}

/// Parses `arm[/key=value...]`: a base arm from [`ARMS`] plus development overrides
/// `t` (threads), `k` (spec frames after a blank), `kt` (spec frames after a prediction),
/// `spin` (µs), `defer` (0/1). The advertised arms take no overrides.
pub fn arm_config(name: &str) -> Result<Config, String> {
    let mut parts = name.split('/');
    let mut cfg = base_config(parts.next().unwrap_or_default())?;
    for kv in parts {
        let (key, value) = kv
            .split_once('=')
            .ok_or_else(|| format!("arm '{name}': override '{kv}' is not key=value"))?;
        let n: u64 = value
            .parse()
            .map_err(|_| format!("arm '{name}': '{value}' is not a number"))?;
        match key {
            "t" => cfg.threads = n.max(1) as usize,
            "k" => cfg.spec_k = n.max(1) as usize,
            "kt" => cfg.spec_k_token = n.max(1) as usize,
            "spin" => cfg.spin_us = n,
            "defer" => cfg.defer_probs = n != 0,
            _ => return Err(format!("arm '{name}': unknown override '{key}'")),
        }
    }
    if cfg.backend == Backend::Accelerate
        && (cfg.threads > 1 || cfg.spec_k > 1 || cfg.spec_k_token > 1)
    {
        return Err(format!(
            "arm '{name}': the Accelerate arm is single-pass, single-caller"
        ));
    }
    if cfg.backend == Backend::C
        && (cfg.format != Format::F16 || !cfg.raw_argmax || !cfg.precompute)
    {
        return Err(format!(
            "arm '{name}': the C control implements the f16 raw-argmax design only"
        ));
    }
    Ok(cfg)
}

/// One emitted token; also the `vt_token` ABI struct (24 bytes).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Token {
    pub id: i32,
    pub frame_index: i32,
    pub duration_idx: i32,
    /// The duration value (`tdt_durations[duration_idx]`), as the native token data stores it.
    pub duration: i32,
    pub p: f32,
    pub plog: f32,
}

/// Work counts of one decode (the timing row's `work`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Work {
    pub n_frames: usize,
    pub n_tokens: usize,
    /// Greedy steps (joint evaluations consumed) — the native loop's iteration count.
    pub n_steps: usize,
    /// Prediction-network runs.
    pub n_pred: usize,
    /// Joint columns computed (`> n_steps` only when speculation discards columns).
    pub n_cols: usize,
}

/// One greedy step as observed (equivalence diagnostics only).
#[derive(Clone, Copy, Debug)]
pub struct StepTrace {
    pub t: usize,
    pub token: usize,
    pub dur_idx: usize,
    /// Top-1 minus top-2 raw logit over the token slots.
    pub tok_margin: f32,
    /// Top-1 minus top-2 raw logit over the duration slots.
    pub dur_margin: f32,
}

/// Wall time per decode phase in µs, summed over profiled decodes (Rust arms only; never on in
/// timed runs).
#[derive(Clone, Copy, Debug, Default)]
pub struct Profile {
    /// Pool wake, state reset and the encoder projection (precompute arms).
    pub setup_us: f64,
    /// Prediction network (both LSTM layers and the projection).
    pub predict_us: f64,
    /// Joint network passes (encoder projection per step for non-precompute arms).
    pub joint_us: f64,
    /// Argmax, log-softmax in the loop, decisions and bookkeeping on the calling thread.
    pub serial_us: f64,
    /// Deferred p/plog after the loop.
    pub probs_us: f64,
    pub decodes: usize,
    pub work: Work,
}

/// Lap timer that costs one branch when off.
struct Laps(Option<std::time::Instant>);

impl Laps {
    #[inline(always)]
    fn lap(&mut self, acc: &mut f64) {
        if let Some(last) = self.0.as_mut() {
            let now = std::time::Instant::now();
            *acc += (now - *last).as_secs_f64() * 1e6;
            *last = now;
        }
    }
}

#[derive(Default)]
struct Scratch {
    encproj: Vec<f32>,
    enc_q: Vec<u8>,
    h: Vec<Vec<f32>>,
    h_next: Vec<Vec<f32>>,
    c: Vec<Vec<f32>>,
    x0: Vec<f32>,
    gates: Vec<f32>,
    gates_hh: Vec<f32>,
    pred: Vec<f32>,
    hidden: Vec<f32>,
    hidden_q: Vec<u8>,
    x_q: Vec<u8>,
    h_q: Vec<u8>,
    logits: Vec<f32>,
    partial: Vec<(usize, f32)>,
    /// Window capacity (columns) of `hidden`, `logits` and the `partial` stride.
    kcap: usize,
    lp: Vec<f32>,
    lp_parts: Vec<f32>,
    tok_logits: Vec<f32>,
}

pub struct Engine {
    name: String,
    cfg: Config,
    w: Weights,
    pool: Option<Pool>,
    s: Scratch,
    c: Option<cimpl::CEngine>,
    profile: Option<Profile>,
}

fn q8_bytes(n: usize) -> usize {
    n / 32 * Q8_BLOCK
}

/// `y[rows - rows.start] = M[rows]·x`, in the matrix's format (`xq` is `x` as q8_0 for Q8).
///
/// # Safety
/// Pointers cover the ranges (see [`kernels::matvec`]).
#[inline]
unsafe fn mat_rows(
    m: &Mat,
    backend: Backend,
    x: *const f32,
    xq: *const u8,
    y: *mut f32,
    rows: Range<usize>,
) {
    unsafe {
        match (&m.data, backend) {
            (MatData::F32(v), Backend::Accelerate) => {
                accel::gemv(v.as_ptr().add(rows.start * m.k), rows.len(), m.k, x, y)
            }
            (MatData::F32(v), _) => kernels::matvec(v.as_ptr(), m.k, x, y, rows),
            (MatData::F16(v), _) => kernels::matvec(v.as_ptr(), m.k, x, y, rows),
            (MatData::Q8(v), _) => kernels::matvec_q8(v.as_ptr(), m.k / 32, xq, y, rows),
        }
    }
}

/// [`mat_rows`] for `n_cols` columns (column-major blocks; `ys` points at column 0, row
/// `rows.start`).
#[inline]
#[allow(clippy::too_many_arguments)]
unsafe fn mat_cols(
    m: &Mat,
    backend: Backend,
    xs: *const f32,
    x_stride: usize,
    xq: *const u8,
    n_cols: usize,
    ys: *mut f32,
    y_stride: usize,
    rows: Range<usize>,
) {
    unsafe {
        match &m.data {
            MatData::F32(v) if backend != Backend::Accelerate => {
                kernels::matmul_cols(v.as_ptr(), m.k, xs, x_stride, n_cols, ys, y_stride, rows)
            }
            MatData::F16(v) => {
                kernels::matmul_cols(v.as_ptr(), m.k, xs, x_stride, n_cols, ys, y_stride, rows)
            }
            _ => {
                let qstride = q8_bytes(m.k);
                for c in 0..n_cols {
                    mat_rows(
                        m,
                        backend,
                        xs.add(c * x_stride),
                        xq.wrapping_add(c * qstride),
                        ys.add(c * y_stride),
                        rows.clone(),
                    );
                }
            }
        }
    }
}

/// `c = f·c + i·g`, `h' = o·tanh(c)` for `units` (gates already summed with the bias).
///
/// # Safety
/// `gates` holds `4p`, `c` and `h_next` hold `p` floats; `units ⊂ 0..p`.
unsafe fn cell_update(
    gates: *mut f32,
    p: usize,
    units: Range<usize>,
    c: *mut f32,
    h_next: *mut f32,
) {
    unsafe {
        let n = units.len();
        let s = units.start;
        let gi = std::slice::from_raw_parts_mut(gates.add(s), n);
        simd::sigmoid_in_place(gi);
        let gf = std::slice::from_raw_parts_mut(gates.add(p + s), n);
        simd::sigmoid_in_place(gf);
        let go = std::slice::from_raw_parts_mut(gates.add(2 * p + s), n);
        simd::sigmoid_in_place(go);
        let gg = std::slice::from_raw_parts_mut(gates.add(3 * p + s), n);
        simd::tanh_in_place(gg);
        let c = std::slice::from_raw_parts_mut(c.add(s), n);
        let h = std::slice::from_raw_parts_mut(h_next.add(s), n);
        for u in 0..n {
            c[u] = gf[u] * c[u] + gi[u] * gg[u];
            h[u] = c[u];
        }
        simd::tanh_in_place(h);
        for u in 0..n {
            h[u] = go[u] * h[u];
        }
    }
}

#[inline(always)]
fn relu(v: f32) -> f32 {
    if v > 0.0 { v } else { 0.0 }
}

impl Engine {
    /// Opens the model and builds the arm `name` (see [`arm_config`]).
    pub fn new(model_path: &std::path::Path, name: &str) -> Result<Engine, String> {
        let cfg = arm_config(name)?;
        let model = parakeet_model::Model::open(model_path)
            .map_err(|e| format!("{}: {e}", model_path.display()))?;
        let w = Weights::load(&model, cfg.format)?;
        drop(model);
        Engine::from_weights(name, cfg, w)
    }

    /// Builds an engine over already-loaded weights (tests, synthetic models).
    pub fn from_weights(name: &str, cfg: Config, w: Weights) -> Result<Engine, String> {
        w.validate()?;
        if w.format() != cfg.format {
            return Err(format!(
                "arm '{name}' needs {:?} weights, got {:?}",
                cfg.format,
                w.format()
            ));
        }
        let pool =
            (cfg.threads > 1).then(|| Pool::new(cfg.threads, Duration::from_micros(cfg.spin_us)));
        let c = if cfg.backend == Backend::C {
            Some(cimpl::CEngine::new(&w, &cfg)?)
        } else {
            None
        };
        let d = &w.dims;
        let kmax = cfg.spec_k.max(cfg.spec_k_token);
        let parts = cfg.threads.max(1);
        let s = Scratch {
            h: vec![vec![0.0; d.p]; d.n_layers],
            h_next: vec![vec![0.0; d.p]; d.n_layers],
            c: vec![vec![0.0; d.p]; d.n_layers],
            x0: vec![0.0; d.p],
            gates: vec![0.0; 4 * d.p],
            gates_hh: vec![0.0; 4 * d.p],
            pred: vec![0.0; d.p],
            hidden: vec![0.0; kmax * d.p],
            hidden_q: vec![0; kmax * q8_bytes(d.p)],
            x_q: vec![0; q8_bytes(d.p)],
            h_q: vec![0; q8_bytes(d.p)],
            logits: vec![0.0; kmax * d.n_out],
            partial: vec![(0, 0.0); parts * kmax],
            kcap: kmax,
            lp: vec![0.0; d.n_out],
            lp_parts: vec![0.0; parts * d.n_out],
            ..Scratch::default()
        };
        Ok(Engine {
            name: name.to_owned(),
            cfg,
            w,
            pool,
            s,
            c,
            profile: None,
        })
    }

    /// Turns phase profiling on (resetting it) or off. Profiled decodes pay a clock read per
    /// phase boundary; the C arm is not instrumented.
    pub fn set_profiling(&mut self, on: bool) {
        self.profile = on.then(Profile::default);
    }

    /// Phase times accumulated since profiling was turned on.
    pub fn profile(&self) -> Option<&Profile> {
        self.profile.as_ref()
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn config(&self) -> &Config {
        &self.cfg
    }

    pub fn weights(&self) -> &Weights {
        &self.w
    }

    fn parts(&self) -> usize {
        self.pool.as_ref().map_or(1, Pool::threads)
    }

    /// Greedy TDT decode of `n_frames` encoder states (`enc`: frame-major `[n_frames][n_state]`)
    /// into `out` (cleared first). `trace` (diagnostics only) receives every step.
    pub fn decode(
        &mut self,
        enc: &[f32],
        n_frames: usize,
        n_state: usize,
        out: &mut Vec<Token>,
        trace: Option<&mut Vec<StepTrace>>,
    ) -> Result<Work, String> {
        let d = &self.w.dims;
        if n_state != d.s {
            return Err(format!("n_state {n_state} != model encoder width {}", d.s));
        }
        if enc.len() < n_frames * n_state {
            return Err(format!(
                "enc holds {} floats, need {}",
                enc.len(),
                n_frames * n_state
            ));
        }
        out.clear();
        if let Some(c) = &mut self.c {
            return c.decode(enc, n_frames, out);
        }
        let mut laps = Laps(self.profile.is_some().then(std::time::Instant::now));
        if let Some(pool) = &self.pool {
            pool.wake();
        }
        let mut prof = Profile::default();
        let work = self.decode_inner(
            &enc[..n_frames * n_state],
            n_frames,
            out,
            trace,
            &mut laps,
            &mut prof,
        );
        if let Some(pool) = &self.pool {
            pool.sleep();
        }
        if let Some(total) = self.profile.as_mut() {
            total.setup_us += prof.setup_us;
            total.predict_us += prof.predict_us;
            total.joint_us += prof.joint_us;
            total.serial_us += prof.serial_us;
            total.probs_us += prof.probs_us;
            total.decodes += 1;
            total.work.n_frames += work.n_frames;
            total.work.n_tokens += work.n_tokens;
            total.work.n_steps += work.n_steps;
            total.work.n_pred += work.n_pred;
            total.work.n_cols += work.n_cols;
        }
        Ok(work)
    }

    fn decode_inner(
        &mut self,
        enc: &[f32],
        n_frames: usize,
        out: &mut Vec<Token>,
        mut trace: Option<&mut Vec<StepTrace>>,
        laps: &mut Laps,
        prof: &mut Profile,
    ) -> Work {
        let (n_out, n_tok, blank, max_symbols) = {
            let d = &self.w.dims;
            (d.n_out, d.n_tok, d.blank, d.max_symbols)
        };
        let cfg = self.cfg.clone();
        for l in 0..self.w.dims.n_layers {
            self.s.h[l].fill(0.0);
            self.s.c[l].fill(0.0);
        }
        self.s.tok_logits.clear();
        let mut work = Work {
            n_frames,
            ..Work::default()
        };
        if cfg.precompute {
            self.precompute(enc, n_frames);
        }
        laps.lap(&mut prof.setup_us);

        let mut t = 0usize;
        let mut emitted = 0usize;
        let mut last = blank;
        let mut pending = true;
        let mut fresh_state = true;
        let (mut win_start, mut win_len) = (0usize, 0usize);
        while t < n_frames {
            if pending {
                laps.lap(&mut prof.serial_us);
                self.predict(last);
                laps.lap(&mut prof.predict_us);
                work.n_pred += 1;
                pending = false;
                fresh_state = true;
                win_len = 0;
            }
            let col = if t >= win_start && t < win_start + win_len {
                t - win_start
            } else {
                let k = if fresh_state {
                    cfg.spec_k_token
                } else {
                    cfg.spec_k
                }
                .min(n_frames - t);
                laps.lap(&mut prof.serial_us);
                self.joint(enc, t, k);
                laps.lap(&mut prof.joint_us);
                work.n_cols += k;
                win_start = t;
                win_len = k;
                0
            };
            fresh_state = false;
            work.n_steps += 1;

            let row = &self.s.logits[col * n_out..(col + 1) * n_out];
            let best = if cfg.raw_argmax {
                self.token_argmax(col)
            } else {
                simd::log_softmax(row, &mut self.s.lp);
                simd::argmax_native(&self.s.lp[..n_tok]).0
            };
            let dur_idx = simd::argmax_duration(&row[n_tok..]);
            let mut duration = self.w.dims.durations[dur_idx] as usize;
            if let Some(tr) = trace.as_deref_mut() {
                tr.push(StepTrace {
                    t,
                    token: best,
                    dur_idx,
                    tok_margin: simd::top2_margin(&row[..n_tok]),
                    dur_margin: simd::top2_margin(&row[n_tok..]),
                });
            }
            if best == blank {
                if duration == 0 {
                    duration = 1;
                }
                t += duration;
                emitted = 0;
                continue;
            }
            let (prob, plog) = if !cfg.raw_argmax {
                (simd::token_p(&self.s.lp, n_tok, best), self.s.lp[best])
            } else if cfg.defer_probs {
                self.s.tok_logits.extend_from_slice(row);
                (f32::NAN, f32::NAN)
            } else {
                let row = &self.s.logits[col * n_out..(col + 1) * n_out];
                simd::token_p_plog(row, n_tok, best, &mut self.s.lp)
            };
            out.push(Token {
                id: best as i32,
                frame_index: t as i32,
                duration_idx: dur_idx as i32,
                duration: duration as i32,
                p: prob,
                plog,
            });
            last = best;
            pending = true;
            if duration > 0 {
                t += duration;
                emitted = 0;
            } else {
                emitted += 1;
                if emitted >= max_symbols {
                    t += 1;
                    emitted = 0;
                }
            }
        }
        laps.lap(&mut prof.serial_us);
        if cfg.raw_argmax && cfg.defer_probs {
            self.finish_probs(out);
        }
        laps.lap(&mut prof.probs_us);
        work.n_tokens = out.len();
        work
    }

    /// Runs `f(part)` on every participant.
    fn par(&self, f: &(impl Fn(usize) + Sync)) {
        match &self.pool {
            Some(pool) => pool.run(f),
            None => f(0),
        }
    }

    /// `encproj[t] = enc_w·enc[t] + enc_b` for every frame.
    fn precompute(&mut self, enc: &[f32], n_frames: usize) {
        let (p, s) = (self.w.dims.p, self.w.dims.s);
        if self.s.encproj.len() < n_frames * p {
            self.s.encproj.resize(n_frames * p, 0.0);
        }
        let backend = self.cfg.backend;
        let out = SyncPtr(self.s.encproj.as_mut_ptr());
        let w = &self.w;
        if backend == Backend::Accelerate {
            let MatData::F32(v) = &w.enc_w.data else {
                unreachable!("accel weights are f32")
            };
            unsafe { accel::gemm_nt(enc.as_ptr(), n_frames, v.as_ptr(), p, s, out.get()) };
            for t in 0..n_frames {
                for (o, &b) in self.s.encproj[t * p..(t + 1) * p].iter_mut().zip(&w.enc_b) {
                    *o += b;
                }
            }
            return;
        }
        let parts = self.parts();
        let xq = if w.format() == Format::Q8 {
            let qb = q8_bytes(s);
            if self.s.enc_q.len() < n_frames * qb {
                self.s.enc_q.resize(n_frames * qb, 0);
            }
            let q = SyncPtr(self.s.enc_q.as_mut_ptr());
            self.par(&|part| {
                for t in split(n_frames, parts, part, 1) {
                    let dst = unsafe { std::slice::from_raw_parts_mut(q.get().add(t * qb), qb) };
                    kernels::quantize_act_q8_0(&enc[t * s..(t + 1) * s], dst);
                }
            });
            SyncConst(self.s.enc_q.as_ptr())
        } else {
            SyncConst(std::ptr::null())
        };
        const BLOCK: usize = 16;
        let next = AtomicUsize::new(0);
        let x = SyncConst(enc.as_ptr());
        self.par(&|_part| {
            loop {
                let b = next.fetch_add(1, Relaxed);
                let rows = b * BLOCK..((b + 1) * BLOCK).min(p);
                if rows.start >= p {
                    break;
                }
                unsafe {
                    mat_cols(
                        &w.enc_w,
                        backend,
                        x.get(),
                        s,
                        xq.get(),
                        n_frames,
                        out.get().add(rows.start),
                        p,
                        rows.clone(),
                    );
                    for t in 0..n_frames {
                        for r in rows.clone() {
                            *out.get().add(t * p + r) += w.enc_b[r];
                        }
                    }
                }
            }
        });
    }

    /// One prediction step for `token`: both LSTM layers, then `pred = pred_w·h + pred_b`.
    fn predict(&mut self, token: usize) {
        let p = self.w.dims.p;
        let n_layers = self.w.dims.n_layers;
        let q8 = self.w.format() == Format::Q8;
        let backend = self.cfg.backend;
        let parts = self.parts();
        let mut x0 = std::mem::take(&mut self.s.x0);
        self.w.embed_row(token, &mut x0);
        self.s.x0 = x0;
        for l in 0..n_layers {
            let x: *const f32 = if l == 0 {
                self.s.x0.as_ptr()
            } else {
                self.s.h_next[l - 1].as_ptr()
            };
            if q8 {
                let xs = unsafe { std::slice::from_raw_parts(x, p) };
                kernels::quantize_act_q8_0(xs, &mut self.s.x_q);
                kernels::quantize_act_q8_0(&self.s.h[l], &mut self.s.h_q);
            }
            let (x, h) = (SyncConst(x), SyncConst(self.s.h[l].as_ptr()));
            let (xq, hq) = (
                SyncConst(self.s.x_q.as_ptr()),
                SyncConst(self.s.h_q.as_ptr()),
            );
            let gates = SyncPtr(self.s.gates.as_mut_ptr());
            let gates_hh = SyncPtr(self.s.gates_hh.as_mut_ptr());
            let c = SyncPtr(self.s.c[l].as_mut_ptr());
            let hn = SyncPtr(self.s.h_next[l].as_mut_ptr());
            let (w_ih, w_hh, b) = (&self.w.w_ih[l], &self.w.w_hh[l], &self.w.b_h[l]);
            self.par(&|part| {
                let units = split(p, parts, part, 4);
                if units.is_empty() {
                    return;
                }
                unsafe {
                    if backend == Backend::Accelerate {
                        // Whole matrices at once (Accelerate picks its own blocking).
                        mat_rows(w_ih, backend, x.get(), xq.get(), gates.get(), 0..4 * p);
                        mat_rows(w_hh, backend, h.get(), hq.get(), gates_hh.get(), 0..4 * p);
                        for r in 0..4 * p {
                            *gates.get().add(r) += *gates_hh.get().add(r) + b[r];
                        }
                    } else {
                        for g in 0..4 {
                            let rows = g * p + units.start..g * p + units.end;
                            mat_rows(
                                w_ih,
                                backend,
                                x.get(),
                                xq.get(),
                                gates.get().add(rows.start),
                                rows.clone(),
                            );
                            mat_rows(
                                w_hh,
                                backend,
                                h.get(),
                                hq.get(),
                                gates_hh.get().add(rows.start),
                                rows.clone(),
                            );
                            for r in rows {
                                *gates.get().add(r) += *gates_hh.get().add(r) + b[r];
                            }
                        }
                    }
                    cell_update(gates.get(), p, units, c.get(), hn.get());
                }
            });
        }
        for l in 0..n_layers {
            std::mem::swap(&mut self.s.h[l], &mut self.s.h_next[l]);
        }
        let top = SyncConst(self.s.h[n_layers - 1].as_ptr());
        if q8 {
            kernels::quantize_act_q8_0(&self.s.h[n_layers - 1], &mut self.s.h_q);
        }
        let hq = SyncConst(self.s.h_q.as_ptr());
        let pred = SyncPtr(self.s.pred.as_mut_ptr());
        let (pw, pb) = (&self.w.pred_w, &self.w.pred_b);
        let single = backend == Backend::Accelerate;
        self.par(&|part| {
            let rows = if single {
                0..p
            } else {
                split(p, parts, part, 4)
            };
            unsafe {
                mat_rows(
                    pw,
                    backend,
                    top.get(),
                    hq.get(),
                    pred.get().add(rows.start),
                    rows.clone(),
                );
                for r in rows {
                    *pred.get().add(r) += pb[r];
                }
            }
        });
    }

    /// Logits for frames `t..t + k` under the current predictor state (one `joint_net` pass),
    /// plus each participant's token first-maximum per column when the argmax is raw.
    fn joint(&mut self, enc: &[f32], t: usize, k: usize) {
        let (p, s, n_out, n_tok) = (
            self.w.dims.p,
            self.w.dims.s,
            self.w.dims.n_out,
            self.w.dims.n_tok,
        );
        let backend = self.cfg.backend;
        let parts = self.parts();
        let q8 = self.w.format() == Format::Q8;
        if k > self.s.kcap {
            self.s.kcap = k;
            self.s.hidden.resize(k * p, 0.0);
            self.s.hidden_q.resize(k * q8_bytes(p), 0);
            self.s.logits.resize(k * n_out, 0.0);
            self.s.partial.resize(parts * k, (0, 0.0));
        }
        // Encoder projection of the window's frames: precomputed, or one matvec per frame.
        let e_base: *const f32 = if self.cfg.precompute {
            self.s.encproj[t * p..].as_ptr()
        } else {
            if self.s.encproj.len() < k * p {
                self.s.encproj.resize(k * p, 0.0);
            }
            for j in 0..k {
                let frame = &enc[(t + j) * s..(t + j + 1) * s];
                if q8 {
                    kernels::quantize_act_q8_0(frame, &mut self.s.x_q);
                }
                let (x, xq) = (SyncConst(frame.as_ptr()), SyncConst(self.s.x_q.as_ptr()));
                let out = SyncPtr(self.s.encproj[j * p..].as_mut_ptr());
                let (ew, eb) = (&self.w.enc_w, &self.w.enc_b);
                let single = backend == Backend::Accelerate;
                self.par(&|part| {
                    let rows = if single {
                        0..p
                    } else {
                        split(p, parts, part, 4)
                    };
                    unsafe {
                        mat_rows(
                            ew,
                            backend,
                            x.get(),
                            xq.get(),
                            out.get().add(rows.start),
                            rows.clone(),
                        );
                        for r in rows {
                            *out.get().add(r) += eb[r];
                        }
                    }
                });
            }
            self.s.encproj.as_ptr()
        };
        for j in 0..k {
            let e = unsafe { std::slice::from_raw_parts(e_base.add(j * p), p) };
            let hidden = &mut self.s.hidden[j * p..(j + 1) * p];
            for ((hv, &ev), &pv) in hidden.iter_mut().zip(e).zip(&self.s.pred) {
                *hv = relu(ev + pv);
            }
            if q8 {
                let qb = q8_bytes(p);
                kernels::quantize_act_q8_0(
                    &self.s.hidden[j * p..(j + 1) * p],
                    &mut self.s.hidden_q[j * qb..(j + 1) * qb],
                );
            }
        }
        let hidden = SyncConst(self.s.hidden.as_ptr());
        let hq = SyncConst(self.s.hidden_q.as_ptr());
        let logits = SyncPtr(self.s.logits.as_mut_ptr());
        let partial = SyncPtr(self.s.partial.as_mut_ptr());
        let kmax = self.s.kcap;
        let raw = self.cfg.raw_argmax;
        let (nw, nb) = (&self.w.net_w, &self.w.net_b);
        let single = backend == Backend::Accelerate;
        self.par(&|part| {
            let rows = if single {
                0..n_out
            } else {
                split(n_out, parts, part, 4)
            };
            unsafe {
                mat_cols(
                    nw,
                    backend,
                    hidden.get(),
                    p,
                    hq.get(),
                    k,
                    logits.get().add(rows.start),
                    n_out,
                    rows.clone(),
                );
                for j in 0..k {
                    let row = std::slice::from_raw_parts_mut(logits.get().add(j * n_out), n_out);
                    for r in rows.clone() {
                        row[r] += nb[r];
                    }
                    if raw {
                        let tok = rows.start.min(n_tok)..rows.end.min(n_tok);
                        *partial.get().add(part * kmax + j) = if tok.is_empty() {
                            (0, f32::NEG_INFINITY)
                        } else {
                            let (i, v) = simd::first_max(&row[tok.clone()]);
                            (tok.start + i, v)
                        };
                    }
                }
            }
        });
    }

    /// Native token argmax of column `col` from the participants' partial maxima.
    fn token_argmax(&self, col: usize) -> usize {
        let kmax = self.s.kcap;
        let parts = if self.cfg.backend == Backend::Accelerate {
            1
        } else {
            self.parts()
        };
        let combined =
            simd::combine_partials((0..parts).map(|part| self.s.partial[part * kmax + col]));
        match combined {
            Some((best, _)) => best,
            None => {
                let n_out = self.w.dims.n_out;
                simd::argmax_native_scalar(
                    &self.s.logits[col * n_out..col * n_out + self.w.dims.n_tok],
                )
                .0
            }
        }
    }

    /// Deferred `p`/`plog`: every saved token row through [`simd::token_p_plog`], tokens
    /// spread over the participants.
    fn finish_probs(&mut self, out: &mut [Token]) {
        let (n_out, n_tok) = (self.w.dims.n_out, self.w.dims.n_tok);
        let parts = self.parts();
        let n = out.len();
        debug_assert_eq!(self.s.tok_logits.len(), n * n_out);
        let rows = SyncConst(self.s.tok_logits.as_ptr());
        let lp = SyncPtr(self.s.lp_parts.as_mut_ptr());
        let toks = SyncPtr(out.as_mut_ptr());
        self.par(&|part| {
            let mut i = part;
            while i < n {
                unsafe {
                    let row = std::slice::from_raw_parts(rows.get().add(i * n_out), n_out);
                    let scratch = std::slice::from_raw_parts_mut(lp.get().add(part * n_out), n_out);
                    let tok = &mut *toks.get().add(i);
                    let (pr, pl) = simd::token_p_plog(row, n_tok, tok.id as usize, scratch);
                    tok.p = pr;
                    tok.plog = pl;
                }
                i += parts;
            }
        });
    }

    /// Logits of `k` frames from `t` computed one column at a time and as one batch, for the
    /// spec bit-identity test. Returns `(single, batched)`.
    #[doc(hidden)]
    pub fn probe_window(
        &mut self,
        enc: &[f32],
        n_frames: usize,
        token: usize,
        t: usize,
        k: usize,
    ) -> (Vec<f32>, Vec<f32>) {
        let n_out = self.w.dims.n_out;
        for l in 0..self.w.dims.n_layers {
            self.s.h[l].fill(0.0);
            self.s.c[l].fill(0.0);
        }
        if let Some(pool) = &self.pool {
            pool.wake();
        }
        if self.cfg.precompute {
            self.precompute(enc, n_frames);
        }
        self.predict(token);
        let mut single = Vec::new();
        for j in 0..k {
            self.joint(enc, t + j, 1);
            single.extend_from_slice(&self.s.logits[..n_out]);
        }
        self.joint(enc, t, k);
        let batched = self.s.logits[..k * n_out].to_vec();
        if let Some(pool) = &self.pool {
            pool.sleep();
        }
        (single, batched)
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // Join worker threads (Rust pool, C engine) before the weights they borrow go away.
        self.c.take();
        self.pool.take();
    }
}
