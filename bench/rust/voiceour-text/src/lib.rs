//! Benchmark-only Rust port of Voiceour's deterministic post-ASR text path (bet B3).
//!
//! The port follows the Swift sources function by function (see README.md for the
//! production call sequence) and must produce byte-identical output. Unicode behaviour
//! comes from `tables.rs`, generated from the production runtime itself.

pub mod bench;
pub mod cleanup;
pub mod ffi;
pub mod glossary;
pub mod icu;
pub mod inputs;
pub mod literal;
pub mod oracle;
pub mod pipeline;
pub mod repair;
#[rustfmt::skip]
pub mod tables;
pub mod uni;
pub mod vocabulary;

pub use pipeline::{Pipeline, Processed};
pub use repair::{OrdinaryWords, RepairVocabulary, VocabularyRepairEngine};
pub use vocabulary::{ProtectedTerm, compile};
