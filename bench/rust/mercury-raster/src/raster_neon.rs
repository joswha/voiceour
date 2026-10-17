//! `rust-neon`: `MercuryRasterizer.render`'s arithmetic, restructured for the core rather
//! than the formula: NEON lanes, hoisted column invariants and a staged row pipeline.
//!
//! Byte identity is preserved by construction. Every lane runs exactly the scalar
//! operation sequence: NEON add, multiply, divide and square root are lane-wise and
//! correctly rounded like their scalar forms, conversions round the same way (FCVTN to
//! nearest, FCVTZS toward zero), no multiply-add is fused, and every `Swift.max` and
//! `Swift.min` becomes the same comparison feeding a select. Only where work happens
//! changes:
//!
//! - values Swift recomputes per pixel but that depend only on the column (the in-span
//!   field gradient for either sign, its length, the radius gradient, `-horizontal`) are
//!   computed once per column with the identical expression;
//! - each row runs three short stages through column-indexed L1 scratch instead of one
//!   ~300-cycle dependent chain per pixel, so the out-of-order core overlaps many pixels:
//!   1. geometry, two pixels per `float64x2`: coverage, crown, normal, finite-eye view,
//!      incidence and the mirror direction rounded to `Float`;
//!   2. room and Fresnel, four pixels per `float32x4` for the octahedral fold, then per
//!      pixel the 16-byte texel taps NEON cannot gather;
//!   3. display response and bytes, two pixels per `float64x2`.
//!
//! Cap columns go through the scalar reference port in `raster.rs` whole; the
//! out-of-gamut slide and partially covered edge pixels finish there per pixel.

use core::arch::aarch64::*;

use crate::environment::{Environment, RESOLUTION, STORAGE};
use crate::field::{Column, Field};
use crate::optics::{
    self, EYE_DISTANCE, FRESNEL_COUNT, FRESNEL_MINIMUM, OPAQUE_TRANSFER_COUNT, Optics,
};
use crate::raster::{self, CROWN_ASPECT, Frame, Span};
use crate::response::{DisplayLookup, LOOKUP_COUNT};
use crate::swift::{self, LEAST_NONZERO_F64};

/// Stage loops read up to three columns past the span; every buffer carries this slack.
const PAD: usize = 4;

/// Per-column invariants and per-row stage buffers, all indexed by raster column.
#[derive(Default)]
pub struct Scratch {
    /// In span with a positive radius: eligible for the paired path.
    paired: Vec<bool>,
    center: Vec<f64>,
    radius: Vec<f64>,
    /// `field::gradient`'s x component for `offset >= 0` and for `offset < 0`.
    gradient_upper: Vec<f64>,
    gradient_lower: Vec<f64>,
    /// `gradientLength * pixelSize` for either sign.
    denominator_upper: Vec<f64>,
    denominator_lower: Vec<f64>,
    /// `radiusSlope / length`.
    radius_gradient: Vec<f64>,
    /// `-horizontal`, the finite-eye view's x numerator.
    negative_horizontal: Vec<f64>,

    /// 1 when the pixel continues through stages 2 and 3.
    live: Vec<u8>,
    coverage: Vec<f64>,
    incidence: Vec<f64>,
    reflected_x: Vec<f32>,
    reflected_y: Vec<f32>,
    reflected_z: Vec<f32>,
    /// Linear `room × Fresnel`, four doubles per column (r, g, b, padding).
    scene: Vec<f64>,
}

