//! Error type.

use std::fmt;
use std::io;
use std::path::PathBuf;

use crate::dtype::DType;

/// Everything that can go wrong opening or reading a model file.
#[derive(Debug)]
pub enum Error {
    /// The file could not be opened or mapped.
    Io {
        /// File path.
        path: PathBuf,
        /// Underlying error.
        source: io::Error,
    },
    /// Malformed container bytes (the native record parser refuses them too).
    Format(String),
    /// Hyperparameters `parakeet_validate_hparams` (or `ggml_ftype_to_ggml_type`) refuses.
    HParams(String),
    /// The record set, shapes or payload sizes differ from what `parakeet_model_load` builds.
    Architecture(String),
    /// A typed accessor was used on a tensor of another element type or shape.
    DType {
        /// Tensor name.
        tensor: String,
        /// What the accessor needs.
        expected: &'static str,
        /// The tensor's element type.
        actual: DType,
    },
}

/// `Result` defaulting to [`Error`].
pub type Result<T, E = Error> = std::result::Result<T, E>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Error::Format(msg) => write!(f, "model format: {msg}"),
            Error::HParams(msg) => write!(f, "model hparams: {msg}"),
            Error::Architecture(msg) => write!(f, "model architecture: {msg}"),
            Error::DType {
                tensor,
                expected,
                actual,
            } => write!(f, "tensor {tensor}: needs {expected}, is {actual}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}
