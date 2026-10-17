//! Element types a parakeet tensor record may carry, and bit-exact ports of the scalar
//! conversions ggml itself uses for them.
//!
//! * fp16 <-> fp32: `ggml_compute_fp16_to_fp32` / `ggml_compute_fp32_to_fp16`
//!   (Vendor/parakeet/ggml/src/ggml-impl.h L384-L434, the Maratyszcza FP16 algorithm:
//!   round-to-nearest-even, NaN -> 0x7E00 with the input's sign).
//! * q8_0: `quantize_row_q8_0_ref` / `dequantize_row_q8_0`
//!   (Vendor/parakeet/ggml/src/ggml-quants.c L276, L553), block layout `block_q8_0`
//!   (ggml-common.h L251).
//! * q4_K / q6_K: `dequantize_row_q4_K` / `dequantize_row_q6_K` (ggml-quants.c L1529, L1939).

use std::fmt;

/// Element type of a tensor record: exactly the set `parakeet_tensor_record_type_layout`
/// accepts (parakeet.cpp L793-L819). Any other ggml type id makes the native loader reject
/// the file, so it is rejected here too.
#[allow(non_camel_case_types)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DType {
    /// `GGML_TYPE_F32` (id 0): little-endian IEEE binary32.
    F32,
    /// `GGML_TYPE_F16` (id 1): little-endian IEEE binary16 bit patterns.
    F16,
    /// `GGML_TYPE_Q8_0` (id 8): 32-element blocks of `{ f16 d; i8 qs[32] }` (34 bytes).
    Q8_0,
    /// `GGML_TYPE_Q4_K` (id 12): 256-element super-blocks of 144 bytes.
    Q4_K,
    /// `GGML_TYPE_Q6_K` (id 14): 256-element super-blocks of 210 bytes.
    Q6_K,
}

impl DType {
    /// Maps a ggml type id from a tensor record header.
    pub const fn from_ggml_id(id: i32) -> Option<DType> {
        match id {
            0 => Some(DType::F32),
            1 => Some(DType::F16),
            8 => Some(DType::Q8_0),
            12 => Some(DType::Q4_K),
            14 => Some(DType::Q6_K),
            _ => None,
        }
    }

    /// The ggml type id (`enum ggml_type`, ggml.h L389).
    pub const fn ggml_id(self) -> i32 {
        match self {
            DType::F32 => 0,
            DType::F16 => 1,
            DType::Q8_0 => 8,
            DType::Q4_K => 12,
            DType::Q6_K => 14,
        }
    }

    /// ggml's type name.
    pub const fn name(self) -> &'static str {
        ggml_type_name(self.ggml_id())
    }

    /// Elements per block (`ggml_blck_size`).
    pub const fn block_size(self) -> usize {
        match self {
            DType::F32 | DType::F16 => 1,
            DType::Q8_0 => QK8_0,
            DType::Q4_K | DType::Q6_K => QK_K,
        }
    }

    /// Bytes per block (`ggml_type_size`).
    pub const fn type_size(self) -> usize {
        match self {
            DType::F32 => 4,
            DType::F16 => 2,
            DType::Q8_0 => BLOCK_Q8_0_BYTES,
            DType::Q4_K => BLOCK_Q4_K_BYTES,
            DType::Q6_K => BLOCK_Q6_K_BYTES,
        }
    }

    /// True for block-quantized types.
    pub const fn is_quantized(self) -> bool {
        matches!(self, DType::Q8_0 | DType::Q4_K | DType::Q6_K)
    }

    /// Bytes of one row of `n` elements, or `None` when `n` is not a whole number of blocks.
    pub const fn row_bytes(self, n: usize) -> Option<usize> {
        if n % self.block_size() != 0 {
            return None;
        }
        (n / self.block_size()).checked_mul(self.type_size())
    }

    /// Payload bytes of a tensor with ggml extents `ne`, computed exactly like
    /// `parakeet_tensor_record_payload_bytes` (parakeet.cpp L884): `ne[0]` must be a positive
    /// whole number of blocks, every extent positive, and the product must not overflow.
    pub fn payload_bytes(self, ne: &[i64; 4]) -> Option<usize> {
        if ne.iter().any(|&n| n <= 0) {
            return None;
        }
        let mut bytes = self.row_bytes(usize::try_from(ne[0]).ok()?)?;
        for &n in &ne[1..] {
            bytes = bytes.checked_mul(usize::try_from(n).ok()?)?;
        }
        Some(bytes)
    }
}

