//! `RepairVocabulary` and `VocabularyRepairEngine` (VocabularyRepair.swift).

use std::collections::{HashMap, HashSet};

use crate::glossary::{self, StringSet};
use crate::icu::{self, AliasMatcher};
use crate::uni::{self, Utf16Index};
use crate::vocabulary::ProtectedTerm;

pub const FROZEN_PHONETIC_THRESHOLD: f64 = 0.95;
const EPSILON: f64 = 1e-12;
const MAXIMUM_WINDOW_WORDS: usize = 5;

/// The bundled lowercase ordinary-word list (`ordinary-words.txt`), every entry ASCII.
pub struct OrdinaryWords(HashSet<String>);

impl OrdinaryWords {
    /// `Set(contents.split(whereSeparator: \.isNewline).map(String.init))`.
    pub fn parse(contents: &str) -> Self {
        let mut words = HashSet::with_capacity(240_000);
        for line in contents.split([
            '\n', '\r', '\u{0B}', '\u{0C}', '\u{85}', '\u{2028}', '\u{2029}',
        ]) {
            if !line.is_empty() {
                words.insert(line.to_owned());
            }
        }
        assert!(
            words.iter().all(|word| word.is_ascii()),
            "ordinary words are ASCII"
        );
        Self(words)
    }

    /// `Set<String>.contains` for this all-ASCII set: a non-ASCII probe is a member
    /// only when it is canonically equivalent to an ASCII word.
    pub fn contains(&self, value: &str) -> bool {
        match uni::canon_key(value) {
            key if key.is_ascii() => self.0.contains(key.as_ref()),
            _ => false,
        }
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// `RepairVocabulary.fromActiveTerms(_:ordinaryWords:)`: the frozen risk partition.
pub struct RepairVocabulary<'w> {
    pub surfaces: Vec<String>,
    pub protected_surfaces: Vec<String>,
    pub phonetic_threshold: f64,
    pub ordinary_words: &'w OrdinaryWords,
    pub single_letter_words: Vec<String>,
}

impl<'w> RepairVocabulary<'w> {
    pub fn from_active_terms(
        active_terms: &[&ProtectedTerm],
        ordinary_words: &'w OrdinaryWords,
    ) -> Self {
        let mut eligible = Vec::with_capacity(active_terms.len());
        let mut protected = Vec::with_capacity(active_terms.len());
        for term in active_terms {
            let canonical = &term.canonical;
            if ordinary_words.contains(&uni::lowercased(canonical))
                || uni::grapheme_count(canonical) <= 2
            {
                protected.push(canonical.clone());
            } else {
                eligible.push(canonical.clone());
            }
        }
        Self {
            surfaces: eligible,
            protected_surfaces: protected,
            phonetic_threshold: FROZEN_PHONETIC_THRESHOLD,
            ordinary_words,
            single_letter_words: vec!["a".to_owned(), "i".to_owned()],
        }
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct KeyPair {
    grapheme: Vec<u8>,
    phone: Vec<u8>,
}

struct Surface {
    canonical: String,
    rank: usize,
    profiles: Vec<KeyPair>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Canonical,
    Alias,
    Phonetic,
    Protected,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Canonical => "canonical",
            Self::Alias => "alias",
            Self::Phonetic => "phonetic",
            Self::Protected => "protected",
        }
    }
}

struct LexicalPattern {
    canonical: usize,
    kind: Kind,
    expression: AliasMatcher,
}

struct ProtectedPattern {
    canonical: String,
    discovery: usize,
    expression: AliasMatcher,
}

/// Spans are UTF-16 offsets, as `NSRange`.
#[derive(Clone)]
struct Candidate<'t> {
    start: usize,
    end: usize,
    canonical: &'t str,
    canonical_rank: usize,
    kind: Kind,
    score: f64,
    discovery: usize,
    matched: &'t str,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RepairEvent {
    pub start: usize,
    pub end: usize,
    pub before: String,
    pub after: String,
    pub kind: Kind,
    pub score: f64,
}

pub struct RepairOutcome {
    pub text: String,
    pub events: Vec<RepairEvent>,
}

pub struct VocabularyRepairEngine<'w> {
    surfaces: Vec<Surface>,
    lexical_patterns: Vec<LexicalPattern>,
    protected_patterns: Vec<ProtectedPattern>,
    ordinary_words: &'w OrdinaryWords,
    single_letter_words: StringSet,
    phonetic_threshold: f64,
}

