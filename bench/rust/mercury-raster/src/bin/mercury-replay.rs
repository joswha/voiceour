//! Offline replay of the Swift harness dump (`swift-mercury-harness dump`).
//!
//! Rebuilds every room from its seed, compares the tables with Swift's bit for bit,
//! re-renders every dumped row with each Rust arm and compares the RGBA bytes with the
//! production Swift raster. Prints a summary, writes `replay-equivalence.json` next to
//! the dump, and exits 4 when anything differs.
//!
//! `--time-passes N` adds a pure-Rust development timing loop. It is not the paired
//! measurement: official numbers come from the Swift harness's interleaved `time` mode.
//!
//! ```text
//! mercury-replay [--dump DIR] [--arms rust,rust-neon] [--time-passes N]
//! ```

use std::fmt::Write as _;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use mercury_raster::environment::{LEVEL_STRIDE, LEVELS, STORAGE};
use mercury_raster::field::Field;
use mercury_raster::response::DisplayResponse;
use mercury_raster::{Arm, Engine};

const ROWS_MAGIC: &[u8; 8] = b"MRB6ROWS";
const TABLES_MAGIC: &[u8; 8] = b"MRB6TABL";

struct Reader {
    bytes: Vec<u8>,
    position: usize,
}

impl Reader {
    fn open(path: &PathBuf) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|error| format!("{}: {error}", path.display()))?;
        Ok(Self { bytes, position: 0 })
    }

    fn take(&mut self, count: usize) -> Result<&[u8], String> {
        let end = self.position + count;
        if end > self.bytes.len() {
            return Err(format!("truncated dump at byte {}", self.position));
        }
        let slice = &self.bytes[self.position..end];
        self.position = end;
        Ok(slice)
    }

    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn u64(&mut self) -> Result<u64, String> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn f64(&mut self) -> Result<f64, String> {
        Ok(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn f32s(&mut self, count: usize) -> Result<Vec<f32>, String> {
        Ok(self
            .take(count * 4)?
            .chunks_exact(4)
            .map(|chunk| f32::from_le_bytes(chunk.try_into().unwrap()))
            .collect())
    }
}

struct Lighting {
    seed: u64,
    response: DisplayResponse,
}

struct Row {
    id: String,
    lighting: usize,
    increased_contrast: bool,
    length: f64,
    lateral_offset: f64,
    swift_box: [f64; 4],
    has_image: bool,
    top: Vec<f32>,
    bottom: Vec<f32>,
    raster: Vec<u8>,
}

struct Dump {
    width: usize,
    height: usize,
    scale: f64,
    lightings: Vec<Lighting>,
    rows: Vec<Row>,
}

fn row_id(kind: u32, index: u32) -> String {
    match kind {
        0 => format!("seed-{index:02}"),
        1 => format!("motion-{index:04}"),
        2 => format!("seedic-{index:02}"),
        3 => format!("pose-{index:04}"),
        _ => format!("kind{kind}-{index}"),
    }
}

fn read_rows(directory: &PathBuf) -> Result<Dump, String> {
    let mut reader = Reader::open(&directory.join("rows.bin"))?;
    if reader.take(8)? != ROWS_MAGIC || reader.u32()? != 1 {
        return Err("rows.bin: unknown format".to_owned());
    }
    let width = reader.u32()? as usize;
    let height = reader.u32()? as usize;
    let bytes_per_row = reader.u32()? as usize;
    let scale = reader.f64()?;
    let stations = reader.u32()? as usize;
    let lighting_count = reader.u32()? as usize;
    let row_count = reader.u32()? as usize;
    if bytes_per_row != width * 4 {
        return Err(format!(
            "rows.bin: {bytes_per_row} bytes per row for width {width}"
        ));
    }
    let mut lightings = Vec::with_capacity(lighting_count);
    for _ in 0..lighting_count {
        let seed = reader.u64()?;
        let response = DisplayResponse {
            exponent: reader.f64()?,
            half_saturation: reader.f64()?,
            ceiling: reader.f64()?,
            scene_median: reader.f64()?,
            scene_highlight: reader.f64()?,
        };
        lightings.push(Lighting { seed, response });
    }
    let mut rows = Vec::with_capacity(row_count);
    for _ in 0..row_count {
        let kind = reader.u32()?;
        let index = reader.u32()?;
        let lighting = reader.u32()? as usize;
        let increased_contrast = reader.u32()? != 0;
        let length = reader.f64()?;
        let lateral_offset = reader.f64()?;
        let swift_box = [reader.f64()?, reader.f64()?, reader.f64()?, reader.f64()?];
        let has_image = reader.u32()? != 0;
        let _reserved = reader.u32()?;
        let top = reader.f32s(stations)?;
        let bottom = reader.f32s(stations)?;
        let raster = reader.take(bytes_per_row * height)?.to_vec();
        if lighting >= lighting_count {
            return Err(format!(
                "row {} names lighting {lighting}",
                row_id(kind, index)
            ));
        }
        rows.push(Row {
            id: row_id(kind, index),
            lighting,
            increased_contrast,
            length,
            lateral_offset,
            swift_box,
            has_image,
            top,
            bottom,
            raster,
        });
    }
    Ok(Dump {
        width,
        height,
        scale,
        lightings,
        rows,
    })
}

/// Swift's tables per seed, RGB lanes only.
fn read_tables(directory: &PathBuf) -> Result<Vec<(u64, Vec<f32>)>, String> {
    let mut reader = Reader::open(&directory.join("tables.bin"))?;
    if reader.take(8)? != TABLES_MAGIC || reader.u32()? != 1 {
        return Err("tables.bin: unknown format".to_owned());
    }
    let levels = reader.u32()? as usize;
    let storage = reader.u32()? as usize;
    let count = reader.u32()? as usize;
    if levels != LEVELS || storage != STORAGE {
        return Err(format!(
            "tables.bin: {levels} levels of {storage}², expected {LEVELS} of {STORAGE}²"
        ));
    }
    let mut result = Vec::with_capacity(count);
    for _ in 0..count {
        let seed = reader.u64()?;
        result.push((seed, reader.f32s(levels * storage * storage * 3)?));
    }
    Ok(result)
}

#[derive(Default)]
struct ArmSummary {
    rows: usize,
    identical: usize,
    differing_bytes: usize,
    max_abs: u8,
    mismatches: Vec<(String, usize, u8)>,
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(4),
        Err(message) => {
            eprintln!("mercury-replay: {message}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<bool, String> {
    let mut directory = default_dump_directory();
    let mut arms = vec![Arm::Scalar];
    let mut time_passes = 0usize;
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--dump" => {
                directory = PathBuf::from(arguments.next().ok_or("--dump needs a directory")?)
            }
            "--arms" => {
                let list = arguments.next().ok_or("--arms needs a list")?;
                arms = list
                    .split(',')
                    .map(|name| {
                        Arm::parse(name)
                            .ok_or(format!("unknown arm {name:?}; known: {}", Arm::NAMES))
                    })
                    .collect::<Result<_, _>>()?;
            }
            "--time-passes" => {
                time_passes = arguments
                    .next()
                    .ok_or("--time-passes needs a count")?
                    .parse()
                    .map_err(|_| "--time-passes needs a count")?;
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }

    let dump = read_rows(&directory)?;
    let swift_tables = read_tables(&directory)?;
    println!(
        "mercury-replay: {} rows, {} lightings, {}x{} @{}x from {}",
        dump.rows.len(),
        dump.lightings.len(),
        dump.width,
        dump.height,
        dump.scale,
        directory.display()
    );

    let build_started = Instant::now();
    let mut engines: Vec<Vec<Engine>> = arms
        .iter()
        .map(|&arm| {
            dump.lightings
                .iter()
                .map(|lighting| Engine::new(lighting.seed, lighting.response, arm))
                .collect()
        })
        .collect();
    let build_seconds = build_started.elapsed().as_secs_f64();

    // Tables: bit identity of all three levels, RGB lanes.
    let mut table_lightings = 0usize;
    let mut table_identical = 0usize;
    let mut table_differing_floats = 0usize;
    let mut table_max_abs = 0f32;
    for (seed, swift) in &swift_tables {
        let Some(position) = dump
            .lightings
            .iter()
            .position(|lighting| lighting.seed == *seed)
        else {
            return Err(format!("tables.bin seed {seed:#018x} has no lighting"));
        };
        let rust = engines[0][position].environment().tables();
        let mut differing = 0usize;
        for (index, texel) in rust.iter().enumerate().take(LEVELS * LEVEL_STRIDE) {
            for lane in 0..3 {
                let expected = swift[index * 3 + lane];
                let actual = texel.0[lane];
                if expected.to_bits() != actual.to_bits() {
                    differing += 1;
                    table_max_abs = table_max_abs.max((expected - actual).abs());
                }
            }
        }
        table_lightings += 1;
        table_differing_floats += differing;
        if differing == 0 {
            table_identical += 1;
        }
    }

    // Field boxes.
    let mut box_mismatches = 0usize;
    for row in &dump.rows {
        let bounding =
            Field::new(&row.top, &row.bottom, row.length, row.lateral_offset).bounding_box;
        let rust_box = [
            bounding.min_x(),
            bounding.max_x(),
            bounding.min_y(),
            bounding.max_y(),
        ];
        if rust_box
            .iter()
            .zip(&row.swift_box)
            .any(|(a, b)| a.to_bits() != b.to_bits())
        {
            box_mismatches += 1;
        }
    }

    // Rasters.
    let byte_count = dump.width * 4 * dump.height;
    let mut buffer = vec![0u8; byte_count];
    let mut summaries: Vec<ArmSummary> = arms.iter().map(|_| ArmSummary::default()).collect();
    for row in &dump.rows {
        for (arm_index, engines) in engines.iter_mut().enumerate() {
            let status = engines[row.lighting].render(
                &row.top,
                &row.bottom,
                row.length,
                row.lateral_offset,
                row.increased_contrast,
                dump.scale,
                &mut buffer,
                dump.width,
                dump.height,
            )?;
            let drawn = status == mercury_raster::RenderStatus::Rendered;
            let summary = &mut summaries[arm_index];
            summary.rows += 1;
            if drawn != row.has_image {
                summary
                    .mismatches
                    .push((format!("{} (image presence)", row.id), byte_count, 255));
                continue;
            }
            let mut differing = 0usize;
            let mut max_abs = 0u8;
            for (actual, expected) in buffer.iter().zip(&row.raster) {
                if actual != expected {
                    differing += 1;
                    max_abs = max_abs.max(actual.abs_diff(*expected));
                }
            }
            summary.differing_bytes += differing;
            summary.max_abs = summary.max_abs.max(max_abs);
            if differing == 0 {
                summary.identical += 1;
            } else {
                summary
                    .mismatches
                    .push((row.id.clone(), differing, max_abs));
            }
        }
    }

    let mut identical = table_identical == table_lightings && box_mismatches == 0;
    println!(
        "tables: {table_identical}/{table_lightings} lightings bit-identical \
         ({table_differing_floats} differing floats, max |Δ| {table_max_abs:e}); built in {build_seconds:.2}s"
    );
    println!(
        "field boxes: {} rows, {box_mismatches} mismatches",
        dump.rows.len()
    );
    let mut json = String::new();
    let _ = write!(
        json,
        "{{\"rows\":{},\"lightings\":{},\"tables\":{{\"lightings\":{table_lightings},\"identical\":{table_identical},\
         \"differing_floats\":{table_differing_floats},\"max_abs\":{table_max_abs:e}}},\
         \"field_box_mismatches\":{box_mismatches},\"arms\":{{",
        dump.rows.len(),
        dump.lightings.len()
    );
    for (arm_index, (arm, summary)) in arms.iter().zip(&summaries).enumerate() {
        identical &= summary.identical == summary.rows;
        println!(
            "{}: {}/{} rows byte-identical, {} differing bytes, max |Δ| {}",
            arm.name(),
            summary.identical,
            summary.rows,
            summary.differing_bytes,
            summary.max_abs
        );
        for (id, differing, max_abs) in summary.mismatches.iter().take(10) {
            println!("  {id}: {differing} differing bytes, max |Δ| {max_abs}");
        }
        if arm_index > 0 {
            json.push(',');
        }
        let _ = write!(
            json,
            "\"{}\":{{\"rows\":{},\"identical\":{},\"differing_bytes\":{},\"max_abs\":{},\"mismatches\":[",
            arm.name(),
            summary.rows,
            summary.identical,
            summary.differing_bytes,
            summary.max_abs
        );
        for (index, (id, differing, max_abs)) in summary.mismatches.iter().enumerate() {
            if index > 0 {
                json.push(',');
            }
            let _ = write!(
                json,
                "{{\"row_id\":\"{id}\",\"differing_bytes\":{differing},\"max_abs\":{max_abs}}}"
            );
        }
        json.push_str("]}");
    }
    json.push_str("}}\n");
    let report = directory.join("replay-equivalence.json");
    std::fs::write(&report, json).map_err(|error| format!("{}: {error}", report.display()))?;

    if time_passes > 0 {
        time(&dump, &arms, &mut engines, &mut buffer, time_passes)?;
    }
    Ok(identical)
}

/// Development-only pure-Rust timing: per arm, median and p99 over every row and pass.
fn time(
    dump: &Dump,
    arms: &[Arm],
    engines: &mut [Vec<Engine>],
    buffer: &mut [u8],
    passes: usize,
) -> Result<(), String> {
    let mut samples: Vec<Vec<f64>> = arms.iter().map(|_| Vec::new()).collect();
    for pass in 0..=passes {
        for (sequence, row) in dump.rows.iter().enumerate() {
            for offset in 0..arms.len() {
                let arm_index = (sequence + offset) % arms.len();
                let started = Instant::now();
                engines[arm_index][row.lighting].render(
                    &row.top,
                    &row.bottom,
                    row.length,
                    row.lateral_offset,
                    row.increased_contrast,
                    dump.scale,
                    buffer,
                    dump.width,
                    dump.height,
                )?;
                let elapsed = started.elapsed().as_secs_f64() * 1e6;
                if pass > 0 {
                    samples[arm_index].push(elapsed);
                }
            }
        }
    }
    for (arm, values) in arms.iter().zip(&mut samples) {
        values.sort_by(f64::total_cmp);
        let at = |fraction: f64| values[((values.len() - 1) as f64 * fraction) as usize];
        println!(
            "time {}: n={} p50 {:.1} µs, p90 {:.1} µs, p99 {:.1} µs (pure Rust, development only)",
            arm.name(),
            values.len(),
            at(0.5),
            at(0.9),
            at(0.99)
        );
    }
    Ok(())
}

/// `<repo>/.build/rust-bench/mercury`, found from this crate's manifest directory.
fn default_dump_directory() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.build/rust-bench/mercury")
}