impl fmt::Display for DType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// ggml's name for any `enum ggml_type` id (ggml.h L389-L433); `"?"` for unknown ids.
pub const fn ggml_type_name(id: i32) -> &'static str {
    match id {
        0 => "f32",
        1 => "f16",
        2 => "q4_0",
        3 => "q4_1",
        6 => "q5_0",
        7 => "q5_1",
        8 => "q8_0",
        9 => "q8_1",
        10 => "q2_K",
        11 => "q3_K",
        12 => "q4_K",
        13 => "q5_K",
        14 => "q6_K",
        15 => "q8_K",
        16 => "iq2_xxs",
        17 => "iq2_xs",
        18 => "iq3_xxs",
        19 => "iq1_s",
        20 => "iq4_nl",
        21 => "iq3_s",
        22 => "iq2_s",
        23 => "iq4_xs",
        24 => "i8",
        25 => "i16",
        26 => "i32",
        27 => "i64",
        28 => "f64",
        29 => "iq1_m",
        30 => "bf16",
        34 => "tq1_0",
        35 => "tq2_0",
        39 => "mxfp4",
        40 => "nvfp4",
        41 => "q1_0",
        42 => "q2_0",
        _ => "?",
    }
}

/// `ggml_ftype_to_ggml_type` (ggml.c L1426): the ggml type id of a model-level `ftype`
/// (after `ftype %= GGML_QNT_VERSION_FACTOR`). `None` where ggml asserts (unknown ftype,
/// `GGML_FTYPE_MOSTLY_Q4_1_SOME_F16`).
pub const fn ftype_to_ggml_type(ftype: i32) -> Option<i32> {
    match ftype {
        0 => Some(0),   // ALL_F32 -> F32
        1 => Some(1),   // MOSTLY_F16 -> F16
        24 => Some(30), // MOSTLY_BF16 -> BF16
        2 => Some(2),   // MOSTLY_Q4_0
        3 => Some(3),   // MOSTLY_Q4_1
        27 => Some(41), // MOSTLY_Q1_0
        28 => Some(42), // MOSTLY_Q2_0
        8 => Some(6),   // MOSTLY_Q5_0
        9 => Some(7),   // MOSTLY_Q5_1
        7 => Some(8),   // MOSTLY_Q8_0
        25 => Some(39), // MOSTLY_MXFP4
        26 => Some(40), // MOSTLY_NVFP4
        10 => Some(10), // MOSTLY_Q2_K
        11 => Some(11), // MOSTLY_Q3_K
        12 => Some(12), // MOSTLY_Q4_K
        13 => Some(13), // MOSTLY_Q5_K
        14 => Some(14), // MOSTLY_Q6_K
        15 => Some(16), // MOSTLY_IQ2_XXS
        16 => Some(17), // MOSTLY_IQ2_XS
        17 => Some(18), // MOSTLY_IQ3_XXS
        18 => Some(19), // MOSTLY_IQ1_S
        23 => Some(29), // MOSTLY_IQ1_M
        19 => Some(20), // MOSTLY_IQ4_NL
        22 => Some(23), // MOSTLY_IQ4_XS
        20 => Some(21), // MOSTLY_IQ3_S
        21 => Some(22), // MOSTLY_IQ2_S
        _ => None,
    }
}

// ---------------------------------------------------------------------------------------------
// fp16

/// fp16 bit pattern -> f32, exactly `ggml_compute_fp16_to_fp32` (ggml-impl.h L384).
/// Exact for every finite value; infinities and NaN payloads are preserved.
pub fn f16_to_f32(h: u16) -> f32 {
    let w = u32::from(h) << 16;
    let sign = w & 0x8000_0000;
    let two_w = w.wrapping_add(w);

    let exp_offset: u32 = 0xE0 << 23;
    let exp_scale = f32::from_bits(0x0780_0000); // 0x1.0p-112f
    let normalized_value = f32::from_bits((two_w >> 4) + exp_offset) * exp_scale;

    let magic_mask: u32 = 126 << 23;
    let magic_bias = 0.5f32;
    let denormalized_value = f32::from_bits((two_w >> 17) | magic_mask) - magic_bias;

    let denormalized_cutoff: u32 = 1 << 27;
    let result = sign
        | if two_w < denormalized_cutoff {
            denormalized_value.to_bits()
        } else {
            normalized_value.to_bits()
        };
    f32::from_bits(result)
}

