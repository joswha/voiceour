//! Deterministic B3 inputs: realistic transcripts from repository benchmark rows,
//! glossaries converted from the repository vocabularies, seeded scaling glossaries,
//! and seeded fuzz cases with matching fuzz glossaries.
//!
//! Only repository data is read; nothing under `~/Library/Application Support/Voiceour`.

use std::collections::HashSet;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::bench::SplitMix64;

pub struct Config {
    pub repo: PathBuf,
    pub out: PathBuf,
    pub fuzz_per_glossary: usize,
    pub seed: u64,
}

/// Persistent glossary sizes of the scaling set. The pool is generated once at the largest size
/// and every glossary is a prefix of it, so adding a size leaves the others unchanged.
const SCALES: [usize; 6] = [0, 10, 50, 100, 1000, 5000];
const FUZZ_GLOSSARIES: usize = 12;
/// A fixed date so generated glossaries are byte-stable: 2026-01-01 as seconds since 2001.
const BASE_DATE: f64 = 788_918_400.0;

#[derive(Clone)]
struct Term {
    canonical: String,
    spoken: Vec<String>,
    /// (surface, confirmedAt, rejectedAt)
    labeled: Vec<(String, Option<f64>, Option<f64>)>,
    case_policy: &'static str,
    protected: bool,
    source: &'static str,
    tombstoned: Option<f64>,
    term_id: Option<String>,
}

impl Term {
    fn new(canonical: &str) -> Self {
        Self {
            canonical: canonical.to_owned(),
            spoken: Vec::new(),
            labeled: Vec::new(),
            case_policy: "exact",
            protected: true,
            source: "bundled",
            tombstoned: None,
            term_id: None,
        }
    }

    fn spoken(mut self, aliases: &[&str]) -> Self {
        self.spoken = aliases.iter().map(|alias| (*alias).to_owned()).collect();
        self
    }

    fn json(&self) -> Value {
        let mut object = serde_json::Map::new();
        if let Some(id) = &self.term_id {
            object.insert("term_id".into(), json!(id));
        }
        object.insert("canonical".into(), json!(self.canonical));
        object.insert("spoken_aliases".into(), json!(self.spoken));
        object.insert("case_policy".into(), json!(self.case_policy));
        object.insert("protected".into(), json!(self.protected));
        object.insert("source".into(), json!(self.source));
        let labeled: Vec<Value> = self
            .labeled
            .iter()
            .map(|(surface, confirmed, rejected)| {
                let mut label = serde_json::Map::new();
                label.insert("surface".into(), json!(surface));
                if let Some(date) = confirmed {
                    label.insert("confirmed_at".into(), json!(date));
                }
                if let Some(date) = rejected {
                    label.insert("rejected_at".into(), json!(date));
                }
                Value::Object(label)
            })
            .collect();
        object.insert("labeled_aliases".into(), Value::Array(labeled));
        if let Some(date) = self.tombstoned {
            object.insert("tombstoned_at".into(), json!(date));
        }
        Value::Object(object)
    }
}

/// `Settings.defaultGlossary` (Models.swift).
fn default_glossary() -> Vec<Term> {
    vec![
        Term::new("NVIDIA Parakeet").spoken(&["nvidia parakeet", "envidia parakeet"]),
        Term::new("FastConformer-TDT").spoken(&["fast conformer t d t", "fastconformer tdt"]),
        Term::new("NSPasteboard").spoken(&["n s pasteboard", "ns paste board"]),
        Term::new("CGEvent").spoken(&["c g event", "cg event"]),
        Term::new("AXUIElement").spoken(&["a x ui element", "ax ui element"]),
        Term::new("AVAudioEngine").spoken(&["a v audio engine", "av audio engine"]),
        Term::new("kubectl").spoken(&["cube cuddle", "kube cuddle"]),
    ]
}

fn write_glossary(dir: &Path, name: &str, terms: &[Term]) -> Result<(), String> {
    let value = json!({"name": name, "terms": terms.iter().map(Term::json).collect::<Vec<_>>()});
    let path = dir.join(format!("{name}.json"));
    std::fs::write(
        &path,
        serde_json::to_string_pretty(&value).map_err(|e| e.to_string())? + "\n",
    )
    .map_err(|error| format!("{}: {error}", path.display()))
}