impl Scratch {
    fn prepare(&mut self, columns: &[Column], span: &Span, frame: &Frame, width: usize) {
        let capacity = width + PAD;
        if self.paired.len() < capacity {
            self.paired.resize(capacity, false);
            self.live.resize(capacity, 0);
            for values in [
                &mut self.center,
                &mut self.radius,
                &mut self.gradient_upper,
                &mut self.gradient_lower,
                &mut self.denominator_upper,
                &mut self.denominator_lower,
                &mut self.radius_gradient,
                &mut self.negative_horizontal,
                &mut self.coverage,
                &mut self.incidence,
            ] {
                values.resize(capacity, 0.0);
            }
            for values in [
                &mut self.reflected_x,
                &mut self.reflected_y,
                &mut self.reflected_z,
            ] {
                values.resize(capacity, 0.0);
            }
            self.scene.resize(capacity * 4, 0.0);
        }
        // Stage 1 rewrites the span's flags every row; nothing outside it may stay live.
        self.live.fill(0);
        let length = frame.length;
        for index in span.first_column..=span.last_column {
            let column = &columns[index];
            // `field::gradient` for each branch of its sign, the same expression it evaluates.
            let (upper_sign, lower_sign) = (1.0f64, -1.0f64);
            let upper_x = (column.radius_slope + upper_sign * column.center_slope) / length;
            let lower_x = (column.radius_slope + lower_sign * column.center_slope) / length;
            let (upper_y, lower_y) = (-upper_sign, -lower_sign);
            let upper_length = (upper_x * upper_x + upper_y * upper_y).sqrt();
            let lower_length = (lower_x * lower_x + lower_y * lower_y).sqrt();
            self.paired[index] =
                column.in_span && column.radius > 0.0 && upper_length > 1e-9 && lower_length > 1e-9;
            self.center[index] = column.center;
            self.radius[index] = column.radius;
            self.gradient_upper[index] = upper_x;
            self.gradient_lower[index] = lower_x;
            self.denominator_upper[index] = upper_length * frame.pixel_size;
            self.denominator_lower[index] = lower_length * frame.pixel_size;
            self.radius_gradient[index] = column.radius_slope / length;
            self.negative_horizontal[index] = -frame.horizontal(index);
        }
    }
}

/// Same contract as `raster::render`.
#[allow(clippy::too_many_arguments)]
pub fn render(
    field: &Field,
    environment: &Environment,
    lookup: &DisplayLookup,
    scale: f64,
    columns: &mut Vec<Column>,
    scratch: &mut Scratch,
    out: &mut [u8],
    width: usize,
    height: usize,
) {
    let Some(span) = raster::span(field, scale, out, width, height) else {
        return;
    };
    raster::resolve_columns(field, &span, scale, columns, width);
    let optics: &Optics = &optics::OPTICS;
    let frame = Frame::new(field, scale);
    scratch.prepare(columns, &span, &frame, width);
    let four_epsilon_squared = 4.0 * frame.epsilon * frame.epsilon;
    for row in span.first_row..=span.last_row {
        let vertical = frame.vertical(row);
        let row_start = row * width;

        // Stage 1; remembers the live interval so the later stages skip the dead margin.
        let mut first_live = usize::MAX;
        let mut last_live = 0;
        let mut index = span.first_column;
        while index <= span.last_column {
            if index < span.last_column && scratch.paired[index] && scratch.paired[index + 1] {
                // SAFETY: `index + 1 <= last_column < width`, inside every scratch buffer.
                if unsafe { geometry(scratch, index, vertical, four_epsilon_squared) } {
                    first_live = first_live.min(index);
                    last_live = index + 1;
                }
                index += 2;
            } else {
                scratch.live[index] = 0;
                let start = (row_start + index) * 4;
                raster::shade(
                    &frame,
                    &columns[index],
                    frame.horizontal(index),
                    vertical,
                    environment,
                    optics,
                    lookup,
                    &mut out[start..start + 4],
                );
                index += 1;
            }
        }
        if first_live > last_live {
            continue;
        }

        let mut index = first_live;
        while index <= last_live {
            // SAFETY: reads `index..index + 4 <= last_column + 4 <= width + PAD`.
            unsafe { room(scratch, environment, optics, index) };
            index += 4;
        }

        let mut index = first_live;
        while index <= last_live {
            let start = (row_start + index) * 4;
            // SAFETY: as above; `respond` writes only live pixels, all inside the span.
            unsafe { respond(scratch, optics, lookup, index, &mut out[start..]) };
            index += 2;
        }
    }
}

#[inline(always)]
fn splat(value: f64) -> float64x2_t {
    unsafe { vdupq_n_f64(value) }
}

#[inline(always)]
fn splat32(value: f32) -> float32x4_t {
    unsafe { vdupq_n_f32(value) }
}

