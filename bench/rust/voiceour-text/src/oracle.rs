//! Primitive-level differential test against the production runtime.
//!
//! `oracle-gen` writes random strings built to stress grapheme breaking, case mapping,
//! canonical equivalence and the ICU patterns; `swift-text-bench oracle` answers each
//! primitive question in Swift; `oracle-check` asks the same of this crate and reports
//! every disagreement by field.

use std::collections::BTreeMap;

use serde_json::{Value, json};
use unicode_normalization::UnicodeNormalization;

use crate::bench::SplitMix64;
use crate::icu::{self, AliasMatcher};
use crate::uni::{self, Utf16Index};
use crate::vocabulary::{CasePolicy, ProtectedTerm, TermSource};
use crate::{cleanup, glossary, literal};

/// Scalars chosen for the rules they exercise, by group.
const POOL: &[&str] = &[
    // Grapheme breaking: CR LF, controls, extenders, ZWJ, spacing marks, prepend, Hangul, RI, emoji.
    "\r",
    "\n",
    "\r\n",
    "\t",
    "\u{0}",
    "\u{7F}",
    "\u{85}",
    "\u{300}",
    "\u{301}",
    "\u{308}",
    "\u{316}",
    "\u{332}",
    "\u{345}",
    "\u{20DD}",
    "\u{200C}",
    "\u{200D}",
    "\u{FE0F}",
    "\u{FE0E}",
    "\u{E0041}",
    "\u{1F3FB}",
    "\u{903}",
    "\u{93E}",
    "\u{600}",
    "\u{6DD}",
    "\u{110BD}",
    "\u{1100}",
    "\u{1161}",
    "\u{11A8}",
    "\u{AC00}",
    "\u{AC01}",
    "\u{1F1FA}",
    "\u{1F1F8}",
    "\u{1F600}",
    "\u{2764}",
    "\u{1F468}",
    "\u{1F469}",
    "\u{915}",
    "\u{94D}",
    "\u{937}",
    "\u{924}",
    "\u{93F}",
    "\u{E33}",
    "\u{E40}",
    "\u{AA5}",
    // Case mapping and folding specials.
    "\u{DF}",
    "\u{1E9E}",
    "\u{130}",
    "\u{131}",
    "\u{17F}",
    "\u{212A}",
    "\u{212B}",
    "\u{C5}",
    "\u{3A3}",
    "\u{3C3}",
    "\u{3C2}",
    "\u{1C4}",
    "\u{1C5}",
    "\u{1C6}",
    "\u{149}",
    "\u{1F0}",
    "\u{390}",
    "\u{3B0}",
    "\u{FB01}",
    "\u{FB00}",
    "\u{FB03}",
    "\u{FB05}",
    "\u{FB06}",
    "\u{1FFC}",
    "\u{1FB3}",
    "\u{1F88}",
    "\u{587}",
    "\u{FB13}",
    "\u{13A0}",
    "\u{AB70}",
    "\u{10A0}",
    "\u{2D00}",
    "\u{1C90}",
    "\u{10400}",
    "\u{10428}",
    "\u{1E900}",
    "\u{1E922}",
    "\u{2C65}",
    "\u{A7C0}",
    "\u{1E9B}",
    "\u{345}",
    "\u{399}",
    "\u{3B9}",
    "\u{1FBE}",
    "\u{2160}",
    "\u{2170}",
    "\u{24B6}",
    "\u{24D0}",
    // Compatibility decompositions to ASCII.
    "\u{FF21}",
    "\u{FF41}",
    "\u{FF11}",
    "\u{1D400}",
    "\u{1D7CE}",
    "\u{B2}",
    "\u{2075}",
    "\u{2081}",
    "\u{BD}",
    "\u{2153}",
    "\u{2121}",
    "\u{2122}",
    "\u{2116}",
    "\u{338F}",
    "\u{3392}",
    "\u{2460}",
    "\u{2474}",
    "\u{2488}",
    "\u{1F100}",
    "\u{2024}",
    "\u{2025}",
    "\u{2026}",
    "\u{FE52}",
    "\u{FF0E}",
    "\u{FF03}",
    "\u{FE6B}",
    "\u{2100}",
    "\u{33C2}",
    // Precomposed letters and their decompositions.
    "\u{E9}",
    "e\u{301}",
    "\u{E0}",
    "a\u{300}",
    "\u{F1}",
    "n\u{303}",
    "\u{FC}",
    "u\u{308}",
    "\u{1EA0}",
    "\u{1EA1}",
    "\u{1E0C}\u{307}",
    "\u{1E0A}\u{323}",
    "q\u{307}\u{323}",
    "q\u{323}\u{307}",
    // Whitespace and invisibles.
    " ",
    " ",
    "  ",
    "\u{A0}",
    "\u{1680}",
    "\u{2000}",
    "\u{2009}",
    "\u{200A}",
    "\u{2028}",
    "\u{2029}",
    "\u{202F}",
    "\u{205F}",
    "\u{3000}",
    "\u{200B}",
    "\u{2060}",
    "\u{FEFF}",
    "\u{AD}",
    "\u{180E}",
    "\u{B}",
    "\u{C}",
    "\u{1C}",
    // Punctuation and symbols.
    ".",
    ",",
    "?",
    "!",
    "-",
    "_",
    "/",
    "~",
    "#",
    "+",
    "&",
    "@",
    "%",
    "'",
    "\"",
    "(",
    ")",
    "[",
    "]",
    "{",
    "}",
    "*",
    "\\",
    "^",
    "$",
    "|",
    "`",
    ";",
    ":",
    "<",
    ">",
    "=",
    "\u{37E}",
    "\u{1FEF}",
    "\u{2010}",
    "\u{2014}",
    "\u{2018}",
    "\u{201C}",
    "\u{AB}",
    "\u{BF}",
    "\u{A7}",
    "\u{20AC}",
    "\u{1F8B0}",
    "\u{10100}",
    // Digits and numbers.
    "0",
    "1",
    "7",
    "9",
    "\u{660}",
    "\u{663}",
    "\u{966}",
    "\u{FF19}",
    "\u{4E00}",
    "\u{4E8C}",
    "\u{2167}",
    "\u{1D7D8}",
    // Scripts.
    "\u{3B1}",
    "\u{391}",
    "\u{43F}",
    "\u{41F}",
    "\u{5D0}",
    "\u{627}",
    "\u{E01}",
    "\u{6771}",
    "\u{30AB}",
    "\u{D55C}",
    "\u{10D0}",
    "\u{531}",
    "\u{561}",
    "\u{F8FF}",
    "\u{378}",
    "\u{FFFD}",
    "\u{1D11E}",
];

