//! `encoder-bench`: runs the MLX encoder arms through the `ve_*` C ABI on dumped mel inputs,
//! checks every output against the dumped native Metal encoder states and writes contract timing
//! rows (bet B4, arms `mlx:<arm>`).
//!
//! ```text
//! encoder-bench --dumps <dir> --arms f32,f16 --passes N --output rows.jsonl
//!               [--write-states <dir>] [--model <path>] [--limit N] [--seed S]
//! ```
//!
//! Pass 0 is warmup (excluded by the analyzer); passes 1..=N are timed. `elapsed_us` is one
//! `ve_encode` call: host mel -> MLX arrays, graph build, one `eval`, GPU sync, host copy-out.

use std::ffi::{CString, c_char};
use std::fmt::Write as _;
use std::fs;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::Instant;

use encoder_mlx::ffi::{ve_encode, ve_engine_free, ve_engine_new};
use encoder_mlx::{Arm, Engine, MLX_COMMIT, MLX_RS_VERSION, MLX_VERSION, N_MELS, N_STATE};
use parakeet_model::pin;

const USAGE: &str = "usage: encoder-bench --dumps <corpus dump dir> --arms <a,b,...> --passes N --output <rows.jsonl>
                     [--write-states <dir>] [--model <path>] [--limit N] [--seed S]
arms: f32,f16,compiled-f32,compiled-f16,f32-mm16,compiled-f32-mm16,f32-sdpa,f16-manual";

// ---------------------------------------------------------------------------------------------
// Minimal JSON (index.jsonl in, rows out)

/// Only objects, strings and numbers are read; booleans and arrays are parsed and dropped.
#[derive(Debug)]
enum Json {
    Null,
    Bool,
    Num(f64),
    Str(String),
    Arr,
    Obj(Vec<(String, Json)>),
}

impl Json {
    fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
    fn str_field(&self, key: &str) -> Result<&str, String> {
        match self.get(key) {
            Some(Json::Str(s)) => Ok(s),
            _ => Err(format!("missing string field {key:?}")),
        }
    }
    fn num_field(&self, key: &str) -> Result<f64, String> {
        match self.get(key) {
            Some(Json::Num(n)) => Ok(*n),
            _ => Err(format!("missing number field {key:?}")),
        }
    }
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn parse(text: &str) -> Result<Json, String> {
        let mut p = Parser {
            s: text.as_bytes(),
            i: 0,
        };
        let value = p.value()?;
        p.ws();
        if p.i != p.s.len() {
            return Err(format!("trailing data at byte {}", p.i));
        }
        Ok(value)
    }
    fn ws(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }
    fn eat(&mut self, lit: &str) -> Result<(), String> {
        if self.s[self.i..].starts_with(lit.as_bytes()) {
            self.i += lit.len();
            Ok(())
        } else {
            Err(format!("expected {lit:?} at byte {}", self.i))
        }
    }
    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        match self.s.get(self.i) {
            None => Err("unexpected end".to_owned()),
            Some(b'n') => self.eat("null").map(|_| Json::Null),
            Some(b't') => self.eat("true").map(|_| Json::Bool),
            Some(b'f') => self.eat("false").map(|_| Json::Bool),
            Some(b'"') => self.string().map(Json::Str),
            Some(b'[') => {
                self.i += 1;
                self.ws();
                if self.s.get(self.i) == Some(&b']') {
                    self.i += 1;
                    return Ok(Json::Arr);
                }
                loop {
                    self.value()?;
                    self.ws();
                    match self.s.get(self.i) {
                        Some(b',') => self.i += 1,
                        Some(b']') => {
                            self.i += 1;
                            return Ok(Json::Arr);
                        }
                        _ => return Err(format!("bad array at byte {}", self.i)),
                    }
                }
            }
            Some(b'{') => {
                self.i += 1;
                let mut fields = Vec::new();
                self.ws();
                if self.s.get(self.i) == Some(&b'}') {
                    self.i += 1;
                    return Ok(Json::Obj(fields));
                }
                loop {
                    self.ws();
                    let key = self.string()?;
                    self.ws();
                    self.eat(":")?;
                    fields.push((key, self.value()?));
                    self.ws();
                    match self.s.get(self.i) {
                        Some(b',') => self.i += 1,
                        Some(b'}') => {
                            self.i += 1;
                            return Ok(Json::Obj(fields));
                        }
                        _ => return Err(format!("bad object at byte {}", self.i)),
                    }
                }
            }
            Some(_) => {
                let start = self.i;
                while self.i < self.s.len()
                    && matches!(
                        self.s[self.i],
                        b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9'
                    )
                {
                    self.i += 1;
                }
                let text =
                    std::str::from_utf8(&self.s[start..self.i]).map_err(|e| e.to_string())?;
                text.parse::<f64>()
                    .map(Json::Num)
                    .map_err(|_| format!("bad number {text:?} at byte {start}"))
            }
        }
    }
    fn hex4(&mut self) -> Result<u32, String> {
        let digits = self.s.get(self.i..self.i + 4).ok_or("short \\u escape")?;
        let text = std::str::from_utf8(digits).map_err(|e| e.to_string())?;
        self.i += 4;
        u32::from_str_radix(text, 16).map_err(|_| format!("bad \\u escape {text:?}"))
    }
    fn string(&mut self) -> Result<String, String> {
        self.eat("\"")?;
        let mut out = Vec::new();
        loop {
            let byte = *self.s.get(self.i).ok_or("unterminated string")?;
            self.i += 1;
            match byte {
                b'"' => return String::from_utf8(out).map_err(|e| e.to_string()),
                b'\\' => {
                    let escape = *self.s.get(self.i).ok_or("unterminated escape")?;
                    self.i += 1;
                    let ch = match escape {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let mut code = self.hex4()?;
                            if (0xD800..0xDC00).contains(&code) {
                                self.eat("\\u")?;
                                let low = self.hex4()?;
                                code = 0x10000
                                    + ((code - 0xD800) << 10)
                                    + (low.wrapping_sub(0xDC00) & 0x3FF);
                            }
                            char::from_u32(code).ok_or("bad code point")?
                        }
                        other => return Err(format!("bad escape \\{}", other as char)),
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                other => out.push(other),
            }
        }
    }
}