/// f32 -> fp16 bit pattern, exactly `ggml_compute_fp32_to_fp16` (ggml-impl.h L407):
/// round-to-nearest-even, overflow to infinity, every NaN to `0x7E00` with the input's sign.
pub fn f32_to_f16(f: f32) -> u16 {
    let scale_to_inf = f32::from_bits(0x7780_0000); // 0x1.0p+112f
    let scale_to_zero = f32::from_bits(0x0880_0000); // 0x1.0p-110f
    let mut base = (f.abs() * scale_to_inf) * scale_to_zero;

    let w = f.to_bits();
    let shl1_w = w.wrapping_add(w);
    let sign = w & 0x8000_0000;
    let mut bias = shl1_w & 0xFF00_0000;
    if bias < 0x7100_0000 {
        bias = 0x7100_0000;
    }

    base = f32::from_bits((bias >> 1) + 0x0780_0000) + base;
    let bits = base.to_bits();
    let exp_bits = (bits >> 13) & 0x0000_7C00;
    let mantissa_bits = bits & 0x0000_0FFF;
    let nonsign = exp_bits + mantissa_bits;
    // C: `(sign >> 16) | (cond ? 0x7E00 : nonsign)`, implicitly narrowed to uint16_t.
    ((sign >> 16)
        | if shl1_w > 0xFF00_0000 {
            0x7E00
        } else {
            nonsign
        }) as u16
}

/// Converts a slice of fp16 bit patterns to f32 (`ggml_fp16_to_fp32_row`, ggml.c L468).
pub fn f16_slice_to_f32(src: &[u16], dst: &mut [f32]) {
    assert_eq!(src.len(), dst.len(), "f16_slice_to_f32: length mismatch");
    for (d, &s) in dst.iter_mut().zip(src) {
        *d = f16_to_f32(s);
    }
}

/// Converts a slice of f32 to fp16 bit patterns with [`f32_to_f16`].
pub fn f32_slice_to_f16(src: &[f32], dst: &mut [u16]) {
    assert_eq!(src.len(), dst.len(), "f32_slice_to_f16: length mismatch");
    for (d, &s) in dst.iter_mut().zip(src) {
        *d = f32_to_f16(s);
    }
}

// ---------------------------------------------------------------------------------------------
// q8_0

/// Elements per q8_0 block (`QK8_0`, ggml-common.h L251).
pub const QK8_0: usize = 32;
/// Bytes per q8_0 block: `sizeof(block_q8_0)` = 2 (f16 scale) + 32 (i8 quants).
pub const BLOCK_Q8_0_BYTES: usize = 34;

/// One q8_0 block, layout-identical to ggml's `block_q8_0` (ggml-common.h L252):
/// element `j` of the block is `qs[j] * f16_to_f32(d)`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockQ8_0 {
    /// Scale `d` as an fp16 bit pattern (little-endian on disk).
    pub d: u16,
    /// Signed quants.
    pub qs: [i8; QK8_0],
}

const _: () = assert!(std::mem::size_of::<BlockQ8_0>() == BLOCK_Q8_0_BYTES);
const _: () = assert!(std::mem::align_of::<BlockQ8_0>() == 2);

impl BlockQ8_0 {
    /// Decodes one block from its 34 on-disk bytes.
    pub fn from_bytes(bytes: &[u8; BLOCK_Q8_0_BYTES]) -> BlockQ8_0 {
        let mut qs = [0i8; QK8_0];
        for (q, &b) in qs.iter_mut().zip(&bytes[2..]) {
            *q = b as i8;
        }
        BlockQ8_0 {
            d: u16::from_le_bytes([bytes[0], bytes[1]]),
            qs,
        }
    }

    /// Encodes the block as its 34 on-disk bytes.
    pub fn to_bytes(&self) -> [u8; BLOCK_Q8_0_BYTES] {
        let mut out = [0u8; BLOCK_Q8_0_BYTES];
        out[..2].copy_from_slice(&self.d.to_le_bytes());
        for (o, &q) in out[2..].iter_mut().zip(&self.qs) {
            *o = q as u8;
        }
        out
    }

    /// The block scale as f32.
    pub fn scale(&self) -> f32 {
        f16_to_f32(self.d)
    }

