//! Arms: how the encoder stores weights and activations, and which op set it runs.

use candle_core::DType;

/// Weight and activation precision.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Precision {
    /// f32 activations; the file's f16 matrices widened to f32 at load; MLX gemm in f32.
    F32,
    /// f16 activations and weights; MLX gemm in f16 (float accumulation, f16 output).
    F16,
    /// bf16 activations and weights (f16 matrices rounded to bf16 at load).
    Bf16,
    /// f32 activations; f16 matrices kept as stored and multiplied by candle's port of ggml's
    /// `kernel_mul_mm_f16_f32` (`QTensor` of `GgmlDType::F16`), f32 output.
    F16w,
    /// f32 activations; matrices requantized to q8_0 at load (ggml `quantize_row_q8_0_ref`
    /// port) and multiplied by candle's `kernel_mul_mm_q8_0_f32`.
    Q8_0,
}

/// One benchmark arm: a precision plus the op set.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Arm {
    pub precision: Precision,
    /// `false`: candle's stock ops (plus the depthwise convolutions candle lacks).
    /// `true`: residual + LayerNorm, Q/K/V split, the relative shift and the conv module's
    /// GLU / depthwise / BatchNorm / SiLU chain run as fused custom kernels, and attention
    /// writes its output straight into the frame-major layout.
    pub fused: bool,
}

/// Every arm the engine accepts, in the order `ve_arms` reports them.
pub const ARM_NAMES: &str =
    "f32,f16,bf16,f16w,q8_0,f32+fused,f16+fused,bf16+fused,f16w+fused,q8_0+fused";

/// `ARM_NAMES` as a NUL-terminated C string for `ve_arms`.
pub const ARM_NAMES_C: &std::ffi::CStr =
    c"f32,f16,bf16,f16w,q8_0,f32+fused,f16+fused,bf16+fused,f16w+fused,q8_0+fused";

impl Arm {
    pub fn parse(name: &str) -> Option<Arm> {
        let (base, fused) = match name.strip_suffix("+fused") {
            Some(base) => (base, true),
            None => (name, false),
        };
        let precision = match base {
            "f32" => Precision::F32,
            "f16" => Precision::F16,
            "bf16" => Precision::Bf16,
            "f16w" => Precision::F16w,
            "q8_0" => Precision::Q8_0,
            _ => return None,
        };
        Some(Arm { precision, fused })
    }

    pub fn name(&self) -> String {
        let base = match self.precision {
            Precision::F32 => "f32",
            Precision::F16 => "f16",
            Precision::Bf16 => "bf16",
            Precision::F16w => "f16w",
            Precision::Q8_0 => "q8_0",
        };
        if self.fused {
            format!("{base}+fused")
        } else {
            base.to_owned()
        }
    }

    /// Storage type of activations (and of the dense weights).
    pub fn act_dtype(&self) -> DType {
        match self.precision {
            Precision::F32 | Precision::F16w | Precision::Q8_0 => DType::F32,
            Precision::F16 => DType::F16,
            Precision::Bf16 => DType::BF16,
        }
    }

    /// Suffix of the custom kernel instantiation for the activation type.
    pub fn kernel_suffix(&self) -> &'static str {
        match self.act_dtype() {
            DType::F16 => "f16",
            DType::BF16 => "bf16",
            _ => "f32",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_listed_arm_round_trips() {
        for name in ARM_NAMES.split(',') {
            let arm = Arm::parse(name).expect(name);
            assert_eq!(arm.name(), name);
        }
        assert_eq!(ARM_NAMES_C.to_str().unwrap(), ARM_NAMES);
        assert!(Arm::parse("f64").is_none());
    }
}
