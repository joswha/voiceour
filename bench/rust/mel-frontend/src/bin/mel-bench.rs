//! `mel-bench`: B2 timing and equivalence rows for the Rust mel arms against the dumped native
//! mel (`.build/rust-bench/dumps/<corpus>/<n>.mel.f32`).
//!
//! ```text
//! mel-bench --dumps <dir> [--arms a,b,...] [--passes N] [--output rows.jsonl] [--model <bin>]
//!           [--repo-root <dir>] [--threads N] [--limit N] [--corpus name,...]
//! ```
//! `--dumps` is one corpus directory (holding `index.jsonl`) or a parent of several. Each row's WAV
//! is checked against `audio_sha256` and decoded by the port of the sidecar's `WAVFile`. Passes
//! `0..=N` run; pass 0 is the warmup. Each timing row's `elapsed_us` is one `vm_compute` call;
//! `equal_ref` and `err` compare its output with the dumped mel.

use std::fmt::Write as _;
use std::fs;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::sync::Arc;
use std::time::Instant;

use mel_frontend::{ARM_NAMES, Arm, DEFAULT_THREADS, Engine, Frontend, vm_compute, vm_engine, wav};
use parakeet_model::pin;
use serde_json::{Value, json};

/// Output frames beyond the expected count, as the Swift harness allocates them.
const FRAME_SLACK: usize = 16;

struct Options {
    dumps: PathBuf,
    arms: Vec<String>,
    passes: usize,
    output: Option<PathBuf>,
    model: PathBuf,
    repo_root: PathBuf,
    threads: usize,
    limit: Option<usize>,
    corpora: Option<Vec<String>>,
}

const USAGE: &str = "usage: mel-bench --dumps <dir> [--arms a,b,...] [--passes N] [--output rows.jsonl] \
                     [--model <bin>] [--repo-root <dir>] [--threads N] [--limit N] [--corpus name,...]";

fn parse_options() -> Result<Options, String> {
    let mut options = Options {
        dumps: PathBuf::new(),
        arms: ARM_NAMES.iter().map(|arm| (*arm).to_owned()).collect(),
        passes: 3,
        output: None,
        model: pin::default_model_path(),
        repo_root: PathBuf::from("."),
        threads: DEFAULT_THREADS,
        limit: None,
        corpora: None,
    };
    let mut have_dumps = false;
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        let mut value = || {
            args.next()
                .ok_or_else(|| format!("{flag} needs a value\n{USAGE}"))
        };
        match flag.as_str() {
            "--dumps" => {
                options.dumps = PathBuf::from(value()?);
                have_dumps = true;
            }
            "--arms" => options.arms = value()?.split(',').map(str::to_owned).collect(),
            "--passes" => {
                options.passes = value()?.parse().map_err(|e| format!("--passes: {e}"))?
            }
            "--output" => options.output = Some(PathBuf::from(value()?)),
            "--model" => options.model = PathBuf::from(value()?),
            "--repo-root" => options.repo_root = PathBuf::from(value()?),
            "--threads" => {
                options.threads = value()?.parse().map_err(|e| format!("--threads: {e}"))?
            }
            "--limit" => {
                options.limit = Some(value()?.parse().map_err(|e| format!("--limit: {e}"))?)
            }
            "--corpus" => options.corpora = Some(value()?.split(',').map(str::to_owned).collect()),
            "-h" | "--help" => return Err(USAGE.to_owned()),
            other => return Err(format!("unknown argument {other}\n{USAGE}")),
        }
    }
    if !have_dumps {
        return Err(USAGE.to_owned());
    }
    for arm in &options.arms {
        if Arm::parse(arm).is_none() {
            return Err(format!(
                "unknown arm '{arm}'; arms: {}",
                ARM_NAMES.join(",")
            ));
        }
    }
    Ok(options)
}

struct Row {
    id: String,
    audio_s: f64,
    samples: Vec<f32>,
    reference: Vec<f32>,
    n_frames: usize,
}

struct Corpus {
    name: String,
    dir: PathBuf,
    index_sha256: String,
    rows: Vec<Row>,
}

fn corpus_dirs(options: &Options) -> Result<Vec<PathBuf>, String> {
    if options.dumps.join("index.jsonl").is_file() {
        return Ok(vec![options.dumps.clone()]);
    }
    let entries =
        fs::read_dir(&options.dumps).map_err(|e| format!("{}: {e}", options.dumps.display()))?;
    let mut dirs: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.join("index.jsonl").is_file())
        .collect();
    dirs.sort();
    if let Some(wanted) = &options.corpora {
        dirs.retain(|dir| {
            wanted
                .iter()
                .any(|name| dir.file_name().is_some_and(|f| f == name.as_str()))
        });
    }
    if dirs.is_empty() {
        return Err(format!("no index.jsonl under {}", options.dumps.display()));
    }
    Ok(dirs)
}

