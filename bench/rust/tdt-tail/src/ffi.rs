//! C ABI (`libtdt_tail.dylib`, prefix `vt_`), exactly the program contract's tail ABI. Handles are
//! single-threaded; no panic crosses the boundary: every entry point catches it and reports
//! through `err`.
//!
//! ```c
//! int32_t vt_abi_version(void);                 // 1
//! const char *vt_arms(void);                    // "naive,precompute,...,best,c-best"
//! typedef struct vt_engine vt_engine;
//! typedef struct { int32_t id, frame_index, duration_idx, duration; float p, plog; } vt_token;
//! vt_engine *vt_engine_new(const char *model_path, const char *arm, char *err, size_t err_len);
//! // enc: frame-major [n_frames][n_state] f32. Returns token count (<= max_tokens) or -1.
//! int32_t vt_decode(vt_engine *, const float *enc, int32_t n_frames, int32_t n_state,
//!                   vt_token *out, int32_t max_tokens, char *err, size_t err_len);
//! void vt_engine_free(vt_engine *);
//! ```

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

use crate::engine::{Engine, Token};

static ARMS_C: &CStr = c"naive,precompute,rawargmax,f16w,mt,spec,accel,q8,best,c-best";

/// The handle behind `vt_engine *`: an engine plus its reusable token buffer.
pub struct VtEngine {
    engine: Engine,
    tokens: Vec<Token>,
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

unsafe fn c_str<'a>(p: *const c_char, what: &str) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(format!("{what} is NULL"));
    }
    // SAFETY: the caller passes a NUL-terminated string.
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| format!("{what} is not UTF-8"))
}

#[unsafe(no_mangle)]
pub extern "C" fn vt_abi_version() -> i32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn vt_arms() -> *const c_char {
    ARMS_C.as_ptr()
}

/// # Safety
/// `model_path` and `arm` are NUL-terminated strings; `err` holds `err_len` bytes (or is NULL).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vt_engine_new(
    model_path: *const c_char,
    arm: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> *mut VtEngine {
    guarded(err, err_len, std::ptr::null_mut(), || {
        let path = unsafe { c_str(model_path, "model_path") }?;
        let arm = unsafe { c_str(arm, "arm") }?;
        let engine = Engine::new(Path::new(path), arm)?;
        Ok(Box::into_raw(Box::new(VtEngine {
            engine,
            tokens: Vec::new(),
        })))
    })
}

/// # Safety
/// `engine` came from `vt_engine_new`; `enc` holds `n_frames · n_state` floats; `out` holds
/// `max_tokens` tokens; `err` holds `err_len` bytes (or is NULL).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vt_decode(
    engine: *mut VtEngine,
    enc: *const f32,
    n_frames: i32,
    n_state: i32,
    out: *mut Token,
    max_tokens: i32,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    guarded(err, err_len, -1, || {
        if engine.is_null() {
            return Err("engine is NULL".into());
        }
        if n_frames < 0 || n_state <= 0 || max_tokens < 0 {
            return Err(format!(
                "bad sizes: n_frames {n_frames}, n_state {n_state}, max_tokens {max_tokens}"
            ));
        }
        if (enc.is_null() && n_frames > 0) || (out.is_null() && max_tokens > 0) {
            return Err("enc or out is NULL".into());
        }
        // SAFETY: a live handle, used from one thread (the contract).
        let handle = unsafe { &mut *engine };
        let (n_frames, n_state) = (n_frames as usize, n_state as usize);
        let enc: &[f32] = if n_frames == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(enc, n_frames * n_state) }
        };
        handle
            .engine
            .decode(enc, n_frames, n_state, &mut handle.tokens, None)?;
        let n = handle.tokens.len();
        if n > max_tokens as usize {
            return Err(format!(
                "decode produced {n} tokens but max_tokens is {max_tokens}"
            ));
        }
        // SAFETY: `out` holds `max_tokens >= n` tokens.
        unsafe { std::ptr::copy_nonoverlapping(handle.tokens.as_ptr(), out, n) };
        Ok(n as i32)
    })
}

/// # Safety
/// `engine` came from `vt_engine_new` (or is NULL) and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vt_engine_free(engine: *mut VtEngine) {
    if !engine.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(engine) })));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_arms_match_the_engine_table() {
        assert_eq!(ARMS_C.to_str().unwrap(), crate::engine::ARMS);
        assert_eq!(std::mem::size_of::<Token>(), 24);
        assert_eq!(std::mem::align_of::<Token>(), 4);
    }

    #[test]
    fn errors_are_reported_through_err() {
        let mut buf = [0 as c_char; 256];
        let e = unsafe {
            vt_engine_new(
                c"/nonexistent/model.bin".as_ptr(),
                c"best".as_ptr(),
                buf.as_mut_ptr(),
                buf.len(),
            )
        };
        assert!(e.is_null());
        let msg = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert!(msg.contains("nonexistent"), "{msg}");
        let e = unsafe {
            vt_engine_new(
                c"/x".as_ptr(),
                c"nope".as_ptr(),
                buf.as_mut_ptr(),
                buf.len(),
            )
        };
        assert!(e.is_null());
        let msg = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert!(msg.contains("unknown arm"), "{msg}");
        let rc = unsafe {
            vt_decode(
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
                1024,
                std::ptr::null_mut(),
                0,
                buf.as_mut_ptr(),
                buf.len(),
            )
        };
        assert_eq!(rc, -1);
    }
}