/// `Array(Set(values)).sorted()`: de-duplicated by canonical equivalence, in Swift
/// `String` order.
fn unique_sorted(values: &[String]) -> Vec<String> {
    let mut seen = StringSet::default();
    let mut unique: Vec<String> = values
        .iter()
        .filter(|value| seen.insert(value))
        .cloned()
        .collect();
    unique.sort_by(|lhs, rhs| uni::swift_cmp(lhs, rhs));
    unique
}

impl<'w> VocabularyRepairEngine<'w> {
    pub fn new(vocabulary: &RepairVocabulary<'w>) -> Self {
        let ordered_canonicals = unique_sorted(&vocabulary.surfaces);
        // Owners are canonical indices; canonicals are distinct under `==`, so index
        // sets compare like the Swift `Set<String>` of canonicals.
        let mut alias_owners: HashMap<String, Vec<usize>> = HashMap::new();
        let add_owner = |key: String, owner: usize, owners: &mut HashMap<String, Vec<usize>>| {
            let key = uni::canon_key(&key).into_owned();
            let entry = owners.entry(key).or_default();
            if !entry.contains(&owner) {
                entry.push(owner);
            }
        };
        let mut raw_aliases: Vec<Vec<String>> = Vec::with_capacity(ordered_canonicals.len());
        for (owner, canonical) in ordered_canonicals.iter().enumerate() {
            add_owner(
                uni::cf_fold(&uni::normalized_whitespace(canonical)),
                owner,
                &mut alias_owners,
            );
            raw_aliases.push(derived_aliases(canonical));
        }
        for (owner, aliases) in raw_aliases.iter().enumerate() {
            for alias in aliases {
                add_owner(uni::cf_fold(alias), owner, &mut alias_owners);
            }
        }

        let mut surfaces = Vec::with_capacity(ordered_canonicals.len());
        let mut lexical_patterns = Vec::new();
        for (rank, canonical) in ordered_canonicals.iter().enumerate() {
            let mut aliases: Vec<&String> = raw_aliases[rank]
                .iter()
                .filter(|alias| {
                    alias_owners
                        .get(uni::canon_key(&uni::cf_fold(alias)).as_ref())
                        .is_some_and(|owners| owners == &[rank])
                })
                .collect();
            aliases.sort_by(|left, right| {
                let (left_count, right_count) =
                    (uni::grapheme_count(left), uni::grapheme_count(right));
                if left_count != right_count {
                    return right_count.cmp(&left_count);
                }
                let (left_folded, right_folded) = (uni::cf_fold(left), uni::cf_fold(right));
                if !uni::canon_eq(&left_folded, &right_folded) {
                    return uni::swift_cmp(&left_folded, &right_folded);
                }
                uni::swift_cmp(left, right)
            });

            let mut profiles = Vec::new();
            let mut seen_profiles = HashSet::new();
            for surface in std::iter::once(canonical).chain(aliases.iter().copied()) {
                let profile = keys(surface);
                if !profile.grapheme.is_empty() && seen_profiles.insert(profile.clone()) {
                    profiles.push(profile);
                }
            }
            surfaces.push(Surface {
                canonical: canonical.clone(),
                rank,
                profiles,
            });

            lexical_patterns.push(LexicalPattern {
                canonical: rank,
                kind: Kind::Canonical,
                expression: AliasMatcher::new(canonical),
            });
            for alias in aliases {
                lexical_patterns.push(LexicalPattern {
                    canonical: rank,
                    kind: Kind::Alias,
                    expression: AliasMatcher::new(alias),
                });
            }
        }

        let protected_patterns = unique_sorted(&vocabulary.protected_surfaces)
            .into_iter()
            .enumerate()
            .map(|(discovery, surface)| ProtectedPattern {
                expression: AliasMatcher::new(&surface),
                canonical: surface,
                discovery,
            })
            .collect();
        let mut single_letter_words = StringSet::default();
        for word in &vocabulary.single_letter_words {
            single_letter_words.insert(&uni::cf_fold(word));
        }
        Self {
            surfaces,
            lexical_patterns,
            protected_patterns,
            ordinary_words: vocabulary.ordinary_words,
            single_letter_words,
            phonetic_threshold: vocabulary.phonetic_threshold,
        }
    }

    pub fn surface_count(&self) -> usize {
        self.surfaces.len()
    }

