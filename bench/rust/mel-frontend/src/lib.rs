//! Benchmark-only Rust ports of parakeet.cpp's log-mel frontend (`log_mel_spectrogram`,
//! `Vendor/parakeet/src/parakeet.cpp` L4949–L5221) for bet B2, behind the `vm_` C ABI of the
//! shared contract. Nothing in the app depends on this crate.
//!
//! Arms (see README.md): `faithful`, `faithful-spawn`, `faithful-mt`, `sparse` and `best`
//! reproduce the native output bit for bit; `realfft` and `vdsp` swap in modern FFTs and are
//! measured for error; `best-approx` names the fastest arm overall.
//!
//! ```no_run
//! use std::sync::Arc;
//! use mel_frontend::{Arm, Engine, Frontend};
//!
//! let frontend = Arc::new(Frontend::open(parakeet_model::pin::default_model_path())?);
//! let mut engine = Engine::new(Arc::clone(&frontend), Arm::Best, 6)?;
//! let samples = vec![0.0f32; 16_000];
//! let mut mel = vec![0.0f32; frontend.n_frames(samples.len()) * frontend.n_mels];
//! let frames = engine.compute(&samples, &mut mel)?;
//! assert_eq!(frames, 101);
//! # Ok::<(), String>(())
//! ```

#[cfg(not(all(target_arch = "aarch64", target_os = "macos")))]
compile_error!("mel-frontend targets aarch64-apple-darwin (NEON, __sincosf_stret, Accelerate)");

mod approx;
mod engine;
mod exact;
mod faithful;
mod ffi;
mod frontend;
mod kernels;
mod pipeline;
mod pool;
pub mod wav;

pub use engine::{ARM_NAMES, Arm, DEFAULT_THREADS, Engine};
pub use ffi::{vm_abi_version, vm_arms, vm_compute, vm_engine, vm_engine_free, vm_engine_new};
pub use frontend::{Frontend, SparseFilters};