fn write_cases(path: &Path, cases: &[(String, String)]) -> Result<(), String> {
    let file =
        std::fs::File::create(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut out = std::io::BufWriter::new(file);
    for (id, text) in cases {
        writeln!(out, "{}", json!({"id": id, "text": text})).map_err(|e| e.to_string())?;
    }
    out.flush().map_err(|e| e.to_string())
}

fn read_json(path: &Path) -> Result<Value, String> {
    let text =
        std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?;
    serde_json::from_str(&text).map_err(|error| format!("{}: {error}", path.display()))
}

/// Unique `raw_transcript`s of every non-fake backend row in `benchmarks/results`, then
/// the reference text of any decode dumps under `.build/rust-bench/dumps`.
fn realistic_cases(repo: &Path) -> Result<Vec<(String, String)>, String> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(repo.join("benchmarks/results"))
        .map_err(|e| e.to_string())?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.to_string_lossy().ends_with(".results.jsonl"))
        .collect();
    files.sort();
    let mut seen = HashSet::new();
    let mut cases = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file).map_err(|e| e.to_string())?;
        let mut lines = text.lines();
        let Some(meta) = lines
            .next()
            .and_then(|line| serde_json::from_str::<Value>(line).ok())
        else {
            continue;
        };
        let fake = meta.get("backend").and_then(Value::as_str) == Some("fake")
            || meta.get("model_id").and_then(Value::as_str) == Some("fake");
        if fake {
            continue;
        }
        let stem = file
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("?")
            .trim_end_matches(".results.jsonl");
        for line in lines {
            let Ok(row) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let (Some(id), Some(raw)) = (
                row.get("id").and_then(Value::as_str),
                row.get("raw_transcript").and_then(Value::as_str),
            ) else {
                continue;
            };
            if seen.insert(raw.to_owned()) {
                cases.push((format!("{stem}/{id}"), raw.to_owned()));
            }
        }
    }
    let dumps = repo.join(".build/rust-bench/dumps");
    if let Ok(entries) = std::fs::read_dir(&dumps) {
        let mut corpora: Vec<PathBuf> = entries
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .collect();
        corpora.sort();
        for corpus in corpora {
            let Ok(index) = std::fs::read_to_string(corpus.join("index.jsonl")) else {
                continue;
            };
            let name = corpus
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("?")
                .to_owned();
            for line in index.lines() {
                let Ok(row) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                let (Some(id), Some(raw)) = (
                    row.get("id").and_then(Value::as_str),
                    row.pointer("/ref/text").and_then(Value::as_str),
                ) else {
                    continue;
                };
                if seen.insert(raw.to_owned()) {
                    cases.push((format!("dump/{name}/{id}"), raw.to_owned()));
                }
            }
        }
    }
    Ok(cases)
}

/// `fixtures/text/cleanup_pairs.json` inputs plus the literal strings of the VoiceCore
/// text-path tests and a few hand-picked edge cases.
fn fixture_cases(repo: &Path) -> Result<Vec<(String, String)>, String> {
    let mut cases = Vec::new();
    if let Value::Array(pairs) = read_json(&repo.join("fixtures/text/cleanup_pairs.json"))? {
        for pair in pairs {
            if let (Some(name), Some(raw)) = (
                pair.get("name").and_then(Value::as_str),
                pair.get("raw").and_then(Value::as_str),
            ) {
                cases.push((format!("cleanup_pairs/{name}"), raw.to_owned()));
            }
        }
    }
    let extra = [
        "spell that k u b e",
        "letter-by-letter S w i f t U I",
        "letter by letter v o i c e",
        "literal kubectl",
        "run literal xcode",
        "snake case Hello World",
        "use snake case Voice Capture",
        "camel case hello WORLD",
        "use camel case voice capture",
        "capital n s pasteboard",
        "say uppercase swift now",
        "dash dash verbose",
        "well dash known",
        "example dot com",
        "voice underscore core",
        "spell that v one dot two dash beta",
        "spell that capital n s pasteboard",
        "",
        "   \n\t ",
        "um uh um",
        "hello",
        "we want one-to-one parity",
        "pick one of them",
        "one two three four five six",
        "the Z axis moved",
        "run cube cuddle now",
        "run KUBECTL now",
        "please run cube uh cuddle now",
        "run cube cube cuddle now",
        "use boon to boon to now",
        "uh please run cube uh cuddle uh now",
        "the the use the the Ubun now",
        "please uh run cube cuddle now",
        "please please run cube cuddle now",
        "use n s pasteboard",
        "I am denied access",
        "Throttle hash cut jobs",
        "Build this in swift ui today",
        "Build with swift ui",
        "Build the panel with Swift UI.",
        "I am ready.",
        "Open Wirashark, then start Jupiter.",
        "Uh let's do a cleanup over the surfaces",
        "... concept of a thread. Um basically our platform",
        "deploy on Google Cloud",
        "ask claude about it",
        "Um, so the the Kubernetis cluster uses cube cuddle and swift ui. Uh then we deploy.",
        "line one\r\nline two\rline three\nline four",
        "café cafe\u{301} CAFÉ Straße STRASSE İstanbul ΟΔΟΣ",
    ];
    for (index, text) in extra.iter().enumerate() {
        cases.push((format!("extra/{index:03}"), (*text).to_owned()));
    }
    Ok(cases)
}