/// `Swift.max(x, y)` lane-wise: `y >= x ? y : x`.
#[inline(always)]
fn swift_max(x: float64x2_t, y: float64x2_t) -> float64x2_t {
    unsafe { vbslq_f64(vcgeq_f64(y, x), y, x) }
}

/// `Swift.min(x, y)` lane-wise: `y < x ? y : x`.
#[inline(always)]
fn swift_min(x: float64x2_t, y: float64x2_t) -> float64x2_t {
    unsafe { vbslq_f64(vcltq_f64(y, x), y, x) }
}

/// `Int(value)` per lane, clamped to `0...last` so garbage lanes stay in bounds; valid
/// lanes are already inside, where the clamp is the identity.
#[inline(always)]
fn index_lanes(value: float64x2_t, last: usize) -> int64x2_t {
    unsafe {
        let truncated = vcvtq_s64_f64(value);
        let low = vdupq_n_s64(0);
        let high = vdupq_n_s64(last as i64);
        vbslq_s64(
            vcgtq_s64(truncated, high),
            high,
            vbslq_s64(vcltq_s64(truncated, low), low, truncated),
        )
    }
}

/// Stage 1 for pixels `index` and `index + 1`: coverage, crown, normal, view, incidence
/// and the `Float` mirror direction. Returns whether either pixel is covered.
///
/// # Safety
/// `index + 1` is inside every scratch buffer.
#[inline(always)]
unsafe fn geometry(
    s: &mut Scratch,
    index: usize,
    vertical: f64,
    four_epsilon_squared: f64,
) -> bool {
    unsafe {
        let zero = splat(0.0);
        let one = splat(1.0);
        let two = splat(2.0);
        let half = splat(0.5);
        let aspect = splat(CROWN_ASPECT);

        // Signed field, gradient and coverage.
        let center = vld1q_f64(s.center.as_ptr().add(index));
        let radius = vld1q_f64(s.radius.as_ptr().add(index));
        let offset = vsubq_f64(splat(vertical), center);
        let signed_distance = vsubq_f64(radius, vabsq_f64(offset));
        let upper = vcgeq_f64(offset, zero);
        let field_x = vbslq_f64(
            upper,
            vld1q_f64(s.gradient_upper.as_ptr().add(index)),
            vld1q_f64(s.gradient_lower.as_ptr().add(index)),
        );
        let field_y = vbslq_f64(upper, splat(-1.0), one);
        let denominator = vbslq_f64(
            upper,
            vld1q_f64(s.denominator_upper.as_ptr().add(index)),
            vld1q_f64(s.denominator_lower.as_ptr().add(index)),
        );
        let coverage = swift_min(
            swift_max(
                vaddq_f64(half, vdivq_f64(signed_distance, denominator)),
                zero,
            ),
            one,
        );
        let covered = vcgtq_f64(coverage, zero);
        let live = [
            vgetq_lane_u64::<0>(covered) as u8 & 1,
            vgetq_lane_u64::<1>(covered) as u8 & 1,
        ];
        *s.live.as_mut_ptr().add(index) = live[0];
        *s.live.as_mut_ptr().add(index + 1) = live[1];
        if live[0] | live[1] == 0 {
            return false;
        }
        vst1q_f64(s.coverage.as_mut_ptr().add(index), coverage);

        // Half-elliptic crown and its two partials.
        let root = vsqrtq_f64(vaddq_f64(
            vmulq_f64(signed_distance, signed_distance),
            splat(four_epsilon_squared),
        ));
        let smoothed = vmulq_f64(half, vaddq_f64(signed_distance, root));
        let rate = vmulq_f64(half, vaddq_f64(one, vdivq_f64(signed_distance, root)));
        let radicand = swift_max(
            vmulq_f64(smoothed, vsubq_f64(vmulq_f64(two, radius), smoothed)),
            splat(LEAST_NONZERO_F64),
        );
        let crown = vsqrtq_f64(radicand);
        let height = vmulq_f64(aspect, crown);
        let field_derivative = vmulq_f64(
            vdivq_f64(vmulq_f64(aspect, vsubq_f64(radius, smoothed)), crown),
            rate,
        );
        let radius_derivative = vdivq_f64(vmulq_f64(aspect, smoothed), crown);

        // Total crown gradient; the in-span radius gradient is (radiusSlope / length, 0).
        let radius_gradient = vld1q_f64(s.radius_gradient.as_ptr().add(index));
        let crown_x = vaddq_f64(
            vmulq_f64(field_derivative, field_x),
            vmulq_f64(radius_derivative, radius_gradient),
        );
        let crown_y = vaddq_f64(
            vmulq_f64(field_derivative, field_y),
            vmulq_f64(radius_derivative, zero),
        );

        // `normalize((-crown_x, -crown_y, 1))`, including its degenerate guard.
        let normal_x = vnegq_f64(crown_x);
        let normal_y = vnegq_f64(crown_y);
        let squared = vaddq_f64(
            vaddq_f64(vmulq_f64(normal_x, normal_x), vmulq_f64(normal_y, normal_y)),
            vmulq_f64(one, one),
        );
        let normal_valid = vcgtq_f64(squared, splat(1e-24));
        let inverse = vdivq_f64(one, vsqrtq_f64(squared));
        let normal_x = vbslq_f64(normal_valid, vmulq_f64(normal_x, inverse), zero);
        let normal_y = vbslq_f64(normal_valid, vmulq_f64(normal_y, inverse), zero);
        let normal_z = vbslq_f64(normal_valid, vmulq_f64(one, inverse), one);

        // Finite-eye view with the binomial normalization.
        let inverse_depth = vdivq_f64(one, vsubq_f64(splat(EYE_DISTANCE), height));
        let horizontal_unit = vmulq_f64(
            vld1q_f64(s.negative_horizontal.as_ptr().add(index)),
            inverse_depth,
        );
        let vertical_unit = vmulq_f64(splat(-vertical), inverse_depth);
        let squared_offset = vaddq_f64(
            vmulq_f64(horizontal_unit, horizontal_unit),
            vmulq_f64(vertical_unit, vertical_unit),
        );
        let normalization = vaddq_f64(
            one,
            vmulq_f64(
                squared_offset,
                vaddq_f64(
                    splat(-0.5),
                    vmulq_f64(
                        squared_offset,
                        vsubq_f64(splat(0.375), vmulq_f64(splat(0.3125), squared_offset)),
                    ),
                ),
            ),
        );
        let view_x = vmulq_f64(horizontal_unit, normalization);
        let view_y = vmulq_f64(vertical_unit, normalization);
        let view_z = normalization;

        // Incidence and the mirror direction, rounded to `Float` for the room lookup.
        let incidence = swift_max(
            vaddq_f64(
                vaddq_f64(vmulq_f64(normal_x, view_x), vmulq_f64(normal_y, view_y)),
                vmulq_f64(normal_z, view_z),
            ),
            splat(1e-4),
        );
        vst1q_f64(s.incidence.as_mut_ptr().add(index), incidence);
        let twice = vmulq_f64(two, incidence);
        vst1_f32(
            s.reflected_x.as_mut_ptr().add(index),
            vcvt_f32_f64(vsubq_f64(vmulq_f64(twice, normal_x), view_x)),
        );
        vst1_f32(
            s.reflected_y.as_mut_ptr().add(index),
            vcvt_f32_f64(vsubq_f64(vmulq_f64(twice, normal_y), view_y)),
        );
        vst1_f32(
            s.reflected_z.as_mut_ptr().add(index),
            vcvt_f32_f64(vsubq_f64(vmulq_f64(twice, normal_z), view_z)),
        );
        true
    }
}