const WORDS: &[&str] = &[
    "swift",
    "SwiftUI",
    "kube",
    "cuddle",
    "ss",
    "SS",
    "strasse",
    "ab",
    "k",
    "K",
    "i",
    "I",
    "id",
    "ID",
    "x86_64",
    "node.js",
    "C#",
    "go",
    "um",
    "uh",
    "the",
    "spell",
    "that",
    "dash",
    "dot",
    "capital",
    "camel",
    "case",
    "letter",
    "by",
    "AWS",
    "HTTPServer",
    "iPhone",
    "v2",
    "3.14",
    "a1b2",
    "ABCDef",
    "fi",
    "st",
    "sigma",
];

fn piece(rng: &mut SplitMix64) -> String {
    match rng.below(10) {
        0..=4 => (*rng.pick(POOL)).to_owned(),
        5..=7 => (*rng.pick(WORDS)).to_owned(),
        8 => {
            // Any valid scalar, to catch table gaps.
            loop {
                if let Some(c) = char::from_u32(rng.below(0x11_0000) as u32) {
                    return c.to_string();
                }
            }
        }
        _ => {
            (((b'a' + rng.below(26) as u8) as char).to_string())
                + if rng.chance(1, 2) { " " } else { "" }
        }
    }
}

fn random_string(rng: &mut SplitMix64, max_pieces: usize) -> String {
    let count = rng.below(max_pieces + 1);
    (0..count).map(|_| piece(rng)).collect()
}

/// A variant `NSRegularExpression` should match the alias against: case changes,
/// full-folding expansions and whitespace runs.
fn alias_variant(alias: &str, rng: &mut SplitMix64) -> String {
    let mut out = String::new();
    for c in alias.chars() {
        let replaced = match (c, rng.below(6)) {
            (' ', 0) => "\u{A0}\u{2003}".to_owned(),
            (' ', 1) => "\t\n ".to_owned(),
            ('s', 0) | ('S', 0) => "\u{17F}".to_owned(),
            ('k', 0) | ('K', 0) => "\u{212A}".to_owned(),
            (_, 2) => c.to_uppercase().collect(),
            (_, 3) => c.to_lowercase().collect(),
            _ => c.to_string(),
        };
        out.push_str(&replaced);
    }
    out.replace("ss", if rng.chance(1, 2) { "\u{DF}" } else { "ss" })
}

pub fn generate(count: usize, seed: u64) -> Vec<Value> {
    let mut rng = SplitMix64(seed ^ 0x0AC1E);
    (0..count)
        .map(|_| {
            let alias = (0..1 + rng.below(3))
                .map(|_| random_string(&mut rng, 3))
                .collect::<Vec<_>>()
                .join(" ");
            let mut s = random_string(&mut rng, 12);
            if rng.chance(1, 2) {
                let position = s
                    .char_indices()
                    .map(|(index, _)| index)
                    .nth(rng.below(s.chars().count() + 1))
                    .unwrap_or(s.len());
                let planted = alias_variant(&alias, &mut rng);
                s.insert_str(position, &format!(" {planted} "));
            }
            let t = match rng.below(5) {
                0 => s.nfd().collect(),
                1 => s.nfc().collect(),
                2 => s.chars().take(rng.below(s.chars().count() + 1)).collect(),
                3 => s.clone(),
                _ => random_string(&mut rng, 6),
            };
            json!({"s": s, "t": t, "alias": alias})
        })
        .collect()
}