fn load_corpus(dir: &Path, options: &Options, frontend: &Frontend) -> Result<Corpus, String> {
    let index_path = dir.join("index.jsonl");
    let index = fs::read(&index_path).map_err(|e| format!("{}: {e}", index_path.display()))?;
    let mut rows = Vec::new();
    for (line_number, line) in index.split(|&b| b == b'\n').enumerate() {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        if options.limit.is_some_and(|limit| rows.len() >= limit) {
            break;
        }
        let entry: Value = serde_json::from_slice(line)
            .map_err(|e| format!("{}:{}: {e}", index_path.display(), line_number + 1))?;
        let field = |name: &str| {
            entry
                .get(name)
                .ok_or_else(|| format!("{}: row lacks {name}", index_path.display()))
        };
        let id = field("id")?
            .as_str()
            .ok_or("id is not a string")?
            .to_owned();
        let text = |name: &str| -> Result<String, String> {
            Ok(field(name)?
                .as_str()
                .ok_or_else(|| format!("{id}: {name} is not a string"))?
                .to_owned())
        };
        let number = |name: &str| {
            field(name)?
                .as_u64()
                .ok_or_else(|| format!("{id}: {name} is not an integer"))
        };

        let audio_path = text("audio_path")?;
        let audio_path = if Path::new(&audio_path).is_absolute() {
            PathBuf::from(&audio_path)
        } else {
            options.repo_root.join(&audio_path)
        };
        let audio =
            fs::read(&audio_path).map_err(|e| format!("{id}: {}: {e}", audio_path.display()))?;
        let digest = pin::sha256_hex(&audio);
        if digest != text("audio_sha256")? {
            return Err(format!(
                "{id}: {} sha256 {digest} is not the dump's",
                audio_path.display()
            ));
        }
        let samples = wav::read_samples(&audio).map_err(|e| format!("{id}: {e}"))?;
        if samples.len() as u64 != number("n_samples")? {
            return Err(format!(
                "{id}: decoded {} samples, the dump has {}",
                samples.len(),
                number("n_samples")?
            ));
        }
        let n_frames = number("n_mel_frames")? as usize;
        let n_mels = number("n_mels")? as usize;
        if n_frames != frontend.n_frames(samples.len()) || n_mels != frontend.n_mels {
            return Err(format!(
                "{id}: dump mel is {n_frames} x {n_mels}, expected {} x {}",
                frontend.n_frames(samples.len()),
                frontend.n_mels
            ));
        }
        let mel_path = dir.join(text("mel_file")?);
        let mel_bytes =
            fs::read(&mel_path).map_err(|e| format!("{id}: {}: {e}", mel_path.display()))?;
        if mel_bytes.len() != n_frames * n_mels * 4 {
            return Err(format!(
                "{id}: {} has {} bytes, expected {}",
                mel_path.display(),
                mel_bytes.len(),
                n_frames * n_mels * 4
            ));
        }
        if let Some(expected) = entry.get("mel_sha256").and_then(Value::as_str) {
            let digest = pin::sha256_hex(&mel_bytes);
            if digest != expected {
                return Err(format!(
                    "{id}: {} sha256 {digest} is not the index's {expected}",
                    mel_path.display()
                ));
            }
        }
        let reference = mel_bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        let audio_s = field("audio_s")?
            .as_f64()
            .ok_or_else(|| format!("{id}: audio_s is not a number"))?;
        rows.push(Row {
            id,
            audio_s,
            samples,
            reference,
            n_frames,
        });
    }
    Ok(Corpus {
        name: dir.file_name().map_or_else(
            || dir.display().to_string(),
            |name| name.to_string_lossy().into_owned(),
        ),
        dir: dir.to_owned(),
        index_sha256: pin::sha256_hex(&index),
        rows,
    })
}