/// Stage 2 for pixels `index..index + 4`: octahedral fold four at a time, then each live
/// pixel's bilinear room taps and Fresnel lookup, stored as linear scene radiance.
///
/// # Safety
/// `index + 3` is inside every scratch buffer.
#[inline(always)]
unsafe fn room(s: &mut Scratch, environment: &Environment, optics: &Optics, index: usize) {
    unsafe {
        let live = s.live.as_ptr().add(index).cast::<u32>().read_unaligned();
        if live == 0 {
            return;
        }
        let zero = splat32(0.0);
        let one = splat32(1.0);
        let reflected_x = vld1q_f32(s.reflected_x.as_ptr().add(index));
        let reflected_y = vld1q_f32(s.reflected_y.as_ptr().add(index));
        let reflected_z = vld1q_f32(s.reflected_z.as_ptr().add(index));

        // `MercuryOctahedralMap.encode`.
        let denominator = vaddq_f32(
            vaddq_f32(vabsq_f32(reflected_x), vabsq_f32(reflected_y)),
            vabsq_f32(reflected_z),
        );
        let encodable = vcgtq_f32(denominator, splat32(swift::float_literal(1e-12)));
        let projected_x = vdivq_f32(reflected_x, denominator);
        let projected_y = vdivq_f32(reflected_y, denominator);
        let projected_z = vdivq_f32(reflected_z, denominator);
        let folded = vcltq_f32(projected_z, zero);
        let sign_x = vbslq_f32(vcltq_f32(projected_x, zero), splat32(-1.0), one);
        let sign_y = vbslq_f32(vcltq_f32(projected_y, zero), splat32(-1.0), one);
        let fold_x = vmulq_f32(vsubq_f32(one, vabsq_f32(projected_y)), sign_x);
        let fold_y = vmulq_f32(vsubq_f32(one, vabsq_f32(projected_x)), sign_y);
        let point_x = vbslq_f32(encodable, vbslq_f32(folded, fold_x, projected_x), zero);
        let point_y = vbslq_f32(encodable, vbslq_f32(folded, fold_y, projected_y), zero);

        // Bilinear coordinates in the bordered chart.
        let half_resolution = splat32(0.5 * RESOLUTION as f32);
        let coordinate_x = vaddq_f32(
            vmulq_f32(vaddq_f32(point_x, one), half_resolution),
            splat32(0.5),
        );
        let coordinate_y = vaddq_f32(
            vmulq_f32(vaddq_f32(point_y, one), half_resolution),
            splat32(0.5),
        );
        let resolution = vdupq_n_s32(RESOLUTION as i32);
        let column = vminq_s32(
            vmaxq_s32(vcvtq_s32_f32(coordinate_x), vdupq_n_s32(0)),
            resolution,
        );
        let row = vminq_s32(
            vmaxq_s32(vcvtq_s32_f32(coordinate_y), vdupq_n_s32(0)),
            resolution,
        );
        let column_fraction = vsubq_f32(coordinate_x, vcvtq_f32_s32(column));
        let row_fraction = vsubq_f32(coordinate_y, vcvtq_f32_s32(row));
        let base = vaddq_s32(vmulq_s32(row, vdupq_n_s32(STORAGE as i32)), column);
        let mut bases = [0i32; 4];
        vst1q_s32(bases.as_mut_ptr(), base);
        let mut column_fractions = [0f32; 4];
        vst1q_f32(column_fractions.as_mut_ptr(), column_fraction);
        let mut row_fractions = [0f32; 4];
        vst1q_f32(row_fractions.as_mut_ptr(), row_fraction);

        // `MercuryOptics.fresnel(cosine:)` indices and fractions.
        let minimum = splat(FRESNEL_MINIMUM);
        let mut fresnel_lower = [0i64; 4];
        let mut fresnel_fraction = [0f32; 4];
        for half_index in 0..2 {
            let incidence = vld1q_f64(s.incidence.as_ptr().add(index + half_index * 2));
            let clamped = swift_min(swift_max(incidence, minimum), splat(1.0));
            let scaled = vdivq_f64(
                vmulq_f64(
                    vsubq_f64(clamped, minimum),
                    splat((FRESNEL_COUNT - 1) as f64),
                ),
                splat(1.0 - FRESNEL_MINIMUM),
            );
            let lower = index_lanes(scaled, FRESNEL_COUNT - 1);
            vst1q_s64(fresnel_lower.as_mut_ptr().add(half_index * 2), lower);
            vst1_f32(
                fresnel_fraction.as_mut_ptr().add(half_index * 2),
                vcvt_f32_f64(vsubq_f64(scaled, vcvtq_f64_s64(lower))),
            );
        }

        let tables = environment.tables().as_ptr().cast::<f32>();
        let fresnel_table = optics.fresnel.as_ptr().cast::<f32>();
        for lane in 0..4 {
            if live.to_le_bytes()[lane] == 0 {
                continue;
            }
            // `MercuryEnvironment.sample(level: 0, ...)`: four taps, two lerps.
            let taps = tables.add(bases[lane] as usize * 4);
            let top_left = vld1q_f32(taps);
            let top_right = vld1q_f32(taps.add(4));
            let bottom_left = vld1q_f32(taps.add(STORAGE * 4));
            let bottom_right = vld1q_f32(taps.add(STORAGE * 4 + 4));
            let across = vdupq_n_f32(column_fractions[lane]);
            let top = vaddq_f32(top_left, vmulq_f32(vsubq_f32(top_right, top_left), across));
            let bottom = vaddq_f32(
                bottom_left,
                vmulq_f32(vsubq_f32(bottom_right, bottom_left), across),
            );
            let radiance = vaddq_f32(
                top,
                vmulq_f32(vsubq_f32(bottom, top), vdupq_n_f32(row_fractions[lane])),
            );

            // Fresnel: `table[lower] + (table[upper] - table[lower]) * fraction`.
            let lower = fresnel_lower[lane] as usize;
            let upper = swift::min(lower + 1, FRESNEL_COUNT - 1);
            let low = vld1q_f32(fresnel_table.add(lower * 4));
            let high = vld1q_f32(fresnel_table.add(upper * 4));
            let fresnel = vaddq_f32(
                low,
                vmulq_f32(vsubq_f32(high, low), vdupq_n_f32(fresnel_fraction[lane])),
            );

            // Linear scene radiance in `Double`, (r, g) and (b, padding).
            let scene = s.scene.as_mut_ptr().add((index + lane) * 4);
            vst1q_f64(
                scene,
                vmulq_f64(
                    vcvt_f64_f32(vget_low_f32(radiance)),
                    vcvt_f64_f32(vget_low_f32(fresnel)),
                ),
            );
            vst1q_f64(
                scene.add(2),
                vmulq_f64(vcvt_high_f64_f32(radiance), vcvt_high_f64_f32(fresnel)),
            );
        }
    }
}

