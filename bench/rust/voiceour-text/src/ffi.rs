//! C ABI (`libvoiceour_text.dylib`, prefix `vtx_`): the port behind `dlopen`, so the Swift
//! harness can time it in the same process as the shipped Swift code (arm `rust-ffi`).
//! Handles are single-threaded; no panic crosses the boundary: every entry point catches it
//! and reports through `err`.
//!
//! ```c
//! int32_t vtx_abi_version(void);                     // 1
//! const char *vtx_arms(void);                        // "rust-ffi"
//! typedef struct vtx_engine vtx_engine;
//! // glossary_json: the bytes of a glossary file ({"name", "terms": [...]}, the file the
//! // harnesses read); ordinary_words: path of ordinary-words.txt, parsed once per process
//! // (Swift's `static let bundledOrdinaryWords`). The engine compiles the active snapshot and
//! // builds the cached repair engine, as an earlier utterance of a warm process did.
//! vtx_engine *vtx_engine_new(const uint8_t *glossary_json, size_t glossary_len,
//!                            const char *ordinary_words, const char *arm,
//!                            char *err, size_t err_len);
//! // stage 0 text: input is the raw transcript, output the inserted text
//! //   (LiteralComposition + clean + cached-engine check + repair).
//! // stage 1 compile: VocabularyCompiler.compile; output the active term ids joined by "\n".
//! // stage 2 engine: a cold repair-engine build from the active terms; output the partition's
//! //   surfaces joined by "\n", "\n--\n", its protected surfaces joined by "\n".
//! // stage 3 echo: the boundary alone; input validated as UTF-8 and copied to the output.
//! // compile and engine ignore `input`. Returns the output's byte length n and copies the
//! // output to `out` when n <= out_cap; otherwise copies nothing (vtx_last_output fetches it
//! // without re-running). Returns -1 on error, with the message in `err`.
//! int64_t vtx_run(vtx_engine *, int32_t stage, const uint8_t *input, size_t input_len,
//!                 uint8_t *out, size_t out_cap, char *err, size_t err_len);
//! // The last run's output under vtx_run's length/capacity contract.
//! int64_t vtx_last_output(const vtx_engine *, uint8_t *out, size_t out_cap);
//! // Drops what the last run retained (its output; for stage 2, the engine it built), so a
//! // caller keeps deallocation outside its timed region, where Swift releases its results.
//! void vtx_release(vtx_engine *);
//! void vtx_engine_free(vtx_engine *);
//! ```

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::slice;
use std::sync::OnceLock;

use crate::bench::{self, GlossaryFile};
use crate::pipeline::Pipeline;
use crate::repair::{OrdinaryWords, RepairVocabulary, VocabularyRepairEngine};
use crate::vocabulary::{self, ProtectedTerm};

static ARMS: &CStr = c"rust-ffi";

pub const STAGE_TEXT: i32 = 0;
pub const STAGE_COMPILE: i32 = 1;
pub const STAGE_ENGINE: i32 = 2;
pub const STAGE_ECHO: i32 = 3;

/// `RepairVocabulary.bundledOrdinaryWords`: parsed by the first engine from the path it is
/// given, shared by the rest.
static ORDINARY: OnceLock<(PathBuf, OrdinaryWords)> = OnceLock::new();

fn ordinary_words(path: &Path) -> Result<&'static OrdinaryWords, String> {
    if ORDINARY.get().is_none() {
        let contents = std::fs::read_to_string(path)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        // A concurrent first call may win the race; its words come from the same file.
        let _ = ORDINARY.set((path.to_owned(), OrdinaryWords::parse(&contents)));
    }
    let (loaded, words) = ORDINARY.get().ok_or("ordinary words did not load")?;
    if loaded != path {
        return Err(format!(
            "ordinary words already loaded from {}, not {}",
            loaded.display(),
            path.display()
        ));
    }
    Ok(words)
}

pub struct Engine {
    /// The glossary's terms, as decoded.
    terms: Vec<ProtectedTerm>,
    /// The compiled snapshot as indices into `terms`. Each call borrows it as the
    /// `&[&ProtectedTerm]` the port takes: one small allocation inside the timed call.
    active: Vec<usize>,
    pipeline: Pipeline<'static>,
    ordinary: &'static OrdinaryWords,
    /// The engine stage 2 built last, held until `vtx_release`.
    built: Option<VocabularyRepairEngine<'static>>,
    output: Vec<u8>,
}

impl Engine {
    fn new(glossary_json: &[u8], ordinary_path: &Path, arm: &str) -> Result<Self, String> {
        if arm != "rust-ffi" {
            return Err(format!(
                "unknown arm {arm:?}; known: {}",
                ARMS.to_str().unwrap_or("?")
            ));
        }
        let glossary: GlossaryFile = serde_json::from_slice(glossary_json)
            .map_err(|error| format!("glossary JSON: {error}"))?;
        let ordinary = ordinary_words(ordinary_path)?;
        let terms = glossary.terms;
        let base = terms.as_ptr() as usize;
        let active: Vec<usize> = vocabulary::compile(&terms, bench::reference_date_now())
            .into_iter()
            .map(|term| (std::ptr::from_ref(term) as usize - base) / size_of::<ProtectedTerm>())
            .collect();
        let mut engine = Self {
            terms,
            active,
            pipeline: Pipeline::new(ordinary),
            ordinary,
            built: None,
            output: Vec::new(),
        };
        // A warm process: an earlier utterance built the cached engine (the Swift arms do the same).
        let active: Vec<&ProtectedTerm> = engine
            .active
            .iter()
            .map(|&index| &engine.terms[index])
            .collect();
        engine.pipeline.repair_engine(&active);
        Ok(engine)
    }

