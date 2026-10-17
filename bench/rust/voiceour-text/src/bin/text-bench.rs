//! `text-bench`: parity, timing and input generation for bet B3 (Rust side).
//!
//! ```text
//! text-bench gen-inputs [--out DIR] [--fuzz-per-glossary N] [--seed S]
//! text-bench parity  --cases F --glossary G --out O
//! text-bench compare A.jsonl B.jsonl [--max-diffs N]
//! text-bench bench   --stage text|compile|engine|ordinary --cases F --glossary G --out O
//!                    [--passes N] [--arms rust,rust@aa] [--seed S] [--ref PARITY] [--corpus NAME]
//! text-bench oracle-gen   --out F [--count N] [--seed S]
//! text-bench oracle-check --in F --swift G [--max-examples N]
//! ```

use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde_json::{Value, json};
use voiceour_text::bench::{self, Case, GlossaryFile, TimingRow};
use voiceour_text::repair::RepairVocabulary;
use voiceour_text::{OrdinaryWords, Pipeline, inputs, oracle, vocabulary};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .expect("repo root")
}

fn ordinary_words_path() -> PathBuf {
    repo_root().join("Sources/VoiceCore/Resources/ordinary-words.txt")
}

fn load_ordinary_words() -> OrdinaryWords {
    let path = ordinary_words_path();
    let contents = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    OrdinaryWords::parse(&contents)
}

struct Args {
    positional: Vec<String>,
    options: HashMap<String, String>,
}

impl Args {
    fn parse(raw: &[String]) -> Self {
        let mut positional = Vec::new();
        let mut options = HashMap::new();
        let mut index = 0;
        while index < raw.len() {
            if let Some(key) = raw[index].strip_prefix("--") {
                let value = raw.get(index + 1).cloned().unwrap_or_default();
                options.insert(key.to_owned(), value);
                index += 2;
            } else {
                positional.push(raw[index].clone());
                index += 1;
            }
        }
        Self {
            positional,
            options,
        }
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.options.get(key).map(String::as_str)
    }

    fn required(&self, key: &str) -> &str {
        self.get(key)
            .unwrap_or_else(|| fail(&format!("missing --{key}")))
    }

    fn number<T: std::str::FromStr>(&self, key: &str, default: T) -> T {
        self.get(key).map_or(default, |value| {
            value
                .parse()
                .unwrap_or_else(|_| fail(&format!("bad --{key}")))
        })
    }
}

fn fail(message: &str) -> ! {
    eprintln!("text-bench: {message}");
    std::process::exit(2)
}

fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = raw.first() else {
        fail("usage: text-bench <gen-inputs|parity|compare|bench> ...");
    };
    let args = Args::parse(&raw[1..]);
    match command.as_str() {
        "gen-inputs" => {
            let out = args.get("out").map_or_else(
                || repo_root().join(".build/rust-bench/b3/inputs"),
                PathBuf::from,
            );
            let config = inputs::Config {
                repo: repo_root(),
                out,
                fuzz_per_glossary: args.number("fuzz-per-glossary", 10_000),
                seed: args.number("seed", 0xB3),
            };
            if let Err(error) = inputs::generate(&config) {
                fail(&error);
            }
        }
        "parity" => parity(&args),
        "compare" => compare(&args),
        "bench" => bench_command(&args),
        "oracle-gen" => {
            let rows = oracle::generate(args.number("count", 100_000), args.number("seed", 0xB3));
            let lines: Vec<String> = rows.iter().map(Value::to_string).collect();
            std::fs::write(args.required("out"), lines.join("\n") + "\n")
                .unwrap_or_else(|error| fail(&error.to_string()));
        }
        "oracle-check" => {
            let inputs = read_jsonl(args.required("in"));
            let swift = read_jsonl(args.required("swift"));
            if inputs.len() != swift.len() {
                fail(&format!(
                    "{} inputs but {} Swift answers",
                    inputs.len(),
                    swift.len()
                ));
            }
            let (rows, disagreements, examples) =
                oracle::check(&inputs, &swift, args.number("max-examples", 10));
            for example in &examples {
                println!("{example}");
            }
            let fields = swift
                .first()
                .and_then(Value::as_object)
                .map_or(0, serde_json::Map::len);
            println!(
                "oracle: {rows} rows x {fields} fields; disagreements by field: {disagreements:?}"
            );
            if !disagreements.is_empty() {
                std::process::exit(1);
            }
        }
        other => fail(&format!("unknown command {other}")),
    }
}