    pub fn repair(&self, text: &str) -> RepairOutcome {
        if self.surfaces.is_empty() {
            return RepairOutcome {
                text: text.to_owned(),
                events: Vec::new(),
            };
        }
        let index = Utf16Index::new(text);
        let mut spans = Vec::new();
        let protected = self.protected_spans(&index, &mut spans);
        let lexical = resolve_longest(self.lexical_matches(&index, &protected, &mut spans));
        let tokens: Vec<(usize, usize)> = icu::token_spans(text)
            .into_iter()
            .map(|(start, end)| (index.unit(start), index.unit(end)))
            .collect();
        let mut fuzzy: Vec<Candidate<'_>> = Vec::new();
        let mut discovery = lexical
            .iter()
            .map(|candidate| candidate.discovery as i64)
            .max()
            .unwrap_or(-1)
            + 1;

        let maximum_width = MAXIMUM_WINDOW_WORDS.min(tokens.len());
        for width in 1..=maximum_width {
            for start_index in 0..=(tokens.len() - width) {
                let start = tokens[start_index].0;
                let end = tokens[start_index + width - 1].1;
                if overlaps_span(start, end, &lexical) || overlaps_span(start, end, &protected) {
                    continue;
                }
                let matched = index.slice(start, end);
                let left_keys = keys(matched);
                let mut best: Option<&Surface> = None;
                let mut best_score = 0.0;
                for surface in &self.surfaces {
                    let score = score(&left_keys, &surface.profiles);
                    if score > best_score + EPSILON {
                        best = Some(surface);
                        best_score = score;
                    } else if (score - best_score).abs() <= EPSILON
                        && best.is_some_and(|current| surface.rank < current.rank)
                    {
                        best = Some(surface);
                    }
                }
                if let Some(best) = best {
                    if best_score + EPSILON >= self.phonetic_threshold {
                        fuzzy.push(Candidate {
                            start,
                            end,
                            canonical: &best.canonical,
                            canonical_rank: best.rank,
                            kind: Kind::Phonetic,
                            score: best_score,
                            discovery: discovery as usize,
                            matched,
                        });
                        discovery += 1;
                    }
                }
            }
        }

        let mut accepted = lexical;
        let mut eligible: Vec<Candidate<'_>> = fuzzy
            .into_iter()
            .filter(|candidate| !self.is_ordinary_span(candidate.matched))
            .collect();
        eligible.sort_by(precedes_for_phonetic_acceptance);
        for candidate in eligible {
            if !overlaps_span(candidate.start, candidate.end, &accepted) {
                accepted.push(candidate);
            }
        }
        apply(accepted, &index)
    }

    fn protected_spans<'s>(
        &'s self,
        index: &Utf16Index<'s>,
        spans: &mut Vec<(usize, usize)>,
    ) -> Vec<Candidate<'s>> {
        let text = index.text();
        let mut out = Vec::new();
        for pattern in &self.protected_patterns {
            spans.clear();
            pattern.expression.find_all(text, spans);
            for &(start, end) in spans.iter() {
                out.push(Candidate {
                    start: index.unit(start),
                    end: index.unit(end),
                    canonical: &pattern.canonical,
                    canonical_rank: 0,
                    kind: Kind::Protected,
                    score: 1.0,
                    discovery: pattern.discovery,
                    matched: &text[start..end],
                });
            }
        }
        out
    }

    fn lexical_matches<'s>(
        &'s self,
        index: &Utf16Index<'s>,
        protected: &[Candidate<'s>],
        spans: &mut Vec<(usize, usize)>,
    ) -> Vec<Candidate<'s>> {
        let text = index.text();
        let mut candidates = Vec::new();
        let mut discovery = 0;
        for pattern in &self.lexical_patterns {
            spans.clear();
            pattern.expression.find_all(text, spans);
            for &(start, end) in spans.iter() {
                let candidate = Candidate {
                    start: index.unit(start),
                    end: index.unit(end),
                    canonical: &self.surfaces[pattern.canonical].canonical,
                    canonical_rank: pattern.canonical,
                    kind: pattern.kind,
                    score: 1.0,
                    discovery,
                    matched: &text[start..end],
                };
                discovery += 1;
                let overlapping: Vec<&Candidate<'s>> = protected
                    .iter()
                    .filter(|other| candidate.start < other.end && other.start < candidate.end)
                    .collect();
                if overlapping.is_empty()
                    || can_supersede_protected_prefix(&candidate, &overlapping)
                {
                    candidates.push(candidate);
                }
            }
        }
        candidates
    }

    fn is_ordinary_span(&self, text: &str) -> bool {
        let tokens = icu::token_spans(text);
        if tokens.len() < 2 {
            return false;
        }
        tokens.iter().all(|&(start, end)| {
            let folded = uni::cf_fold(&text[start..end]);
            if folded.is_empty() || !folded.bytes().all(|b| b.is_ascii_alphabetic()) {
                return false;
            }
            if folded.chars().count() == 1 {
                return self.single_letter_words.contains(&folded);
            }
            self.ordinary_words.contains(&folded)
        })
    }
}