fn jargon_canonicals(repo: &Path) -> Result<Vec<String>, String> {
    let value = read_json(&repo.join("bench/autoresearch/jargon.terms.json"))?;
    let mut seen = HashSet::new();
    let mut canonicals = Vec::new();
    if let Value::Object(map) = value {
        for (_, entry) in map {
            if let Some(canonical) = entry.get("canonical").and_then(Value::as_str) {
                if seen.insert(canonical.to_owned()) {
                    canonicals.push(canonical.to_owned());
                }
            }
        }
    }
    Ok(canonicals)
}

fn repair_vocabulary(repo: &Path) -> Result<(Vec<String>, Vec<String>), String> {
    let value = read_json(&repo.join("bench/autoresearch/repair.vocabulary.json"))?;
    let list = |key: &str| -> Vec<String> {
        value
            .get(key)
            .and_then(Value::as_array)
            .map_or_else(Vec::new, |items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
    };
    Ok((list("surfaces"), list("protected_surfaces")))
}

/// How a word-list import would store a canonical (WordListImporter).
fn imported(canonical: &str) -> Term {
    Term {
        protected: false,
        source: "manualImport",
        ..Term::new(canonical)
    }
}

/// A plausible mishearing of `canonical` as a recogniser emits it.
fn spoken_forms(canonical: &str, rng: &mut SplitMix64) -> Vec<String> {
    let mut forms = Vec::new();
    let lower = canonical.to_lowercase();
    // Acronym letter-spacing: "AWS" -> "a w s".
    if canonical.len() >= 2
        && canonical.len() <= 6
        && canonical.chars().all(|c| c.is_ascii_uppercase())
    {
        forms.push(
            lower
                .chars()
                .map(String::from)
                .collect::<Vec<_>>()
                .join(" "),
        );
    }
    // Split camel case: "SwiftUI" -> "swift ui".
    let mut spaced = String::new();
    let mut previous: Option<char> = None;
    for c in canonical.chars() {
        if let Some(p) = previous {
            if (p.is_ascii_lowercase() && c.is_ascii_uppercase())
                || (p.is_ascii_alphabetic() && c.is_ascii_digit())
            {
                spaced.push(' ');
            }
        }
        spaced.push(c.to_ascii_lowercase());
        previous = Some(c);
    }
    if spaced != lower {
        forms.push(spaced.replace(['-', '.', '_'], " "));
    }
    // One phonetic near miss: swap a vowel.
    if rng.chance(1, 2) && lower.chars().count() > 4 {
        let vowels = ['a', 'e', 'i', 'o', 'u'];
        let chars: Vec<char> = lower.chars().collect();
        if let Some(position) =
            (1..chars.len() - 1).find(|&i| vowels.contains(&chars[i]) && rng.chance(1, 2))
        {
            let mut miss = chars.clone();
            miss[position] = *rng.pick(&vowels);
            let miss: String = miss.into_iter().collect();
            if miss != lower {
                forms.push(miss);
            }
        }
    }
    forms
}

const SYLLABLES: &[&str] = &[
    "zen", "kor", "vex", "lumi", "tera", "quan", "nebu", "arc", "flux", "hydra", "cyto", "nova",
    "orbi", "pyra", "strato", "vela", "mira", "solu", "tachy", "omni", "gale", "ryn", "dex",
    "plex",
];
const SUFFIXES: &[&str] = &[
    "DB", "Kit", "Flow", "Hub", "OS", "ML", "ify", "Base", "Mesh", "Grid", "Sync", "Ops", "X",
    "IO", "Lab", "QL",
];
const HARD_NEGATIVES: &[&str] = &[
    "Anchor", "Bridge", "Canvas", "Harbor", "Lantern", "Shell", "Kernel", "Branch", "Commit",
    "Merge", "Cloud", "Depth", "Queue", "Stack", "Heap", "Buffer", "Frame", "Thread", "Swift",
    "Rust", "Go", "Metal", "Node", "Cargo",
];

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    chars.next().map_or_else(String::new, |first| {
        first.to_ascii_uppercase().to_string() + chars.as_str()
    })
}

