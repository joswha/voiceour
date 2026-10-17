//! encoder-bench: bet B4 timing rows (arms `candle:<arm>`) for the candle-metal encoder, with
//! every row's states compared against the native Metal encoder states in the dump.
//!
//! ```text
//! encoder-bench --dumps <dir> [--dumps <dir>...] --arms f32,f16w+fused --passes N --output rows.jsonl
//!               [--write-states <dir>] [--model <path>] [--limit N] [--seed S]
//!               [--profile-ops N]
//! ```
//!
//! `--dumps` takes a corpus directory (holding `index.jsonl`) or a parent of corpus directories.
//! Pass 0 is the warmup pass (the analyzer drops it); `--passes 0` runs it alone, which is the
//! numerics run. Within a pass rows follow a seeded permutation and the arms alternate forward
//! and reverse order per row. `elapsed_us` is one `Encoder::encode` call — the body of
//! `ve_encode`: host mel in, host states out, synchronized.
//!
//! `--write-states <dir>` writes our states in the dump layout, `<dir>/<arm>/<corpus>/<n>.enc.f32`
//! next to a copy of the corpus `index.jsonl`, on pass 0.
//!
//! `--profile-ops N` instead encodes the first N rows of each corpus per arm with a device
//! synchronization after every stage and prints where the time goes (serialized, attribution
//! only; no timing rows).

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::Instant;

use encoder_candle::dumps::{Corpus, f32_bytes};
use encoder_candle::json::{num, quote};
use encoder_candle::metrics::{Agreement, compare};
use encoder_candle::{ARM_NAMES, Arm, Encoder, Precision};

struct Args {
    dumps: Vec<PathBuf>,
    arms: Vec<Arm>,
    passes: usize,
    output: Option<PathBuf>,
    write_states: Option<PathBuf>,
    model: PathBuf,
    limit: Option<usize>,
    seed: u64,
    profile_ops: Option<usize>,
}

fn usage() -> String {
    format!(
        "usage: encoder-bench --dumps <dir> [--dumps <dir>...] --arms <a,b,...> --passes N --output <rows.jsonl>\n\
         \x20                    [--write-states <dir>] [--model <path>] [--limit N] [--seed S] [--profile-ops N]\n\
         arms: {ARM_NAMES}"
    )
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        dumps: Vec::new(),
        arms: Vec::new(),
        passes: 1,
        output: None,
        write_states: None,
        model: parakeet_model::pin::default_model_path(),
        limit: None,
        seed: 0x5EED_B4A,
        profile_ops: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--dumps" => args.dumps.push(PathBuf::from(value()?)),
            "--arms" => {
                for name in value()?.split(',').filter(|s| !s.is_empty()) {
                    let name = name.strip_prefix("candle:").unwrap_or(name);
                    args.arms.push(
                        Arm::parse(name)
                            .ok_or(format!("unknown arm {name:?}; arms: {ARM_NAMES}"))?,
                    );
                }
            }
            "--passes" => {
                args.passes = value()?.parse().map_err(|_| "--passes takes an integer")?
            }
            "--output" => args.output = Some(PathBuf::from(value()?)),
            "--write-states" => args.write_states = Some(PathBuf::from(value()?)),
            "--model" => args.model = PathBuf::from(value()?),
            "--limit" => {
                args.limit = Some(value()?.parse().map_err(|_| "--limit takes an integer")?)
            }
            "--seed" => args.seed = value()?.parse().map_err(|_| "--seed takes an integer")?,
            "--profile-ops" => {
                args.profile_ops = Some(
                    value()?
                        .parse()
                        .map_err(|_| "--profile-ops takes an integer")?,
                )
            }
            "-h" | "--help" => return Err(usage()),
            other => return Err(format!("unknown flag {other}\n{}", usage())),
        }
    }
    if args.dumps.is_empty() || args.arms.is_empty() {
        return Err(usage());
    }
    if args.profile_ops.is_none() && args.output.is_none() {
        return Err(format!("--output is required\n{}", usage()));
    }
    Ok(args)
}