fn json_str(out: &mut String, s: &str) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn json_num(out: &mut String, value: f64) {
    if value.is_finite() {
        let _ = write!(out, "{value}");
    } else {
        out.push_str("null");
    }
}

fn json_opt_str(out: &mut String, value: Option<&str>) {
    match value {
        Some(s) => json_str(out, s),
        None => out.push_str("null"),
    }
}

// ---------------------------------------------------------------------------------------------
// Host description (same fields as the other harnesses)

fn command_line(program: &str, arguments: &[&str]) -> Option<String> {
    let output = Command::new(program).args(arguments).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn sysctl(name: &str) -> Option<String> {
    command_line("/usr/sbin/sysctl", &["-n", name])
}

fn host_json() -> String {
    let load: Vec<f64> = sysctl("vm.loadavg")
        .map(|text| {
            text.trim_matches(|c| c == '{' || c == '}' || c == ' ')
                .split_whitespace()
                .filter_map(|value| value.parse().ok())
                .collect()
        })
        .unwrap_or_default();
    let power = command_line("/usr/bin/pmset", &["-g", "batt"])
        .map(|text| {
            if text.contains("AC Power") {
                "AC"
            } else if text.contains("Battery Power") {
                "battery"
            } else {
                "unknown"
            }
        })
        .unwrap_or("unknown");
    let int = |name: &str| sysctl(name).and_then(|value| value.parse::<u64>().ok());
    let mut out = String::from("{\"chip\":");
    json_opt_str(&mut out, sysctl("machdep.cpu.brand_string").as_deref());
    out.push_str(",\"os\":");
    json_opt_str(&mut out, sysctl("kern.osproductversion").as_deref());
    out.push_str(",\"os_build\":");
    json_opt_str(&mut out, sysctl("kern.osversion").as_deref());
    out.push_str(",\"power\":");
    json_str(&mut out, power);
    out.push_str(",\"load_avg\":[");
    for (i, value) in load.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        json_num(&mut out, *value);
    }
    out.push(']');
    for (key, name) in [
        ("cpu_threads", "hw.ncpu"),
        ("perf_cores", "hw.perflevel0.physicalcpu"),
        ("eff_cores", "hw.perflevel1.physicalcpu"),
        ("memory_bytes", "hw.memsize"),
    ] {
        let _ = write!(out, ",\"{key}\":");
        match int(name) {
            Some(v) => {
                let _ = write!(out, "{v}");
            }
            None => out.push_str("null"),
        }
    }
    out.push('}');
    out
}