/// A seeded synthetic product-like canonical with spoken aliases and provenance.
fn synthetic_term(index: usize, rng: &mut SplitMix64) -> Term {
    let canonical = match rng.below(7) {
        0 => format!(
            "{}{}",
            capitalize(rng.pick(&SYLLABLES)),
            rng.pick(&SUFFIXES)
        ),
        1 => format!(
            "{}{}",
            capitalize(rng.pick(&SYLLABLES)),
            capitalize(rng.pick(&SYLLABLES))
        ),
        2 => format!("{}-{}", rng.pick(&SYLLABLES), rng.pick(&SYLLABLES)),
        3 => format!("{}{}", rng.pick(&SYLLABLES).to_uppercase(), rng.below(10)),
        4 => format!(
            "{} {}",
            capitalize(rng.pick(&SYLLABLES)),
            capitalize(rng.pick(&SYLLABLES))
        ),
        5 => format!(
            "{}.{}",
            rng.pick(&SYLLABLES),
            ["io", "js", "rs", "ai"][rng.below(4)]
        ),
        _ => format!(
            "{}{}{}",
            capitalize(rng.pick(&SYLLABLES)),
            rng.pick(&SYLLABLES),
            rng.below(100)
        ),
    };
    let mut term = Term::new(&canonical);
    term.spoken = spoken_forms(&canonical, rng);
    provenance(&mut term, index, rng);
    term
}

fn provenance(term: &mut Term, index: usize, rng: &mut SplitMix64) {
    match rng.below(10) {
        0 => {
            term.source = "explicitCorrection";
            term.protected = true;
            let surface = term
                .spoken
                .first()
                .cloned()
                .unwrap_or_else(|| term.canonical.to_lowercase());
            term.labeled
                .push((surface, Some(BASE_DATE + (index as f64) * 60.0), None));
        }
        1..=6 => {
            term.source = "manualImport";
            term.protected = false;
        }
        7 | 8 => term.source = "bundled",
        _ => {
            term.source = "appProfile";
            term.protected = rng.chance(1, 2);
        }
    }
    if rng.chance(1, 12) && !term.spoken.is_empty() {
        let surface = term.spoken[0].clone();
        term.labeled
            .push((surface, Some(BASE_DATE - 3600.0), Some(BASE_DATE)));
    }
    if rng.chance(1, 30) {
        // Past tombstones drop out; far-future ones are still active.
        term.tombstoned = Some(if rng.chance(1, 2) {
            BASE_DATE - 86_400.0
        } else {
            BASE_DATE * 4.0
        });
    }
}

fn scaling_pool(jargon: &[String], seed: u64) -> Vec<Term> {
    let mut rng = SplitMix64(seed ^ 0x5CA1E);
    let mut jargon_terms: Vec<Term> = jargon
        .iter()
        .enumerate()
        .map(|(index, canonical)| {
            let mut term = Term::new(canonical);
            term.spoken = spoken_forms(canonical, &mut rng);
            provenance(&mut term, index, &mut rng);
            term
        })
        .collect();
    rng.shuffle(&mut jargon_terms);
    let mut seen: HashSet<String> = jargon
        .iter()
        .map(|canonical| canonical.to_lowercase())
        .collect();
    let mut pool = Vec::new();
    let mut synthetic_index = 0;
    let mut jargon_iter = jargon_terms.into_iter();
    while pool.len() < SCALES[SCALES.len() - 1] {
        if pool.len() % 2 == 0 {
            if let Some(term) = jargon_iter.next() {
                pool.push(term);
                continue;
            }
        }
        let term = if synthetic_index % 25 == 0 {
            // A hard negative: an ordinary word as a canonical, with a common-word alias.
            let word = HARD_NEGATIVES[(synthetic_index / 25) % HARD_NEGATIVES.len()];
            let mut term = Term::new(&format!(
                "{word}{}",
                if synthetic_index / 25 >= HARD_NEGATIVES.len() {
                    (synthetic_index / 25).to_string()
                } else {
                    String::new()
                }
            ));
            term.spoken = vec![word.to_lowercase()];
            provenance(&mut term, synthetic_index, &mut rng);
            term
        } else {
            synthetic_term(synthetic_index, &mut rng)
        };
        synthetic_index += 1;
        if seen.insert(term.canonical.to_lowercase()) {
            pool.push(term);
        }
    }
    pool
}

// MARK: - Fuzz

