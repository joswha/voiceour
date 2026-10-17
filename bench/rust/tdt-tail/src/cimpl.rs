//! FFI to the C11 control (`c/vt_c.c`), the `c-best` arm. The Rust side owns the fp16 weights
//! (the same buffers `best` computes with) and the C engine borrows them.

use std::ffi::c_void;

use crate::engine::{Config, Token, Work};
use crate::weights::{MatData, Weights};

const MAX_LAYERS: usize = 4;

#[repr(C)]
struct VtcModel {
    p: usize,
    s: usize,
    n_tok: usize,
    blank: usize,
    n_out: usize,
    n_layers: usize,
    max_symbols: usize,
    durations: *const i32,
    embed: *const u16,
    w_ih: [*const u16; MAX_LAYERS],
    w_hh: [*const u16; MAX_LAYERS],
    b_h: [*const f32; MAX_LAYERS],
    pred_w: *const u16,
    pred_b: *const f32,
    enc_w: *const u16,
    enc_b: *const f32,
    net_w: *const u16,
    net_b: *const f32,
}

#[repr(C)]
#[derive(Default)]
struct VtcWork {
    n_frames: usize,
    n_tokens: usize,
    n_steps: usize,
    n_pred: usize,
    n_cols: usize,
}

unsafe extern "C" {
    fn vtc_engine_new(
        m: *const VtcModel,
        threads: usize,
        spec_k: usize,
        spec_k_token: usize,
        spin_us: u64,
    ) -> *mut c_void;
    fn vtc_decode(
        e: *mut c_void,
        enc: *const f32,
        n_frames: usize,
        tokens: *mut *const Token,
        work: *mut VtcWork,
    ) -> i32;
    fn vtc_engine_free(e: *mut c_void);
}

/// A C engine over weights owned by the enclosing [`crate::Engine`] (which drops it first).
pub struct CEngine {
    raw: *mut c_void,
    _durations: Box<[i32]>,
}

// SAFETY: the handle is used from one thread at a time (vt handles are single-threaded).
unsafe impl Send for CEngine {}

fn f16(data: &MatData) -> Result<*const u16, String> {
    match data {
        MatData::F16(v) => Ok(v.as_ptr()),
        _ => Err("the C control needs fp16 weights".into()),
    }
}

impl CEngine {
    pub fn new(w: &Weights, cfg: &Config) -> Result<CEngine, String> {
        let d = &w.dims;
        if d.n_layers > MAX_LAYERS {
            return Err(format!(
                "the C control supports at most {MAX_LAYERS} LSTM layers"
            ));
        }
        let durations: Box<[i32]> = d.durations.clone().into_boxed_slice();
        let mut model = VtcModel {
            p: d.p,
            s: d.s,
            n_tok: d.n_tok,
            blank: d.blank,
            n_out: d.n_out,
            n_layers: d.n_layers,
            max_symbols: d.max_symbols,
            durations: durations.as_ptr(),
            embed: w.embed.as_ptr(),
            w_ih: [std::ptr::null(); MAX_LAYERS],
            w_hh: [std::ptr::null(); MAX_LAYERS],
            b_h: [std::ptr::null(); MAX_LAYERS],
            pred_w: f16(&w.pred_w.data)?,
            pred_b: w.pred_b.as_ptr(),
            enc_w: f16(&w.enc_w.data)?,
            enc_b: w.enc_b.as_ptr(),
            net_w: f16(&w.net_w.data)?,
            net_b: w.net_b.as_ptr(),
        };
        for l in 0..d.n_layers {
            model.w_ih[l] = f16(&w.w_ih[l].data)?;
            model.w_hh[l] = f16(&w.w_hh[l].data)?;
            model.b_h[l] = w.b_h[l].as_ptr();
        }
        // SAFETY: the model struct is copied by the C side; the buffers it points to live in
        // `w`, which outlives this engine.
        let raw = unsafe {
            vtc_engine_new(
                &model,
                cfg.threads,
                cfg.spec_k,
                cfg.spec_k_token,
                cfg.spin_us,
            )
        };
        if raw.is_null() {
            return Err("vtc_engine_new failed (allocation or thread creation)".into());
        }
        Ok(CEngine {
            raw,
            _durations: durations,
        })
    }

    pub fn decode(
        &mut self,
        enc: &[f32],
        n_frames: usize,
        out: &mut Vec<Token>,
    ) -> Result<Work, String> {
        let mut tokens: *const Token = std::ptr::null();
        let mut work = VtcWork::default();
        // SAFETY: `enc` holds `n_frames · s` floats (checked by the caller).
        let n = unsafe { vtc_decode(self.raw, enc.as_ptr(), n_frames, &mut tokens, &mut work) };
        if n < 0 {
            return Err("vtc_decode: allocation failure".into());
        }
        if n > 0 {
            // SAFETY: the C engine owns `n` tokens at `tokens` until its next call.
            out.extend_from_slice(unsafe { std::slice::from_raw_parts(tokens, n as usize) });
        }
        Ok(Work {
            n_frames: work.n_frames,
            n_tokens: work.n_tokens,
            n_steps: work.n_steps,
            n_pred: work.n_pred,
            n_cols: work.n_cols,
        })
    }
}

impl Drop for CEngine {
    fn drop(&mut self) {
        unsafe { vtc_engine_free(self.raw) };
    }
}
