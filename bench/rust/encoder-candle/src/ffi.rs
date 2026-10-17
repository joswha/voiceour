//! C ABI (`libencoder_candle.dylib`, prefix `ve_`), exactly as the program contract defines it.
//! Handles are single-threaded; no panic crosses the boundary: every entry point catches it and
//! reports through `err`.
//!
//! ```c
//! int32_t ve_abi_version(void);                       // 1
//! const char *ve_arms(void);                          // "f32,f16,bf16,f16w,q8_0,...+fused"
//! typedef struct ve_engine ve_engine;
//! ve_engine *ve_engine_new(const char *model_path, const char *arm, char *err, size_t err_len);
//! // mel: frame-major [n_mel_frames][n_mels]; out: frame-major [n_enc_frames][n_state].
//! // Returns n_enc_frames or -1.
//! int32_t ve_encode(ve_engine *, const float *mel, int32_t n_mel_frames, int32_t n_mels,
//!                   float *out, int32_t max_enc_frames, int32_t n_state, char *err, size_t err_len);
//! void ve_engine_free(ve_engine *);
//! ```

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

use crate::arm::{ARM_NAMES_C, Arm};
use crate::engine::Encoder;

/// Opaque engine handle.
#[allow(non_camel_case_types)]
pub struct ve_engine {
    encoder: Encoder,
}

fn write_error(err: *mut c_char, err_len: usize, message: &str) {
    if err.is_null() || err_len == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let count = bytes.len().min(err_len - 1);
    // SAFETY: the caller provides `err_len` writable bytes at `err`.
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), err.cast::<u8>(), count);
        *err.add(count) = 0;
    }
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&str>() {
        format!("panic: {text}")
    } else if let Some(text) = payload.downcast_ref::<String>() {
        format!("panic: {text}")
    } else {
        "panic".to_owned()
    }
}

/// Runs `body`, mapping an error or a panic to `failure` plus a message in `err`.
fn guarded<T>(
    err: *mut c_char,
    err_len: usize,
    failure: T,
    body: impl FnOnce() -> Result<T, String>,
) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => value,
        Ok(Err(message)) => {
            write_error(err, err_len, &message);
            failure
        }
        Err(payload) => {
            write_error(err, err_len, &panic_message(payload.as_ref()));
            failure
        }
    }
}

/// # Safety
/// `text` must be null or a NUL-terminated string.
unsafe fn c_str<'a>(text: *const c_char, what: &str) -> Result<&'a str, String> {
    if text.is_null() {
        return Err(format!("{what} is null"));
    }
    // SAFETY: per the contract above.
    unsafe { CStr::from_ptr(text) }
        .to_str()
        .map_err(|_| format!("{what} is not UTF-8"))
}

#[unsafe(no_mangle)]
pub extern "C" fn ve_abi_version() -> i32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn ve_arms() -> *const c_char {
    ARM_NAMES_C.as_ptr()
}

/// # Safety
/// `model_path` and `arm` are NUL-terminated strings; `err` holds `err_len` bytes or is null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ve_engine_new(
    model_path: *const c_char,
    arm: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> *mut ve_engine {
    guarded(err, err_len, std::ptr::null_mut(), || {
        // SAFETY: forwarded caller contract.
        let path = unsafe { c_str(model_path, "model_path") }?;
        let name = unsafe { c_str(arm, "arm") }?;
        let arm = Arm::parse(name)
            .ok_or_else(|| format!("unknown arm {name:?}; arms: {}", crate::ARM_NAMES))?;
        let encoder = Encoder::open(path, arm).map_err(|e| e.to_string())?;
        Ok(Box::into_raw(Box::new(ve_engine { encoder })))
    })
}

/// # Safety
/// `engine` comes from `ve_engine_new`; `mel` holds `n_mel_frames * n_mels` floats; `out` holds
/// `max_enc_frames * n_state` floats; `err` holds `err_len` bytes or is null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ve_encode(
    engine: *mut ve_engine,
    mel: *const f32,
    n_mel_frames: i32,
    n_mels: i32,
    out: *mut f32,
    max_enc_frames: i32,
    n_state: i32,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    guarded(err, err_len, -1, || {
        // SAFETY: the caller passes a live handle.
        let engine = unsafe { engine.as_ref() }.ok_or("engine is null")?;
        let encoder = &engine.encoder;
        if mel.is_null() || out.is_null() {
            return Err("mel or out is null".to_owned());
        }
        if n_mel_frames <= 0 || max_enc_frames < 0 {
            return Err(format!(
                "bad sizes: n_mel_frames {n_mel_frames}, max_enc_frames {max_enc_frames}"
            ));
        }
        if n_mels as usize != encoder.n_mels() || n_state as usize != encoder.n_state() {
            return Err(format!(
                "model wants n_mels {} and n_state {}, got {n_mels} and {n_state}",
                encoder.n_mels(),
                encoder.n_state()
            ));
        }
        let n_frames = n_mel_frames as usize;
        let n_enc = Encoder::enc_frames(n_frames);
        if n_enc > max_enc_frames as usize {
            return Err(format!(
                "{n_enc} encoder frames do not fit max_enc_frames {max_enc_frames}"
            ));
        }
        // SAFETY: sizes per the contract above.
        let mel = unsafe { slice::from_raw_parts(mel, n_frames * encoder.n_mels()) };
        let out =
            unsafe { slice::from_raw_parts_mut(out, max_enc_frames as usize * encoder.n_state()) };
        let written = encoder
            .encode(mel, n_frames, out)
            .map_err(|e| e.to_string())?;
        Ok(written as i32)
    })
}

/// # Safety
/// `engine` comes from `ve_engine_new` and is not used afterwards; null is a no-op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ve_engine_free(engine: *mut ve_engine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the pointer came from Box::into_raw in ve_engine_new.
        drop(unsafe { Box::from_raw(engine) });
    }));
}
