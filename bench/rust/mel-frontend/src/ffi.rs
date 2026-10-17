//! The `vm_` C ABI (shared contract, "C ABIs"): `libmel_frontend.dylib`, loaded by
//! `voiceour-bench mel-bench --rust-mel-lib`.
//!
//! ```c
//! int32_t vm_abi_version(void);                // 1
//! const char * vm_arms(void);                  // static, comma-separated
//! vm_engine * vm_engine_new(const char * model_path, const char * arm, char * err, size_t err_len);
//! int32_t vm_compute(vm_engine *, const float * samples, int32_t n_samples, float * out,
//!                    int32_t max_frames, int32_t n_mels, char * err, size_t err_len);
//! void vm_engine_free(vm_engine *);
//! ```
//! `vm_compute` returns the frame count (`n_samples / 160 + 1`) or -1 with `err` filled; it writes
//! nothing on failure. No call unwinds: panics become -1/NULL. A NULL `model_path` opens the
//! pinned model at its default path. Handles are single-threaded.

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::ptr::null_mut;
use std::sync::Arc;

use parakeet_model::pin;

use crate::engine::{ARM_NAMES, Arm, DEFAULT_THREADS, Engine};
use crate::frontend::Frontend;

/// Opaque engine handle.
#[allow(non_camel_case_types)]
pub struct vm_engine {
    engine: Engine,
}

impl vm_engine {
    /// Wraps an engine built through the Rust API (e.g. with a non-default thread count) so it
    /// can be driven through `vm_compute`.
    pub fn from_engine(engine: Engine) -> Box<vm_engine> {
        Box::new(vm_engine { engine })
    }

    pub fn engine(&self) -> &Engine {
        &self.engine
    }
}

const ARMS: &CStr = c"faithful,faithful-spawn,faithful-mt,sparse,best,realfft,vdsp,best-approx";

#[unsafe(no_mangle)]
pub extern "C" fn vm_abi_version() -> i32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn vm_arms() -> *const c_char {
    ARMS.as_ptr()
}

/// # Safety
/// `model_path` and `arm` are NULL or NUL-terminated; `err` is NULL or holds `err_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vm_engine_new(
    model_path: *const c_char,
    arm: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> *mut vm_engine {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Box<vm_engine>, String> {
        // SAFETY: the caller's contract.
        let arm_name = unsafe { c_str(arm) }?.ok_or("arm is NULL")?;
        let arm = Arm::parse(arm_name).ok_or_else(|| {
            format!(
                "unknown arm '{arm_name}'; this library has {}",
                ARM_NAMES.join(",")
            )
        })?;
        // SAFETY: the caller's contract.
        let path = match unsafe { c_str(model_path) }? {
            Some(path) => PathBuf::from(path),
            None => pin::default_model_path(),
        };
        let frontend = Arc::new(Frontend::open(&path)?);
        Ok(vm_engine::from_engine(Engine::new(
            frontend,
            arm,
            DEFAULT_THREADS,
        )?))
    }));
    match flatten(result) {
        Ok(engine) => Box::into_raw(engine),
        Err(message) => {
            // SAFETY: the caller's contract.
            unsafe { write_err(err, err_len, &message) };
            null_mut()
        }
    }
}

/// # Safety
/// `engine` comes from `vm_engine_new` and is not used concurrently; `samples` holds `n_samples`
/// floats (or is NULL with `n_samples == 0`); `out` holds `max_frames * n_mels` floats; `err` is
/// NULL or holds `err_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vm_compute(
    engine: *mut vm_engine,
    samples: *const f32,
    n_samples: i32,
    out: *mut f32,
    max_frames: i32,
    n_mels: i32,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<i32, String> {
        // SAFETY: the caller's contract.
        let engine = unsafe { engine.as_mut() }.ok_or("engine is NULL")?;
        let engine = &mut engine.engine;
        let expected_mels = engine.frontend().n_mels;
        if n_mels < 0 || n_mels as usize != expected_mels {
            return Err(format!("n_mels is {n_mels}; the model has {expected_mels}"));
        }
        if n_samples < 0 || max_frames < 0 {
            return Err(format!(
                "n_samples {n_samples} and max_frames {max_frames} must be >= 0"
            ));
        }
        if (samples.is_null() && n_samples > 0) || out.is_null() {
            return Err("samples or out is NULL".to_owned());
        }
        let n_frames = engine.frontend().n_frames(n_samples as usize);
        if n_frames > max_frames as usize {
            return Err(format!(
                "{n_samples} samples need {n_frames} frames; max_frames is {max_frames}"
            ));
        }
        let samples: &[f32] = if n_samples == 0 {
            &[]
        } else {
            // SAFETY: the caller's contract.
            unsafe { std::slice::from_raw_parts(samples, n_samples as usize) }
        };
        // SAFETY: the caller's contract; only the first `n_frames * n_mels` values are written.
        let out = unsafe { std::slice::from_raw_parts_mut(out, n_frames * expected_mels) };
        engine.compute(samples, out).map(|frames| frames as i32)
    }));
    match flatten(result) {
        Ok(frames) => frames,
        Err(message) => {
            // SAFETY: the caller's contract.
            unsafe { write_err(err, err_len, &message) };
            -1
        }
    }
}

/// # Safety
/// `engine` is NULL or comes from `vm_engine_new` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vm_engine_free(engine: *mut vm_engine) {
    if engine.is_null() {
        return;
    }
    // SAFETY: the caller's contract; a panic while dropping stays on this side.
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(engine) })));
}

/// # Safety
/// `value` is NULL or NUL-terminated.
unsafe fn c_str<'a>(value: *const c_char) -> Result<Option<&'a str>, String> {
    if value.is_null() {
        return Ok(None);
    }
    // SAFETY: the caller's contract.
    let value = unsafe { CStr::from_ptr(value) };
    value
        .to_str()
        .map(Some)
        .map_err(|_| "argument is not UTF-8".to_owned())
}

fn flatten<T>(result: std::thread::Result<Result<T, String>>) -> Result<T, String> {
    match result {
        Ok(inner) => inner,
        Err(panic) => Err(format!(
            "panic: {}",
            panic
                .downcast_ref::<&str>()
                .map(|text| (*text).to_owned())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "non-string payload".to_owned())
        )),
    }
}

/// Copies `message` into `err` as a NUL-terminated string, truncated to `err_len - 1` bytes.
///
/// # Safety
/// `err` is NULL or holds `err_len` bytes.
unsafe fn write_err(err: *mut c_char, err_len: usize, message: &str) {
    if err.is_null() || err_len == 0 {
        return;
    }
    let mut n = message.len().min(err_len - 1);
    while !message.is_char_boundary(n) {
        n -= 1;
    }
    // SAFETY: `n + 1 <= err_len` bytes of `err`.
    unsafe {
        std::ptr::copy_nonoverlapping(message.as_ptr(), err.cast::<u8>(), n);
        *err.add(n) = 0;
    }
}