const COMMON: &[&str] = &[
    "the", "a", "an", "and", "or", "but", "so", "then", "we", "I", "you", "it", "is", "was", "be",
    "to", "of", "in", "on", "at", "for", "with", "from", "by", "this", "that", "these", "those",
    "run", "build", "deploy", "open", "close", "send", "check", "use", "make", "get", "set",
    "call", "write", "read", "ship", "test", "fix", "merge", "push", "pull", "start", "stop",
    "server", "client", "cluster", "file", "folder", "branch", "commit", "release", "today",
    "tomorrow", "now", "later", "please", "maybe", "really", "just", "also", "very", "quick",
    "slow", "new", "old", "good", "bad", "first", "second", "last", "next", "one", "two", "three",
    "four", "five", "hello", "world", "team", "meeting", "notes", "config", "update", "status",
    "error", "issue",
];
const FILLER_FORMS: &[&str] = &[
    "um", "uh", "uhm", "erm", "mmm", "hmm", "Um", "Uh", "UM", "um,", "uh.", "Hmm,", "uh?", "(um)",
];
const COMMANDS: &[&str] = &[
    "spell that",
    "spell",
    "letter by letter",
    "letter-by-letter",
    "Letter By Letter",
    "literal",
    "snake case",
    "camel case",
    "Camel Case",
    "capital",
    "uppercase",
    "Capital",
    "dash",
    "dash dash",
    "Dash",
    "dot",
    "Dot",
    "underscore",
    "SPELL",
    "spell that capital",
    "literal dash",
    "literal dot",
];
const PUNCTUATION: &[&str] = &[
    ".", ",", "?", "!", ";", ":", "-", "--", "\u{2014}", "\u{2013}", "\u{2026}", "'", "\"", "(",
    ")", "[", "]", "/", "\\", "~", "_", "#", "+", "&", "@", "%", "*", "=", "<", ">", "|", "^", "`",
    "$", "\u{20AC}", "\u{A9}", "\u{2122}", "\u{B0}", "\u{A7}", "\u{B6}", "\u{2022}", "\u{AB}",
    "\u{BB}", "\u{BF}", "\u{A1}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{37E}",
    "\u{1FEF}", "...",
];
const NUMBERS: &[&str] = &[
    "42",
    "3.14",
    "1,000",
    "2nd",
    "v2",
    "IPv6",
    "x86_64",
    "100%",
    "0",
    "16000",
    "\u{663}",
    "\u{FF11}\u{FF12}",
    "\u{B2}",
    "\u{216B}",
    "\u{2460}",
    "\u{BD}",
    "2.0.1",
    "10:30",
    "-5",
    "1e9",
    "\u{4E00}",
    "\u{0967}\u{0968}",
];
const UNICODE_WORDS: &[&str] = &[
    "caf\u{E9}",
    "cafe\u{301}",
    "na\u{EF}ve",
    "nai\u{308}ve",
    "Stra\u{DF}e",
    "STRASSE",
    "\u{1E9E}",
    "\u{130}stanbul",
    "\u{131}i",
    "\u{3A3}\u{39F}\u{3A6}\u{399}\u{391}",
    "\u{3C3}\u{3BF}\u{3C6}\u{3AF}\u{3B1}\u{3C2}",
    "\u{39F}\u{394}\u{39F}\u{3A3}",
    "\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430}",
    "\u{43F}\u{440}\u{438}\u{432}\u{435}\u{442}",
    "\u{6771}\u{4EAC}",
    "\u{65E5}\u{672C}\u{8A9E}",
    "\u{D55C}\u{AD6D}\u{C5B4}",
    "\u{1100}\u{1161}\u{11A8}",
    "\u{939}\u{93F}\u{928}\u{94D}\u{926}\u{940}",
    "\u{915}\u{94D}\u{937}\u{924}\u{94D}\u{930}\u{93F}\u{92F}",
    "\u{E20}\u{E32}\u{E29}\u{E32}\u{E44}\u{E17}\u{E22}",
    "\u{627}\u{644}\u{639}\u{631}\u{628}\u{64A}\u{629}",
    "\u{5E2}\u{5D1}\u{5E8}\u{5D9}\u{5EA}",
    "Z\u{FC}rich",
    "\u{D8}resund",
    "\u{C5}ngstr\u{F6}m",
    "\u{212B}ngstr\u{F6}m",
    "\u{212A}elvin",
    "\u{FB01}nance",
    "\u{FB02}ow",
    "\u{FF21}\u{FF22}\u{FF23}",
    "\u{FF41}\u{FF42}\u{FF43}",
    "\u{1D401}old",
    "\u{1D4C8}cript",
    "\u{24D0}\u{24D1}",
    "\u{1C5}emal",
    "\u{1C8}j",
    "\u{149}",
    "\u{17F}tate",
    "\u{FB00}",
    "\u{2167}",
    "x\u{332}",
    "a\u{300}\u{316}",
    "e\u{301}\u{301}",
    "A\u{30A}",
    "\u{1F1}",
    "\u{3C2}",
    "\u{1E9B}",
    "\u{1F80}",
    "\u{390}",
    "SwiftUI\u{301}",
    "Kubernet\u{E9}s",
    "Cr\u{E8}me Br\u{FB}l\u{E9}e",
    "\u{1EA0}\u{1EA1}",
    "\u{2C65}",
    "\u{A7C0}",
    "\u{10400}\u{10428}",
    "\u{1E900}\u{1E922}",
    "\u{13A0}\u{AB70}",
    "\u{10A0}\u{2D00}",
    "\u{0587}",
    "\u{FB13}",
    "\u{1F88}\u{1FB3}",
];
const EMOJI: &[&str] = &[
    "\u{1F600}",
    "\u{1F44D}\u{1F3FD}",
    "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}",
    "\u{1F1FA}\u{1F1F8}",
    "\u{1F1EF}\u{1F1F5}\u{1F1EB}\u{1F1F7}",
    "1\u{FE0F}\u{20E3}",
    "\u{2764}\u{FE0F}",
    "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}",
    "\u{1F9D1}\u{1F3FF}\u{200D}\u{1F4BB}",
    "\u{2708}\u{FE0E}",
    "\u{1F1FA}",
    "\u{1F3FB}",
];
const SEPARATORS: &[&str] = &[
    "\u{A0}", "\u{2009}", "\u{3000}", "\u{200B}", "\u{2028}", "\u{FEFF}", "\u{AD}", "\u{200D}",
    "\u{FE0F}", "\t", "\n", "\r\n", "\r", "  ", "\u{85}", "\u{1680}", "\u{180E}", " \u{301}",
];
const ATTACHED: &[&str] = &[
    "\u{301}",
    "\u{308}",
    "\u{20DD}",
    "\u{903}",
    "\u{600}",
    "\u{200D}",
    "\u{FE0F}",
    "\u{1F3FB}",
    "\u{E0041}",
    "\u{0B}",
];