/// Stage 3 for pixels `index` and `index + 1`: display response and sRGB bytes.
///
/// # Safety
/// `index + 1` is inside every scratch buffer; `pixels` covers every live pixel's bytes.
#[inline(always)]
unsafe fn respond(
    s: &Scratch,
    optics: &Optics,
    lookup: &DisplayLookup,
    index: usize,
    pixels: &mut [u8],
) {
    unsafe {
        let live = [*s.live.as_ptr().add(index), *s.live.as_ptr().add(index + 1)];
        if live[0] | live[1] == 0 {
            return;
        }
        let zero = splat(0.0);
        let one = splat(1.0);
        let scene = s.scene.as_ptr().add(index * 4);
        let first_rg = vld1q_f64(scene);
        let first_b = vld1q_f64(scene.add(2));
        let second_rg = vld1q_f64(scene.add(4));
        let second_b = vld1q_f64(scene.add(6));
        let red = vzip1q_f64(first_rg, second_rg);
        let green = vzip2q_f64(first_rg, second_rg);
        let blue = vzip1q_f64(first_b, second_b);
        let coverage = vld1q_f64(s.coverage.as_ptr().add(index));

        // `MercuryDisplayLookup.map(scene)`: luminance, bounded coordinate, table, ratio.
        let luminance = vaddq_f64(
            vaddq_f64(
                vmulq_f64(splat(0.2126), red),
                vmulq_f64(splat(0.7152), green),
            ),
            vmulq_f64(splat(0.0722), blue),
        );
        let luminance_valid = vandq_u64(
            vcgtq_f64(luminance, zero),
            vcltq_f64(luminance, splat(f64::INFINITY)),
        );
        let unit = vdivq_f64(
            luminance,
            vaddq_f64(luminance, splat(lookup.response.half_saturation)),
        );
        let scaled = vmulq_f64(unit, splat((LOOKUP_COUNT - 1) as f64));
        let lower = index_lanes(scaled, LOOKUP_COUNT - 1);
        let fraction = vcvt_f32_f64(vsubq_f64(scaled, vcvtq_f64_s64(lower)));
        let table = lookup.table.as_ptr().cast::<f32>();
        let sample = |lower: i64, fraction: f32| -> float32x2_t {
            let lower = lower as usize;
            let low = vld1_f32(table.add(lower * 2));
            let high = vld1_f32(table.add(swift::min(lower + 1, LOOKUP_COUNT - 1) * 2));
            vadd_f32(low, vmul_f32(vsub_f32(high, low), vdup_n_f32(fraction)))
        };
        let samples = [
            sample(vgetq_lane_s64::<0>(lower), vget_lane_f32::<0>(fraction)),
            sample(vgetq_lane_s64::<1>(lower), vget_lane_f32::<1>(fraction)),
        ];
        let gain = vcvt_f64_f32(vzip2_f32(samples[0], samples[1]));
        let raw_red = vmulq_f64(red, gain);
        let raw_green = vmulq_f64(green, gain);
        let raw_blue = vmulq_f64(blue, gain);
        let smallest = swift_min(raw_red, swift_min(raw_green, raw_blue));
        let largest = swift_max(raw_red, swift_max(raw_green, raw_blue));
        let fast = vandq_u64(
            luminance_valid,
            vandq_u64(
                vcgeq_f64(smallest, zero),
                vcleq_f64(largest, splat(lookup.response.ceiling)),
            ),
        );
        let opaque = vandq_u64(fast, vcgeq_f64(coverage, one));

        // `encodedByte` on the opaque table, `Int(clamped * 16383 + 0.5)`.
        let last = (OPAQUE_TRANSFER_COUNT - 1) as f64;
        let opaque_index = |value: float64x2_t| -> int64x2_t {
            let clamped = swift_min(swift_max(value, zero), one);
            index_lanes(
                vaddq_f64(vmulq_f64(clamped, splat(last)), splat(0.5)),
                OPAQUE_TRANSFER_COUNT - 1,
            )
        };
        let indices = [
            opaque_index(raw_red),
            opaque_index(raw_green),
            opaque_index(raw_blue),
        ];
        let opaque = [
            vgetq_lane_u64::<0>(opaque) != 0,
            vgetq_lane_u64::<1>(opaque) != 0,
        ];
        let fast = [
            vgetq_lane_u64::<0>(fast) != 0,
            vgetq_lane_u64::<1>(fast) != 0,
        ];
        let opaque_bytes = optics.opaque.as_ptr();
        for lane in 0..2 {
            if live[lane] == 0 {
                continue;
            }
            let pixel = pixels.as_mut_ptr().add(lane * 4);
            let coverage = *s.coverage.as_ptr().add(index + lane);
            if opaque[lane] {
                let (red, green, blue) = if lane == 0 {
                    (
                        vgetq_lane_s64::<0>(indices[0]),
                        vgetq_lane_s64::<0>(indices[1]),
                        vgetq_lane_s64::<0>(indices[2]),
                    )
                } else {
                    (
                        vgetq_lane_s64::<1>(indices[0]),
                        vgetq_lane_s64::<1>(indices[1]),
                        vgetq_lane_s64::<1>(indices[2]),
                    )
                };
                *pixel = *opaque_bytes.add(red as usize);
                *pixel.add(1) = *opaque_bytes.add(green as usize);
                *pixel.add(2) = *opaque_bytes.add(blue as usize);
            } else {
                let scene = s.scene.as_ptr().add((index + lane) * 4);
                let scene = [*scene, *scene.add(1), *scene.add(2)];
                let display = if fast[lane] {
                    let gain = if lane == 0 {
                        vgetq_lane_f64::<0>(gain)
                    } else {
                        vgetq_lane_f64::<1>(gain)
                    };
                    [scene[0] * gain, scene[1] * gain, scene[2] * gain]
                } else {
                    lookup.map(scene)
                };
                *pixel = optics.encoded_byte(display[0], coverage);
                *pixel.add(1) = optics.encoded_byte(display[1], coverage);
                *pixel.add(2) = optics.encoded_byte(display[2], coverage);
            }
            *pixel.add(3) = raster::coverage_byte(coverage);
        }
    }
}