fn load_inputs(args: &Args) -> (Vec<Case>, GlossaryFile) {
    let cases =
        bench::read_cases(Path::new(args.required("cases"))).unwrap_or_else(|error| fail(&error));
    let glossary = bench::read_glossary(Path::new(args.required("glossary")))
        .unwrap_or_else(|error| fail(&error));
    (cases, glossary)
}

fn parity(args: &Args) {
    let (cases, glossary) = load_inputs(args);
    let ordinary = load_ordinary_words();
    let active = vocabulary::compile(&glossary.terms, bench::reference_date_now());
    let partition = RepairVocabulary::from_active_terms(&active, &ordinary);
    let mut pipeline = Pipeline::new(&ordinary);
    let file = std::fs::File::create(args.required("out"))
        .unwrap_or_else(|error| fail(&error.to_string()));
    let mut out = std::io::BufWriter::new(file);
    let meta = json!({
        "type": "parity_meta",
        "harness": "rust",
        "glossary": glossary.name,
        "active": active.iter().map(|term| term.term_id()).collect::<Vec<_>>(),
        "surfaces": partition.surfaces,
        "protected": partition.protected_surfaces,
    });
    writeln!(out, "{meta}").expect("write");
    for case in &cases {
        let processed = pipeline.process(&case.text, &active);
        let events: Vec<Value> = processed
            .repaired
            .as_ref()
            .map(|outcome| {
                outcome
                    .events
                    .iter()
                    .map(|event| {
                        json!([
                            event.start,
                            event.end,
                            event.before,
                            event.after,
                            event.kind.as_str(),
                            format!("{:016x}", event.score.to_bits())
                        ])
                    })
                    .collect()
            })
            .unwrap_or_default();
        let text = processed.text();
        let record = json!({
            "id": case.id,
            "composed": processed.composed,
            "cleaned": processed.cleaned,
            "out": text,
            "out_sha256": bench::sha256_hex(text.as_bytes()),
            "events": events,
        });
        writeln!(out, "{record}").expect("write");
    }
    out.flush().expect("flush");
    eprintln!(
        "parity: {} cases, glossary {} ({} active)",
        cases.len(),
        glossary.name,
        active.len()
    );
}

fn read_jsonl(path: &str) -> Vec<Value> {
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|error| fail(&format!("{path}: {error}")));
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line).unwrap_or_else(|error| fail(&format!("{path}: {error}")))
        })
        .collect()
}

