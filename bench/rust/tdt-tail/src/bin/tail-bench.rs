//! `tail-bench`: replays dumped encoder states through the Rust TDT tail arms.
//!
//! ```text
//! tail-bench --dumps <dir> [--arms a,b,c] [--passes N] [--output rows.jsonl]
//!            [--equivalence report.json] [--profile N] [--model <path>] [--limit N] [--corpus name]
//! ```
//!
//! `<dir>` is one corpus directory (`index.jsonl` + `<n>.enc.f32`) or a directory of them.
//! `--output` writes contract timing rows (bet B1, arms `rust:<arm>`): every pass visits every row,
//! and on each row the arms run back to back in an order that rotates by `(pass + row) mod arms`;
//! `elapsed_us` is the wall time of one decode call (encoder projection included, file reading
//! excluded). Pass 0 is warmup. `--equivalence` runs every arm once per row, untimed, and reports
//! identity against `ref` (Metal tail) and `ref_cpu` (CPU tail), the first divergent step of every
//! mismatch with its raw-logit margins, p/plog error, and bit-identity against `rawargmax`.

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};
use tdt_tail::{ARMS, Engine, StepTrace, Token, Work, canonical, canonical_tokens};

const USAGE: &str = "usage: tail-bench --dumps <dir> [--arms a,b,c] [--passes N] [--output rows.jsonl] \
[--equivalence report.json] [--profile N] [--model <path>] [--limit N] [--corpus name]";

#[derive(Deserialize, Clone)]
struct RefToken {
    id: i32,
    frame_index: i32,
    duration: i32,
    p: f32,
    plog: f32,
}

#[derive(Deserialize, Clone)]
struct RefTail {
    tokens: Vec<RefToken>,
    tokens_sha256: String,
}

impl RefTail {
    fn canonical(&self) -> String {
        canonical_tokens(
            self.tokens
                .iter()
                .map(|t| (t.id, t.frame_index, t.duration)),
        )
    }
}

#[derive(Deserialize, Clone)]
struct Row {
    id: String,
    audio_s: Option<f64>,
    n_enc_frames: usize,
    n_state: usize,
    enc_file: String,
    #[serde(rename = "ref")]
    reference: RefTail,
    ref_cpu: Option<RefTail>,
}

struct Corpus {
    name: String,
    dir: PathBuf,
    rows: Vec<Row>,
}

struct Args {
    dumps: PathBuf,
    arms: Vec<String>,
    passes: usize,
    output: Option<PathBuf>,
    equivalence: Option<PathBuf>,
    model: PathBuf,
    limit: Option<usize>,
    corpora: Vec<String>,
    profile: Option<usize>,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        dumps: PathBuf::new(),
        arms: ARMS.split(',').map(str::to_owned).collect(),
        passes: 2,
        output: None,
        equivalence: None,
        model: parakeet_model::pin::default_model_path(),
        limit: None,
        corpora: Vec::new(),
        profile: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        let mut value = |name: &str| it.next().ok_or_else(|| format!("{name} needs a value"));
        match a.as_str() {
            "--dumps" => args.dumps = value("--dumps")?.into(),
            "--arms" => {
                args.arms = value("--arms")?
                    .split(',')
                    .map(|s| s.trim().to_owned())
                    .filter(|s| !s.is_empty())
                    .collect()
            }
            "--passes" => {
                args.passes = value("--passes")?
                    .parse()
                    .map_err(|_| "--passes needs a number")?
            }
            "--output" => args.output = Some(value("--output")?.into()),
            "--equivalence" => args.equivalence = Some(value("--equivalence")?.into()),
            "--model" => args.model = value("--model")?.into(),
            "--limit" => {
                args.limit = Some(
                    value("--limit")?
                        .parse()
                        .map_err(|_| "--limit needs a number")?,
                )
            }
            "--corpus" => args.corpora.push(value("--corpus")?),
            "--profile" => {
                args.profile = Some(
                    value("--profile")?
                        .parse()
                        .map_err(|_| "--profile needs a number")?,
                )
            }
            "-h" | "--help" => return Err(USAGE.into()),
            other => return Err(format!("unknown argument '{other}'\n{USAGE}")),
        }
    }
    if args.dumps.as_os_str().is_empty() {
        return Err(USAGE.into());
    }
    if args.output.is_none() && args.equivalence.is_none() && args.profile.is_none() {
        return Err(format!(
            "nothing to do: give --output, --equivalence and/or --profile\n{USAGE}"
        ));
    }
    if args.arms.is_empty() {
        return Err("--arms is empty".into());
    }
    Ok(args)
}

