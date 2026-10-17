//! Port of `MercuryField` (Sources/Voiceour/MercuryField.swift) and the CoreGraphics
//! rectangle arithmetic its bounding box uses.

use crate::swift;

/// `RecordingOverlayMetrics.islandSize`.
pub const ISLAND_WIDTH: f64 = 180.0;
pub const ISLAND_HEIGHT: f64 = 34.0;
/// `MercuryMetrics.bleed`.
const BLEED: f64 = 1.5;

/// `CGRect` with the CoreGraphics accessors the rasterizer reads.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    /// `CGRectNull`.
    pub const NULL: Rect = Rect {
        x: f64::INFINITY,
        y: f64::INFINITY,
        width: 0.0,
        height: 0.0,
    };

    pub fn min_x(&self) -> f64 {
        if self.width < 0.0 {
            self.x + self.width
        } else {
            self.x
        }
    }

    pub fn max_x(&self) -> f64 {
        if self.width < 0.0 {
            self.x
        } else {
            self.x + self.width
        }
    }

    pub fn min_y(&self) -> f64 {
        if self.height < 0.0 {
            self.y + self.height
        } else {
            self.y
        }
    }

    pub fn max_y(&self) -> f64 {
        if self.height < 0.0 {
            self.y
        } else {
            self.y + self.height
        }
    }

    fn is_null(&self) -> bool {
        self.x == f64::INFINITY || self.y == f64::INFINITY
    }

    /// `CGRectIntersection`: the overlap stored as origin plus size, or `CGRectNull`.
    pub fn intersection(&self, other: &Rect) -> Rect {
        if self.is_null() || other.is_null() {
            return Rect::NULL;
        }
        let x1 = swift::max(self.min_x(), other.min_x());
        let x2 = swift::min(self.max_x(), other.max_x());
        let y1 = swift::max(self.min_y(), other.min_y());
        let y2 = swift::min(self.max_y(), other.max_y());
        if x2 < x1 || y2 < y1 {
            return Rect::NULL;
        }
        Rect {
            x: x1,
            y: y1,
            width: x2 - x1,
            height: y2 - y1,
        }
    }
}

/// `MercuryField.islandBounds`.
pub fn island_bounds() -> Rect {
    Rect {
        x: -ISLAND_WIDTH / 2.0,
        y: -ISLAND_HEIGHT / 2.0,
        width: ISLAND_WIDTH,
        height: ISLAND_HEIGHT,
    }
}

/// `MercuryField.Column`: everything one pixel column's shading needs.
#[derive(Clone, Copy, Debug, Default)]
pub struct Column {
    pub in_span: bool,
    pub cap_offset: f64,
    pub radius: f64,
    pub center: f64,
    pub radius_slope: f64,
    pub center_slope: f64,
}

/// The single signed field over the simulation's top and bottom samples.
pub struct Field<'a> {
    top: &'a [f32],
    bottom: &'a [f32],
    pub length: f64,
    pub lateral_offset: f64,
    pub bounding_box: Rect,
}

impl<'a> Field<'a> {
    /// `MercuryField(geometry:lateralOffset:)`. `top` and `bottom` hold the same, nonzero
    /// number of stations.
    pub fn new(top: &'a [f32], bottom: &'a [f32], length: f64, lateral_offset: f64) -> Self {
        let mut highest = -f64::MAX;
        let mut lowest = f64::MAX;
        for index in 0..top.len() {
            highest = swift::max(highest, top[index] as f64);
            lowest = swift::min(lowest, bottom[index] as f64);
        }
        let last = top.len() - 1;
        let lead_cap = (top[0] as f64 - bottom[0] as f64) / 2.0;
        let trail_cap = (top[last] as f64 - bottom[last] as f64) / 2.0;
        let extent = Rect {
            x: lateral_offset - length / 2.0 - lead_cap - BLEED,
            y: lowest - BLEED,
            width: length + lead_cap + trail_cap + 2.0 * BLEED,
            height: highest - lowest + 2.0 * BLEED,
        };
        Self {
            top,
            bottom,
            length,
            lateral_offset,
            bounding_box: extent.intersection(&island_bounds()),
        }
    }

    /// `column(atX:)`. `horizontal` is already relative to the body's own centre.
    #[inline(always)]
    pub fn column(&self, horizontal: f64) -> Column {
        let half = self.length / 2.0;
        let clamped = swift::min(swift::max(horizontal, -half), half);
        let material = if self.length > 0.0 {
            (clamped + half) / self.length
        } else {
            0.0
        };
        let stations = self.top.len() - 1;
        let position = material * stations as f64;
        let index = swift::min(position as usize, stations);
        let fraction = position - index as f64;
        let next = swift::min(index + 1, stations);

        let radius = mix(self.radius(index), self.radius(next), fraction);
        let center = mix(self.center(index), self.center(next), fraction);
        let scale = stations as f64;
        Column {
            in_span: horizontal >= -half && horizontal <= half,
            cap_offset: horizontal - clamped,
            radius,
            center,
            radius_slope: mix(self.radius_slope(index), self.radius_slope(next), fraction) * scale,
            center_slope: mix(self.center_slope(index), self.center_slope(next), fraction) * scale,
        }
    }

    #[inline(always)]
    fn radius(&self, index: usize) -> f64 {
        (self.top[index] as f64 - self.bottom[index] as f64) / 2.0
    }

    #[inline(always)]
    fn center(&self, index: usize) -> f64 {
        (self.top[index] as f64 + self.bottom[index] as f64) / 2.0
    }

    #[inline(always)]
    fn radius_slope(&self, index: usize) -> f64 {
        let low = index.saturating_sub(1);
        let high = swift::min(index + 1, self.top.len() - 1);
        (self.radius(high) - self.radius(low)) / (high - low) as f64
    }

    #[inline(always)]
    fn center_slope(&self, index: usize) -> f64 {
        let low = index.saturating_sub(1);
        let high = swift::min(index + 1, self.top.len() - 1);
        (self.center(high) - self.center(low)) / (high - low) as f64
    }
}

/// `MercuryField.gradient(column:vertical:length:)`.
#[inline(always)]
pub fn gradient(column: &Column, vertical: f64, length: f64) -> (f64, f64) {
    if !column.in_span {
        let offset = column.cap_offset;
        let distance = (offset * offset + vertical * vertical).sqrt();
        if !(distance > 1e-9) {
            return (0.0, -1.0);
        }
        return (-offset / distance, -vertical / distance);
    }
    let sign: f64 = if vertical >= 0.0 { 1.0 } else { -1.0 };
    (
        (column.radius_slope + sign * column.center_slope) / length,
        -sign,
    )
}

#[inline(always)]
fn mix(start: f64, end: f64, fraction: f64) -> f64 {
    start + (end - start) * fraction
}