fn compare(args: &Args) {
    let [left_path, right_path] = args.positional.as_slice() else {
        fail("compare needs two parity files")
    };
    let max_diffs: usize = args.number("max-diffs", 5);
    let left = read_jsonl(left_path);
    let right = read_jsonl(right_path);
    let split = |rows: Vec<Value>| {
        let mut meta = None;
        let mut records = Vec::new();
        for row in rows {
            if row.get("type").and_then(Value::as_str) == Some("parity_meta") {
                meta = Some(row);
            } else {
                records.push(row);
            }
        }
        (meta, records)
    };
    let (left_meta, left_records) = split(left);
    let (right_meta, right_records) = split(right);
    let mut problems = 0;
    for key in ["glossary", "active", "surfaces", "protected"] {
        let l = left_meta.as_ref().and_then(|meta| meta.get(key));
        let r = right_meta.as_ref().and_then(|meta| meta.get(key));
        if l != r {
            problems += 1;
            println!(
                "META DIFF {key}: {} vs {}",
                l.map_or("-".into(), Value::to_string),
                r.map_or("-".into(), Value::to_string)
            );
        }
    }
    if left_records.len() != right_records.len() {
        fail(&format!(
            "record counts differ: {} vs {}",
            left_records.len(),
            right_records.len()
        ));
    }
    let fields = ["composed", "cleaned", "out", "out_sha256", "events"];
    let mut diffs: HashMap<&str, usize> = HashMap::new();
    let mut identical = 0;
    let mut shown = 0;
    for (l, r) in left_records.iter().zip(&right_records) {
        if l.get("id") != r.get("id") {
            fail(&format!(
                "row order differs at {:?} vs {:?}",
                l.get("id"),
                r.get("id")
            ));
        }
        let mut same = true;
        for field in fields {
            if l.get(field) != r.get(field) {
                same = false;
                *diffs.entry(field).or_default() += 1;
            }
        }
        if same {
            identical += 1;
        } else if shown < max_diffs {
            shown += 1;
            println!("DIFF {}", l.get("id").map_or("?".into(), Value::to_string));
            for field in fields {
                if l.get(field) != r.get(field) {
                    println!(
                        "  {field}:\n    L {}\n    R {}",
                        l.get(field).map_or("-".into(), Value::to_string),
                        r.get(field).map_or("-".into(), Value::to_string)
                    );
                }
            }
        }
    }
    let total = left_records.len();
    let mut field_report: Vec<_> = diffs.into_iter().collect();
    field_report.sort();
    println!(
        "{}: {identical}/{total} identical ({} differing; by field {:?}; meta problems {problems})",
        Path::new(left_path)
            .file_name()
            .map_or(left_path.as_str(), |name| name.to_str().unwrap_or("?")),
        total - identical,
        field_report
    );
    if identical != total || problems > 0 {
        std::process::exit(1);
    }
}

fn parse_ref(path: Option<&str>) -> HashMap<String, String> {
    let Some(path) = path else {
        return HashMap::new();
    };
    read_jsonl(path)
        .into_iter()
        .filter_map(|row| {
            Some((
                row.get("id")?.as_str()?.to_owned(),
                row.get("out_sha256")?.as_str()?.to_owned(),
            ))
        })
        .collect()
}