/// Unicode and symbol-bearing canonicals for fuzz glossaries.
const FUZZ_CANONICALS: &[&str] = &[
    "Caf\u{E9} Noir",
    "Stra\u{DF}e",
    "na\u{EF}ve",
    "\u{3A3}\u{39F}\u{3A6}\u{399}\u{391}",
    "\u{1C4}emal",
    "\u{130}stanbul",
    "\u{3A9}mega",
    "\u{6771}\u{4EAC}\u{30BF}\u{30EF}\u{30FC}",
    "\u{FB01}nance",
    "e\u{301}clair",
    "Z\u{FC}rich",
    "\u{212A}elvin",
    "\u{3A3}\u{391}\u{3A3}",
    "\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430}",
    "\u{FF21}\u{FF29} Lab",
    "S\u{E3}o Paulo",
    "C#",
    "C++",
    "F#",
    ".NET",
    "Node.js",
    "AT&T",
    "100%",
    "@channel",
    "a/b test",
    "x86_64",
    "HTTP/2",
    "Wi-Fi",
    "U.S.A.",
    "R2-D2",
    "K8s",
    "gRPC",
    "OAuth 2.0",
    "SHA-256",
    "Ed25519",
    "I/O",
    "e-mail",
    "Objective-C",
    "macOS",
    "iPhone",
];

/// Surfaces whose own words the deletion passes would damage.
const FRAGILE: &[(&str, &str)] = &[
    ("kubectl", "cube uh cuddle"),
    ("Ubuntu", "boon to boon to"),
    ("Ubuntu", "the the Ubun"),
    ("Dataflow", "data um flow"),
    ("Rerun", "re re run"),
    ("Hmmbird", "hmm bird"),
];

fn fuzz_glossary(k: usize, jargon: &[String], seed: u64) -> Vec<Term> {
    let mut rng = SplitMix64(seed ^ 0xF0221 ^ ((k as u64) << 32));
    let mut terms: Vec<Term> = Vec::new();
    if k % 3 != 2 {
        terms.extend(default_glossary());
    }
    let jargon_count = [8, 20, 40, 60, 12, 30, 5, 80, 25, 15, 50, 140][k % 12];
    let mut jargon_pick: Vec<&String> = jargon.iter().collect();
    rng.shuffle(&mut jargon_pick);
    for (index, canonical) in jargon_pick.into_iter().take(jargon_count).enumerate() {
        let mut term = Term::new(canonical);
        term.spoken = spoken_forms(canonical, &mut rng);
        provenance(&mut term, index, &mut rng);
        terms.push(term);
    }
    let unicode_count = 4 + rng.below(12);
    let mut unicode_pick: Vec<&str> = FUZZ_CANONICALS.to_vec();
    rng.shuffle(&mut unicode_pick);
    for (index, canonical) in unicode_pick.into_iter().take(unicode_count).enumerate() {
        let mut term = Term::new(canonical);
        term.spoken = spoken_forms(canonical, &mut rng);
        if rng.chance(1, 3) {
            term.spoken.push(canonical.to_lowercase());
        }
        provenance(&mut term, index + 1000, &mut rng);
        term.case_policy = ["exact", "exact", "lower", "title"][rng.below(4)];
        terms.push(term);
    }
    // Fragile surfaces, as a user teaches them (confirmed labels on explicit corrections).
    let fragile: Vec<&(&str, &str)> = FRAGILE.iter().filter(|_| rng.chance(1, 2)).collect();
    for (canonical, surface) in fragile {
        let mut term = Term::new(canonical);
        term.source = "explicitCorrection";
        term.labeled
            .push(((*surface).to_owned(), Some(BASE_DATE + 5.0), None));
        terms.push(term);
    }
    // Aliases that must not generalize: a bare-integer canonical, a one-letter alias.
    if rng.chance(2, 3) {
        for (canonical, alias) in [
            ("1", "one"),
            ("42", "forty two"),
            ("Zed", "Z"),
            ("Xcode", "X"),
        ] {
            let mut term = Term::new(canonical);
            term.source = "explicitCorrection";
            term.labeled
                .push((alias.to_owned(), Some(BASE_DATE + 9.0), None));
            terms.push(term);
        }
    }
    // Hard negatives: ordinary words as canonicals, ordinary-word aliases.
    let negatives: Vec<&&str> = HARD_NEGATIVES.iter().filter(|_| rng.chance(1, 4)).collect();
    for word in negatives {
        let mut term = Term::new(word);
        term.spoken = vec![word.to_lowercase()];
        provenance(&mut term, 2000, &mut rng);
        terms.push(term);
    }
    // An occasional ambiguous pair: one alias claimed by two terms.
    if rng.chance(1, 3) {
        terms.push(Term::new("PostgreSQL").spoken(&["post gres"]));
        terms.push(Term::new("Postgres").spoken(&["post gres"]));
    }
    for (index, term) in terms.iter_mut().enumerate() {
        if rng.chance(1, 10) {
            term.term_id = Some(format!("term-{k}-{index}"));
        }
    }
    terms
}