fn load_corpora(args: &Args) -> Result<Vec<Corpus>, String> {
    let dirs: Vec<PathBuf> = if args.dumps.join("index.jsonl").is_file() {
        vec![args.dumps.clone()]
    } else {
        let mut v: Vec<PathBuf> = fs::read_dir(&args.dumps)
            .map_err(|e| format!("{}: {e}", args.dumps.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.join("index.jsonl").is_file())
            .collect();
        v.sort();
        v
    };
    let mut out = Vec::new();
    for dir in dirs {
        let name = dir
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if !args.corpora.is_empty() && !args.corpora.contains(&name) {
            continue;
        }
        let index = dir.join("index.jsonl");
        let text = fs::read_to_string(&index).map_err(|e| format!("{}: {e}", index.display()))?;
        let mut rows = Vec::new();
        for (n, line) in text
            .lines()
            .enumerate()
            .filter(|(_, l)| !l.trim().is_empty())
        {
            let row: Row = serde_json::from_str(line)
                .map_err(|e| format!("{}:{}: {e}", index.display(), n + 1))?;
            for (label, tail) in [
                ("ref", Some(&row.reference)),
                ("ref_cpu", row.ref_cpu.as_ref()),
            ] {
                if let Some(tail) = tail {
                    let digest = parakeet_model::pin::sha256_hex(tail.canonical().as_bytes());
                    if digest != tail.tokens_sha256 {
                        return Err(format!(
                            "{}: row {}: {label}.tokens_sha256 does not match its tokens",
                            index.display(),
                            row.id
                        ));
                    }
                }
            }
            rows.push(row);
        }
        if let Some(limit) = args.limit {
            rows.truncate(limit);
        }
        if rows.is_empty() {
            return Err(format!("{}: no rows", index.display()));
        }
        out.push(Corpus { name, dir, rows });
    }
    if out.is_empty() {
        return Err(format!(
            "{}: no corpus (index.jsonl) found",
            args.dumps.display()
        ));
    }
    Ok(out)
}

fn load_enc(dir: &Path, row: &Row) -> Result<Vec<f32>, String> {
    let path = dir.join(&row.enc_file);
    let bytes = fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let want = row.n_enc_frames * row.n_state * 4;
    if bytes.len() != want {
        return Err(format!(
            "{}: {} bytes, expected {want}",
            path.display(),
            bytes.len()
        ));
    }
    Ok(bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect())
}

fn sysctl_string(name: &str) -> Option<String> {
    let out = std::process::Command::new("/usr/sbin/sysctl")
        .args(["-n", name])
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn command_line(cmd: &str, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new(cmd).args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn utc_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs()) as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Civil-from-days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

fn host() -> Value {
    let mut load = [0f64; 3];
    unsafe extern "C" {
        fn getloadavg(loadavg: *mut f64, nelem: std::ffi::c_int) -> std::ffi::c_int;
    }
    unsafe { getloadavg(load.as_mut_ptr(), 3) };
    let num = |n: &str| sysctl_string(n).and_then(|s| s.parse::<u64>().ok());
    let power = command_line("/usr/bin/pmset", &["-g", "batt"]).and_then(|s| {
        s.lines()
            .next()
            .and_then(|l| l.split('\'').nth(1).map(str::to_owned))
    });
    json!({
        "chip": sysctl_string("machdep.cpu.brand_string"),
        "os": command_line("/usr/bin/sw_vers", &["-productVersion"]),
        "os_build": command_line("/usr/bin/sw_vers", &["-buildVersion"]),
        "power": power,
        "load_avg": load,
        "cpu_threads": num("hw.logicalcpu"),
        "perf_cores": num("hw.perflevel0.physicalcpu"),
        "eff_cores": num("hw.perflevel1.physicalcpu"),
        "memory_bytes": num("hw.memsize"),
    })
}

fn open_engines(args: &Args, arms: &[String]) -> Result<Vec<Engine>, String> {
    arms.iter()
        .map(|arm| Engine::new(&args.model, arm).map_err(|e| format!("arm {arm}: {e}")))
        .collect()
}

/// `(max_abs, rel_l2)` of `ours - theirs` (rel_l2 against `theirs`).
fn err_stats(pairs: impl Iterator<Item = (f32, f32)>) -> (f64, f64) {
    let (mut max_abs, mut num, mut den) = (0.0f64, 0.0f64, 0.0f64);
    for (a, b) in pairs {
        let d = a as f64 - b as f64;
        max_abs = max_abs.max(d.abs());
        num += d * d;
        den += (b as f64) * (b as f64);
    }
    (
        max_abs,
        if den > 0.0 {
            (num / den).sqrt()
        } else {
            num.sqrt()
        },
    )
}

// ----- timing ----------------------------------------------------------------------------------

fn run_timing(args: &Args, corpora: &[Corpus], path: &Path) -> Result<(), String> {
    let mut engines = open_engines(args, &args.arms)?;
    let file = fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut w = BufWriter::new(file);
    let git_sha = command_line("git", &["rev-parse", "HEAD"]);
    let n_arms = engines.len();
    let mut seq = 0u64;
    let mut tokens = Vec::new();
    // arm -> (elapsed sum, steps, rows) over timed passes, per corpus
    let mut summary: BTreeMap<(String, String), (f64, usize, usize, usize)> = BTreeMap::new();
    for corpus in corpora {
        let meta = json!({
            "type": "run_meta",
            "bet": "B1",
            "harness": "tail-bench (in-process Rust, bench/rust/tdt-tail)",
            "git_sha": git_sha,
            "started_at": utc_now(),
            "host": host(),
            "arms": args.arms.iter().map(|a| format!("rust:{a}")).collect::<Vec<_>>(),
            "passes": args.passes,
            "order": "per row, arms back to back; order rotates by (pass + row index) mod n_arms",
            "corpus": corpus.name,
            "rows": corpus.rows.len(),
            "model": args.model.display().to_string(),
            "configs": engines.iter().map(|e| json!({"arm": e.name(), "config": format!("{:?}", e.config())})).collect::<Vec<_>>(),
            "notes": "elapsed_us = wall time of one vt_decode-equivalent call (Engine::decode): encoder projection included, file read excluded. err = plog vs ref (token strings equal only); err_p = p vs ref.",
        });
        writeln!(w, "{meta}").map_err(|e| e.to_string())?;
        for pass in 0..args.passes {
            for (ri, row) in corpus.rows.iter().enumerate() {
                let enc = load_enc(&corpus.dir, row)?;
                let ref_canon = row.reference.canonical();
                for o in 0..n_arms {
                    let ai = (o + pass + ri) % n_arms;
                    let engine = &mut engines[ai];
                    let start = Instant::now();
                    let work =
                        engine.decode(&enc, row.n_enc_frames, row.n_state, &mut tokens, None);
                    let elapsed = start.elapsed().as_secs_f64() * 1e6;
                    let work =
                        work.map_err(|e| format!("arm {} row {}: {e}", args.arms[ai], row.id))?;
                    let canon = canonical(&tokens);
                    let equal = canon == ref_canon;
                    let (err, err_p) = if equal {
                        let plog = err_stats(
                            tokens
                                .iter()
                                .zip(&row.reference.tokens)
                                .map(|(a, b)| (a.plog, b.plog)),
                        );
                        let p = err_stats(
                            tokens
                                .iter()
                                .zip(&row.reference.tokens)
                                .map(|(a, b)| (a.p, b.p)),
                        );
                        (
                            json!({"max_abs": plog.0, "rel_l2": plog.1}),
                            json!({"max_abs": p.0, "rel_l2": p.1}),
                        )
                    } else {
                        (Value::Null, Value::Null)
                    };
                    let rec = json!({
                        "type": "timing",
                        "bet": "B1",
                        "arm": format!("rust:{}", args.arms[ai]),
                        "corpus": corpus.name,
                        "row_id": row.id,
                        "pass": pass,
                        "seq": seq,
                        "elapsed_us": elapsed,
                        "output_sha256": parakeet_model::pin::sha256_hex(canon.as_bytes()),
                        "equal_ref": equal,
                        "equal_ref_cpu": row.ref_cpu.as_ref().map(|r| r.canonical() == canon),
                        "audio_s": row.audio_s,
                        "work": work_json(&work),
                        "err": err,
                        "err_p": err_p,
                    });
                    seq += 1;
                    writeln!(w, "{rec}").map_err(|e| e.to_string())?;
                    if pass > 0 || args.passes == 1 {
                        let e = summary
                            .entry((corpus.name.clone(), args.arms[ai].clone()))
                            .or_default();
                        e.0 += elapsed;
                        e.1 += work.n_steps;
                        e.2 += 1;
                        e.3 += usize::from(equal);
                    }
                }
            }
        }
    }
    w.flush().map_err(|e| e.to_string())?;
    eprintln!("\n| corpus | arm | rows×passes | mean µs/row | µs/step | =ref |");
    eprintln!("|---|---|---:|---:|---:|---:|");
    for ((corpus, arm), (sum, steps, n, eq)) in &summary {
        eprintln!(
            "| {corpus} | {arm} | {n} | {:.1} | {:.2} | {eq}/{n} |",
            sum / *n as f64,
            sum / (*steps).max(1) as f64
        );
    }
    eprintln!("wrote {} timing rows to {}", seq, path.display());
    Ok(())
}

fn work_json(w: &Work) -> Value {
    json!({"n_frames": w.n_frames, "n_tokens": w.n_tokens, "n_steps": w.n_steps, "n_pred": w.n_pred, "n_cols": w.n_cols})
}

// ----- equivalence -----------------------------------------------------------------------------

/// The first greedy step at which our trace stops being consistent with `reference`'s tokens
/// (blank steps are not recorded in the reference, so a blank is consistent unless it skips a
/// frame the reference emitted on). Returns `(step, kind, reference token at that point)`.
fn first_divergence(
    trace: &[StepTrace],
    durations: &[i32],
    blank: usize,
    reference: &[RefToken],
) -> Option<(usize, &'static str, Option<RefToken>)> {
    let mut k = 0;
    for (s, st) in trace.iter().enumerate() {
        let next = reference.get(k).cloned();
        let t = st.t as i32;
        if st.token != blank {
            let dur = durations[st.dur_idx];
            match &next {
                Some(r) if r.id == st.token as i32 && r.frame_index == t && r.duration == dur => {
                    k += 1
                }
                Some(r) if r.frame_index == t && r.id == st.token as i32 => {
                    return Some((s, "duration", next));
                }
                Some(r) if r.frame_index == t => return Some((s, "token", next)),
                _ => return Some((s, "token-vs-blank", next)),
            }
        } else {
            let advance = durations[st.dur_idx].max(1);
            if let Some(r) = &next {
                if r.frame_index == t {
                    return Some((s, "blank-vs-token", next));
                }
                if r.frame_index < t + advance {
                    return Some((s, "blank-duration", next));
                }
            }
        }
    }
    (k < reference.len()).then(|| (trace.len(), "missing-tail", reference.get(k).cloned()))
}

#[derive(Default)]
struct ArmStats {
    rows: usize,
    equal_ref: usize,
    equal_ref_cpu: usize,
    exact_rawargmax: usize,
    plog_max_abs: f64,
    p_max_abs: f64,
    steps: usize,
    tokens: usize,
    preds: usize,
    cols: usize,
    mismatches: Vec<Value>,
    cpu_mismatches: Vec<Value>,
    not_exact_ids: Vec<String>,
}

fn bits_equal(a: &[Token], b: &[Token]) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(x, y)| {
            x.id == y.id
                && x.frame_index == y.frame_index
                && x.duration_idx == y.duration_idx
                && x.duration == y.duration
                && x.p.to_bits() == y.p.to_bits()
                && x.plog.to_bits() == y.plog.to_bits()
        })
}

