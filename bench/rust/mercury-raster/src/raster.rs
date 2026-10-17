//! Port of `MercuryRasterizer.render` (Sources/Voiceour/MercuryRasterizer.swift) and
//! `MercuryCrown.evaluate` (Sources/Voiceour/MercuryCrown.swift), operation for operation.

use crate::environment::Environment;
use crate::field::{self, Column, Field, island_bounds};
use crate::optics::{self, Optics};
use crate::response::DisplayLookup;
use crate::swift::{self, LEAST_NONZERO_F64};

/// `MercuryMetrics.crownAspect`.
pub const CROWN_ASPECT: f64 = 0.78;
/// `MercuryMetrics.crownFilterFraction`.
pub const CROWN_FILTER_FRACTION: f64 = 0.25;

/// `MercuryCrown.Sample`.
#[derive(Clone, Copy, Debug)]
pub struct Crown {
    pub height: f64,
    pub field_derivative: f64,
    pub radius_derivative: f64,
}

/// `MercuryCrown.evaluate`: `z = aspect * sqrt(2 r φ̃ - φ̃²)` and its two partials.
#[inline(always)]
pub fn crown(field: f64, radius: f64, aspect: f64, epsilon: f64) -> Crown {
    if !(radius > 0.0 && aspect > 0.0 && epsilon > 0.0) {
        return Crown {
            height: 0.0,
            field_derivative: 0.0,
            radius_derivative: 0.0,
        };
    }
    let root = (field * field + 4.0 * epsilon * epsilon).sqrt();
    let smoothed_field = 0.5 * (field + root);
    let field_rate = 0.5 * (1.0 + field / root);
    let radicand = swift::max(
        smoothed_field * (2.0 * radius - smoothed_field),
        LEAST_NONZERO_F64,
    );
    let crown = radicand.sqrt();
    Crown {
        height: aspect * crown,
        field_derivative: aspect * (radius - smoothed_field) / crown * field_rate,
        radius_derivative: aspect * smoothed_field / crown,
    }
}

/// The pixel rectangle `render` shades, or `None` when nothing is drawn.
pub struct Span {
    pub first_column: usize,
    pub last_column: usize,
    pub first_row: usize,
    pub last_row: usize,
}

/// The prologue of `render`: clear the buffer, bound the shaded rectangle.
pub fn span(
    field: &Field,
    scale: f64,
    out: &mut [u8],
    width: usize,
    height: usize,
) -> Option<Span> {
    out[..width * 4 * height].fill(0);
    let bounding = field.bounding_box;
    if !(bounding.width > 0.0 && bounding.height > 0.0) {
        return None;
    }
    let bounds = island_bounds();
    let first_column = swift::max(
        0,
        ((bounding.min_x() - bounds.min_x()) * scale).floor() as isize,
    );
    let last_column = swift::min(
        width as isize - 1,
        ((bounding.max_x() - bounds.min_x()) * scale).ceil() as isize,
    );
    let first_row = swift::max(
        0,
        ((bounds.max_y() - bounding.max_y()) * scale).floor() as isize,
    );
    let last_row = swift::min(
        height as isize - 1,
        ((bounds.max_y() - bounding.min_y()) * scale).ceil() as isize,
    );
    if !(first_column <= last_column && first_row <= last_row) {
        return None;
    }
    Some(Span {
        first_column: first_column as usize,
        last_column: last_column as usize,
        first_row: first_row as usize,
        last_row: last_row as usize,
    })
}

/// The column pass: resolve every shaded column once.
pub fn resolve_columns(
    field: &Field,
    span: &Span,
    scale: f64,
    columns: &mut Vec<Column>,
    width: usize,
) {
    if columns.len() < width {
        columns.resize(width, Column::default());
    }
    let bounds_min_x = island_bounds().min_x();
    let pixel_size = 1.0 / scale;
    let horizontal_offset = field.lateral_offset;
    for column in span.first_column..=span.last_column {
        let position = bounds_min_x + (column as f64 + 0.5) * pixel_size;
        columns[column] = field.column(position - horizontal_offset);
    }
}

/// The per-render constants of `MercuryRasterizer.render`.
pub struct Frame {
    pub bounds_min_x: f64,
    pub bounds_max_y: f64,
    pub pixel_size: f64,
    pub epsilon: f64,
    /// `Swift.max(field.length, 1)`.
    pub length: f64,
}

impl Frame {
    pub fn new(field: &Field, scale: f64) -> Self {
        let bounds = island_bounds();
        let pixel_size = 1.0 / scale;
        Self {
            bounds_min_x: bounds.min_x(),
            bounds_max_y: bounds.max_y(),
            pixel_size,
            epsilon: CROWN_FILTER_FRACTION * pixel_size,
            length: swift::max(field.length, 1.0),
        }
    }