// ---- host / run metadata (same conventions as the other bench crates) ----

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
    let load: Vec<String> = sysctl("vm.loadavg")
        .map(|text| {
            text.trim_matches(|c| c == '{' || c == '}' || c == ' ')
                .split_whitespace()
                .filter_map(|v| v.parse::<f64>().ok())
                .map(num)
                .collect()
        })
        .unwrap_or_default();
    let power = match command_line("/usr/bin/pmset", &["-g", "batt"]) {
        Some(t) if t.contains("AC Power") => "AC",
        Some(t) if t.contains("Battery Power") => "battery",
        _ => "unknown",
    };
    let s = |name: &str| sysctl(name).map_or("null".to_owned(), |v| quote(&v));
    let i = |name: &str| {
        sysctl(name)
            .and_then(|v| v.parse::<u64>().ok())
            .map_or("null".to_owned(), |v| v.to_string())
    };
    format!(
        "{{\"chip\":{},\"os\":{},\"os_build\":{},\"power\":{},\"load_avg\":[{}],\"cpu_threads\":{},\
         \"perf_cores\":{},\"eff_cores\":{},\"memory_bytes\":{}}}",
        s("machdep.cpu.brand_string"),
        s("kern.osproductversion"),
        s("kern.osversion"),
        quote(power),
        load.join(","),
        i("hw.ncpu"),
        i("hw.perflevel0.physicalcpu"),
        i("hw.perflevel1.physicalcpu"),
        i("hw.memsize"),
    )
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn git_sha() -> Option<String> {
    command_line(
        "/usr/bin/git",
        &["-C", repo_root().to_str()?, "rev-parse", "HEAD"],
    )
}

fn now_iso8601() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
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

struct SplitMix64(u64);

