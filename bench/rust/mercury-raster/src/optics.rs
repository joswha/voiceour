//! Port of `MercuryOptics` (Sources/Voiceour/MercuryOptics.swift): the process-built
//! conductor Fresnel, sRGB transfer and opaque-byte tables, plus their exact oracles.

use std::sync::LazyLock;

use crate::environment::Texel;
use crate::swift;

pub const FRESNEL_MINIMUM: f64 = 1e-4;
pub const FRESNEL_COUNT: usize = 1_024;
pub const TRANSFER_COUNT: usize = 4_096;
pub const OPAQUE_TRANSFER_COUNT: usize = 16_384;

/// `MercuryMetrics.mercuryN` / `mercuryK` at the sRGB primaries.
const MERCURY_N: [f64; 3] = [1.85901, 1.55229, 1.11003];
const MERCURY_K: [f64; 3] = [5.0793, 4.65101, 3.94276];

/// The three process-wide tables, built once like Swift's `static let`s.
pub struct Optics {
    pub fresnel: Vec<Texel>,
    pub transfer: Vec<f32>,
    pub opaque: Vec<u8>,
}

pub static OPTICS: LazyLock<Optics> = LazyLock::new(|| Optics {
    fresnel: (0..FRESNEL_COUNT)
        .map(|index| {
            let cosine = FRESNEL_MINIMUM
                + (1.0 - FRESNEL_MINIMUM) * index as f64 / (FRESNEL_COUNT - 1) as f64;
            let value = exact_fresnel(cosine);
            Texel([value[0] as f32, value[1] as f32, value[2] as f32, 0.0])
        })
        .collect(),
    transfer: (0..TRANSFER_COUNT)
        .map(|index| exact_encode_srgb(index as f64 / (TRANSFER_COUNT - 1) as f64) as f32)
        .collect(),
    opaque: (0..OPAQUE_TRANSFER_COUNT)
        .map(|index| {
            let encoded = exact_encode_srgb(index as f64 / (OPAQUE_TRANSFER_COUNT - 1) as f64);
            swift::min(255, swift::max(0, (encoded * 255.0 + 0.5) as isize)) as u8
        })
        .collect(),
});

impl Optics {
    /// `MercuryOptics.fresnel(cosine:)`: one interpolated table lookup.
    #[inline(always)]
    pub fn fresnel(&self, cosine: f64) -> [f64; 3] {
        let clamped = swift::min(swift::max(cosine, FRESNEL_MINIMUM), 1.0);
        let scaled =
            (clamped - FRESNEL_MINIMUM) * (FRESNEL_COUNT - 1) as f64 / (1.0 - FRESNEL_MINIMUM);
        let lower = scaled as usize;
        let upper = swift::min(lower + 1, FRESNEL_COUNT - 1);
        let fraction = (scaled - lower as f64) as f32;
        let low = self.fresnel[lower].0;
        let high = self.fresnel[upper].0;
        [
            (low[0] + (high[0] - low[0]) * fraction) as f64,
            (low[1] + (high[1] - low[1]) * fraction) as f64,
            (low[2] + (high[2] - low[2]) * fraction) as f64,
        ]
    }

    /// `MercuryOptics.encodeSRGB`: interpolated IEC 61966-2-1 transfer.
    #[inline(always)]
    pub fn encode_srgb(&self, value: f64) -> f64 {
        let clamped = swift::min(swift::max(value, 0.0), 1.0);
        let scaled = clamped * (TRANSFER_COUNT - 1) as f64;
        let lower = scaled as usize;
        let upper = swift::min(lower + 1, TRANSFER_COUNT - 1);
        let fraction = (scaled - lower as f64) as f32;
        (self.transfer[lower] + (self.transfer[upper] - self.transfer[lower]) * fraction) as f64
    }

    /// `MercuryOptics.encodedByte(_:coverage:)`.
    #[inline(always)]
    pub fn encoded_byte(&self, value: f64, coverage: f64) -> u8 {
        let clamped = swift::min(swift::max(value, 0.0), 1.0);
        if coverage >= 1.0 {
            let index = (clamped * (OPAQUE_TRANSFER_COUNT - 1) as f64 + 0.5) as usize;
            return self.opaque[index];
        }
        let encoded = self.encode_srgb(clamped) * coverage;
        swift::min(255, swift::max(0, (encoded * 255.0 + 0.5) as isize)) as u8
    }
}

/// `MercuryOptics.exactFresnel`: unpolarized smooth-conductor reflectance.
pub fn exact_fresnel(cosine: f64) -> [f64; 3] {
    let cosine_squared = cosine * cosine;
    let sine_squared = swift::max(0.0, 1.0 - cosine_squared);
    let mut result = [0.0; 3];
    for channel in 0..3 {
        let refraction = MERCURY_N[channel];
        let extinction = MERCURY_K[channel];
        let base = refraction * refraction - extinction * extinction - sine_squared;
        let squares =
            (base * base + 4.0 * refraction * refraction * extinction * extinction).sqrt();
        let real = swift::max(0.0, (squares + base) / 2.0).sqrt();
        let first = squares + cosine_squared;
        let second = 2.0 * real * cosine;
        let perpendicular = (first - second) / (first + second);
        let third = cosine_squared * squares + sine_squared * sine_squared;
        let fourth = second * sine_squared;
        let parallel = perpendicular * (third - fourth) / (third + fourth);
        result[channel] = (perpendicular + parallel) / 2.0;
    }
    result
}

/// `MercuryOptics.exactEncodeSRGB`.
pub fn exact_encode_srgb(value: f64) -> f64 {
    let clamped = swift::min(swift::max(value, 0.0), 1.0);
    if clamped <= 0.003_130_8 {
        12.92 * clamped
    } else {
        1.055 * clamped.powf(1.0 / 2.4) - 0.055
    }
}

/// `MercuryOptics.viewDirection`: binomial normalization around the finite eye axis.
#[inline(always)]
pub fn view_direction(horizontal: f64, vertical: f64, crown_height: f64) -> [f64; 3] {
    let inverse_depth = 1.0 / (EYE_DISTANCE - crown_height);
    let horizontal_unit = -horizontal * inverse_depth;
    let vertical_unit = -vertical * inverse_depth;
    let squared_offset = horizontal_unit * horizontal_unit + vertical_unit * vertical_unit;
    let normalization =
        1.0 + squared_offset * (-0.5 + squared_offset * (0.375 - 0.3125 * squared_offset));
    [
        horizontal_unit * normalization,
        vertical_unit * normalization,
        normalization,
    ]
}

/// `MercuryMetrics.eyeDistance`.
pub const EYE_DISTANCE: f64 = 1400.0;