/// UTC ISO 8601 with seconds.
fn now_iso8601() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64);
    let days = seconds.div_euclid(86_400);
    let rem = seconds.rem_euclid(86_400);
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// SplitMix64 + Fisher–Yates: the per-pass row permutation the other harnesses use.
fn pass_order(rows: usize, pass: usize, seed: u64) -> Vec<usize> {
    let mut state = seed ^ (pass as u64).wrapping_mul(0xA24B_AED4_963E_E407);
    let mut next = || {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    };
    let mut order: Vec<usize> = (0..rows).collect();
    for index in (1..rows).rev() {
        let bound = (index + 1) as u64;
        let zone = u64::MAX - (u64::MAX % bound);
        let other = loop {
            let value = next();
            if value < zone {
                break (value % bound) as usize;
            }
        };
        order.swap(index, other);
    }
    order
}

// ---------------------------------------------------------------------------------------------
// Inputs and metrics

struct Row {
    id: String,
    audio_s: f64,
    n_mel_frames: usize,
    n_enc_frames: usize,
    enc_file: String,
    mel: Vec<f32>,
    enc: Vec<f32>,
}

fn read_f32(path: &Path, count: usize) -> Result<Vec<f32>, String> {
    let bytes = fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if bytes.len() != count * 4 {
        return Err(format!(
            "{}: {} bytes, expected {}",
            path.display(),
            bytes.len(),
            count * 4
        ));
    }
    Ok(bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect())
}

fn read_rows(dir: &Path, limit: Option<usize>) -> Result<Vec<Row>, String> {
    let index = dir.join("index.jsonl");
    let text = fs::read_to_string(&index).map_err(|e| format!("{}: {e}", index.display()))?;
    let mut rows = Vec::new();
    for (line_no, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        if limit.is_some_and(|limit| rows.len() >= limit) {
            break;
        }
        let at = |e: String| format!("{}:{}: {e}", index.display(), line_no + 1);
        let obj = Parser::parse(line).map_err(at)?;
        let n_mels = obj.num_field("n_mels").map_err(at)? as usize;
        let n_state = obj.num_field("n_state").map_err(at)? as usize;
        if n_mels != N_MELS || n_state != N_STATE {
            return Err(at(format!("n_mels {n_mels} / n_state {n_state}")));
        }
        let n_mel_frames = obj.num_field("n_mel_frames").map_err(at)? as usize;
        let n_enc_frames = obj.num_field("n_enc_frames").map_err(at)? as usize;
        let mel_file = obj.str_field("mel_file").map_err(at)?;
        let enc_file = obj.str_field("enc_file").map_err(at)?.to_owned();
        rows.push(Row {
            id: obj.str_field("id").map_err(at)?.to_owned(),
            audio_s: obj.num_field("audio_s").map_err(at)?,
            n_mel_frames,
            n_enc_frames,
            mel: read_f32(&dir.join(mel_file), n_mel_frames * N_MELS)?,
            enc: read_f32(&dir.join(&enc_file), n_enc_frames * N_STATE)?,
            enc_file,
        });
    }
    Ok(rows)
}

#[derive(Clone, Copy)]
struct Err3 {
    max_abs: f64,
    rel_l2: f64,
    min_frame_cos: f64,
}

