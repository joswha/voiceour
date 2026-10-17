//! Port of `MercuryDisplayResponse` (Sources/Voiceour/MercuryDisplayResponse.swift) and
//! `MercuryDisplayLookup` (Sources/Voiceour/MercuryOptics.swift).

use crate::swift;

/// `MercuryMetrics.increasedContrastMedian` / `increasedContrastHighlight`.
pub const INCREASED_CONTRAST_MEDIAN: f64 = 0.30;
pub const INCREASED_CONTRAST_HIGHLIGHT: f64 = 0.90;

/// A session's bounded Naka–Rushton response. Synthesized `Equatable` compares all five.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DisplayResponse {
    pub exponent: f64,
    pub half_saturation: f64,
    pub ceiling: f64,
    pub scene_median: f64,
    pub scene_highlight: f64,
}

impl DisplayResponse {
    /// `MercuryDisplayResponse.solve`.
    pub fn solve(
        scene_median: f64,
        scene_highlight: f64,
        median_target: f64,
        highlight_target: f64,
        ceiling: f64,
    ) -> Option<Self> {
        if !(scene_median.is_finite()
            && scene_highlight.is_finite()
            && median_target.is_finite()
            && highlight_target.is_finite()
            && ceiling.is_finite()
            && scene_median > 0.0
            && scene_highlight > scene_median
            && median_target > 0.0
            && highlight_target > median_target
            && ceiling > highlight_target)
        {
            return None;
        }
        let median_ratio = ceiling / median_target - 1.0;
        let highlight_ratio = ceiling / highlight_target - 1.0;
        let exponent =
            (median_ratio / highlight_ratio).ln() / (scene_highlight / scene_median).ln();
        if !(exponent.is_finite() && exponent > 0.0) {
            return None;
        }
        let half_saturation = scene_median * median_ratio.powf(1.0 / exponent);
        if !(half_saturation.is_finite() && half_saturation > 0.0) {
            return None;
        }
        Some(Self {
            exponent,
            half_saturation,
            ceiling,
            scene_median,
            scene_highlight,
        })
    }

    /// `remapped(medianTarget:highlightTarget:)`.
    pub fn remapped(&self, median_target: f64, highlight_target: f64) -> Option<Self> {
        Self::solve(
            self.scene_median,
            self.scene_highlight,
            median_target,
            highlight_target,
            self.ceiling,
        )
    }

    /// `map(_ sceneLuminance: Double)`.
    pub fn map_luminance(&self, scene_luminance: f64) -> f64 {
        if !(scene_luminance > 0.0) {
            return 0.0;
        }
        if !scene_luminance.is_finite() {
            return self.ceiling;
        }
        let logit = self.exponent * (self.half_saturation.ln() - scene_luminance.ln());
        let mapped = if logit >= 0.0 {
            let tail = (-logit).exp();
            self.ceiling * tail / (1.0 + tail)
        } else {
            let tail = logit.exp();
            self.ceiling / (1.0 + tail)
        };
        swift::min(mapped, self.ceiling.next_down())
    }
}

/// `MercuryDisplayResponse.luminance`: Rec.709 weights, left to right.
#[inline(always)]
pub fn luminance(value: [f64; 3]) -> f64 {
    0.2126 * value[0] + 0.7152 * value[1] + 0.0722 * value[2]
}

/// `MercuryDisplayLookup`: the response compiled into `u = s / (s + h)`.
pub struct DisplayLookup {
    pub response: DisplayResponse,
    pub table: Vec<[f32; 2]>,
}

pub const LOOKUP_COUNT: usize = 2_048;

impl DisplayLookup {
    pub fn new(response: DisplayResponse) -> Self {
        let table = (0..LOOKUP_COUNT)
            .map(|index| {
                if index == 0 {
                    return [0.0, 0.0];
                }
                if index == LOOKUP_COUNT - 1 {
                    return [response.ceiling.next_down() as f32, 0.0];
                }
                let unit = index as f64 / (LOOKUP_COUNT - 1) as f64;
                let scene = response.half_saturation * unit / (1.0 - unit);
                let mapped = response.map_luminance(scene);
                [mapped as f32, (mapped / scene) as f32]
            })
            .collect();
        Self { response, table }
    }

    /// `sample(_ sceneLuminance:)`: mapped luminance and gain.
    #[inline(always)]
    pub fn sample(&self, scene_luminance: f64) -> (f64, f64) {
        if !(scene_luminance > 0.0) {
            return (0.0, 0.0);
        }
        if !scene_luminance.is_finite() {
            return (self.response.ceiling.next_down(), 0.0);
        }
        let unit = scene_luminance / (scene_luminance + self.response.half_saturation);
        let scaled = unit * (LOOKUP_COUNT - 1) as f64;
        let lower = swift::min(scaled as usize, LOOKUP_COUNT - 1);
        let upper = swift::min(lower + 1, LOOKUP_COUNT - 1);
        let fraction = (scaled - lower as f64) as f32;
        let low = self.table[lower];
        let high = self.table[upper];
        (
            (low[0] + (high[0] - low[0]) * fraction) as f64,
            (low[1] + (high[1] - low[1]) * fraction) as f64,
        )
    }

    /// `map(_ scene: SIMD3<Double>)`: luminance response, ratio restore, gamut slide.
    #[inline(always)]
    pub fn map(&self, scene: [f64; 3]) -> [f64; 3] {
        let scene_luminance = luminance(scene);
        if !(scene_luminance > 0.0 && scene_luminance.is_finite()) {
            return [0.0; 3];
        }
        let (mapped_luminance, gain) = self.sample(scene_luminance);
        let raw = [scene[0] * gain, scene[1] * gain, scene[2] * gain];
        let ceiling = self.response.ceiling;
        if swift::min(raw[0], swift::min(raw[1], raw[2])) >= 0.0
            && swift::max(raw[0], swift::max(raw[1], raw[2])) <= ceiling
        {
            return raw;
        }
        self.slide(raw, mapped_luminance)
    }

    /// The out-of-gamut branch of `map`: slide toward neutral along a luminance-free vector.
    #[cold]
    #[inline(never)]
    pub fn slide(&self, raw: [f64; 3], mapped_luminance: f64) -> [f64; 3] {
        let difference = [
            raw[0] - mapped_luminance,
            raw[1] - mapped_luminance,
            raw[2] - mapped_luminance,
        ];
        let upper = self.response.ceiling - mapped_luminance;
        let limit = |delta: f64| -> f64 {
            if delta > 0.0 {
                upper / delta
            } else if delta < 0.0 {
                mapped_luminance / -delta
            } else {
                1.0
            }
        };
        let amount = swift::max(
            0.0,
            swift::min(
                swift::min(1.0, limit(difference[0])),
                swift::min(limit(difference[1]), limit(difference[2])),
            ),
        );
        [
            mapped_luminance + amount * difference[0],
            mapped_luminance + amount * difference[1],
            mapped_luminance + amount * difference[2],
        ]
    }
}
