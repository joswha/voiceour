//! C ABI (`libmercury_raster.dylib`, prefix `mr_`). Handles are single-threaded; no panic
//! crosses the boundary: every entry point catches it and reports through `err`.
//!
//! ```c
//! int32_t mr_abi_version(void);                       // 1
//! const char *mr_arms(void);                          // "rust,rust-neon"
//! typedef struct mr_engine mr_engine;
//! // response: {exponent, halfSaturation, ceiling, sceneMedian, sceneHighlight}
//! mr_engine *mr_engine_new(uint64_t seed, const double *response, const char *arm,
//!                          char *err, size_t err_len);
//! // One production raster. Returns 0 drawn, 1 empty field (no image), -1 error.
//! int32_t mr_render(mr_engine *, const float *top, const float *bottom, int32_t stations,
//!                   double length, double lateral_offset, int32_t increased_contrast,
//!                   double scale, uint8_t *out, int32_t width, int32_t height,
//!                   int32_t bytes_per_row, char *err, size_t err_len);
//! void mr_engine_free(mr_engine *);
//! // Verification probes (never timed).
//! int32_t mr_engine_tables(const mr_engine *, float *out, size_t count); // levels*98*98*3
//! int32_t mr_engine_radiance(const mr_engine *, const float *direction, float *out);
//! int32_t mr_engine_display(mr_engine *, int32_t increased_contrast, const double *scene,
//!                           double *out);
//! void mr_probe_fresnel(double cosine, double *out);
//! double mr_probe_encode_srgb(double value);
//! uint8_t mr_probe_encoded_byte(double value, double coverage);
//! int32_t mr_probe_field_box(const float *top, const float *bottom, int32_t stations,
//!                            double length, double lateral_offset, double *out); // minX,maxX,minY,maxY
//! ```

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

use crate::environment::{LEVEL_STRIDE, LEVELS};
use crate::field::Field;
use crate::optics::OPTICS;
use crate::response::DisplayResponse;
use crate::{Arm, Engine, RenderStatus};

/// Must equal `Arm::NAMES`; checked by a unit test.
static ARMS: &CStr = c"rust,rust-neon";

#[cfg(test)]
#[test]
fn exported_arms_match_the_engine() {
    assert_eq!(ARMS.to_str().unwrap(), Arm::NAMES);
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

#[unsafe(no_mangle)]
pub extern "C" fn mr_abi_version() -> i32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn mr_arms() -> *const c_char {
    ARMS.as_ptr()
}

/// # Safety
/// `response` points at five doubles; `arm` is null or a NUL-terminated string; `err` is
/// null or holds `err_len` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_engine_new(
    seed: u64,
    response: *const f64,
    arm: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> *mut Engine {
    guarded(err, err_len, std::ptr::null_mut(), || {
        if response.is_null() {
            return Err("response is null".to_owned());
        }
        // SAFETY: the caller passes five doubles.
        let values = unsafe { slice::from_raw_parts(response, 5) };
        let arm = if arm.is_null() {
            Arm::Scalar
        } else {
            // SAFETY: the caller passes a NUL-terminated string.
            let name = unsafe { CStr::from_ptr(arm) }
                .to_str()
                .map_err(|_| "arm is not UTF-8".to_owned())?;
            Arm::parse(name)
                .ok_or_else(|| format!("unknown arm {name:?}; known: {}", Arm::NAMES))?
        };
        let response = DisplayResponse {
            exponent: values[0],
            half_saturation: values[1],
            ceiling: values[2],
            scene_median: values[3],
            scene_highlight: values[4],
        };
        Ok(Box::into_raw(Box::new(Engine::new(seed, response, arm))))
    })
}

/// # Safety
/// `engine` came from `mr_engine_new`; `top`/`bottom` hold `stations` floats; `out` holds
/// `bytes_per_row * height` writable bytes; `err` is null or holds `err_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_render(
    engine: *mut Engine,
    top: *const f32,
    bottom: *const f32,
    stations: i32,
    length: f64,
    lateral_offset: f64,
    increased_contrast: i32,
    scale: f64,
    out: *mut u8,
    width: i32,
    height: i32,
    bytes_per_row: i32,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    guarded(err, err_len, -1, || {
        if engine.is_null() || top.is_null() || bottom.is_null() || out.is_null() {
            return Err("null argument".to_owned());
        }
        if stations < 2 || width <= 0 || height <= 0 || bytes_per_row != width * 4 {
            return Err(format!(
                "bad shape: stations {stations}, {width}x{height}, {bytes_per_row} bytes per row"
            ));
        }
        // SAFETY: checked non-null; sizes come from the caller's contract.
        let (engine, top, bottom, out) = unsafe {
            (
                &mut *engine,
                slice::from_raw_parts(top, stations as usize),
                slice::from_raw_parts(bottom, stations as usize),
                slice::from_raw_parts_mut(out, bytes_per_row as usize * height as usize),
            )
        };
        let status = engine.render(
            top,
            bottom,
            length,
            lateral_offset,
            increased_contrast != 0,
            scale,
            out,
            width as usize,
            height as usize,
        )?;
        Ok(match status {
            RenderStatus::Rendered => 0,
            RenderStatus::EmptyField => 1,
        })
    })
}