impl SplitMix64 {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

/// Seeded per-pass row permutation (Fisher-Yates).
fn pass_order(rows: usize, pass: usize, seed: u64) -> Vec<usize> {
    let mut order: Vec<usize> = (0..rows).collect();
    let mut rng = SplitMix64(seed ^ (pass as u64).wrapping_mul(0xA24B_AED4_963E_E407));
    for i in (1..rows).rev() {
        let j = (rng.next() % (i as u64 + 1)) as usize;
        order.swap(i, j);
    }
    order
}

// ---- per (arm, corpus) aggregation ----

#[derive(Default)]
struct Tally {
    rows: usize,
    audio_s: f64,
    errs: Vec<Agreement>,
    /// Timed passes only (pass >= 1).
    elapsed_us: Vec<f64>,
    timed_audio_s: f64,
}

fn median(values: &mut [f64]) -> f64 {
    if values.is_empty() {
        return f64::NAN;
    }
    values.sort_by(f64::total_cmp);
    let n = values.len();
    if n % 2 == 1 {
        values[n / 2]
    } else {
        0.5 * (values[n / 2 - 1] + values[n / 2])
    }
}

fn quantile(values: &mut [f64], q: f64) -> f64 {
    if values.is_empty() {
        return f64::NAN;
    }
    values.sort_by(f64::total_cmp);
    let pos = q * (values.len() - 1) as f64;
    let (lo, hi) = (pos.floor() as usize, pos.ceil() as usize);
    values[lo] + (values[hi] - values[lo]) * (pos - lo as f64)
}

fn summary_json(arm: &str, corpus: &str, t: &Tally) -> String {
    let mut rel: Vec<f64> = t.errs.iter().map(|e| e.rel_l2).collect();
    let max_abs = t.errs.iter().map(|e| e.max_abs).fold(f64::NAN, f64::max);
    let min_cos = t.errs.iter().map(|e| e.min_cos).fold(f64::NAN, f64::min);
    let mut el = t.elapsed_us.clone();
    let total_us: f64 = t.elapsed_us.iter().sum();
    format!(
        "{{\"arm\":{},\"corpus\":{},\"rows\":{},\"audio_s\":{},\"max_abs_max\":{},\"rel_l2_median\":{},\
         \"rel_l2_p95\":{},\"rel_l2_max\":{},\"min_cos_min\":{},\"timed_samples\":{},\"elapsed_us_median\":{},\
         \"us_per_audio_s\":{}}}",
        quote(arm),
        quote(corpus),
        t.rows,
        num(t.audio_s),
        num(max_abs),
        num(quantile(&mut rel.clone(), 0.5)),
        num(quantile(&mut rel.clone(), 0.95)),
        num(rel.iter_mut().fold(f64::NAN, |a, b| a.max(*b))),
        num(min_cos),
        t.elapsed_us.len(),
        num(median(&mut el)),
        num(if t.timed_audio_s > 0.0 {
            total_us / t.timed_audio_s
        } else {
            f64::NAN
        }),
    )
}

fn print_summary(arm: &str, corpus: &str, t: &Tally) {
    let mut rel: Vec<f64> = t.errs.iter().map(|e| e.rel_l2).collect();
    let max_abs = t.errs.iter().map(|e| e.max_abs).fold(f64::NAN, f64::max);
    let min_cos = t.errs.iter().map(|e| e.min_cos).fold(f64::NAN, f64::min);
    let rel_max = rel.iter().copied().fold(f64::NAN, f64::max);
    let mut el = t.elapsed_us.clone();
    let total_us: f64 = t.elapsed_us.iter().sum();
    eprintln!(
        "{arm:>12} {corpus:<15} rows {:>4}  max_abs {:>9.3e}  rel_l2 med {:>9.3e} p95 {:>9.3e} max {:>9.3e}  \
         min_cos {:.6}  | timed {:>4}  med {:>9.0} us  {:>7.0} us/audio-s",
        t.rows,
        max_abs,
        quantile(&mut rel.clone(), 0.5),
        quantile(&mut rel, 0.95),
        rel_max,
        min_cos,
        t.elapsed_us.len(),
        median(&mut el),
        if t.timed_audio_s > 0.0 {
            total_us / t.timed_audio_s
        } else {
            f64::NAN
        },
    );
}

struct Loaded {
    precision: Precision,
    encoder: Encoder,
}

fn load(args: &Args, precisions: &[Precision]) -> Result<Vec<Loaded>, String> {
    precisions
        .iter()
        .map(|&precision| {
            let t0 = Instant::now();
            let encoder = Encoder::open(
                &args.model,
                Arm {
                    precision,
                    fused: false,
                },
            )
            .map_err(|e| e.to_string())?;
            eprintln!(
                "loaded {precision:?} in {:.1} s",
                t0.elapsed().as_secs_f64()
            );
            Ok(Loaded { precision, encoder })
        })
        .collect()
}

fn encoder_for<'a>(loaded: &'a [Loaded], arm: &Arm) -> &'a Encoder {
    &loaded
        .iter()
        .find(|l| l.precision == arm.precision)
        .expect("precision loaded")
        .encoder
}

fn rows_of(args: &Args, corpus: &Corpus) -> usize {
    args.limit
        .map_or(corpus.rows.len(), |l| l.min(corpus.rows.len()))
}

