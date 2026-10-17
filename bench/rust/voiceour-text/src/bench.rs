//! Shared input/output formats of the B3 harnesses (Swift and Rust read and write the
//! same files) and the common timing-row format of the Rust proof program.

use std::fmt::Write as _;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::vocabulary::ProtectedTerm;

/// One utterance: `{"id", "text"}` per JSONL line.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Case {
    pub id: String,
    pub text: String,
}

/// A glossary file: `{"name", "terms": [ProtectedTerm...]}`. Terms use the app's
/// `Settings.glossary` JSON keys; dates are seconds since 2001-01-01 (JSONDecoder's
/// default `Date` encoding).
#[derive(Clone, Debug, Deserialize)]
pub struct GlossaryFile {
    pub name: String,
    pub terms: Vec<ProtectedTerm>,
}

pub fn read_cases(path: &Path) -> Result<Vec<Case>, String> {
    let text =
        std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?;
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .enumerate()
        .map(|(index, line)| {
            serde_json::from_str(line)
                .map_err(|error| format!("{}:{}: {error}", path.display(), index + 1))
        })
        .collect()
}

pub fn read_glossary(path: &Path) -> Result<GlossaryFile, String> {
    let text =
        std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?;
    serde_json::from_str(&text).map_err(|error| format!("{}: {error}", path.display()))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// SplitMix64: a tiny deterministic generator shared by input generation and the
/// pass-order shuffles (the Swift harness implements the same one).
#[derive(Clone)]
pub struct SplitMix64(pub u64);

impl SplitMix64 {
    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in `0..bound` (bound > 0), by rejection.
    pub fn below(&mut self, bound: usize) -> usize {
        let bound = bound as u64;
        let zone = u64::MAX - (u64::MAX % bound);
        loop {
            let value = self.next_u64();
            if value < zone {
                return (value % bound) as usize;
            }
        }
    }

    pub fn chance(&mut self, numerator: usize, denominator: usize) -> bool {
        self.below(denominator) < numerator
    }

    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }

    /// Fisher–Yates.
    pub fn shuffle<T>(&mut self, items: &mut [T]) {
        for index in (1..items.len()).rev() {
            let other = self.below(index + 1);
            items.swap(index, other);
        }
    }
}

/// The order rows are visited in on one pass: a seeded permutation per pass, so drift
/// does not alias with row position. Both harnesses compute the same permutation.
pub fn pass_order(rows: usize, pass: usize, seed: u64) -> Vec<usize> {
    let mut order: Vec<usize> = (0..rows).collect();
    let mut rng = SplitMix64(seed ^ (pass as u64).wrapping_mul(0xA24B_AED4_963E_E407));
    rng.shuffle(&mut order);
    order
}

/// The arm run at `step` (0-based) for the row at `position` of `pass`, with `visit = pass +
/// position`: a cyclic rotation starting at `visit % arms`, reversed on every other cycle, so each arm takes every
/// slot equally often and follows more than one neighbour. With two arms this is the plain
/// forward/reverse alternation. Both harnesses compute the same order.
pub fn arm_at(arms: usize, visit: usize, step: usize) -> usize {
    let first = visit % arms;
    if (visit / arms) % 2 == 0 {
        (first + step) % arms
    } else {
        (first + arms - step) % arms
    }
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

pub fn host_meta() -> serde_json::Value {
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
                "AC".to_owned()
            } else if text.contains("Battery Power") {
                "battery".to_owned()
            } else {
                "unknown".to_owned()
            }
        })
        .unwrap_or_else(|| "unknown".to_owned());
    let int = |name: &str| sysctl(name).and_then(|value| value.parse::<u64>().ok());
    serde_json::json!({
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

pub fn git_sha(repo: &Path) -> Option<String> {
    command_line("/usr/bin/git", &["-C", repo.to_str()?, "rev-parse", "HEAD"])
}

/// UTC ISO 8601 with seconds.
pub fn now_iso8601() -> String {
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

/// `Date()` as `timeIntervalSinceReferenceDate`.
pub fn reference_date_now() -> f64 {
    let unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |duration| duration.as_secs_f64());
    unix - 978_307_200.0
}

#[derive(Serialize)]
pub struct TimingRow<'a> {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub bet: &'static str,
    pub arm: &'a str,
    pub row_id: &'a str,
    pub pass: usize,
    pub seq: usize,
    pub elapsed_us: f64,
    pub output_sha256: String,
    pub equal_ref: Option<bool>,
    pub audio_s: Option<f64>,
    pub work: serde_json::Value,
    pub err: Option<serde_json::Value>,
}