/// Plantable surfaces of a glossary: canonicals, aliases and casing/punctuation variants.
fn plantable(terms: &[Term]) -> Vec<String> {
    let mut surfaces = Vec::new();
    for term in terms {
        surfaces.push(term.canonical.clone());
        surfaces.extend(term.spoken.iter().cloned());
        surfaces.extend(term.labeled.iter().map(|(surface, _, _)| surface.clone()));
    }
    surfaces
}

fn near_miss(surface: &str, rng: &mut SplitMix64) -> String {
    let mut chars: Vec<char> = surface.chars().collect();
    if chars.is_empty() {
        return String::new();
    }
    let position = rng.below(chars.len());
    match rng.below(4) {
        0 => {
            chars.remove(position);
        }
        1 => chars.insert(position, *rng.pick(&['a', 'e', 'i', 'o', 'u', 'h', 'r'])),
        2 => chars[position] = *rng.pick(&['a', 'e', 'i', 'o', 'u', 'k', 's']),
        _ => {
            if position + 1 < chars.len() {
                chars.insert(position + 1, ' ');
            }
        }
    }
    chars.into_iter().collect()
}

fn vary_case(text: &str, rng: &mut SplitMix64) -> String {
    match rng.below(6) {
        0 => text.to_lowercase(),
        1 => text.to_uppercase(),
        2 => capitalize(text),
        _ => text.to_owned(),
    }
}