fn run_profile(args: &Args, corpora: &[Corpus]) -> Result<(), String> {
    let mut precisions: Vec<Precision> = Vec::new();
    for arm in &args.arms {
        if !precisions.contains(&arm.precision) {
            precisions.push(arm.precision);
        }
    }
    let n_rows = args.profile_ops.unwrap_or(1);
    for precision in precisions {
        let loaded = load(args, &[precision])?;
        for arm in args.arms.iter().filter(|a| a.precision == precision) {
            let encoder = encoder_for(&loaded, arm);
            for corpus in corpora {
                let rows: Vec<_> = corpus.rows.iter().take(n_rows).collect();
                let mut out = Vec::new();
                // Warm the pipelines and the buffer pool outside the profile.
                for row in &rows {
                    let mel = corpus.mel(row)?;
                    out.resize(row.n_enc_frames * row.n_state, 0.0);
                    encoder
                        .encode_with(&mel, row.n_mel_frames, &mut out, arm.fused)
                        .map_err(|e| e.to_string())?;
                }
                encoder.set_profiling(true);
                let (mut audio, mut wall) = (0.0, 0.0);
                for row in &rows {
                    let mel = corpus.mel(row)?;
                    out.resize(row.n_enc_frames * row.n_state, 0.0);
                    encoder.profile_start();
                    let t0 = Instant::now();
                    encoder
                        .encode_with(&mel, row.n_mel_frames, &mut out, arm.fused)
                        .map_err(|e| e.to_string())?;
                    wall += t0.elapsed().as_secs_f64();
                    audio += row.audio_s;
                }
                let mut stages = encoder.profile_stages();
                encoder.set_profiling(false);
                let total: f64 = stages.iter().map(|s| s.1).sum();
                stages.sort_by(|a, b| b.1.total_cmp(&a.1));
                eprintln!(
                    "\nprofile {} on {} ({} rows, {:.1} s audio): serialized wall {:.1} ms, staged {:.1} ms",
                    arm.name(),
                    corpus.name,
                    rows.len(),
                    audio,
                    wall * 1e3,
                    total * 1e3
                );
                for (label, secs, count) in &stages {
                    eprintln!(
                        "  {label:<28} {:>9.2} ms  {:>5.1}%  {:>6} calls  {:>8.1} us/call",
                        secs * 1e3,
                        100.0 * secs / total,
                        count,
                        1e6 * secs / *count as f64
                    );
                }
            }
        }
    }
    Ok(())
}