    fn run(&mut self, stage: i32, input: &[u8]) -> Result<usize, String> {
        match stage {
            STAGE_TEXT => {
                let raw = std::str::from_utf8(input)
                    .map_err(|error| format!("input is not UTF-8: {error}"))?;
                let active: Vec<&ProtectedTerm> = self
                    .active
                    .iter()
                    .map(|&index| &self.terms[index])
                    .collect();
                self.output = self.pipeline.process_text(raw, &active).into_bytes();
            }
            STAGE_COMPILE => {
                let snapshot = vocabulary::compile(&self.terms, bench::reference_date_now());
                let mut ids = String::new();
                for (index, term) in snapshot.iter().enumerate() {
                    if index > 0 {
                        ids.push('\n');
                    }
                    ids.push_str(term.term_id());
                }
                self.output = ids.into_bytes();
            }
            STAGE_ENGINE => {
                let active: Vec<&ProtectedTerm> = self
                    .active
                    .iter()
                    .map(|&index| &self.terms[index])
                    .collect();
                let vocabulary = RepairVocabulary::from_active_terms(&active, self.ordinary);
                let engine = VocabularyRepairEngine::new(&vocabulary);
                let mut digest = vocabulary.surfaces.join("\n");
                digest.push_str("\n--\n");
                digest.push_str(&vocabulary.protected_surfaces.join("\n"));
                self.built = Some(engine);
                self.output = digest.into_bytes();
            }
            STAGE_ECHO => {
                let raw = std::str::from_utf8(input)
                    .map_err(|error| format!("input is not UTF-8: {error}"))?;
                self.output = raw.as_bytes().to_vec();
            }
            other => return Err(format!("unknown stage {other}")),
        }
        Ok(self.output.len())
    }
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

/// `bytes` to `out` when it fits; the byte length either way.
///
/// # Safety
/// `out` is null or holds `out_cap` writable bytes.
unsafe fn copy_out(bytes: &[u8], out: *mut u8, out_cap: usize) -> Result<i64, String> {
    if bytes.len() <= out_cap && !bytes.is_empty() {
        if out.is_null() {
            return Err("out is null".to_owned());
        }
        // SAFETY: checked non-null; the caller provides `out_cap >= bytes.len()` bytes.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    }
    i64::try_from(bytes.len()).map_err(|_| "output too long".to_owned())
}

#[unsafe(no_mangle)]
pub extern "C" fn vtx_abi_version() -> i32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn vtx_arms() -> *const c_char {
    ARMS.as_ptr()
}

/// # Safety
/// `glossary_json` holds `glossary_len` bytes; `ordinary_words` and `arm` are NUL-terminated;
/// `err` is null or holds `err_len` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vtx_engine_new(
    glossary_json: *const u8,
    glossary_len: usize,
    ordinary_words: *const c_char,
    arm: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> *mut Engine {
    guarded(err, err_len, std::ptr::null_mut(), || {
        if glossary_json.is_null() || ordinary_words.is_null() || arm.is_null() {
            return Err("null argument".to_owned());
        }
        // SAFETY: the caller's contract above.
        let (glossary, ordinary, arm) = unsafe {
            (
                slice::from_raw_parts(glossary_json, glossary_len),
                CStr::from_ptr(ordinary_words)
                    .to_str()
                    .map_err(|_| "ordinary_words is not UTF-8".to_owned())?,
                CStr::from_ptr(arm)
                    .to_str()
                    .map_err(|_| "arm is not UTF-8".to_owned())?,
            )
        };
        Ok(Box::into_raw(Box::new(Engine::new(
            glossary,
            Path::new(ordinary),
            arm,
        )?)))
    })
}

/// # Safety
/// `engine` came from `vtx_engine_new`; `input` is null with `input_len` 0 or holds
/// `input_len` bytes; `out` is null or holds `out_cap` writable bytes; `err` is null or holds
/// `err_len` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vtx_run(
    engine: *mut Engine,
    stage: i32,
    input: *const u8,
    input_len: usize,
    out: *mut u8,
    out_cap: usize,
    err: *mut c_char,
    err_len: usize,
) -> i64 {
    guarded(err, err_len, -1, || {
        if engine.is_null() || (input.is_null() && input_len > 0) {
            return Err("null argument".to_owned());
        }
        // SAFETY: the caller's contract above.
        let (engine, input) = unsafe {
            (
                &mut *engine,
                if input_len == 0 {
                    &[][..]
                } else {
                    slice::from_raw_parts(input, input_len)
                },
            )
        };
        engine.run(stage, input)?;
        // SAFETY: the caller's contract above.
        unsafe { copy_out(&engine.output, out, out_cap) }
    })
}

/// # Safety
/// `engine` came from `vtx_engine_new`; `out` is null or holds `out_cap` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vtx_last_output(
    engine: *const Engine,
    out: *mut u8,
    out_cap: usize,
) -> i64 {
    guarded(std::ptr::null_mut(), 0, -1, || {
        if engine.is_null() {
            return Err("null engine".to_owned());
        }
        // SAFETY: the caller's contract above.
        unsafe { copy_out(&(*engine).output, out, out_cap) }
    })
}

/// # Safety
/// `engine` came from `vtx_engine_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vtx_release(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract above.
        let engine = unsafe { &mut *engine };
        engine.output = Vec::new();
        engine.built = None;
    }));
}

/// # Safety
/// `engine` came from `vtx_engine_new` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vtx_engine_free(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: created by `Box::into_raw` in `vtx_engine_new`.
        drop(unsafe { Box::from_raw(engine) });
    }));
}