fn can_supersede_protected_prefix(candidate: &Candidate<'_>, protected: &[&Candidate<'_>]) -> bool {
    if !uni::canon_eq(
        &surface_shape(candidate.matched),
        &surface_shape(candidate.canonical),
    ) {
        return false;
    }
    let canonical_count = uni::grapheme_count(candidate.canonical);
    protected.iter().all(|other| {
        canonical_count > uni::grapheme_count(other.canonical)
            && uni::has_prefix(candidate.canonical, other.canonical)
    })
}

/// Drops whitespace Characters and `.`, `_`, `-`.
fn surface_shape(value: &str) -> String {
    uni::graphemes(value)
        .filter(|g| {
            !uni::ch_is_whitespace(g)
                && !uni::ch_is(g, ".")
                && !uni::ch_is(g, "_")
                && !uni::ch_is(g, "-")
        })
        .collect()
}

fn precedes_for_phonetic_acceptance(
    left: &Candidate<'_>,
    right: &Candidate<'_>,
) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    if left.score != right.score {
        return if left.score > right.score {
            Ordering::Less
        } else {
            Ordering::Greater
        };
    }
    let (left_length, right_length) = (left.matched.chars().count(), right.matched.chars().count());
    if left_length != right_length {
        return right_length.cmp(&left_length);
    }
    left.start
        .cmp(&right.start)
        .then(left.canonical_rank.cmp(&right.canonical_rank))
        .then(left.discovery.cmp(&right.discovery))
}