/// Error of `out` against the native states `reference` (both `[frames][N_STATE]`), in f64.
fn compare(out: &[f32], reference: &[f32]) -> Err3 {
    let mut max_abs = 0.0f64;
    let (mut diff2, mut ref2) = (0.0f64, 0.0f64);
    let mut min_cos = f64::INFINITY;
    for (a, b) in out
        .chunks_exact(N_STATE)
        .zip(reference.chunks_exact(N_STATE))
    {
        let (mut dot, mut aa, mut bb) = (0.0f64, 0.0f64, 0.0f64);
        for (&x, &y) in a.iter().zip(b) {
            let (x, y) = (f64::from(x), f64::from(y));
            let d = x - y;
            max_abs = if d.abs() > max_abs || d.is_nan() {
                d.abs()
            } else {
                max_abs
            };
            diff2 += d * d;
            ref2 += y * y;
            dot += x * y;
            aa += x * x;
            bb += y * y;
        }
        let cos = dot / (aa.sqrt() * bb.sqrt());
        min_cos = if cos < min_cos || cos.is_nan() {
            cos
        } else {
            min_cos
        };
    }
    Err3 {
        max_abs,
        rel_l2: (diff2 / ref2).sqrt(),
        min_frame_cos: min_cos,
    }
}

fn as_bytes(values: &[f32]) -> &[u8] {
    // SAFETY: f32 has no padding; arm64 is little-endian, the dump byte order.
    unsafe { std::slice::from_raw_parts(values.as_ptr().cast::<u8>(), values.len() * 4) }
}

fn quantile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    let h = (sorted.len() - 1) as f64 * p;
    let j = h.floor() as usize;
    let next = sorted[(j + 1).min(sorted.len() - 1)];
    sorted[j] + (h - j as f64) * (next - sorted[j])
}

// ---------------------------------------------------------------------------------------------
// Run

struct Options {
    dumps: PathBuf,
    arms: Vec<String>,
    passes: usize,
    output: PathBuf,
    write_states: Option<PathBuf>,
    model: PathBuf,
    limit: Option<usize>,
    seed: u64,
}

fn parse_args() -> Result<Options, String> {
    let mut args = std::env::args().skip(1);
    let (mut dumps, mut arms, mut passes, mut output) = (None, None, None, None);
    let (mut write_states, mut model, mut limit, mut seed) = (None, None, None, 20_261_016u64);
    while let Some(flag) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--dumps" => dumps = Some(PathBuf::from(value()?)),
            "--arms" => arms = Some(value()?.split(',').map(str::to_owned).collect::<Vec<_>>()),
            "--passes" => {
                passes = Some(
                    value()?
                        .parse::<usize>()
                        .map_err(|e| format!("--passes: {e}"))?,
                )
            }
            "--output" => output = Some(PathBuf::from(value()?)),
            "--write-states" => write_states = Some(PathBuf::from(value()?)),
            "--model" => model = Some(PathBuf::from(value()?)),
            "--limit" => {
                limit = Some(
                    value()?
                        .parse::<usize>()
                        .map_err(|e| format!("--limit: {e}"))?,
                )
            }
            "--seed" => {
                seed = value()?
                    .parse::<u64>()
                    .map_err(|e| format!("--seed: {e}"))?
            }
            "-h" | "--help" => return Err(USAGE.to_owned()),
            other => return Err(format!("unknown flag {other}\n{USAGE}")),
        }
    }
    let arms = arms.ok_or(USAGE)?;
    for arm in &arms {
        if Arm::parse(arm).is_none() {
            return Err(format!("unknown arm {arm:?}; known: {}", Arm::NAMES));
        }
    }
    Ok(Options {
        dumps: dumps.ok_or(USAGE)?,
        arms,
        passes: passes.ok_or(USAGE)?,
        output: output.ok_or(USAGE)?,
        write_states,
        model: model.unwrap_or_else(pin::default_model_path),
        limit,
        seed,
    })
}

struct ArmRun {
    name: String,
    engine: *mut Engine,
    load_s: f64,
    /// Per row (index order): error vs the native states (pass 0), timed samples (passes >= 1)
    /// with their graph-build share.
    err: Vec<Option<Err3>>,
    timed_us: Vec<Vec<f64>>,
    build_us: Vec<Vec<f64>>,
    hashes: Vec<Vec<String>>,
}

