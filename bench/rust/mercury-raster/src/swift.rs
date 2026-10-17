//! The Swift standard-library semantics the port reproduces bit for bit.
//!
//! Rust's `f64::max`/`f64::min` are IEEE `maxNum`/`minNum`; Swift's generic `max`/`min`
//! are plain comparisons. They agree on ordinary values but differ on NaN and on the
//! sign of a zero result, so every `Swift.max`/`Swift.min` in the Swift source maps to
//! these two functions rather than to the inherent methods.

/// `Swift.max(x, y)`: `y >= x ? y : x`.
#[inline(always)]
pub fn max<T: PartialOrd>(x: T, y: T) -> T {
    if y >= x { y } else { x }
}

/// `Swift.min(x, y)`: `y < x ? y : x`.
#[inline(always)]
pub fn min<T: PartialOrd>(x: T, y: T) -> T {
    if y < x { y } else { x }
}

/// `Double.leastNonzeroMagnitude`.
pub const LEAST_NONZERO_F64: f64 = f64::from_bits(1);

/// A Swift `Float` literal. On arm64 the builtin literal type is `FPIEEE64`, so a `Float`
/// literal is the decimal rounded to `Double`, then rounded again to `Float`.
#[inline(always)]
pub const fn float_literal(value: f64) -> f32 {
    value as f32
}