fn resolve_longest(candidates: Vec<Candidate<'_>>) -> Vec<Candidate<'_>> {
    let mut ordered = candidates;
    ordered.sort_by(|left, right| {
        let (left_length, right_length) =
            (left.matched.chars().count(), right.matched.chars().count());
        right_length
            .cmp(&left_length)
            .then(left.start.cmp(&right.start))
            .then(left.discovery.cmp(&right.discovery))
    });
    let mut accepted: Vec<Candidate<'_>> = Vec::new();
    for candidate in ordered {
        if !overlaps_span(candidate.start, candidate.end, &accepted) {
            accepted.push(candidate);
        }
    }
    accepted
}

fn overlaps_span(start: usize, end: usize, accepted: &[Candidate<'_>]) -> bool {
    accepted
        .iter()
        .any(|other| start < other.end && other.start < end)
}

fn apply(mut candidates: Vec<Candidate<'_>>, index: &Utf16Index<'_>) -> RepairOutcome {
    let text = index.text();
    candidates.sort_by(|left, right| right.start.cmp(&left.start));
    let mut output = text.to_owned();
    for candidate in &candidates {
        output.replace_range(
            index.byte(candidate.start)..index.byte(candidate.end),
            candidate.canonical,
        );
    }
    candidates.sort_by(|left, right| left.start.cmp(&right.start));
    let events = candidates
        .iter()
        .filter(|candidate| !uni::canon_eq(candidate.matched, candidate.canonical))
        .map(|candidate| RepairEvent {
            start: scalar_offset(candidate.start, index),
            end: scalar_offset(candidate.end, index),
            before: candidate.matched.to_owned(),
            after: candidate.canonical.to_owned(),
            kind: candidate.kind,
            score: candidate.score,
        })
        .collect();
    RepairOutcome {
        text: output,
        events,
    }
}

fn scalar_offset(utf16_offset: usize, index: &Utf16Index<'_>) -> usize {
    index.text()[..index.byte(utf16_offset)].chars().count()
}

fn score(left: &KeyPair, profiles: &[KeyPair]) -> f64 {
    let mut best = 0.0f64;
    for right in profiles {
        if left.grapheme.is_empty() || right.grapheme.is_empty() {
            continue;
        }
        let grapheme_score = normalized_levenshtein_similarity(&left.grapheme, &right.grapheme);
        let phone_score = normalized_levenshtein_similarity(&left.phone, &right.phone);
        let blended = 0.35 * grapheme_score + 0.65 * phone_score;
        best = swift_max(best, swift_max(grapheme_score, blended));
    }
    best
}

/// Swift's `max(x, y)`: `y >= x ? y : x`.
#[inline]
fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

fn normalized_levenshtein_similarity(left: &[u8], right: &[u8]) -> f64 {
    if left == right {
        return 1.0;
    }
    let length = left.len().max(right.len());
    if length == 0 {
        return 1.0;
    }
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let mut previous: Vec<usize> = (0..=right.len()).collect();
    let mut current = vec![0usize; right.len() + 1];
    for (left_index, &left_byte) in left.iter().enumerate() {
        current[0] = left_index + 1;
        for (right_index, &right_byte) in right.iter().enumerate() {
            current[right_index + 1] = (current[right_index] + 1)
                .min(previous[right_index + 1] + 1)
                .min(previous[right_index] + usize::from(left_byte != right_byte));
        }
        std::mem::swap(&mut previous, &mut current);
    }
    1.0 - previous[right.len()] as f64 / length as f64
}

fn keys(value: &str) -> KeyPair {
    let grapheme = grapheme_key(value);
    let phone = phonetic_key(&grapheme);
    KeyPair { grapheme, phone }
}

fn symbol_word(byte: u8) -> Option<&'static [u8]> {
    match byte {
        b'#' => Some(b" sharp "),
        b'+' => Some(b" plus "),
        b'/' => Some(b" slash "),
        b'&' => Some(b" and "),
        b'@' => Some(b" at "),
        b'%' => Some(b" percent "),
        _ => None,
    }
}

fn grapheme_key(value: &str) -> Vec<u8> {
    let mut ascii = Vec::with_capacity(value.len());
    uni::push_nfkd_ascii(&mut ascii, value);
    let mut expanded = Vec::with_capacity(ascii.len());
    for byte in ascii {
        let byte = byte.to_ascii_lowercase();
        match symbol_word(byte) {
            Some(spoken) => expanded.extend_from_slice(spoken),
            None => expanded.push(byte),
        }
    }
    expanded.retain(u8::is_ascii_alphanumeric);
    expanded
}

const PHONETIC_REPLACEMENTS: [(&str, &str); 16] = [
    ("tch", "C"),
    ("sch", "sk"),
    ("tion", "Sn"),
    ("sion", "Sn"),
    ("ough", "A"),
    ("ph", "f"),
    ("ght", "t"),
    ("ch", "C"),
    ("sh", "S"),
    ("th", "T"),
    ("qu", "kw"),
    ("ck", "k"),
    ("ng", "N"),
    ("wh", "w"),
    ("wr", "r"),
    ("kn", "n"),
];

fn phonetic_key(grapheme: &[u8]) -> Vec<u8> {
    let mut key = String::from_utf8(grapheme.to_vec()).expect("ASCII key");
    for (source, replacement) in PHONETIC_REPLACEMENTS {
        if key.contains(source) {
            key = key.replace(source, replacement);
        }
    }
    let bytes = key.as_bytes();
    let mut transformed = Vec::with_capacity(bytes.len() + 2);
    for (index, &byte) in bytes.iter().enumerate() {
        let next = bytes.get(index + 1).copied().unwrap_or(0);
        if byte == b'c' && matches!(next, b'e' | b'i' | b'y') {
            transformed.push(b's');
        } else if byte == b'g' && matches!(next, b'e' | b'i' | b'y') {
            transformed.push(b'j');
        } else {
            match byte {
                b'x' => transformed.extend_from_slice(b"ks"),
                b'q' | b'c' => transformed.push(b'k'),
                b'z' => transformed.push(b's'),
                _ => transformed.push(byte),
            }
        }
    }
    let mut collapsed: Vec<u8> = Vec::with_capacity(transformed.len());
    for byte in transformed {
        let normalized = if matches!(byte, b'a' | b'e' | b'i' | b'o' | b'u' | b'y') {
            b'A'
        } else {
            byte
        };
        if collapsed.last() != Some(&normalized) {
            collapsed.push(normalized);
        }
    }
    collapsed
}

fn digit_word(g: &str) -> Option<&'static str> {
    Some(match g {
        "0" => "zero",
        "1" => "one",
        "2" => "two",
        "3" => "three",
        "4" => "four",
        "5" => "five",
        "6" => "six",
        "7" => "seven",
        "8" => "eight",
        "9" => "nine",
        _ => return None,
    })
}