/// The Swift harness's arm orders (`RustBench.orderSequences`): a Williams design.
fn order_sequences(arm_count: usize) -> Vec<Vec<usize>> {
    if arm_count <= 1 {
        return vec![(0..arm_count).collect()];
    }
    let base: Vec<usize> = (0..arm_count)
        .map(|p| {
            if p == 0 {
                0
            } else if p % 2 == 1 {
                p.div_ceil(2)
            } else {
                arm_count - p / 2
            }
        })
        .collect();
    let shifted: Vec<Vec<usize>> = (0..arm_count)
        .map(|s| base.iter().map(|a| (a + s) % arm_count).collect())
        .collect();
    if arm_count % 2 == 0 {
        shifted
    } else {
        let reversed: Vec<Vec<usize>> = shifted
            .iter()
            .map(|seq| seq.iter().rev().copied().collect())
            .collect();
        shifted.into_iter().chain(reversed).collect()
    }
}

/// Bitwise identity plus the contract's error (`RustBenchComparison`).
struct Comparison {
    identical: bool,
    max_abs: f64,
    rel_l2: f64,
    non_finite: usize,
}

fn compare(candidate: &[f32], reference: &[f32]) -> Comparison {
    let identical = candidate
        .iter()
        .zip(reference)
        .all(|(a, b)| a.to_bits() == b.to_bits());
    let (mut max_abs, mut diff_sq, mut ref_sq, mut non_finite) = (0.0f64, 0.0f64, 0.0f64, 0usize);
    for (&value, &expected) in candidate.iter().zip(reference) {
        let (value, expected) = (value as f64, expected as f64);
        if !value.is_finite() {
            non_finite += 1;
            continue;
        }
        let difference = (value - expected).abs();
        max_abs = max_abs.max(difference);
        diff_sq += difference * difference;
        ref_sq += expected * expected;
    }
    let rel_l2 = if ref_sq > 0.0 {
        (diff_sq / ref_sq).sqrt()
    } else {
        diff_sq.sqrt()
    };
    Comparison {
        identical,
        max_abs,
        rel_l2,
        non_finite,
    }
}

#[derive(Default)]
struct ArmSummary {
    calls: usize,
    failures: usize,
    identical: usize,
    max_abs: f64,
    max_rel_l2: f64,
    timed_us: Vec<f64>,
    timed_audio_s: f64,
    differing_rows: Vec<String>,
}

