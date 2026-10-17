//! Benchmark-only FastConformer encoder of the pinned parakeet-tdt-0.6b-v3 on candle-metal
//! (bet B4a). See README.md for the arms, the C ABI and the measured results.

pub mod arm;
pub mod dumps;
pub mod engine;
pub mod ffi;
pub mod json;
mod kernels;
pub mod metrics;

pub use arm::{ARM_NAMES, Arm, Precision};
pub use engine::{Encoder, MAX_ENC_FRAMES};
