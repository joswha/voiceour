//! Port of `MercuryOctahedralMap`, `MercuryEnvironment` and `RoomOfTenWorld`
//! (Sources/Voiceour/MercuryEnvironment.swift): the static generated room and its three
//! bordered 96² octahedral linear-RGB tables.
//!
//! Every expression keeps the Swift source's operand order; floating-point addition and
//! multiplication are not associative, and byte identity is the contract.

use std::sync::LazyLock;

use crate::noise::{Noise, stream};
use crate::swift::{self, LEAST_NONZERO_F64};

/// `MercuryMetrics.environmentResolution`.
pub const RESOLUTION: usize = 96;
/// One analytic border texel on every edge.
pub const STORAGE: usize = RESOLUTION + 2;
pub const LEVEL_STRIDE: usize = STORAGE * STORAGE;
/// `MercuryMetrics.environmentRoughness.count`.
pub const LEVELS: usize = 3;

const GRID_ROUGHNESS: f64 = 0.019;
const ROOM_LOBE_COUNT: usize = 32;
const ROOM_LAMBDA_MIN: f64 = 20.0;
const ROOM_LAMBDA_MAX: f64 = 600.0;
const ROOM_LOG_INTENSITY_RANGE: f64 = 0.55;
const ROOM_BOUNCE_FRACTION: f64 = 0.30;
const ROOM_CHROMA_STRENGTH: f64 = 0.07;
const INTEGRATION_COUNT: usize = 4_096;

/// `MercuryMetrics.environmentRoughness`, a `[Float]` literal.
fn roughness_levels() -> [f32; LEVELS] {
    [
        swift::float_literal(0.03),
        swift::float_literal(0.09),
        swift::float_literal(0.25),
    ]
}

/// One `SIMD3<Float>` texel: three lanes plus padding, 16-byte aligned like Swift's.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Texel(pub [f32; 4]);

impl Texel {
    #[inline(always)]
    pub fn rgb(self) -> [f32; 3] {
        [self.0[0], self.0[1], self.0[2]]
    }
}

/// `MercuryOctahedralMap.encode`.
#[inline(always)]
pub fn encode(direction: [f32; 3]) -> [f32; 2] {
    let denominator = direction[0].abs() + direction[1].abs() + direction[2].abs();
    if !(denominator > swift::float_literal(1e-12)) {
        return [0.0, 0.0];
    }
    let projected = [
        direction[0] / denominator,
        direction[1] / denominator,
        direction[2] / denominator,
    ];
    if !(projected[2] < 0.0) {
        return [projected[0], projected[1]];
    }
    [
        (1.0 - projected[1].abs()) * sign_not_zero(projected[0]),
        (1.0 - projected[0].abs()) * sign_not_zero(projected[1]),
    ]
}

/// `MercuryOctahedralMap.decode`.
pub fn decode(point: [f32; 2]) -> [f32; 3] {
    let mut direction = [point[0], point[1], 1.0 - point[0].abs() - point[1].abs()];
    let fold = swift::max(-direction[2], 0.0);
    direction[0] += if direction[0] >= 0.0 { -fold } else { fold };
    direction[1] += if direction[1] >= 0.0 { -fold } else { fold };
    let length =
        (direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2])
            .sqrt();
    if length > swift::float_literal(1e-12) {
        [
            direction[0] / length,
            direction[1] / length,
            direction[2] / length,
        ]
    } else {
        [0.0, 0.0, 1.0]
    }
}

#[inline(always)]
fn sign_not_zero(value: f32) -> f32 {
    if value < 0.0 { -1.0 } else { 1.0 }
}

/// Unit direction of every bordered octahedral texel (`MercuryEnvironment.directions`).
static DIRECTIONS: LazyLock<Vec<[f32; 3]>> = LazyLock::new(|| {
    let mut result = Vec::with_capacity(LEVEL_STRIDE);
    let scale = 2.0f32 / RESOLUTION as f32;
    for row in 0..STORAGE {
        let vertical = (row as f32 - 0.5) * scale - 1.0;
        for column in 0..STORAGE {
            let horizontal = (column as f32 - 0.5) * scale - 1.0;
            result.push(decode([horizontal, vertical]));
        }
    }
    result
});

