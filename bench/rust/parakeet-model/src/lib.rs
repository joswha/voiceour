//! Zero-copy reader for the pinned parakeet-tdt-0.6b-v3 ggml model file (benchmark-only).
//!
//! [`Model::open`] memory-maps the file and validates it exactly as Voiceour's
//! `parakeet_model_load` (Vendor/parakeet/src/parakeet.cpp) does with its seekable file loader:
//! magic, hyperparameters, mel filterbank, window, TDT durations, vocabulary and every tensor
//! record (name, type, extents, payload size, architecture slot). Tensor payloads are borrowed
//! from the mapping ([`TensorView::data`]); typed accessors copy only when a payload is
//! misaligned for its element type.
//!
//! The semantic accessors ([`Model::subsampling`], [`Model::encoder_layer`],
//! [`Model::prediction`], [`Model::joint`], [`Model::preprocessor`], [`Model::tdt_durations`])
//! return the arrays the native code computes with after load. See README.md for the full
//! list of load-time and graph-time transformations.
//!
//! ```no_run
//! let model = parakeet_model::Model::open(parakeet_model::pin::default_model_path())?;
//! let joint = model.joint();
//! let net_w = joint.net_w.f16_slice()?; // [8198][640] fp16 bit patterns
//! assert_eq!(net_w.len(), 8198 * 640);
//! # Ok::<(), parakeet_model::Error>(())
//! ```

mod arch;
mod dtype;
mod error;
mod model;
mod views;

pub use arch::{
    Family, GGML_QNT_VERSION_FACTOR, GgmlOp, HParam, HParams, OptionalFamily, Scope, TensorKind,
    expected_name_count,
};
pub use dtype::{
    BLOCK_Q4_K_BYTES, BLOCK_Q6_K_BYTES, BLOCK_Q8_0_BYTES, BlockQ8_0, DType, QK_K, QK8_0,
    dequantize_row_q4_k, dequantize_row_q6_k, dequantize_row_q8_0, f16_slice_to_f32, f16_to_f32,
    f32_slice_to_f16, f32_to_f16, ftype_to_ggml_type, ggml_type_name, quantize_row_q8_0,
};
pub use error::{Error, Result};
pub use model::{
    BLANK_PIECE, FamilyCount, FileLayout, GGML_FILE_MAGIC, GGML_MAX_NAME, Model, TensorView,
    Variant, Vocab,
};
pub use views::{
    EncoderLayer, HOP_LENGTH, Joint, LOG_GUARD, LstmLayer, NORMALIZE_EPS, PREEMPHASIS, Prediction,
    Preprocessor, SAMPLE_RATE, SpeakerKernel, Subsampling,
};

/// The pinned model artifact (see the program contract).
pub mod pin {
    use std::path::PathBuf;

    use sha2::{Digest, Sha256};

    /// File name inside the app's model cache directory.
    pub const FILE_NAME: &str = "ggml-parakeet-tdt-0.6b-v3-f16.bin";
    /// Cache directory, relative to `$HOME`.
    pub const CACHE_DIR: &str = "Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml";
    /// Pinned size in bytes.
    pub const SIZE: u64 = 1_255_897_319;
    /// Pinned SHA-256, lowercase hex.
    pub const SHA256_HEX: &str = "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f";

    /// `$HOME/Library/Caches/Voiceour/parakeet-tdt-0.6b-v3-ggml/ggml-parakeet-tdt-0.6b-v3-f16.bin`
    /// (`.` stands in for an unset `$HOME`).
    pub fn default_model_path() -> PathBuf {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        home.join(CACHE_DIR).join(FILE_NAME)
    }

    /// Lowercase hex SHA-256 of `bytes`.
    pub fn sha256_hex(bytes: &[u8]) -> String {
        Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }
}