fn run_equivalence(args: &Args, corpora: &[Corpus], path: &Path) -> Result<(), String> {
    let mut arms = args.arms.clone();
    if !arms.iter().any(|a| a == "rawargmax") {
        arms.push("rawargmax".into());
    }
    let mut engines = open_engines(args, &arms)?;
    let raw_index = arms
        .iter()
        .position(|a| a == "rawargmax")
        .expect("rawargmax present");
    let (durations, blank) = {
        let d = &engines[0].weights().dims;
        (d.durations.clone(), d.blank)
    };
    let mut report = Vec::new();
    let mut md = String::from(
        "| corpus | arm | rows | =ref | =ref_cpu | ≡rawargmax | plog max|Δ| vs ref | p max|Δ| vs ref | steps | tokens | preds | cols |\n|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n",
    );
    for corpus in corpora {
        let mut stats: Vec<ArmStats> = arms.iter().map(|_| ArmStats::default()).collect();
        let mut ref_cpu_disagree = Vec::new();
        for row in &corpus.rows {
            let enc = load_enc(&corpus.dir, row)?;
            let ref_canon = row.reference.canonical();
            let cpu_canon = row.ref_cpu.as_ref().map(RefTail::canonical);
            let refs_disagree = cpu_canon.as_ref().is_some_and(|c| *c != ref_canon);
            if refs_disagree {
                ref_cpu_disagree.push(row.id.clone());
            }
            let mut outputs: Vec<(Vec<Token>, Vec<StepTrace>)> = Vec::with_capacity(arms.len());
            for engine in engines.iter_mut() {
                let mut tokens = Vec::new();
                let mut trace = Vec::new();
                engine
                    .decode(
                        &enc,
                        row.n_enc_frames,
                        row.n_state,
                        &mut tokens,
                        Some(&mut trace),
                    )
                    .map_err(|e| format!("arm {} row {}: {e}", engine.name(), row.id))?;
                // The traced call must not differ from an untraced one.
                let mut again = Vec::new();
                let work = engine
                    .decode(&enc, row.n_enc_frames, row.n_state, &mut again, None)
                    .map_err(|e| e.to_string())?;
                if !bits_equal(&tokens, &again) {
                    return Err(format!(
                        "arm {} row {}: traced and untraced decodes differ",
                        engine.name(),
                        row.id
                    ));
                }
                let st = &mut stats[outputs.len()];
                st.steps += work.n_steps;
                st.tokens += work.n_tokens;
                st.preds += work.n_pred;
                st.cols += work.n_cols;
                outputs.push((tokens, trace));
            }
            for (ai, (tokens, trace)) in outputs.iter().enumerate() {
                let st = &mut stats[ai];
                st.rows += 1;
                let canon = canonical(tokens);
                if bits_equal(tokens, &outputs[raw_index].0) {
                    st.exact_rawargmax += 1;
                } else {
                    st.not_exact_ids.push(row.id.clone());
                }
                let diverge = |reference: &[RefToken]| -> Value {
                    match first_divergence(trace, &durations, blank, reference) {
                        Some((step, kind, next)) => {
                            let s = trace.get(step);
                            json!({
                                "row_id": row.id,
                                "step": step,
                                "kind": kind,
                                "t": s.map(|s| s.t),
                                "ours": s.map(|s| json!({"token": s.token, "dur_idx": s.dur_idx})),
                                "ref_next": next.map(|r| json!({"id": r.id, "frame_index": r.frame_index, "duration": r.duration})),
                                "tok_margin": s.map(|s| s.tok_margin),
                                "dur_margin": s.map(|s| s.dur_margin),
                                "ref_vs_ref_cpu_disagree": refs_disagree,
                                "n_tokens": tokens.len(),
                                "n_ref_tokens": reference.len(),
                            })
                        }
                        None => {
                            json!({"row_id": row.id, "kind": "undetermined", "ref_vs_ref_cpu_disagree": refs_disagree})
                        }
                    }
                };
                if cpu_canon.as_ref() == Some(&canon) {
                    st.equal_ref_cpu += 1;
                } else if let Some(cpu) = &row.ref_cpu {
                    st.cpu_mismatches.push(diverge(&cpu.tokens));
                }
                if canon == ref_canon {
                    st.equal_ref += 1;
                    for (a, b) in tokens.iter().zip(&row.reference.tokens) {
                        st.plog_max_abs =
                            st.plog_max_abs.max((a.plog as f64 - b.plog as f64).abs());
                        st.p_max_abs = st.p_max_abs.max((a.p as f64 - b.p as f64).abs());
                    }
                } else {
                    st.mismatches.push(diverge(&row.reference.tokens));
                }
            }
        }
        for (ai, st) in stats.iter().enumerate() {
            md.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} | {:.3e} | {:.3e} | {} | {} | {} | {} |\n",
                corpus.name,
                arms[ai],
                st.rows,
                st.equal_ref,
                st.equal_ref_cpu,
                st.exact_rawargmax,
                st.plog_max_abs,
                st.p_max_abs,
                st.steps,
                st.tokens,
                st.preds,
                st.cols
            ));
            report.push(json!({
                "corpus": corpus.name,
                "arm": arms[ai],
                "config": format!("{:?}", engines[ai].config()),
                "rows": st.rows,
                "equal_ref": st.equal_ref,
                "equal_ref_cpu": st.equal_ref_cpu,
                "identity_rate_ref": st.equal_ref as f64 / st.rows as f64,
                "identity_rate_ref_cpu": st.equal_ref_cpu as f64 / st.rows as f64,
                "bit_identical_to_rawargmax": st.exact_rawargmax,
                "not_bit_identical_rows": st.not_exact_ids,
                "plog_max_abs_vs_ref": st.plog_max_abs,
                "p_max_abs_vs_ref": st.p_max_abs,
                "mismatches_vs_ref": st.mismatches,
                "mismatches_vs_ref_cpu": st.cpu_mismatches,
                "ref_vs_ref_cpu_disagree_rows": ref_cpu_disagree,
                "work": {"n_steps": st.steps, "n_tokens": st.tokens, "n_pred": st.preds, "n_cols": st.cols},
            }));
        }
        eprintln!(
            "equivalence: {} done ({} rows)",
            corpus.name,
            corpus.rows.len()
        );
    }
    let doc = json!({"bet": "B1", "model": args.model.display().to_string(), "generated_at": utc_now(), "results": report});
    fs::write(
        path,
        serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())? + "\n",
    )
    .map_err(|e| format!("{}: {e}", path.display()))?;
    println!("{md}");
    for r in &report {
        for key in ["mismatches_vs_ref", "mismatches_vs_ref_cpu"] {
            for m in r[key].as_array().into_iter().flatten() {
                println!(
                    "{key} {} {}: {}",
                    r["corpus"].as_str().unwrap_or(""),
                    r["arm"].as_str().unwrap_or(""),
                    m
                );
            }
        }
    }
    eprintln!("wrote {}", path.display());
    Ok(())
}