fn utf16_ranges(text: &str, spans: &[(usize, usize)]) -> Vec<[usize; 2]> {
    let index = Utf16Index::new(text);
    spans
        .iter()
        .map(|&(start, end)| [index.unit(start), index.unit(end) - index.unit(start)])
        .collect()
}

pub fn answers(s: &str, t: &str, alias: &str) -> Value {
    let graphemes: Vec<usize> = uni::graphemes(s).map(str::len).collect();
    let props: Vec<u8> = uni::graphemes(s)
        .map(|g| {
            u8::from(uni::ch_is_letter(g))
                | (u8::from(uni::ch_is_number(g)) << 1)
                | (u8::from(uni::ch_is_whitespace(g)) << 2)
                | (u8::from(uni::ch_is_uppercase(g)) << 3)
                | (u8::from(uni::ch_is_lowercase(g)) << 4)
        })
        .collect();
    let matcher = AliasMatcher::new(alias);
    let alias_matches = if matcher.is_empty() {
        Value::Null
    } else {
        let mut spans = Vec::new();
        matcher.find_all(s, &mut spans);
        json!(utf16_ranges(s, &spans))
    };
    let contains: Vec<bool> = ["/", " ", "~", "_"]
        .iter()
        .map(|needle| uni::contains_char(s, needle))
        .collect();
    let mut nfkd = Vec::new();
    uni::push_nfkd_ascii(&mut nfkd, s);
    let term = ProtectedTerm {
        term_id: None,
        canonical: if alias.is_empty() {
            "x".to_owned()
        } else {
            alias.to_owned()
        },
        spoken_aliases: vec![t.to_owned()],
        case_policy: CasePolicy::Exact,
        protected: true,
        source: TermSource::Bundled,
        labeled_aliases: Vec::new(),
        tombstoned_at: None,
    };
    json!({
        "graphemes": graphemes,
        "props": props,
        "lower": uni::lowercased(s),
        "upper": uni::uppercased(s),
        "fold": uni::cf_fold(s),
        "nfkd_ascii": String::from_utf8(nfkd).expect("ASCII"),
        "eq": uni::canon_eq(s, t),
        "lt": uni::swift_cmp(s, t).is_lt(),
        "gt": uni::swift_cmp(t, s).is_lt(),
        "has_prefix": [uni::has_prefix(s, t), uni::has_prefix(s, "-")],
        "contains": contains,
        "trim_ws": uni::trim_whitespace_newline(s),
        "trim_ps": s.trim_matches(|c| uni::fd_punctuation(c) || uni::fd_symbol(c)),
        "components": s.split(uni::fd_whitespace_newline).collect::<Vec<_>>(),
        "strip_punct": s.split(uni::fd_punctuation).collect::<String>(),
        "split_space": uni::split_on_space(s),
        "split_ws": uni::split_on_whitespace(s),
        "count": uni::grapheme_count(s),
        "alias_matches": alias_matches,
        "token_matches": utf16_ranges(s, &icu::token_spans(s)),
        "canonical_tokens": glossary::canonical_tokens(s),
        "derived_aliases": glossary::derived_aliases(s),
        "can_generalize": glossary::alias_can_generalize(s, t),
        "normalize": cleanup::normalize(s),
        "literal": literal::apply(s),
        "clean": cleanup::clean(s, &[]),
        "canonicalize": glossary::canonicalize(s, &[&term]),
    })
}

/// Compares every field; returns (rows, per-field disagreement counts, examples).
pub fn check(
    inputs: &[Value],
    swift: &[Value],
    max_examples: usize,
) -> (usize, BTreeMap<String, usize>, Vec<String>) {
    let mut disagreements: BTreeMap<String, usize> = BTreeMap::new();
    let mut examples = Vec::new();
    for (input, expected) in inputs.iter().zip(swift) {
        let s = input.get("s").and_then(Value::as_str).unwrap_or_default();
        let t = input.get("t").and_then(Value::as_str).unwrap_or_default();
        let alias = input
            .get("alias")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let actual = answers(s, t, alias);
        let Value::Object(expected) = expected else {
            continue;
        };
        for (field, value) in expected {
            if actual.get(field) != Some(value) {
                *disagreements.entry(field.clone()).or_default() += 1;
                if examples.len() < max_examples {
                    examples.push(format!(
                        "{field}: s={s:?} t={t:?} alias={alias:?}\n    swift {value}\n    rust  {}",
                        actual.get(field).map_or("-".into(), Value::to_string)
                    ));
                }
            }
        }
    }
    (inputs.len().min(swift.len()), disagreements, examples)
}