fn symbol_character_word(g: &str) -> Option<&'static str> {
    Some(match g {
        "#" => "sharp",
        "+" => "plus",
        "/" => "slash",
        "&" => "and",
        "@" => "at",
        "%" => "percent",
        _ => return None,
    })
}

fn separator_character_word(g: &str) -> Option<&'static str> {
    Some(match g {
        "." => "dot",
        "-" => "dash",
        "_" => "underscore",
        _ => return None,
    })
}

fn digit_spoken(value: &str) -> String {
    let mut result = String::with_capacity(value.len() * 2);
    for g in uni::graphemes(value) {
        match digit_word(g) {
            Some(word) => {
                result.push(' ');
                result.push_str(word);
                result.push(' ');
            }
            None => result.push_str(g),
        }
    }
    result
}

fn symbol_variant(canonical: &str, name_separators: bool) -> String {
    let mut result = String::with_capacity(canonical.len() * 2);
    for g in uni::graphemes(canonical) {
        if let Some(word) = symbol_character_word(g) {
            result.push(' ');
            result.push_str(word);
            result.push(' ');
        } else if let Some(word) = separator_character_word(g) {
            if name_separators {
                result.push(' ');
                result.push_str(word);
                result.push(' ');
            } else {
                result.push(' ');
            }
        } else {
            result.push_str(g);
        }
    }
    result
}

fn is_uppercase_ascii(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_uppercase())
}

/// `VocabularyRepairEngine.derivedAliases(for:)`.
fn derived_aliases(canonical: &str) -> Vec<String> {
    let tokens = glossary::canonical_tokens(canonical);
    let mut candidates: Vec<String> = Vec::new();

    if tokens.len() >= 2 {
        candidates.push(uni::lowercased(&tokens.join(" ")));
        candidates.push(
            tokens
                .iter()
                .map(|token| {
                    if uni::grapheme_count(token) >= 2 && is_uppercase_ascii(token) {
                        uni::lowercased(&uni::graphemes(token).collect::<Vec<_>>().join(" "))
                    } else {
                        uni::lowercased(token)
                    }
                })
                .collect::<Vec<_>>()
                .join(" "),
        );
        let gap_count = tokens.len() - 1;
        // Swift's `1 << gapCount` on a 64-bit Int; a canonical never has 63 gaps.
        let combination_count: u64 = if gap_count >= 64 {
            0
        } else {
            1u64 << gap_count
        };
        for combination in 0..combination_count {
            let mut value = String::new();
            for (token_index, token) in tokens.iter().enumerate() {
                value.push_str(token);
                if token_index < gap_count {
                    let bit = gap_count - token_index - 1;
                    if combination & (1 << bit) == 0 {
                        value.push(' ');
                    }
                }
            }
            candidates.push(uni::lowercased(&value));
        }
    }

    let compact: String = canonical
        .chars()
        .filter(|&c| uni::fd_alphanumeric(c))
        .collect();
    if tokens.len() == 1
        && uni::grapheme_count(&compact) >= 4
        && compact.chars().all(uni::fd_letter)
    {
        let characters: Vec<&str> = uni::graphemes(&compact).collect();
        if characters.len() >= 4 {
            for split in 2..(characters.len() - 1) {
                let joined = format!(
                    "{} {}",
                    characters[..split].concat(),
                    characters[split..].concat()
                );
                candidates.push(uni::lowercased(&joined));
            }
            let abbreviation = format!(
                "{}{}{}",
                characters[0],
                characters.len() - 2,
                characters[characters.len() - 1]
            );
            candidates.push(uni::lowercased(&abbreviation));
        }
    }

    let separator_form = symbol_variant(canonical, false);
    let spoken_form = symbol_variant(canonical, true);
    candidates.push(uni::lowercased(&separator_form));
    candidates.push(uni::lowercased(&spoken_form));
    candidates.push(uni::lowercased(&digit_spoken(&separator_form)));
    candidates.push(uni::lowercased(&digit_spoken(&spoken_form)));

    let canonical_key = uni::cf_fold(&uni::normalized_whitespace(canonical));
    let mut seen = StringSet::default();
    seen.insert(&canonical_key);
    let mut aliases = Vec::new();
    for candidate in candidates {
        let alias = uni::normalized_whitespace(&candidate);
        let key = uni::cf_fold(&alias);
        if !alias.is_empty() && seen.insert(&key) {
            aliases.push(alias);
        }
    }
    aliases
}