/// Fixed golden-spiral lattice (`MercuryEnvironment.integrationDirections`).
static INTEGRATION_DIRECTIONS: LazyLock<Vec<[f32; 3]>> = LazyLock::new(|| {
    let golden = std::f64::consts::PI * (3.0 - 5.0f64.sqrt());
    (0..INTEGRATION_COUNT)
        .map(|index| {
            let height = 1.0 - 2.0 * (index as f64 + 0.5) / INTEGRATION_COUNT as f64;
            let radius = swift::max(0.0, 1.0 - height * height).sqrt();
            let angle = golden * index as f64;
            [
                (radius * angle.cos()) as f32,
                (radius * angle.sin()) as f32,
                height as f32,
            ]
        })
        .collect()
});

/// The generated room the mercury reflects: three prefiltered levels, static after the
/// seed draw. Only `roomOfTen` is ported; Spectral Weather is debug-only in production.
pub struct Environment {
    tables: Vec<Texel>,
}

impl Environment {
    /// `MercuryEnvironment(world: .roomOfTen, seed:)`.
    pub fn room_of_ten(seed: u64) -> Self {
        let room = RoomOfTen::new(seed);
        let mut environment = Self {
            tables: vec![Texel::default(); LEVEL_STRIDE * LEVELS],
        };
        let directions: &[[f32; 3]] = &DIRECTIONS;
        for (level, roughness) in roughness_levels().into_iter().enumerate() {
            let effective =
                ((roughness as f64) * (roughness as f64) + GRID_ROUGHNESS * GRID_ROUGHNESS).sqrt();
            let destination =
                &mut environment.tables[level * LEVEL_STRIDE..(level + 1) * LEVEL_STRIDE];
            room.bake(destination, directions, effective);
        }
        environment.equalize_power();
        environment.apply_normalization();
        environment
    }

    /// All three levels, texel-major.
    pub fn tables(&self) -> &[Texel] {
        &self.tables
    }

    /// The production smooth level (`MercuryEnvironment.radiance(_:)`).
    #[inline(always)]
    pub fn radiance(&self, direction: [f32; 3]) -> [f32; 3] {
        self.sample(0, direction)
    }

    /// `MercuryEnvironment.sample(level:direction:)`: one bilinear four-tap lookup.
    #[inline(always)]
    pub fn sample(&self, level: usize, direction: [f32; 3]) -> [f32; 3] {
        let point = encode(direction);
        let half = 0.5 * RESOLUTION as f32;
        let coordinate_x = (point[0] + 1.0) * half + 0.5;
        let coordinate_y = (point[1] + 1.0) * half + 0.5;
        let column = swift::min(swift::max(coordinate_x as isize, 0), RESOLUTION as isize);
        let row = swift::min(swift::max(coordinate_y as isize, 0), RESOLUTION as isize);
        let column_fraction = coordinate_x - column as f32;
        let row_fraction = coordinate_y - row as f32;
        let base = level * LEVEL_STRIDE + row as usize * STORAGE + column as usize;
        let taps = &self.tables[base..base + STORAGE + 2];
        let top_left = taps[0].0;
        let top_right = taps[1].0;
        let bottom_left = taps[STORAGE].0;
        let bottom_right = taps[STORAGE + 1].0;
        let mut result = [0.0f32; 3];
        for lane in 0..3 {
            let top = top_left[lane] + (top_right[lane] - top_left[lane]) * column_fraction;
            let bottom =
                bottom_left[lane] + (bottom_right[lane] - bottom_left[lane]) * column_fraction;
            result[lane] = top + (bottom - top) * row_fraction;
        }
        result
    }