fn fuzz_case(surfaces: &[String], rng: &mut SplitMix64) -> String {
    let length = match rng.below(50) {
        0 => 0,
        1..=10 => 1 + rng.below(5),
        11..=30 => 6 + rng.below(15),
        31..=48 => 21 + rng.below(40),
        _ => 100 + rng.below(200),
    };
    let mut words: Vec<String> = Vec::with_capacity(length);
    for _ in 0..length {
        let word = match rng.below(100) {
            0..=29 => vary_case(rng.pick(&COMMON), rng),
            30..=37 => (*rng.pick(&FILLER_FORMS)).to_owned(),
            38..=43 => {
                // A stutter: repeat the last one to four words.
                let span = 1 + rng.below(4).min(words.len().saturating_sub(1));
                if words.len() >= span {
                    let repeated = words[words.len() - span..].join(" ");
                    if rng.chance(1, 3) {
                        format!("{repeated},")
                    } else {
                        repeated
                    }
                } else {
                    vary_case(rng.pick(&COMMON), rng)
                }
            }
            44..=50 => (*rng.pick(&COMMANDS)).to_owned(),
            51..=54 => {
                let letters = 1 + rng.below(6);
                (0..letters)
                    .map(|_| {
                        let letter = (b'a' + rng.below(26) as u8) as char;
                        if rng.chance(1, 4) {
                            letter.to_ascii_uppercase().to_string()
                        } else {
                            letter.to_string()
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            }
            55..=59 => (*rng.pick(&NUMBERS)).to_owned(),
            60..=66 => (*rng.pick(&PUNCTUATION)).to_owned(),
            67..=74 => (*rng.pick(&UNICODE_WORDS)).to_owned(),
            75..=77 => (*rng.pick(&EMOJI)).to_owned(),
            78..=91 if !surfaces.is_empty() => vary_case(rng.pick(surfaces), rng),
            92..=96 if !surfaces.is_empty() => near_miss(rng.pick(surfaces), rng),
            _ => vary_case(rng.pick(&COMMON), rng),
        };
        let word = match rng.below(20) {
            0 => format!("{word}."),
            1 => format!("{word},"),
            2 => format!("{word}?"),
            3 => format!("{word}{}", rng.pick(&ATTACHED)),
            4 => format!("\"{word}\""),
            _ => word,
        };
        words.push(word);
    }
    let mut text = String::new();
    if rng.chance(1, 15) {
        text.push_str(rng.pick(&SEPARATORS));
    }
    for (index, word) in words.iter().enumerate() {
        if index > 0 {
            match rng.below(40) {
                0 => {}
                1..=3 => text.push_str(rng.pick(&SEPARATORS)),
                4 => text.push_str(rng.pick(&ATTACHED)),
                5 => text.push_str("  "),
                _ => text.push(' '),
            }
        }
        text.push_str(word);
    }
    if rng.chance(1, 15) {
        text.push_str(rng.pick(&SEPARATORS));
    }
    text
}

pub fn generate(config: &Config) -> Result<(), String> {
    let cases_dir = config.out.join("cases");
    let glossary_dir = config.out.join("glossaries");
    std::fs::create_dir_all(&cases_dir).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&glossary_dir).map_err(|e| e.to_string())?;
    let mut matrix: Vec<Value> = Vec::new();

    let realistic = realistic_cases(&config.repo)?;
    write_cases(&cases_dir.join("realistic.jsonl"), &realistic)?;
    let fixtures = fixture_cases(&config.repo)?;
    write_cases(&cases_dir.join("fixtures.jsonl"), &fixtures)?;

    let jargon = jargon_canonicals(&config.repo)?;
    let (surfaces, protected) = repair_vocabulary(&config.repo)?;

    let default7 = default_glossary();
    write_glossary(&glossary_dir, "default7", &default7)?;
    let mut user_jargon = default7.clone();
    user_jargon.extend(jargon.iter().map(|canonical| imported(canonical)));
    write_glossary(&glossary_dir, "user-jargon", &user_jargon)?;
    let mut seen = HashSet::new();
    let repair_vocab: Vec<Term> = surfaces
        .iter()
        .chain(&protected)
        .filter(|canonical| seen.insert(canonical.to_lowercase()))
        .map(|canonical| Term {
            source: "explicitCorrection",
            ..Term::new(canonical)
        })
        .collect();
    write_glossary(&glossary_dir, "repair-vocab", &repair_vocab)?;
    for glossary in ["default7", "user-jargon", "repair-vocab"] {
        matrix.push(json!({"set": "realistic", "cases": "cases/realistic.jsonl", "glossary": format!("glossaries/{glossary}.json")}));
        matrix.push(json!({"set": "fixtures", "cases": "cases/fixtures.jsonl", "glossary": format!("glossaries/{glossary}.json")}));
    }

    let pool = scaling_pool(&jargon, config.seed);
    for scale in SCALES {
        let name = format!("scale-{scale}");
        write_glossary(&glossary_dir, &name, &pool[..scale])?;
        matrix.push(json!({"set": "scaling", "cases": "cases/realistic.jsonl", "glossary": format!("glossaries/{name}.json")}));
    }

    let mut fuzz_total = 0;
    for k in 0..FUZZ_GLOSSARIES {
        let terms = fuzz_glossary(k, &jargon, config.seed);
        let name = format!("fuzz-{k:02}");
        write_glossary(&glossary_dir, &name, &terms)?;
        let surfaces = plantable(&terms);
        let mut rng = SplitMix64(config.seed ^ 0xCA5E ^ ((k as u64) << 40));
        let cases: Vec<(String, String)> = (0..config.fuzz_per_glossary)
            .map(|index| (format!("{name}/{index:06}"), fuzz_case(&surfaces, &mut rng)))
            .collect();
        fuzz_total += cases.len();
        write_cases(&cases_dir.join(format!("{name}.jsonl")), &cases)?;
        matrix.push(json!({"set": "fuzz", "cases": format!("cases/{name}.jsonl"), "glossary": format!("glossaries/{name}.json")}));
    }

    let manifest = json!({
        "seed": config.seed,
        "realistic_cases": realistic.len(),
        "fixture_cases": fixtures.len(),
        "fuzz_cases": fuzz_total,
        "matrix": matrix,
    });
    std::fs::write(
        config.out.join("manifest.json"),
        serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())? + "\n",
    )
    .map_err(|e| e.to_string())?;
    eprintln!(
        "gen-inputs: {} realistic, {} fixture, {fuzz_total} fuzz cases; {} glossaries -> {}",
        realistic.len(),
        fixtures.len(),
        3 + SCALES.len() + FUZZ_GLOSSARIES,
        config.out.display()
    );
    Ok(())
}