    /// Dequantizes the block (`dequantize_row_q8_0` for one block).
    pub fn dequantize(&self, out: &mut [f32; QK8_0]) {
        let d = self.scale();
        for (o, &q) in out.iter_mut().zip(&self.qs) {
            *o = f32::from(q) * d;
        }
    }
}

/// Quantizes `x` (a whole number of 32-element blocks) into q8_0 bytes, bit-exactly like
/// `quantize_row_q8_0_ref` (ggml-quants.c L276) — the routine `ggml_quantize_chunk(GGML_TYPE_Q8_0,
/// ...)` runs for the opt-in CPU-tail load-time repack (parakeet.cpp L3216).
///
/// Panics unless `x.len() % 32 == 0` and `y.len() == x.len() / 32 * 34`.
pub fn quantize_row_q8_0(x: &[f32], y: &mut [u8]) {
    assert!(
        x.len() % QK8_0 == 0,
        "quantize_row_q8_0: length not a multiple of 32"
    );
    assert_eq!(
        y.len(),
        x.len() / QK8_0 * BLOCK_Q8_0_BYTES,
        "quantize_row_q8_0: bad output length"
    );
    for (xb, yb) in x
        .chunks_exact(QK8_0)
        .zip(y.chunks_exact_mut(BLOCK_Q8_0_BYTES))
    {
        // MAX(a, b) is `((a) > (b) ? (a) : (b))` in ggml-quants.c.
        let mut amax = 0.0f32;
        for &v in xb {
            let a = v.abs();
            amax = if amax > a { amax } else { a };
        }
        let d = amax / 127.0;
        // C `d ? 1.0f/d : 0.0f`: NaN is truthy, as is `d != 0.0` here.
        let id = if d != 0.0 { 1.0 / d } else { 0.0 };
        yb[..2].copy_from_slice(&f32_to_f16(d).to_le_bytes());
        for (q, &v) in yb[2..].iter_mut().zip(xb) {
            // roundf (half away from zero) == f32::round; the result is in [-127, 127].
            *q = ((v * id).round() as i8) as u8;
        }
    }
}