    /// Pins the rougher levels to the sharpest one's mean (`equalizePower`).
    fn equalize_power(&mut self) {
        let reference = self.weighted_mean(0);
        if !(reference > 1e-12) {
            return;
        }
        for level in 1..LEVELS {
            let mean = self.weighted_mean(level);
            if !(mean > 1e-12) {
                continue;
            }
            let scale = (reference / mean) as f32;
            for texel in &mut self.tables[level * LEVEL_STRIDE..(level + 1) * LEVEL_STRIDE] {
                for lane in 0..4 {
                    texel.0[lane] *= scale;
                }
            }
        }
    }

    fn weighted_mean(&self, level: usize) -> f64 {
        let mut total = 0.0;
        let directions: &[[f32; 3]] = &INTEGRATION_DIRECTIONS;
        for &direction in directions {
            let value = self.sample(level, direction);
            total += 0.2126 * value[0] as f64 + 0.7152 * value[1] as f64 + 0.0722 * value[2] as f64;
        }
        total / directions.len() as f64
    }

    /// One fixed scalar placing the room in a sane numeric range (`applyNormalization`).
    fn apply_normalization(&mut self) {
        let mean = self.weighted_mean(0);
        let normalization: f32 = if mean > 1e-12 {
            (1.0 / mean) as f32
        } else {
            1.0
        };
        if normalization == 1.0 {
            return;
        }
        for texel in &mut self.tables {
            for lane in 0..4 {
                texel.0[lane] *= normalization;
            }
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Source {
    sharpness: f64,
    intensity: f64,
    axis: [f64; 3],
    chroma_coefficient: f64,
    tint: [f64; 3],
}

/// `RoomOfTenWorld`: bounded spherical-Gaussian area sources over a neutral bounce.
struct RoomOfTen {
    sources: Vec<Source>,
}

impl RoomOfTen {
    fn new(seed: u64) -> Self {
        let noise = Noise::new(seed);
        let count = ROOM_LOBE_COUNT;
        let log_minimum = ROOM_LAMBDA_MIN.ln();
        let log_maximum = ROOM_LAMBDA_MAX.ln();
        let mut sources = Vec::with_capacity(count);
        for index in 0..count {
            let counter = index as u64;
            let band = noise.uniform(stream::ROOM_LOBES, counter.wrapping_mul(3));
            let azimuth_draw =
                noise.uniform(stream::ROOM_LOBES, counter.wrapping_mul(3).wrapping_add(1));
            let sharpness_draw =
                noise.uniform(stream::ROOM_LOBES, counter.wrapping_mul(3).wrapping_add(2));
            let height = -1.0 + 2.0 * (index as f64 + band) / count as f64;
            let radius = swift::max(0.0, 1.0 - height * height).sqrt();
            let azimuth = 2.0 * std::f64::consts::PI * azimuth_draw;
            let intensity_draw = 2.0 * noise.uniform(stream::ROOM_INTENSITY, counter) - 1.0;
            let chroma_draw = 2.0 * noise.uniform(stream::ROOM_CHROMA, counter) - 1.0;
            sources.push(Source {
                sharpness: (log_minimum + sharpness_draw * (log_maximum - log_minimum)).exp(),
                intensity: (ROOM_LOG_INTENSITY_RANGE * intensity_draw).exp(),
                axis: [radius * azimuth.cos(), radius * azimuth.sin(), height],
                chroma_coefficient: chroma_draw,
                tint: [1.0, 1.0, 1.0],
            });
        }

        let source_mean = sources
            .iter()
            .fold(0.0, |total, source| total + power(source));
        let chroma_mean = sources.iter().fold(0.0, |total, source| {
            total + power(source) * source.chroma_coefficient
        }) / swift::max(source_mean, 1e-12);
        let maximum_chroma = sources.iter().fold(0.0, |worst, source| {
            swift::max(worst, (source.chroma_coefficient - chroma_mean).abs())
        });
        let opponent = opponent(&noise);
        let source_share = 1.0 - ROOM_BOUNCE_FRACTION;
        let sources = sources
            .into_iter()
            .map(|source| {
                let coefficient =
                    (source.chroma_coefficient - chroma_mean) / swift::max(maximum_chroma, 1e-12);
                let weight = ROOM_CHROMA_STRENGTH * coefficient;
                Source {
                    sharpness: source.sharpness,
                    intensity: source.intensity * source_share / swift::max(source_mean, 1e-12),
                    axis: source.axis,
                    chroma_coefficient: coefficient,
                    tint: [
                        1.0 + weight * opponent[0],
                        1.0 + weight * opponent[1],
                        1.0 + weight * opponent[2],
                    ],
                }
            })
            .collect();
        Self { sources }
    }

    /// `RoomOfTenWorld.bake`: exact spherical-Gaussian convolution, one texel per direction.
    ///
    /// The per-source factors depend only on the level's roughness. Swift evaluates them
    /// inside the texel loop; they are the same expressions on the same operands, so
    /// hoisting them changes no bit and only speeds up construction.
    fn bake(&self, destination: &mut [Texel], directions: &[[f32; 3]], roughness: f64) {
        struct Lobe {
            filtered: f64,
            weight: f64,
            axis: [f64; 3],
            tint: [f64; 3],
        }
        let lobes: Vec<Lobe> = self
            .sources
            .iter()
            .map(|source| {
                let filtered = source.sharpness / (1.0 + source.sharpness * roughness * roughness);
                let power_scale = (filtered / source.sharpness)
                    * (1.0 - (-2.0 * source.sharpness).exp())
                    / swift::max(1.0 - (-2.0 * filtered).exp(), 1e-12);
                Lobe {
                    filtered,
                    // `source.intensity * powerScale * exp(...)` multiplies left to right.
                    weight: source.intensity * power_scale,
                    axis: source.axis,
                    tint: source.tint,
                }
            })
            .collect();
        for (texel, direction) in destination.iter_mut().zip(directions) {
            let vector = [
                direction[0] as f64,
                direction[1] as f64,
                direction[2] as f64,
            ];
            let mut value = [ROOM_BOUNCE_FRACTION; 3];
            for lobe in &lobes {
                let cosine =
                    vector[0] * lobe.axis[0] + vector[1] * lobe.axis[1] + vector[2] * lobe.axis[2];
                let contribution = lobe.weight * (lobe.filtered * (cosine - 1.0)).exp();
                value[0] += contribution * lobe.tint[0];
                value[1] += contribution * lobe.tint[1];
                value[2] += contribution * lobe.tint[2];
            }
            *texel = Texel([
                swift::max(value[0], LEAST_NONZERO_F64) as f32,
                swift::max(value[1], LEAST_NONZERO_F64) as f32,
                swift::max(value[2], LEAST_NONZERO_F64) as f32,
                0.0,
            ]);
        }
    }
}

fn power(source: &Source) -> f64 {
    source.intensity * (1.0 - (-2.0 * source.sharpness).exp()) / (2.0 * source.sharpness)
}

/// Seed-random opponent projected onto the Rec.709 luminance-null plane.
fn opponent(noise: &Noise) -> [f64; 3] {
    let random = noise.unit_vector(stream::ROOM_CHROMA, 10_000);
    let luminance = [0.2126, 0.7152, 0.0722];
    let dot = random[0] * luminance[0] + random[1] * luminance[1] + random[2] * luminance[2];
    let norm =
        luminance[0] * luminance[0] + luminance[1] * luminance[1] + luminance[2] * luminance[2];
    let ratio = dot / norm;
    let projected = [
        random[0] - luminance[0] * ratio,
        random[1] - luminance[1] * ratio,
        random[2] - luminance[2] * ratio,
    ];
    let scale = swift::max(
        projected[0].abs(),
        swift::max(projected[1].abs(), projected[2].abs()),
    );
    let divisor = swift::max(scale, 1e-12);
    [
        projected[0] / divisor,
        projected[1] / divisor,
        projected[2] / divisor,
    ]
}