fn sysctl(name: &str) -> Option<String> {
    let output = Command::new("/usr/sbin/sysctl")
        .arg("-n")
        .arg(name)
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn command_line(program: &str, arguments: &[&str]) -> Option<String> {
    let output = Command::new(program).args(arguments).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn host_meta() -> Value {
    let load: Vec<f64> = sysctl("vm.loadavg")
        .map(|text| {
            text.trim_matches(|c| c == '{' || c == '}' || c == ' ')
                .split_whitespace()
                .filter_map(|v| v.parse().ok())
                .collect()
        })
        .unwrap_or_default();
    let power = command_line("/usr/bin/pmset", &["-g", "batt"]).map_or("unknown", |text| {
        if text.contains("AC Power") {
            "AC"
        } else if text.contains("Battery Power") {
            "battery"
        } else {
            "unknown"
        }
    });
    let int = |name: &str| sysctl(name).and_then(|value| value.parse::<u64>().ok());
    json!({
        "chip": sysctl("machdep.cpu.brand_string"),
        "os": sysctl("kern.osproductversion"),
        "os_build": sysctl("kern.osversion"),
        "power": power,
        "load_avg": load,
        "cpu_threads": int("hw.ncpu"),
        "perf_cores": int("hw.perflevel0.physicalcpu"),
        "eff_cores": int("hw.perflevel1.physicalcpu"),
        "memory_bytes": int("hw.memsize"),
    })
}

/// UTC ISO 8601 with seconds (Howard Hinnant's civil-from-days).
fn now_iso8601() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs() as i64);
    let (days, rem) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
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

fn output_sha256(values: &[f32]) -> String {
    let bytes: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    pin::sha256_hex(&bytes)
}

fn median(values: &mut [f64]) -> f64 {
    if values.is_empty() {
        return f64::NAN;
    }
    values.sort_by(f64::total_cmp);
    let mid = values.len() / 2;
    if values.len() % 2 == 1 {
        values[mid]
    } else {
        (values[mid - 1] + values[mid]) / 2.0
    }
}

fn run() -> Result<bool, String> {
    let options = parse_options()?;
    let frontend = Arc::new(Frontend::open(&options.model)?);
    let mut engines: Vec<(String, Box<vm_engine>)> = Vec::new();
    for name in &options.arms {
        let arm = Arm::parse(name).expect("validated");
        let engine = Engine::new(Arc::clone(&frontend), arm, options.threads)?;
        engines.push((name.clone(), vm_engine::from_engine(engine)));
    }
    let labels: Vec<String> = engines
        .iter()
        .map(|(name, _)| format!("rust:{name}"))
        .collect();
    let sequences = order_sequences(engines.len());
    let git_sha = command_line(
        "/usr/bin/git",
        &[
            "-C",
            &options.repo_root.to_string_lossy(),
            "rev-parse",
            "HEAD",
        ],
    );
    let mut writer = match &options.output {
        Some(path) => Some(BufWriter::new(
            fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?,
        )),
        None => None,
    };
    let mut emit = |value: Value| -> Result<(), String> {
        if let Some(writer) = writer.as_mut() {
            serde_json::to_writer(&mut *writer, &value).map_err(|e| e.to_string())?;
            writer.write_all(b"\n").map_err(|e| e.to_string())?;
        }
        Ok(())
    };

    let mut seq = 0usize;
    let mut report = String::new();
    let mut all_bit_identical_arms_exact = true;
    for dir in corpus_dirs(&options)? {
        let corpus = load_corpus(&dir, &options, &frontend)?;
        eprintln!(
            "mel-bench: {} rows from {}",
            corpus.rows.len(),
            corpus.dir.display()
        );
        let arms_meta: Vec<Value> = engines
            .iter()
            .map(|(name, engine)| {
                let engine = engine.engine();
                json!({
                    "arm": format!("rust:{name}"),
                    "implementation": engine.arm().name(),
                    "bit_identical_by_construction": engine.arm().bit_identical(),
                    "threads": engine.threads(),
                    "groups_per_frame": engine.groups_per_frame(),
                })
            })
            .collect();
        emit(json!({
            "type": "run_meta",
            "bet": "B2",
            "harness": "mel-bench (bench/rust/mel-frontend)",
            "git_sha": git_sha,
            "started_at": now_iso8601(),
            "host": host_meta(),
            "arms": labels,
            "passes": options.passes,
            "order": format!(
                "passes 0..={}, pass 0 warmup; rows in dump index order; pass p, row index r runs Williams sequence \
                 (p + r) mod {} of order_sequences (as voiceour-bench RustBench.orderSequences); seq is the global \
                 execution order",
                options.passes,
                sequences.len()
            ),
            "corpus": corpus.name,
            "notes": "elapsed_us = wall time (std::time::Instant) of one vm_compute call into a NaN-filled \
                      [n_frames + 16][128] buffer. Samples: the Rust port of WAVFile.readSamples after checking the \
                      file's sha256 against index.jsonl audio_sha256. Reference: the dump's <n>.mel.f32 (the native \
                      parakeet_pcm_to_mel output, checked against mel_sha256). equal_ref = bitwise identical; err = \
                      max_abs / rel_l2 against the reference (null when the output has non-finite values). \
                      best-approx runs the arm named in run_meta.arm_details[].implementation.",
            "dump": { "dir": corpus.dir.display().to_string(), "index_sha256": corpus.index_sha256 },
            "model": options.model.display().to_string(),
            "threads": options.threads,
            "arm_details": arms_meta,
        }))?;

        let mut summaries: Vec<ArmSummary> =
            engines.iter().map(|_| ArmSummary::default()).collect();
        let mut err_buffer = vec![0 as std::ffi::c_char; 1024];
        for pass in 0..=options.passes {
            for (row_index, row) in corpus.rows.iter().enumerate() {
                let max_frames = row.n_frames + FRAME_SLACK;
                let mut out = vec![f32::NAN; max_frames * frontend.n_mels];
                for &arm_index in &sequences[(pass + row_index) % sequences.len()] {
                    let (name, engine) = &mut engines[arm_index];
                    out.fill(f32::NAN);
                    err_buffer[0] = 0;
                    let engine_ptr: *mut vm_engine = &mut **engine;
                    let start = Instant::now();
                    // SAFETY: a live engine, `samples` and `out` sized as passed, a 1 KiB error buffer.
                    let frames = unsafe {
                        vm_compute(
                            engine_ptr,
                            row.samples.as_ptr(),
                            row.samples.len() as i32,
                            out.as_mut_ptr(),
                            max_frames as i32,
                            frontend.n_mels as i32,
                            err_buffer.as_mut_ptr(),
                            err_buffer.len(),
                        )
                    };
                    let elapsed_us = start.elapsed().as_secs_f64() * 1e6;
                    let summary = &mut summaries[arm_index];
                    summary.calls += 1;
                    let engine = engine.engine();
                    let mut work = json!({
                        "n_samples": row.samples.len(),
                        "threads": engine.threads(),
                        "groups_per_frame": engine.groups_per_frame(),
                        "implementation": engine.arm().name(),
                    });
                    let timing = if frames < 0 || frames as usize != row.n_frames {
                        let message = if frames < 0 {
                            // SAFETY: NUL-terminated by vm_compute (or still empty).
                            unsafe { std::ffi::CStr::from_ptr(err_buffer.as_ptr()) }
                                .to_string_lossy()
                                .into_owned()
                        } else {
                            format!("{frames} frames, expected {}", row.n_frames)
                        };
                        summary.failures += 1;
                        work["error"] = json!(message);
                        json!({"type": "timing", "bet": "B2", "arm": format!("rust:{name}"), "row_id": row.id,
                               "pass": pass, "seq": seq, "elapsed_us": Value::Null, "output_sha256": Value::Null,
                               "equal_ref": Value::Null, "audio_s": row.audio_s, "work": work, "err": Value::Null})
                    } else {
                        let mel = &out[..row.n_frames * frontend.n_mels];
                        let comparison = compare(mel, &row.reference);
                        work["n_frames"] = json!(frames);
                        work["non_finite"] = json!(comparison.non_finite);
                        if pass == 0 {
                            if comparison.identical {
                                summary.identical += 1;
                            } else {
                                summary.differing_rows.push(row.id.clone());
                            }
                            summary.max_abs = summary.max_abs.max(comparison.max_abs);
                            summary.max_rel_l2 = summary.max_rel_l2.max(comparison.rel_l2);
                        }
                        if pass > 0 || options.passes == 0 {
                            summary.timed_us.push(elapsed_us);
                            summary.timed_audio_s += row.audio_s;
                        }
                        let err = if comparison.non_finite == 0 {
                            json!({"max_abs": comparison.max_abs, "rel_l2": comparison.rel_l2})
                        } else {
                            Value::Null
                        };
                        json!({"type": "timing", "bet": "B2", "arm": format!("rust:{name}"), "row_id": row.id,
                               "pass": pass, "seq": seq, "elapsed_us": elapsed_us, "output_sha256": output_sha256(mel),
                               "equal_ref": comparison.identical, "audio_s": row.audio_s, "work": work, "err": err})
                    };
                    emit(timing)?;
                    seq += 1;
                }
            }
            eprintln!("mel-bench: {} pass {pass} done", corpus.name);
        }

        let rows = corpus.rows.len();
        let _ = writeln!(
            report,
            "\n{} ({rows} rows, {:.1} s audio; timing over passes {}):",
            corpus.name,
            corpus.rows.iter().map(|row| row.audio_s).sum::<f64>(),
            if options.passes == 0 {
                "0".to_owned()
            } else {
                format!("1..={}", options.passes)
            }
        );
        let _ = writeln!(
            report,
            "  {:<22} {:>9} {:>12} {:>12} {:>13} {:>11} {:>11}",
            "arm",
            "identical",
            "max_abs",
            "max_rel_l2",
            "median_us/row",
            "mean_us/row",
            "us/audio_s"
        );
        for ((name, engine), summary) in engines.iter().zip(summaries.iter_mut()) {
            let mean = summary.timed_us.iter().sum::<f64>() / summary.timed_us.len().max(1) as f64;
            let per_audio_s = summary.timed_us.iter().sum::<f64>() / summary.timed_audio_s;
            let _ = writeln!(
                report,
                "  {:<22} {:>4}/{:<4} {:>12.3e} {:>12.3e} {:>13.1} {:>11.1} {:>11.1}{}",
                format!("rust:{name}"),
                summary.identical,
                rows,
                summary.max_abs,
                summary.max_rel_l2,
                median(&mut summary.timed_us),
                mean,
                per_audio_s,
                if summary.failures > 0 {
                    format!("  ({} failed calls)", summary.failures)
                } else {
                    String::new()
                }
            );
            if engine.engine().arm().bit_identical() && summary.identical != rows {
                all_bit_identical_arms_exact = false;
                let _ = writeln!(
                    report,
                    "    differing rows: {}",
                    summary.differing_rows.join(", ")
                );
            }
        }
    }
    if let Some(writer) = writer.as_mut() {
        writer.flush().map_err(|e| e.to_string())?;
    }
    eprint!("{report}");
    Ok(all_bit_identical_arms_exact)
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => {
            eprintln!("mel-bench: a bit-identical arm differed from the dump");
            ExitCode::from(1)
        }
        Err(message) => {
            eprintln!("mel-bench: {message}");
            ExitCode::from(2)
        }
    }
}
