//! Benchmark-only Rust port of Voiceour's production mercury rasterizer (bet B6).
//!
//! Every numeric path reproduces `Sources/Voiceour/Mercury*.swift` operation for
//! operation, so output bytes are compared for identity rather than within a tolerance.
//! Nothing here is linked into the app; the Swift harness under
//! `bench/rust/swift-mercury-harness` loads the cdylib with `dlopen`.

#[cfg(not(target_arch = "aarch64"))]
compile_error!("mercury-raster targets aarch64-apple-darwin, the contract target of bet B6");

pub mod environment;
pub mod field;
pub mod noise;
pub mod optics;
pub mod raster;
pub mod raster_neon;
pub mod response;
pub mod swift;

mod ffi;

use environment::Environment;
use field::{Column, Field, ISLAND_HEIGHT, ISLAND_WIDTH};
use response::{
    DisplayLookup, DisplayResponse, INCREASED_CONTRAST_HIGHLIGHT, INCREASED_CONTRAST_MEDIAN,
};

/// One implementation of the per-raster path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arm {
    /// Line-for-line port of `MercuryRasterizer.render`.
    Scalar,
    /// The same arithmetic, two pixels per NEON instruction, column invariants hoisted.
    Neon,
}

impl Arm {
    /// `mr_arms()`.
    pub const NAMES: &'static str = "rust,rust-neon";

    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "rust" => Some(Self::Scalar),
            "rust-neon" => Some(Self::Neon),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Scalar => "rust",
            Self::Neon => "rust-neon",
        }
    }
}

/// What one `render` call drew.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RenderStatus {
    Rendered,
    /// The field's bounding box is empty; production draws no image for it.
    EmptyField,
}

/// One session's room, response and scratch: `MercuryEngine`'s lighting plus its
/// `MercuryRasterizer`.
pub struct Engine {
    arm: Arm,
    environment: Environment,
    response: DisplayResponse,
    lookup: DisplayLookup,
    columns: Vec<Column>,
    neon: raster_neon::Scratch,
}

impl Engine {
    /// Builds the Room of Ten for `seed` and the lookup for `response`.
    pub fn new(seed: u64, response: DisplayResponse, arm: Arm) -> Self {
        Self {
            arm,
            environment: Environment::room_of_ten(seed),
            response,
            lookup: DisplayLookup::new(response),
            columns: Vec::new(),
            neon: raster_neon::Scratch::default(),
        }
    }

    pub fn arm(&self) -> Arm {
        self.arm
    }

    pub fn environment(&self) -> &Environment {
        &self.environment
    }

    /// The response `MercuryRasterizer.render` selects for this appearance.
    pub fn selected_response(&self, increased_contrast: bool) -> DisplayResponse {
        if increased_contrast {
            self.response
                .remapped(INCREASED_CONTRAST_MEDIAN, INCREASED_CONTRAST_HIGHLIGHT)
                .unwrap_or(self.response)
        } else {
            self.response
        }
    }

    /// `MercuryRasterizer.lookup(for:)`: one cached lookup, rebuilt when the key changes.
    pub fn lookup(&mut self, increased_contrast: bool) -> &DisplayLookup {
        let selected = self.selected_response(increased_contrast);
        if self.lookup.response != selected {
            self.lookup = DisplayLookup::new(selected);
        }
        &self.lookup
    }

    /// One production raster: `MercuryField(geometry:lateralOffset:)` followed by
    /// `MercuryRasterizer.image(...)`'s pixel fill into `out` (`width * 4` bytes per row).
    #[allow(clippy::too_many_arguments)]
    pub fn render(
        &mut self,
        top: &[f32],
        bottom: &[f32],
        length: f64,
        lateral_offset: f64,
        increased_contrast: bool,
        scale: f64,
        out: &mut [u8],
        width: usize,
        height: usize,
    ) -> Result<RenderStatus, String> {
        if top.len() < 2 || top.len() != bottom.len() {
            return Err(format!(
                "need matching top/bottom samples, got {} and {}",
                top.len(),
                bottom.len()
            ));
        }
        let expected_width = (ISLAND_WIDTH * scale).round() as usize;
        let expected_height = (ISLAND_HEIGHT * scale).round() as usize;
        if width != expected_width || height != expected_height {
            return Err(format!(
                "scale {scale} needs a {expected_width}x{expected_height} raster, got {width}x{height}"
            ));
        }
        if out.len() < width * 4 * height {
            return Err(format!(
                "output holds {} bytes, need {}",
                out.len(),
                width * 4 * height
            ));
        }
        let field = Field::new(top, bottom, length, lateral_offset);
        let bounding = field.bounding_box;
        if !(bounding.width > 0.0 && bounding.height > 0.0) {
            out[..width * 4 * height].fill(0);
            return Ok(RenderStatus::EmptyField);
        }
        self.lookup(increased_contrast);
        match self.arm {
            Arm::Scalar => raster::render(
                &field,
                &self.environment,
                &self.lookup,
                scale,
                &mut self.columns,
                out,
                width,
                height,
            ),
            Arm::Neon => raster_neon::render(
                &field,
                &self.environment,
                &self.lookup,
                scale,
                &mut self.columns,
                &mut self.neon,
                out,
                width,
                height,
            ),
        }
        Ok(RenderStatus::Rendered)
    }
}