fn run(args: &Args) -> Result<(), String> {
    let mut corpora = Vec::new();
    for dir in &args.dumps {
        corpora.extend(Corpus::discover(dir)?);
    }
    if args.profile_ops.is_some() {
        return run_profile(args, &corpora);
    }
    let output = args.output.as_ref().expect("checked in parse_args");
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let mut out =
        BufWriter::new(File::create(output).map_err(|e| format!("{}: {e}", output.display()))?);

    let mut precisions: Vec<Precision> = Vec::new();
    for arm in &args.arms {
        if !precisions.contains(&arm.precision) {
            precisions.push(arm.precision);
        }
    }
    // Timing runs interleave every arm, so every precision stays loaded. The numerics run
    // (--passes 0) loads one precision at a time to bound memory.
    let groups: Vec<Vec<Precision>> = if args.passes == 0 {
        precisions.iter().map(|p| vec![*p]).collect()
    } else {
        vec![precisions.clone()]
    };

    let started_at = now_iso8601();
    let git = git_sha();
    let host = host_json();
    let mut tallies: BTreeMap<(String, String), Tally> = BTreeMap::new();
    let mut seq = 0usize;
    let mut states = Vec::new();

    for group in groups {
        let loaded = load(args, &group)?;
        let arms: Vec<Arm> = args
            .arms
            .iter()
            .copied()
            .filter(|a| group.contains(&a.precision))
            .collect();
        let arm_names: Vec<String> = arms
            .iter()
            .map(|a| format!("candle:{}", a.name()))
            .collect();
        for corpus in &corpora {
            let n_rows = rows_of(args, corpus);
            writeln!(
                out,
                "{{\"type\":\"run_meta\",\"bet\":\"B4\",\"harness\":\"rust:encoder-bench\",\"git_sha\":{},\
                 \"started_at\":{},\"host\":{},\"arms\":[{}],\"passes\":{},\"order\":{},\"corpus\":{},\"notes\":{}}}",
                git.as_deref().map_or("null".to_owned(), quote),
                quote(&started_at),
                host,
                arm_names.iter().map(|a| quote(a)).collect::<Vec<_>>().join(","),
                args.passes,
                quote(&format!(
                    "per-pass seeded row permutation (seed {}); arms alternate forward/reverse per row; pass 0 warmup",
                    args.seed
                )),
                quote(&corpus.name),
                quote(&format!(
                    "candle 0.11.0 metal encoder (bench/rust/encoder-candle); {n_rows} of {} rows; err vs the dump's \
                     native Metal encoder states; elapsed_us = Encoder::encode (host mel in, host states out)",
                    corpus.rows.len()
                )),
            )
            .map_err(|e| e.to_string())?;

            if let Some(dir) = &args.write_states {
                for arm in &arms {
                    let dst = dir.join(arm.name()).join(&corpus.name);
                    fs::create_dir_all(&dst).map_err(|e| format!("{}: {e}", dst.display()))?;
                    fs::copy(corpus.dir.join("index.jsonl"), dst.join("index.jsonl"))
                        .map_err(|e| format!("{}: {e}", dst.display()))?;
                }
            }

            for pass in 0..=args.passes {
                let order = pass_order(n_rows, pass, args.seed);
                for (position, &index) in order.iter().enumerate() {
                    let row = &corpus.rows[index];
                    let mel = corpus.mel(row)?;
                    let reference = corpus.enc(row)?;
                    let forward = position % 2 == 0;
                    for k in 0..arms.len() {
                        let arm = arms[if forward { k } else { arms.len() - 1 - k }];
                        let encoder = encoder_for(&loaded, &arm);
                        states.clear();
                        states.resize(row.n_enc_frames * row.n_state, 0.0f32);
                        let t0 = Instant::now();
                        let n_enc = encoder
                            .encode_with(&mel, row.n_mel_frames, &mut states, arm.fused)
                            .map_err(|e| format!("{} {}: {e}", arm.name(), row.id))?;
                        let elapsed_us = t0.elapsed().as_secs_f64() * 1e6;
                        if n_enc != row.n_enc_frames {
                            return Err(format!(
                                "{}: {n_enc} frames, dump has {}",
                                row.id, row.n_enc_frames
                            ));
                        }
                        let agreement = compare(&states, &reference, row.n_state);
                        let bytes = f32_bytes(&states);
                        let sha = parakeet_model::pin::sha256_hex(&bytes);
                        writeln!(
                            out,
                            "{{\"type\":\"timing\",\"bet\":\"B4\",\"arm\":{},\"row_id\":{},\"pass\":{pass},\"seq\":{seq},\
                             \"elapsed_us\":{},\"output_sha256\":{},\"equal_ref\":null,\"audio_s\":{},\"work\":\
                             {{\"n_mel_frames\":{},\"n_enc_frames\":{},\"corpus\":{}}},\"err\":{{\"max_abs\":{},\
                             \"rel_l2\":{},\"min_cos\":{}}}}}",
                            quote(&format!("candle:{}", arm.name())),
                            quote(&row.id),
                            num(elapsed_us),
                            quote(&sha),
                            num(row.audio_s),
                            row.n_mel_frames,
                            n_enc,
                            quote(&corpus.name),
                            num(agreement.max_abs),
                            num(agreement.rel_l2),
                            num(agreement.min_cos),
                        )
                        .map_err(|e| e.to_string())?;
                        seq += 1;
                        let tally = tallies
                            .entry((arm.name(), corpus.name.clone()))
                            .or_default();
                        if pass == 0 {
                            tally.rows += 1;
                            tally.audio_s += row.audio_s;
                            tally.errs.push(agreement);
                            if let Some(dir) = &args.write_states {
                                let path =
                                    dir.join(arm.name()).join(&corpus.name).join(&row.enc_file);
                                fs::write(&path, &bytes)
                                    .map_err(|e| format!("{}: {e}", path.display()))?;
                            }
                        } else {
                            tally.elapsed_us.push(elapsed_us);
                            tally.timed_audio_s += row.audio_s;
                        }
                    }
                }
                out.flush().map_err(|e| e.to_string())?;
            }
            for arm in &arms {
                if let Some(t) = tallies.get(&(arm.name(), corpus.name.clone())) {
                    print_summary(&arm.name(), &corpus.name, t);
                }
            }
        }
    }
    out.flush().map_err(|e| e.to_string())?;

    let summary_path = output.with_extension("summary.json");
    let lines: Vec<String> = tallies
        .iter()
        .map(|((arm, corpus), t)| summary_json(arm, corpus, t))
        .collect();
    fs::write(&summary_path, format!("[\n{}\n]\n", lines.join(",\n")))
        .map_err(|e| format!("{}: {e}", summary_path.display()))?;
    eprintln!("wrote {} and {}", output.display(), summary_path.display());
    Ok(())
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}