fn bench_command(args: &Args) {
    let stage = args.get("stage").unwrap_or("text").to_owned();
    let (cases, glossary) = load_inputs(args);
    let passes: usize = args.number("passes", 10);
    let seed: u64 = args.number("seed", 0xB3);
    let arms: Vec<String> = args
        .get("arms")
        .unwrap_or("rust,rust@aa")
        .split(',')
        .map(str::to_owned)
        .filter(|arm| !arm.is_empty())
        .collect();
    let reference = parse_ref(args.get("ref"));
    let ordinary = load_ordinary_words();
    let ordinary_path = ordinary_words_path();
    let started_at = bench::now_iso8601();

    let persistent = &glossary.terms;
    let active = vocabulary::compile(persistent, bench::reference_date_now());
    let mut pipelines: Vec<Pipeline<'_>> = arms.iter().map(|_| Pipeline::new(&ordinary)).collect();
    for pipeline in &mut pipelines {
        // A warm process: the engine was built by an earlier utterance.
        pipeline.repair_engine(&active);
    }
    let engine_reps: usize = args.number("engine-reps", 20);
    let row_ids: Vec<String> = match stage.as_str() {
        "text" | "compile" => cases.iter().map(|case| case.id.clone()).collect(),
        "engine" | "ordinary" => (0..engine_reps)
            .map(|rep| format!("{}#{rep}", glossary.name))
            .collect(),
        other => fail(&format!("unknown stage {other}")),
    };

    let mut rows: Vec<String> = Vec::with_capacity(row_ids.len() * arms.len() * (passes + 1));
    let mut seq = 0;
    for pass in 0..=passes {
        for (position, &row) in bench::pass_order(row_ids.len(), pass, seed)
            .iter()
            .enumerate()
        {
            for step in 0..arms.len() {
                let arm_index = bench::arm_at(arms.len(), pass + position, step);
                let arm = &arms[arm_index];
                let (elapsed, output, work) = match stage.as_str() {
                    "text" => {
                        let case = &cases[row];
                        let pipeline = &mut pipelines[arm_index];
                        let start = Instant::now();
                        let text = pipeline.process_text(&case.text, &active);
                        let elapsed = start.elapsed();
                        let work = json!({"chars_in": case.text.chars().count(), "chars_out": text.chars().count(), "active_terms": active.len()});
                        (elapsed, text, work)
                    }
                    "compile" => {
                        let start = Instant::now();
                        let snapshot = vocabulary::compile(persistent, bench::reference_date_now());
                        let elapsed = start.elapsed();
                        let ids = snapshot
                            .iter()
                            .map(|term| term.term_id())
                            .collect::<Vec<_>>()
                            .join("\n");
                        (
                            elapsed,
                            ids,
                            json!({"terms_in": persistent.len(), "active_terms": snapshot.len()}),
                        )
                    }
                    "engine" => {
                        let start = Instant::now();
                        let engine = Pipeline::build_engine(&active, &ordinary);
                        let elapsed = start.elapsed();
                        let surfaces = engine.surface_count();
                        drop(engine);
                        let partition = RepairVocabulary::from_active_terms(&active, &ordinary);
                        let digest = format!(
                            "{}\n--\n{}",
                            partition.surfaces.join("\n"),
                            partition.protected_surfaces.join("\n")
                        );
                        (
                            elapsed,
                            digest,
                            json!({"active_terms": active.len(), "surfaces": surfaces}),
                        )
                    }
                    _ => {
                        let start = Instant::now();
                        let contents =
                            std::fs::read_to_string(&ordinary_path).expect("ordinary words");
                        let words = OrdinaryWords::parse(&contents);
                        drop(contents);
                        let elapsed = start.elapsed();
                        (
                            elapsed,
                            words.len().to_string(),
                            json!({"words": words.len()}),
                        )
                    }
                };
                let output_sha256 = bench::sha256_hex(output.as_bytes());
                let equal_ref = if stage == "text" && !reference.is_empty() {
                    reference
                        .get(&row_ids[row])
                        .map(|expected| *expected == output_sha256)
                } else {
                    None
                };
                let row_json = TimingRow {
                    kind: "timing",
                    bet: "B3",
                    arm,
                    row_id: &row_ids[row],
                    pass,
                    seq,
                    elapsed_us: elapsed.as_secs_f64() * 1e6,
                    output_sha256,
                    equal_ref,
                    audio_s: None,
                    work,
                    err: None,
                };
                rows.push(serde_json::to_string(&row_json).expect("row"));
                seq += 1;
            }
        }
    }

    let meta = json!({
        "type": "run_meta",
        "bet": "B3",
        "harness": "rust:text-bench",
        "git_sha": bench::git_sha(&repo_root()),
        "started_at": started_at,
        "host": bench::host_meta(),
        "arms": arms,
        "passes": passes,
        "order": format!("per-pass seeded row permutation (seed {seed}); arm order per row: cyclic rotation from (pass + position) mod arms, reversed on every other cycle"),
        "corpus": args.get("corpus").unwrap_or("unnamed"),
        "notes": format!(
            "stage={stage}; glossary={} ({} terms, {} active); cases={}; release build (lto=fat, codegen-units=1)",
            glossary.name, persistent.len(), active.len(), cases.len()
        ),
        "stage": stage,
        "glossary": glossary.name,
    });
    let file = std::fs::File::create(args.required("out"))
        .unwrap_or_else(|error| fail(&error.to_string()));
    let mut out = std::io::BufWriter::new(file);
    writeln!(out, "{meta}").expect("write");
    for row in rows {
        writeln!(out, "{row}").expect("write");
    }
    out.flush().expect("flush");
}