/// # Safety
/// `engine` came from `mr_engine_new` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_engine_free(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: created by `Box::into_raw` in `mr_engine_new`.
        drop(unsafe { Box::from_raw(engine) });
    }));
}

/// Copies the three bordered levels' RGB lanes. Returns the float count or -1.
///
/// # Safety
/// `out` holds `count` writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_engine_tables(
    engine: *const Engine,
    out: *mut f32,
    count: usize,
) -> i32 {
    guarded(std::ptr::null_mut(), 0, -1, || {
        let needed = LEVELS * LEVEL_STRIDE * 3;
        if engine.is_null() || out.is_null() || count < needed {
            return Err(String::new());
        }
        // SAFETY: checked non-null and large enough.
        let (engine, out) = unsafe { (&*engine, slice::from_raw_parts_mut(out, needed)) };
        for (index, texel) in engine.environment().tables().iter().enumerate() {
            out[index * 3..index * 3 + 3].copy_from_slice(&texel.rgb());
        }
        Ok(needed as i32)
    })
}

/// # Safety
/// `direction` holds three floats; `out` three writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_engine_radiance(
    engine: *const Engine,
    direction: *const f32,
    out: *mut f32,
) -> i32 {
    guarded(std::ptr::null_mut(), 0, -1, || {
        if engine.is_null() || direction.is_null() || out.is_null() {
            return Err(String::new());
        }
        // SAFETY: checked non-null; three floats each.
        let (engine, direction, out) = unsafe {
            (
                &*engine,
                slice::from_raw_parts(direction, 3),
                slice::from_raw_parts_mut(out, 3),
            )
        };
        out.copy_from_slice(&engine.environment().radiance([
            direction[0],
            direction[1],
            direction[2],
        ]));
        Ok(0)
    })
}

/// `MercuryDisplayLookup.map(scene)` for the engine's selected response.
///
/// # Safety
/// `scene` holds three doubles; `out` three writable doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_engine_display(
    engine: *mut Engine,
    increased_contrast: i32,
    scene: *const f64,
    out: *mut f64,
) -> i32 {
    guarded(std::ptr::null_mut(), 0, -1, || {
        if engine.is_null() || scene.is_null() || out.is_null() {
            return Err(String::new());
        }
        // SAFETY: checked non-null; three doubles each.
        let (engine, scene, out) = unsafe {
            (
                &mut *engine,
                slice::from_raw_parts(scene, 3),
                slice::from_raw_parts_mut(out, 3),
            )
        };
        let lookup = engine.lookup(increased_contrast != 0);
        out.copy_from_slice(&lookup.map([scene[0], scene[1], scene[2]]));
        Ok(0)
    })
}

/// # Safety
/// `out` holds three writable doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_probe_fresnel(cosine: f64, out: *mut f64) {
    if out.is_null() {
        return;
    }
    let value = OPTICS.fresnel(cosine);
    // SAFETY: checked non-null; three doubles.
    unsafe { slice::from_raw_parts_mut(out, 3) }.copy_from_slice(&value);
}

#[unsafe(no_mangle)]
pub extern "C" fn mr_probe_encode_srgb(value: f64) -> f64 {
    OPTICS.encode_srgb(value)
}

#[unsafe(no_mangle)]
pub extern "C" fn mr_probe_encoded_byte(value: f64, coverage: f64) -> u8 {
    OPTICS.encoded_byte(value, coverage)
}

/// `MercuryField(...).boundingBox` as minX, maxX, minY, maxY.
///
/// # Safety
/// `top`/`bottom` hold `stations` floats; `out` four writable doubles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mr_probe_field_box(
    top: *const f32,
    bottom: *const f32,
    stations: i32,
    length: f64,
    lateral_offset: f64,
    out: *mut f64,
) -> i32 {
    guarded(std::ptr::null_mut(), 0, -1, || {
        if top.is_null() || bottom.is_null() || out.is_null() || stations < 2 {
            return Err(String::new());
        }
        // SAFETY: checked non-null; sizes from the caller's contract.
        let (top, bottom, out) = unsafe {
            (
                slice::from_raw_parts(top, stations as usize),
                slice::from_raw_parts(bottom, stations as usize),
                slice::from_raw_parts_mut(out, 4),
            )
        };
        let bounding = Field::new(top, bottom, length, lateral_offset).bounding_box;
        out.copy_from_slice(&[
            bounding.min_x(),
            bounding.max_x(),
            bounding.min_y(),
            bounding.max_y(),
        ]);
        Ok(0)
    })
}
