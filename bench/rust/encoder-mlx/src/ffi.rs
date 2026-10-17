//! C ABI (`libencoder_mlx.dylib`, prefix `ve_`). Handles are single-threaded; no panic crosses
//! the boundary: every entry point catches it and reports through `err`.
//!
//! ```c
//! int32_t ve_abi_version(void);                         // 1
//! const char *ve_arms(void);                            // "f32,f16,compiled-f32,..."
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
use std::path::Path;
use std::slice;

use crate::engine::{Engine, N_MELS, N_STATE, n_enc_frames};

/// Must equal `Arm::NAMES`; checked by a unit test.
static ARMS: &CStr =
    c"f32,f16,compiled-f32,compiled-f16,f32-mm16,compiled-f32-mm16,f32-sdpa,f16-manual";

#[cfg(test)]
#[test]
fn exported_arms_match_the_engine() {
    use crate::engine::Arm;
    assert_eq!(ARMS.to_str().unwrap(), Arm::NAMES);
    let names: Vec<&str> = Arm::ALL.iter().map(|arm| arm.name).collect();
    assert_eq!(names.join(","), Arm::NAMES);
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

fn c_str<'a>(ptr: *const c_char, what: &str) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err(format!("{what} is null"));
    }
    // SAFETY: the caller passes a NUL-terminated string.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| format!("{what} is not UTF-8"))
}

#[unsafe(no_mangle)]
pub extern "C" fn ve_abi_version() -> i32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn ve_arms() -> *const c_char {
    ARMS.as_ptr()
}

/// Loads the model (mmap, native validation) and uploads its encoder weights to MLX for `arm`.
/// Engines of one precision created on one thread share the uploaded weights.
///
/// # Safety
/// `model_path` and `arm` are NUL-terminated strings; `err` is null or holds `err_len` writable
/// bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ve_engine_new(
    model_path: *const c_char,
    arm: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> *mut Engine {
    guarded(err, err_len, std::ptr::null_mut(), || {
        let path = c_str(model_path, "model_path")?;
        let arm = c_str(arm, "arm")?;
        Ok(Box::into_raw(Box::new(Engine::new(Path::new(path), arm)?)))
    })
}

/// One utterance: host mel -> MLX graph -> one `eval` -> host states.
///
/// # Safety
/// `engine` came from `ve_engine_new`; `mel` holds `n_mel_frames * n_mels` floats; `out` holds
/// `max_enc_frames * n_state` writable floats; `err` is null or holds `err_len` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ve_encode(
    engine: *mut Engine,
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
        if engine.is_null() || mel.is_null() || out.is_null() {
            return Err("null engine, mel or out".to_owned());
        }
        if n_mels != N_MELS as i32 || n_state != N_STATE as i32 {
            return Err(format!(
                "n_mels {n_mels} / n_state {n_state}, expected {N_MELS} / {N_STATE}"
            ));
        }
        if n_mel_frames <= 0 || max_enc_frames < 0 {
            return Err(format!(
                "n_mel_frames {n_mel_frames}, max_enc_frames {max_enc_frames}"
            ));
        }
        let n_mel_frames = n_mel_frames as usize;
        let needed = n_enc_frames(n_mel_frames);
        if needed > max_enc_frames as usize {
            return Err(format!(
                "{needed} encoder frames do not fit max_enc_frames {max_enc_frames}"
            ));
        }
        // SAFETY: the caller guarantees the buffer sizes documented above.
        let mel = unsafe { slice::from_raw_parts(mel, n_mel_frames * N_MELS) };
        let out = unsafe { slice::from_raw_parts_mut(out, max_enc_frames as usize * N_STATE) };
        // SAFETY: `engine` came from `ve_engine_new` and is used by one thread at a time.
        let engine = unsafe { &mut *engine };
        let frames = engine.encode(mel, n_mel_frames, out)?;
        i32::try_from(frames).map_err(|_| "frame count overflow".to_owned())
    })
}

/// # Safety
/// `engine` came from `ve_engine_new` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ve_engine_free(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: `engine` came from `Box::into_raw` in `ve_engine_new`.
        drop(unsafe { Box::from_raw(engine) });
    }));
}
