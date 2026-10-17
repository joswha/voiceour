//! Benchmark-only FastConformer encoder of the pinned parakeet-tdt-0.6b-v3 model, written in
//! Rust over MLX's Metal kernels through `mlx-rs` (bet B4b of the Rust proof program).
//!
//! - [`engine`]: weights as loaded by `parakeet_model_load` and the encoder graph.
//! - [`ffi`]: the `ve_*` C ABI that `libencoder_mlx.dylib` exports for the Swift harness.

pub mod engine;
pub mod ffi;

pub use engine::{
    Arm, Attention, Engine, MLX_COMMIT, MLX_RS_VERSION, MLX_VERSION, N_MELS, N_STATE, Precision,
    Profile, n_enc_frames,
};
