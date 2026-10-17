//! Benchmark-only Rust TDT decode tail for bet B1 of the Rust proof program.
//!
//! Replays the greedy TDT tail of Voiceour's vendored parakeet.cpp (`parakeet_decode`, the
//! merged prediction + joint step graph, `create_token_data`) on dumped encoder states, as an
//! ablation ladder of arms selectable by name through the `vt_` C ABI ([`ffi`]) and
//! `tail-bench --arms`. See README.md for the arms, the equivalence contract and results.

pub mod accel;
pub mod cimpl;
pub mod engine;
pub mod ffi;
pub mod kernels;
pub mod pool;
pub mod simd;
pub mod weights;

pub use engine::{
    ARMS, BEST, Backend, Config, Engine, StepTrace, Token, Work, arm_config, perf_cores,
};
pub use weights::{Dims, Format, Mat, Weights};

/// The canonical token string of the program contract: `"<id>:<frame_index>:<duration>"` per
/// token, joined with `,`.
pub fn canonical_tokens(tokens: impl IntoIterator<Item = (i32, i32, i32)>) -> String {
    let mut s = String::new();
    for (i, (id, frame, duration)) in tokens.into_iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!("{id}:{frame}:{duration}"));
    }
    s
}

/// [`canonical_tokens`] of decoded tokens.
pub fn canonical(tokens: &[Token]) -> String {
    canonical_tokens(tokens.iter().map(|t| (t.id, t.frame_index, t.duration)))
}