// ----- profile ---------------------------------------------------------------------------------

/// Phase breakdown per Rust arm (untimed diagnostics; `c-best` is not instrumented): every row
/// once as warmup, then `reps` profiled decodes per row, arms interleaved per row.
fn run_profile(args: &Args, corpora: &[Corpus], reps: usize) -> Result<(), String> {
    let arms: Vec<String> = args
        .arms
        .iter()
        .filter(|a| !a.starts_with("c-best"))
        .cloned()
        .collect();
    let mut engines = open_engines(args, &arms)?;
    let mut tokens = Vec::new();
    println!(
        "| corpus | arm | µs/step | setup | predict | joint | serial | probs | µs/prediction | µs/joint column |"
    );
    println!("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|");
    for corpus in corpora {
        for e in engines.iter_mut() {
            e.set_profiling(false);
        }
        for pass in 0..=reps {
            for row in &corpus.rows {
                let enc = load_enc(&corpus.dir, row)?;
                for e in engines.iter_mut() {
                    e.decode(&enc, row.n_enc_frames, row.n_state, &mut tokens, None)?;
                }
            }
            if pass == 0 {
                for e in engines.iter_mut() {
                    e.set_profiling(true);
                }
            }
        }
        for e in &engines {
            let p = e.profile().expect("profiling on");
            let steps = p.work.n_steps.max(1) as f64;
            let total = p.setup_us + p.predict_us + p.joint_us + p.serial_us + p.probs_us;
            println!(
                "| {} | {} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} |",
                corpus.name,
                e.name(),
                total / steps,
                p.setup_us / steps,
                p.predict_us / steps,
                p.joint_us / steps,
                p.serial_us / steps,
                p.probs_us / steps,
                p.predict_us / p.work.n_pred.max(1) as f64,
                p.joint_us / p.work.n_cols.max(1) as f64,
            );
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    let result = load_corpora(&args).and_then(|corpora| {
        if let Some(path) = &args.equivalence {
            run_equivalence(&args, &corpora, path)?;
        }
        if let Some(reps) = args.profile {
            run_profile(&args, &corpora, reps)?;
        }
        if let Some(path) = &args.output {
            run_timing(&args, &corpora, path)?;
        }
        Ok(())
    });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tail-bench: {e}");
            ExitCode::FAILURE
        }
    }
}