/// Dequantizes q8_0 bytes (a whole number of 34-byte blocks) into `y`, exactly
/// `dequantize_row_q8_0` (ggml-quants.c L553): `y = qs[j] * fp16_to_fp32(d)`.
///
/// Panics unless `x.len() % 34 == 0` and `y.len() == x.len() / 34 * 32`.
pub fn dequantize_row_q8_0(x: &[u8], y: &mut [f32]) {
    assert!(
        x.len() % BLOCK_Q8_0_BYTES == 0,
        "dequantize_row_q8_0: partial block"
    );
    assert_eq!(
        y.len(),
        x.len() / BLOCK_Q8_0_BYTES * QK8_0,
        "dequantize_row_q8_0: bad output length"
    );
    for (xb, yb) in x
        .chunks_exact(BLOCK_Q8_0_BYTES)
        .zip(y.chunks_exact_mut(QK8_0))
    {
        let d = f16_to_f32(u16::from_le_bytes([xb[0], xb[1]]));
        for (o, &q) in yb.iter_mut().zip(&xb[2..]) {
            *o = f32::from(q as i8) * d;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// k-quants (accepted by the native record parser; not present in the pinned f16 file)

/// Elements per k-quant super-block (`QK_K`, ggml-common.h L89).
pub const QK_K: usize = 256;
/// `sizeof(block_q4_K)`: f16 d, f16 dmin, 12 scale bytes, 128 quant bytes.
pub const BLOCK_Q4_K_BYTES: usize = 144;
/// `sizeof(block_q6_K)`: 128 low-quant bytes, 64 high-quant bytes, 16 i8 scales, f16 d.
pub const BLOCK_Q6_K_BYTES: usize = 210;

fn get_scale_min_k4(j: usize, q: &[u8]) -> (u8, u8) {
    if j < 4 {
        (q[j] & 63, q[j + 4] & 63)
    } else {
        (
            (q[j + 4] & 0xF) | ((q[j - 4] >> 6) << 4),
            (q[j + 4] >> 4) | ((q[j] >> 6) << 4),
        )
    }
}

/// `dequantize_row_q4_K` (ggml-quants.c L1529), scalar order of operations preserved.
pub fn dequantize_row_q4_k(x: &[u8], y: &mut [f32]) {
    assert!(
        x.len() % BLOCK_Q4_K_BYTES == 0,
        "dequantize_row_q4_k: partial block"
    );
    assert_eq!(
        y.len(),
        x.len() / BLOCK_Q4_K_BYTES * QK_K,
        "dequantize_row_q4_k: bad output length"
    );
    for (block, out) in x
        .chunks_exact(BLOCK_Q4_K_BYTES)
        .zip(y.chunks_exact_mut(QK_K))
    {
        let d = f16_to_f32(u16::from_le_bytes([block[0], block[1]]));
        let min = f16_to_f32(u16::from_le_bytes([block[2], block[3]]));
        let scales = &block[4..16];
        let qs = &block[16..];
        let mut is = 0;
        for (chunk, q) in out.chunks_exact_mut(64).zip(qs.chunks_exact(32)) {
            let (sc, m) = get_scale_min_k4(is, scales);
            let d1 = d * f32::from(sc);
            let m1 = min * f32::from(m);
            let (sc, m) = get_scale_min_k4(is + 1, scales);
            let d2 = d * f32::from(sc);
            let m2 = min * f32::from(m);
            for l in 0..32 {
                chunk[l] = d1 * f32::from(q[l] & 0xF) - m1;
            }
            for l in 0..32 {
                chunk[32 + l] = d2 * f32::from(q[l] >> 4) - m2;
            }
            is += 2;
        }
    }
}

/// `dequantize_row_q6_K` (ggml-quants.c L1939), scalar order of operations preserved.
pub fn dequantize_row_q6_k(x: &[u8], y: &mut [f32]) {
    assert!(
        x.len() % BLOCK_Q6_K_BYTES == 0,
        "dequantize_row_q6_k: partial block"
    );
    assert_eq!(
        y.len(),
        x.len() / BLOCK_Q6_K_BYTES * QK_K,
        "dequantize_row_q6_k: bad output length"
    );
    for (block, out) in x
        .chunks_exact(BLOCK_Q6_K_BYTES)
        .zip(y.chunks_exact_mut(QK_K))
    {
        let (ql_all, rest) = block.split_at(QK_K / 2);
        let (qh_all, rest) = rest.split_at(QK_K / 4);
        let (sc_all, d_bytes) = rest.split_at(QK_K / 16);
        let d = f16_to_f32(u16::from_le_bytes([d_bytes[0], d_bytes[1]]));
        for n in 0..2 {
            let ql = &ql_all[n * 64..];
            let qh = &qh_all[n * 32..];
            let sc = &sc_all[n * 8..];
            let y = &mut out[n * 128..];
            for l in 0..32 {
                let is = l / 16;
                let q1 = ((ql[l] & 0xF) | ((qh[l] & 3) << 4)) as i8 - 32;
                let q2 = ((ql[l + 32] & 0xF) | (((qh[l] >> 2) & 3) << 4)) as i8 - 32;
                let q3 = ((ql[l] >> 4) | (((qh[l] >> 4) & 3) << 4)) as i8 - 32;
                let q4 = ((ql[l + 32] >> 4) | (((qh[l] >> 6) & 3) << 4)) as i8 - 32;
                y[l] = d * f32::from(sc[is] as i8) * f32::from(q1);
                y[l + 32] = d * f32::from(sc[is + 2] as i8) * f32::from(q2);
                y[l + 64] = d * f32::from(sc[is + 4] as i8) * f32::from(q3);
                y[l + 96] = d * f32::from(sc[is + 6] as i8) * f32::from(q4);
            }
        }
    }
}

/// Dequantizes `data` (a whole number of rows of `dtype`) into `out`.
pub(crate) fn dequantize_into(dtype: DType, data: &[u8], out: &mut [f32]) {
    match dtype {
        DType::F32 => {
            assert_eq!(data.len(), out.len() * 4);
            for (o, b) in out.iter_mut().zip(data.chunks_exact(4)) {
                *o = f32::from_le_bytes([b[0], b[1], b[2], b[3]]);
            }
        }
        DType::F16 => {
            assert_eq!(data.len(), out.len() * 2);
            for (o, b) in out.iter_mut().zip(data.chunks_exact(2)) {
                *o = f16_to_f32(u16::from_le_bytes([b[0], b[1]]));
            }
        }
        DType::Q8_0 => dequantize_row_q8_0(data, out),
        DType::Q4_K => dequantize_row_q4_k(data, out),
        DType::Q6_K => dequantize_row_q6_k(data, out),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hardware binary32 -> binary16 conversion (FPCR default: round-to-nearest-even). This is
    /// what clang emits for `(__fp16) f` on Apple silicon, an independent reference.
    #[cfg(target_arch = "aarch64")]
    fn hw_f32_to_f16(x: f32) -> u16 {
        let out: u32;
        // SAFETY: pure register arithmetic, no memory access.
        unsafe {
            std::arch::asm!(
                "fcvt {h:h}, {s:s}",
                "fmov {o:w}, {h:s}",
                s = in(vreg) x,
                h = out(vreg) _,
                o = out(reg) out,
                options(pure, nomem, nostack),
            );
        }
        out as u16
    }

    #[cfg(target_arch = "aarch64")]
    fn hw_f16_to_f32(h: u16) -> f32 {
        let out: f32;
        // SAFETY: pure register arithmetic, no memory access.
        unsafe {
            std::arch::asm!(
                "fmov {t:s}, {i:w}",
                "fcvt {o:s}, {t:h}",
                i = in(reg) u32::from(h),
                t = out(vreg) _,
                o = out(vreg) out,
                options(pure, nomem, nostack),
            );
        }
        out
    }

    #[test]
    fn f16_to_f32_round_trips_every_non_nan_pattern() {
        for h in 0..=u16::MAX {
            let f = f16_to_f32(h);
            let is_nan = (h & 0x7C00) == 0x7C00 && (h & 0x03FF) != 0;
            if is_nan {
                assert!(f.is_nan(), "{h:#06x} must decode to NaN");
                assert_eq!(f32_to_f16(f), 0x7E00 | (h & 0x8000), "NaN canonicalization");
            } else {
                assert_eq!(f32_to_f16(f), h, "round trip of {h:#06x} via {f:e}");
            }
        }
    }

    #[cfg(target_arch = "aarch64")]
    #[test]
    fn f16_to_f32_matches_hardware_for_every_pattern() {
        for h in 0..=u16::MAX {
            let ours = f16_to_f32(h);
            let hw = hw_f16_to_f32(h);
            if hw.is_nan() {
                assert!(ours.is_nan());
            } else {
                assert_eq!(ours.to_bits(), hw.to_bits(), "{h:#06x}");
            }
        }
    }

    #[cfg(target_arch = "aarch64")]
    #[test]
    fn f32_to_f16_matches_hardware_rne() {
        let check = |x: f32| {
            let ours = f32_to_f16(x);
            if x.is_nan() {
                assert_eq!(ours & 0x7FFF, 0x7E00, "NaN {:#010x}", x.to_bits());
            } else {
                assert_eq!(ours, hw_f32_to_f16(x), "{x:e} ({:#010x})", x.to_bits());
            }
        };
        // Every f16 value and its neighbourhood: the exact value, the exact rounding ties
        // (half an f16 ulp away) and one f32 ulp either side of each tie.
        for h in 0..0x7C00u16 {
            for sign in [0u16, 0x8000] {
                let v = f16_to_f32(h | sign);
                let next = f16_to_f32((h + 1) | sign);
                let tie = (f64::from(v) + f64::from(next)) / 2.0;
                let tie32 = tie as f32;
                for x in [
                    v,
                    tie32,
                    f32::from_bits(tie32.to_bits().wrapping_add(1)),
                    f32::from_bits(tie32.to_bits().wrapping_sub(1)),
                ] {
                    check(x);
                }
            }
        }
        // A dense sweep across the whole f32 range (prime stride hits every exponent).
        let mut bits = 0u32;
        loop {
            check(f32::from_bits(bits));
            match bits.checked_add(4099) {
                Some(b) => bits = b,
                None => break,
            }
        }
        for x in [
            0.0f32,
            -0.0,
            f32::INFINITY,
            f32::NEG_INFINITY,
            65504.0,
            65519.99,
            65520.0,
            1e-8,
            -1e-8,
        ] {
            check(x);
        }
    }

    #[test]
    fn f32_to_f16_known_values() {
        assert_eq!(f32_to_f16(1.0), 0x3C00);
        assert_eq!(f32_to_f16(-2.0), 0xC000);
        assert_eq!(f32_to_f16(65504.0), 0x7BFF);
        assert_eq!(f32_to_f16(65520.0), 0x7C00); // ties-to-even overflows to +inf
        assert_eq!(f32_to_f16(5.960_464_5e-8), 0x0001); // smallest subnormal
        assert_eq!(f32_to_f16(1.0 + 1.0 / 2048.0), 0x3C00); // tie -> even mantissa
        assert_eq!(f32_to_f16(1.0 + 3.0 / 2048.0), 0x3C02); // tie -> even mantissa (up)
        assert_eq!(f32_to_f16(f32::NAN), 0x7E00);
    }

    #[test]
    fn q8_0_block_layout_and_known_values() {
        // amax 127 -> d = 1.0 exactly, quants are the rounded inputs.
        let mut x = [0.0f32; 32];
        for (j, v) in x.iter_mut().enumerate() {
            *v = j as f32 * 4.0 - 64.0; // -64 .. 60
        }
        x[31] = 127.0;
        x[30] = 2.5; // rounds half away from zero -> 3
        x[29] = -2.5; // -> -3
        let mut q = [0u8; 34];
        quantize_row_q8_0(&x, &mut q);
        assert_eq!(u16::from_le_bytes([q[0], q[1]]), 0x3C00, "d == 1.0");
        let block = BlockQ8_0::from_bytes(&q);
        assert_eq!(block.to_bytes(), q);
        assert_eq!(block.qs[31], 127);
        assert_eq!(block.qs[30], 3);
        assert_eq!(block.qs[29], -3);
        assert_eq!(block.qs[0], -64);
        let mut y = [0.0f32; 32];
        dequantize_row_q8_0(&q, &mut y);
        let mut z = [0.0f32; 32];
        block.dequantize(&mut z);
        assert_eq!(y, z);
        assert_eq!(y[30], 3.0);
        assert_eq!(y[0], -64.0);
    }

    #[test]
    fn q8_0_zero_block_has_zero_scale() {
        let x = [0.0f32; 64];
        let mut q = [0xAAu8; 68];
        quantize_row_q8_0(&x, &mut q);
        assert!(q.iter().all(|&b| b == 0));
        let mut y = [1.0f32; 64];
        dequantize_row_q8_0(&q, &mut y);
        assert!(y.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn q8_0_round_trip_error_is_bounded_by_half_a_step() {
        // Deterministic pseudo-random rows with a wide dynamic range.
        let mut state = 0x2545_F491_4F6C_DD1Du64;
        let mut x = vec![0.0f32; 32 * 257];
        for (i, v) in x.iter_mut().enumerate() {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let unit = (state >> 40) as f32 / (1u64 << 24) as f32 * 2.0 - 1.0;
            *v = unit * 10f32.powi((i / 32 % 9) as i32 - 4);
        }
        let mut q = vec![0u8; x.len() / 32 * 34];
        quantize_row_q8_0(&x, &mut q);
        let mut y = vec![0.0f32; x.len()];
        dequantize_row_q8_0(&q, &mut y);
        for (b, (xb, yb)) in x.chunks_exact(32).zip(y.chunks_exact(32)).enumerate() {
            let d = f16_to_f32(u16::from_le_bytes([q[b * 34], q[b * 34 + 1]]));
            let amax = xb.iter().fold(0.0f32, |m, v| m.max(v.abs()));
            let exact = amax / 127.0;
            // d is amax/127 rounded to f16: relative error <= 2^-11 for normal results,
            // absolute error <= 2^-25 (half the smallest subnormal step) below 2^-14.
            assert!(
                (d - exact).abs() <= exact * 4.9e-4 + 3.0e-8,
                "block {b}: d {d} vs {exact}"
            );
            for (&a, &r) in xb.iter().zip(yb) {
                // Quants come from the unrounded scale (|a/exact - q| <= 0.5); dequantizing with
                // the f16 scale adds at most 127 * |d - exact|.
                let bound = 0.5 * exact + 127.0 * (d - exact).abs() + 1e-6 * amax;
                assert!((a - r).abs() <= bound, "block {b}: {a} vs {r} (d {d})");
            }
        }
    }

    #[test]
    fn q4_k_dequant_matches_formula() {
        let mut block = [0u8; BLOCK_Q4_K_BYTES];
        block[..2].copy_from_slice(&f32_to_f16(0.5).to_le_bytes()); // d
        block[2..4].copy_from_slice(&f32_to_f16(0.25).to_le_bytes()); // dmin
        // Sub-block j (0..8) scale/min: j < 4 -> low 6 bits of scales[j] / scales[j+4];
        // j >= 4 -> nibbles of scales[j+4] plus top 2 bits of scales[j-4] / scales[j].
        let sc: [u8; 8] = [1, 2, 3, 4, 17, 33, 49, 63];
        let mn: [u8; 8] = [5, 6, 7, 8, 18, 34, 50, 62];
        let scales = &mut block[4..16];
        for j in 0..4 {
            scales[j] = sc[j] | ((sc[j + 4] >> 4) << 6);
            scales[j + 4] = mn[j] | ((mn[j + 4] >> 4) << 6);
            scales[j + 8] = (sc[j + 4] & 0xF) | ((mn[j + 4] & 0xF) << 4);
        }
        for (i, q) in block[16..].iter_mut().enumerate() {
            *q = (i as u8).wrapping_mul(37);
        }
        let mut y = [0.0f32; QK_K];
        dequantize_row_q4_k(&block, &mut y);
        for sub in 0..8 {
            let (s, m) = get_scale_min_k4(sub, &block[4..16]);
            assert_eq!(
                (s, m),
                (sc[sub], mn[sub]),
                "scale packing for sub-block {sub}"
            );
            for l in 0..32 {
                let byte = block[16 + (sub / 2) * 32 + l];
                let nib = if sub % 2 == 0 { byte & 0xF } else { byte >> 4 };
                let expect = 0.5 * f32::from(s) * f32::from(nib) - 0.25 * f32::from(m);
                assert_eq!(y[sub * 32 + l], expect);
            }
        }
    }

    #[test]
    fn q6_k_dequant_matches_formula() {
        let mut block = [0u8; BLOCK_Q6_K_BYTES];
        // 6-bit quant value for element e: low 4 bits in ql, high 2 bits in qh.
        let quant = |e: usize| ((e * 11 + 5) % 64) as u8;
        for e in 0..QK_K {
            let n = e / 128;
            let r = e % 128;
            let l = r % 32;
            let part = r / 32; // 0: ql[l] low, 1: ql[l+32] low, 2: ql[l] high, 3: ql[l+32] high
            let q = quant(e);
            let ql_index = n * 64 + l + if part % 2 == 1 { 32 } else { 0 };
            if part < 2 {
                block[ql_index] |= q & 0xF;
            } else {
                block[ql_index] |= (q & 0xF) << 4;
            }
            block[128 + n * 32 + l] |= (q >> 4) << (2 * part);
        }
        for (i, s) in block[192..208].iter_mut().enumerate() {
            *s = (i as i8 - 8) as u8;
        }
        block[208..].copy_from_slice(&f32_to_f16(0.125).to_le_bytes());
        let mut y = [0.0f32; QK_K];
        dequantize_row_q6_k(&block, &mut y);
        for e in 0..QK_K {
            let n = e / 128;
            let r = e % 128;
            let l = r % 32;
            let part = r / 32;
            let scale = (block[192 + n * 8 + l / 16 + 2 * part]) as i8;
            let expect = 0.125 * f32::from(scale) * f32::from(quant(e) as i8 - 32);
            assert_eq!(y[e], expect, "element {e}");
        }
    }

    #[test]
    fn payload_bytes_matches_native_rules() {
        assert_eq!(DType::F32.payload_bytes(&[1024, 1, 1, 1]), Some(4096));
        assert_eq!(
            DType::F16.payload_bytes(&[1024, 4096, 1, 1]),
            Some(8 * 1024 * 1024)
        );
        assert_eq!(DType::Q8_0.payload_bytes(&[64, 3, 1, 1]), Some(2 * 34 * 3));
        assert_eq!(DType::Q8_0.payload_bytes(&[48, 1, 1, 1]), None); // not whole blocks
        assert_eq!(DType::Q6_K.payload_bytes(&[256, 2, 1, 1]), Some(420));
        assert_eq!(DType::F32.payload_bytes(&[0, 1, 1, 1]), None);
        assert_eq!(DType::from_ggml_id(26), None); // I32 records are refused natively
        assert_eq!(ftype_to_ggml_type(1), Some(1));
        assert_eq!(ftype_to_ggml_type(4), None);
    }
}