fn new_engine(model: &Path, arm: &str) -> Result<*mut Engine, String> {
    let path = CString::new(model.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
    let arm_c = CString::new(arm).map_err(|e| e.to_string())?;
    let mut err = [0 as c_char; 1024];
    // SAFETY: NUL-terminated strings and a 1024-byte error buffer.
    let engine =
        unsafe { ve_engine_new(path.as_ptr(), arm_c.as_ptr(), err.as_mut_ptr(), err.len()) };
    if engine.is_null() {
        // SAFETY: `ve_engine_new` NUL-terminates `err`.
        let message = unsafe { std::ffi::CStr::from_ptr(err.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        return Err(format!("ve_engine_new({arm}): {message}"));
    }
    Ok(engine)
}

fn run(options: &Options) -> Result<(), String> {
    let corpus = options
        .dumps
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "?".to_owned());
    let rows = read_rows(&options.dumps, options.limit)?;
    if rows.is_empty() {
        return Err("no rows".to_owned());
    }
    eprintln!(
        "encoder-bench: corpus {corpus}, {} rows, arms {:?}, passes {} (+ warmup)",
        rows.len(),
        options.arms,
        options.passes
    );

    let mut arms = Vec::new();
    for name in &options.arms {
        let start = Instant::now();
        let engine = new_engine(&options.model, name)?;
        let load_s = start.elapsed().as_secs_f64();
        eprintln!("  engine {name}: ready in {load_s:.2} s");
        arms.push(ArmRun {
            name: name.clone(),
            engine,
            load_s,
            err: vec![None; rows.len()],
            timed_us: vec![Vec::new(); rows.len()],
            build_us: vec![Vec::new(); rows.len()],
            hashes: vec![Vec::new(); rows.len()],
        });
    }

    if let Some(parent) = options.output.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let file = fs::File::create(&options.output)
        .map_err(|e| format!("{}: {e}", options.output.display()))?;
    let mut sink = BufWriter::new(file);
    let repo = command_line("/usr/bin/git", &["rev-parse", "--show-toplevel"]);
    let git_sha = repo
        .as_deref()
        .and_then(|root| command_line("/usr/bin/git", &["-C", root, "rev-parse", "HEAD"]));
    let mut meta = String::from(
        "{\"type\":\"run_meta\",\"bet\":\"B4\",\"harness\":\"rust:encoder-bench (encoder-mlx)\",\"git_sha\":",
    );
    json_opt_str(&mut meta, git_sha.as_deref());
    meta.push_str(",\"started_at\":");
    json_str(&mut meta, &now_iso8601());
    meta.push_str(",\"host\":");
    meta.push_str(&host_json());
    meta.push_str(",\"arms\":[");
    for (i, arm) in arms.iter().enumerate() {
        if i > 0 {
            meta.push(',');
        }
        json_str(&mut meta, &format!("mlx:{}", arm.name));
    }
    let _ = write!(meta, "],\"passes\":{},\"order\":", options.passes);
    json_str(
        &mut meta,
        &format!(
            "pass 0 warmup then passes 1..={}; per-pass seeded row permutation (SplitMix64 Fisher-Yates, seed {}); arms alternate forward/reverse per row",
            options.passes, options.seed
        ),
    );
    meta.push_str(",\"corpus\":");
    json_str(&mut meta, &corpus);
    meta.push_str(",\"notes\":");
    let load_notes: Vec<String> = arms
        .iter()
        .map(|a| format!("{} {:.2}s", a.name, a.load_s))
        .collect();
    json_str(
        &mut meta,
        &format!(
            "MLX {MLX_VERSION} ({MLX_COMMIT}) via mlx-rs {MLX_RS_VERSION}; elapsed_us = one ve_encode call (host mel -> MLX, graph build, one eval, GPU sync, copy-out); err vs the dumped native Metal encoder states (f64 accumulation), min_frame_cos = minimum per-frame cosine; equal_ref null (state bit-identity is work.bit_equal; transcript identity is judged by the Swift harness); engine load {}",
            load_notes.join(", ")
        ),
    );
    meta.push('}');
    writeln!(sink, "{meta}").map_err(|e| e.to_string())?;

    let state_dirs: Vec<Option<PathBuf>> = arms
        .iter()
        .map(|arm| options.write_states.as_ref().map(|dir| dir.join(&arm.name)))
        .collect();
    let mut state_index: Vec<Vec<String>> = vec![Vec::new(); arms.len()];
    for dir in state_dirs.iter().flatten() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }

    let max_frames = rows.iter().map(|r| r.n_enc_frames).max().unwrap_or(0);
    let mut out = vec![0.0f32; max_frames * N_STATE];
    let mut err_buf = [0 as c_char; 1024];
    let mut seq = 0u64;
    let started = Instant::now();
    for pass in 0..=options.passes {
        let order = pass_order(rows.len(), pass, options.seed);
        for (position, &r) in order.iter().enumerate() {
            let row = &rows[r];
            let arm_order: Vec<usize> = if position % 2 == 0 {
                (0..arms.len()).collect()
            } else {
                (0..arms.len()).rev().collect()
            };
            for a in arm_order {
                let arm = &mut arms[a];
                let start = Instant::now();
                // SAFETY: buffers sized per the ABI; `err_buf` holds 1024 bytes.
                let frames = unsafe {
                    ve_encode(
                        arm.engine,
                        row.mel.as_ptr(),
                        row.n_mel_frames as i32,
                        N_MELS as i32,
                        out.as_mut_ptr(),
                        max_frames as i32,
                        N_STATE as i32,
                        err_buf.as_mut_ptr(),
                        err_buf.len(),
                    )
                };
                let elapsed_us = start.elapsed().as_secs_f64() * 1e6;
                // SAFETY: the engine is live and `ve_encode` has returned.
                let profile = unsafe { (*arm.engine).last_profile() };
                if frames < 0 {
                    // SAFETY: `ve_encode` NUL-terminates `err_buf` on failure.
                    let message = unsafe { std::ffi::CStr::from_ptr(err_buf.as_ptr()) }
                        .to_string_lossy()
                        .into_owned();
                    return Err(format!("{} row {}: {message}", arm.name, row.id));
                }
                if frames as usize != row.n_enc_frames {
                    return Err(format!(
                        "{} row {}: {frames} frames, dump has {}",
                        arm.name, row.id, row.n_enc_frames
                    ));
                }
                let states = &out[..row.n_enc_frames * N_STATE];
                let digest = pin::sha256_hex(as_bytes(states));
                let err = compare(states, &row.enc);
                let bit_equal = states
                    .iter()
                    .zip(&row.enc)
                    .all(|(x, y)| x.to_bits() == y.to_bits());
                if pass == 0 {
                    arm.err[r] = Some(err);
                    if let Some(dir) = &state_dirs[a] {
                        let path = dir.join(&row.enc_file);
                        fs::write(&path, as_bytes(states))
                            .map_err(|e| format!("{}: {e}", path.display()))?;
                        let mut line = String::from("{\"id\":");
                        json_str(&mut line, &row.id);
                        line.push_str(",\"enc_file\":");
                        json_str(&mut line, &row.enc_file);
                        let _ = write!(
                            line,
                            ",\"n_enc_frames\":{},\"n_state\":{N_STATE},\"enc_sha256\":",
                            row.n_enc_frames
                        );
                        json_str(&mut line, &digest);
                        line.push_str(",\"max_abs\":");
                        json_num(&mut line, err.max_abs);
                        line.push_str(",\"rel_l2\":");
                        json_num(&mut line, err.rel_l2);
                        line.push_str(",\"min_frame_cos\":");
                        json_num(&mut line, err.min_frame_cos);
                        line.push('}');
                        state_index[a].push(line);
                    }
                } else {
                    arm.timed_us[r].push(elapsed_us);
                    arm.build_us[r].push(profile.build_us);
                }
                arm.hashes[r].push(digest.clone());

                let mut line = String::from("{\"type\":\"timing\",\"bet\":\"B4\",\"arm\":");
                json_str(&mut line, &format!("mlx:{}", arm.name));
                line.push_str(",\"row_id\":");
                json_str(&mut line, &row.id);
                let _ = write!(line, ",\"pass\":{pass},\"seq\":{seq},\"elapsed_us\":");
                json_num(&mut line, elapsed_us);
                line.push_str(",\"output_sha256\":");
                json_str(&mut line, &digest);
                line.push_str(",\"equal_ref\":null,\"audio_s\":");
                json_num(&mut line, row.audio_s);
                let _ = write!(
                    line,
                    ",\"work\":{{\"n_mel_frames\":{},\"n_enc_frames\":{},\"bit_equal\":{bit_equal},\"build_us\":{:.1},\"eval_us\":{:.1},\"copy_us\":{:.1}}},\"err\":{{\"max_abs\":",
                    row.n_mel_frames,
                    row.n_enc_frames,
                    profile.build_us,
                    profile.eval_us,
                    profile.copy_us
                );
                json_num(&mut line, err.max_abs);
                line.push_str(",\"rel_l2\":");
                json_num(&mut line, err.rel_l2);
                line.push_str(",\"min_frame_cos\":");
                json_num(&mut line, err.min_frame_cos);
                line.push_str("}}");
                writeln!(sink, "{line}").map_err(|e| e.to_string())?;
                seq += 1;
            }
        }
        eprintln!(
            "  pass {pass} done at {:.1} s",
            started.elapsed().as_secs_f64()
        );
    }
    sink.flush().map_err(|e| e.to_string())?;

    for (a, dir) in state_dirs.iter().enumerate() {
        if let Some(dir) = dir {
            let path = dir.join("index.jsonl");
            let mut text = state_index[a].join("\n");
            text.push('\n');
            fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
        }
    }

    // Summary (stderr): numerics per arm over all rows; timing medians over passes >= 1.
    eprintln!(
        "\n| arm | rows | max_abs (max) | rel_l2 (median) | rel_l2 (max) | min frame cos | nondeterministic rows | median elapsed ms | median graph build ms | sum of per-row medians s |"
    );
    eprintln!("|---|---|---|---|---|---|---|---|---|---|");
    for arm in &arms {
        let errs: Vec<Err3> = arm.err.iter().flatten().copied().collect();
        let nonfinite = errs
            .iter()
            .filter(|e| !e.max_abs.is_finite() || !e.rel_l2.is_finite())
            .count();
        let max_abs = errs.iter().map(|e| e.max_abs).fold(0.0f64, f64::max);
        let mut rel: Vec<f64> = errs.iter().map(|e| e.rel_l2).collect();
        rel.sort_by(f64::total_cmp);
        let min_cos = errs
            .iter()
            .map(|e| e.min_frame_cos)
            .fold(f64::INFINITY, f64::min);
        let nondeterministic = arm
            .hashes
            .iter()
            .filter(|h| h.iter().any(|x| x != &h[0]))
            .count();
        let per_row_median = |samples: &[Vec<f64>]| -> Vec<f64> {
            samples
                .iter()
                .filter(|t| !t.is_empty())
                .map(|t| {
                    let mut t = t.clone();
                    t.sort_by(f64::total_cmp);
                    quantile(&t, 0.5)
                })
                .collect()
        };
        let mut medians = per_row_median(&arm.timed_us);
        let mut builds = per_row_median(&arm.build_us);
        let total_s: f64 = medians.iter().sum::<f64>() / 1e6;
        medians.sort_by(f64::total_cmp);
        builds.sort_by(f64::total_cmp);
        eprintln!(
            "| mlx:{} | {} | {:.4e} | {:.4e} | {:.4e} | {:.6} | {} | {:.2} | {:.2} | {:.3} |{}",
            arm.name,
            errs.len(),
            max_abs,
            quantile(&rel, 0.5),
            rel.last().copied().unwrap_or(f64::NAN),
            min_cos,
            nondeterministic,
            quantile(&medians, 0.5) / 1e3,
            quantile(&builds, 0.5) / 1e3,
            total_s,
            if nonfinite > 0 {
                format!(" {nonfinite} NON-FINITE rows")
            } else {
                String::new()
            }
        );
    }
    for arm in &arms {
        // SAFETY: created by `ve_engine_new`, not used afterwards.
        unsafe { ve_engine_free(arm.engine) };
    }
    eprintln!("rows: {}", options.output.display());
    Ok(())
}

fn main() -> ExitCode {
    let options = match parse_args() {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    match run(&options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("encoder-bench: {message}");
            ExitCode::FAILURE
        }
    }
}