    #[inline(always)]
    pub fn vertical(&self, row: usize) -> f64 {
        self.bounds_max_y - (row as f64 + 0.5) * self.pixel_size
    }

    #[inline(always)]
    pub fn horizontal(&self, column: usize) -> f64 {
        self.bounds_min_x + (column as f64 + 0.5) * self.pixel_size
    }
}

/// `MercuryRasterizer.render` for `image(...)`: RGBA8 premultiplied-last, `width * 4`
/// bytes per row, every pixel outside the body zero.
pub fn render(
    field: &Field,
    environment: &Environment,
    lookup: &DisplayLookup,
    scale: f64,
    columns: &mut Vec<Column>,
    out: &mut [u8],
    width: usize,
    height: usize,
) {
    let Some(span) = span(field, scale, out, width, height) else {
        return;
    };
    resolve_columns(field, &span, scale, columns, width);
    let optics: &Optics = &optics::OPTICS;
    let frame = Frame::new(field, scale);
    for row in span.first_row..=span.last_row {
        let vertical = frame.vertical(row);
        for column_index in span.first_column..=span.last_column {
            let index = (row * width + column_index) * 4;
            shade(
                &frame,
                &columns[column_index],
                frame.horizontal(column_index),
                vertical,
                environment,
                optics,
                lookup,
                &mut out[index..index + 4],
            );
        }
    }
}

/// One pixel of `MercuryRasterizer.render`'s inner loop; leaves uncovered pixels alone.
#[inline(always)]
#[allow(clippy::too_many_arguments)]
pub fn shade(
    frame: &Frame,
    column: &Column,
    horizontal: f64,
    vertical: f64,
    environment: &Environment,
    optics: &Optics,
    lookup: &DisplayLookup,
    pixel: &mut [u8],
) {
    if !(column.radius > 0.0) {
        return;
    }
    let length = frame.length;
    let offset = vertical - column.center;
    let distance = if column.in_span {
        offset.abs()
    } else {
        (column.cap_offset * column.cap_offset + offset * offset).sqrt()
    };
    let signed_distance = column.radius - distance;
    let (field_x, field_y) = field::gradient(column, offset, length);
    let gradient_length = (field_x * field_x + field_y * field_y).sqrt();
    if !(gradient_length > 1e-9) {
        return;
    }
    let coverage = swift::min(
        swift::max(
            0.5 + signed_distance / (gradient_length * frame.pixel_size),
            0.0,
        ),
        1.0,
    );
    if !(coverage > 0.0) {
        return;
    }

    let crown = crown(signed_distance, column.radius, CROWN_ASPECT, frame.epsilon);
    let radius_gradient = if column.in_span {
        (column.radius_slope / length, 0.0)
    } else {
        (0.0, 0.0)
    };
    let crown_x = crown.field_derivative * field_x + crown.radius_derivative * radius_gradient.0;
    let crown_y = crown.field_derivative * field_y + crown.radius_derivative * radius_gradient.1;
    let normal = normalize([-crown_x, -crown_y, 1.0]);
    let view = optics::view_direction(horizontal, vertical, crown.height);
    let incidence = swift::max(
        normal[0] * view[0] + normal[1] * view[1] + normal[2] * view[2],
        1e-4,
    );
    let twice = 2.0 * incidence;
    let reflected = [
        twice * normal[0] - view[0],
        twice * normal[1] - view[1],
        twice * normal[2] - view[2],
    ];
    let room = environment.radiance([
        reflected[0] as f32,
        reflected[1] as f32,
        reflected[2] as f32,
    ]);
    let fresnel = optics.fresnel(incidence);
    let scene = [
        room[0] as f64 * fresnel[0],
        room[1] as f64 * fresnel[1],
        room[2] as f64 * fresnel[2],
    ];
    let display = lookup.map(scene);
    pixel[0] = optics.encoded_byte(display[0], coverage);
    pixel[1] = optics.encoded_byte(display[1], coverage);
    pixel[2] = optics.encoded_byte(display[2], coverage);
    pixel[3] = coverage_byte(coverage);
}

/// `MercuryRasterizer.normalize`.
#[inline(always)]
pub fn normalize(value: [f64; 3]) -> [f64; 3] {
    let squared_length = value[0] * value[0] + value[1] * value[1] + value[2] * value[2];
    if !(squared_length > 1e-24) {
        return [0.0, 0.0, 1.0];
    }
    let inverse = 1.0 / squared_length.sqrt();
    [value[0] * inverse, value[1] * inverse, value[2] * inverse]
}

/// `MercuryRasterizer.byte`.
#[inline(always)]
pub fn coverage_byte(value: f64) -> u8 {
    swift::min(255, swift::max(0, (value * 255.0 + 0.5) as isize)) as u8
}
