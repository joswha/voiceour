//! The `NSRegularExpression` (ICU 78) patterns of the text path, matched by hand.
//!
//! The `regex` crate cannot express the alias pattern (it has no look-around) and its
//! case-insensitive mode uses simple folding, while ICU folds literal strings fully
//! (`ß` matches `ss`). These matchers follow ICU's compiled program instead:
//! `swift-text-bench oracle` compares them with `NSRegularExpression` match by match.

use crate::uni::{self, FullFold};

/// One literal run of an alias pattern as ICU compiles it under `(?i)`.
#[derive(Clone, Debug)]
enum Literal {
    /// `URX_ONECHAR_I`: the run folds to one code point; one input scalar matches when
    /// its *simple* folding equals it.
    One(char),
    /// `URX_STRING_I`: the fully folded run, compared with the fully folded input; a
    /// match may not end inside one input scalar's expansion.
    Many(Vec<char>),
}

/// `(?i)(?<![A-Za-z0-9_])` + escaped parts joined by `\s+` + `(?![A-Za-z0-9_])`, the
/// pattern of both `Glossary.aliasRegex` and `VocabularyRepairEngine.aliasPattern`.
#[derive(Clone, Debug)]
pub struct AliasMatcher {
    parts: Vec<Literal>,
}

impl AliasMatcher {
    /// Parts are `alias.split(whereSeparator: \.isWhitespace)`.
    pub fn new(alias: &str) -> Self {
        let parts = uni::split_on_whitespace(alias)
            .into_iter()
            .map(|part| {
                let mut folded = Vec::with_capacity(part.len());
                for c in part.chars() {
                    uni::push_icu_full_fold(&mut folded, c);
                }
                if folded.len() == 1 {
                    Literal::One(folded[0])
                } else {
                    Literal::Many(folded)
                }
            })
            .collect();
        Self { parts }
    }

    /// `aliasRegex` returns `nil` (and the alias is skipped) for an empty part list.
    pub fn is_empty(&self) -> bool {
        self.parts.is_empty()
    }

    /// Every match, as `matches(in:range:)` reports them: leftmost, non-overlapping,
    /// as byte ranges of `text`.
    pub fn find_all(&self, text: &str, out: &mut Vec<(usize, usize)>) {
        let mut previous: Option<char> = None;
        let mut position = 0;
        while position <= text.len() {
            let next = text[position..].chars().next();
            let behind_ok = !previous.is_some_and(uni::icu_word_ci);
            if behind_ok {
                if let Some(end) = self.match_parts(text, 0, position) {
                    out.push((position, end));
                    if end > position {
                        previous = text[..end].chars().next_back();
                        position = end;
                        continue;
                    }
                }
            }
            // No match here, or an empty one: advance one scalar.
            match next {
                Some(c) => {
                    previous = Some(c);
                    position += c.len_utf8();
                }
                None => break,
            }
        }
    }

    fn match_parts(&self, text: &str, index: usize, position: usize) -> Option<usize> {
        let end = match self.parts.get(index) {
            None => position, // no parts at all: the empty pattern
            Some(literal) => match_literal(literal, text, position)?,
        };
        if index + 1 >= self.parts.len() {
            return match text[end..].chars().next() {
                Some(c) if uni::icu_word_ci(c) => None,
                _ => Some(end),
            };
        }
        // `\s+`, greedy: try the longest run of spaces first, then shorter ones.
        let mut run_end = end;
        for c in text[end..].chars() {
            if !uni::icu_space(c) {
                break;
            }
            run_end += c.len_utf8();
        }
        let mut candidate = run_end;
        while candidate > end {
            if let Some(found) = self.match_parts(text, index + 1, candidate) {
                return Some(found);
            }
            candidate -= text[..candidate]
                .chars()
                .next_back()
                .map_or(1, char::len_utf8);
        }
        None
    }
}

fn match_literal(literal: &Literal, text: &str, position: usize) -> Option<usize> {
    match literal {
        Literal::One(expected) => {
            let c = text[position..].chars().next()?;
            (uni::icu_simple_fold(c) == *expected).then(|| position + c.len_utf8())
        }
        Literal::Many(expected) => {
            let mut matched = 0;
            let mut end = position;
            let mut input = text[position..].chars();
            while matched < expected.len() {
                let c = input.next()?;
                match uni::icu_full_fold(c) {
                    FullFold::One(folded) => {
                        if folded != expected[matched] {
                            return None;
                        }
                        matched += 1;
                    }
                    FullFold::Many(folded) => {
                        for f in folded.chars() {
                            if matched >= expected.len() || f != expected[matched] {
                                return None;
                            }
                            matched += 1;
                        }
                    }
                }
                end += c.len_utf8();
            }
            Some(end)
        }
    }
}

/// `[A-Za-z0-9+#/_-]+(?:\.[A-Za-z0-9+#/_-]+)*`, the repair engine's token pattern:
/// every match as a byte range.
pub fn token_spans(text: &str) -> Vec<(usize, usize)> {
    #[inline]
    fn token_byte(b: u8) -> bool {
        b.is_ascii_alphanumeric() || matches!(b, b'+' | b'#' | b'/' | b'_' | b'-')
    }
    let bytes = text.as_bytes();
    let mut spans = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if !token_byte(bytes[index]) {
            index += 1;
            continue;
        }
        let start = index;
        while index < bytes.len() && token_byte(bytes[index]) {
            index += 1;
        }
        while index + 1 < bytes.len() && bytes[index] == b'.' && token_byte(bytes[index + 1]) {
            index += 1;
            while index < bytes.len() && token_byte(bytes[index]) {
                index += 1;
            }
        }
        spans.push((start, index));
    }
    spans
}

/// The five `NSRegularExpression` substitutions of `canonicalTokens`:
/// `[\s._-]+` -> `" "`, then the four case/digit boundary splits (`"$1 $2"`).
pub fn canonical_token_boundaries(canonical: &str) -> String {
    // `[\s._-]+` -> " "
    let mut spaced = String::with_capacity(canonical.len() + 8);
    let mut in_run = false;
    for c in canonical.chars() {
        if uni::icu_space(c) || matches!(c, '.' | '_' | '-') {
            if !in_run {
                spaced.push(' ');
                in_run = true;
            }
        } else {
            in_run = false;
            spaced.push(c);
        }
    }
    let upper_then_title = split_upper_run(&spaced);
    let camel = split_pairs(
        &upper_then_title,
        |a| a.is_ascii_lowercase(),
        |b| b.is_ascii_uppercase(),
    );
    let letter_digit = split_pairs(&camel, |a| a.is_ascii_alphabetic(), |b| b.is_ascii_digit());
    split_pairs(
        &letter_digit,
        |a| a.is_ascii_digit(),
        |b| b.is_ascii_alphabetic(),
    )
}

/// `([A-Z]+)([A-Z][a-z])` -> `"$1 $2"`. A match needs an uppercase run of at least two
/// followed by a lowercase letter, and splits before the run's last letter.
fn split_upper_run(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len() + 4);
    let mut copied = 0;
    let mut index = 0;
    while index < bytes.len() {
        if !bytes[index].is_ascii_uppercase() {
            index += 1;
            continue;
        }
        let start = index;
        while index < bytes.len() && bytes[index].is_ascii_uppercase() {
            index += 1;
        }
        if index - start >= 2 && index < bytes.len() && bytes[index].is_ascii_lowercase() {
            out.push_str(&text[copied..index - 1]);
            out.push(' ');
            out.push_str(&text[index - 1..index + 1]);
            index += 1;
            copied = index;
        }
    }
    out.push_str(&text[copied..]);
    out
}

/// `([x])([y])` -> `"$1 $2"` for two single-byte ASCII classes.
fn split_pairs(text: &str, first: impl Fn(u8) -> bool, second: impl Fn(u8) -> bool) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len() + 4);
    let mut copied = 0;
    let mut index = 0;
    while index + 1 < bytes.len() {
        if first(bytes[index]) && second(bytes[index + 1]) {
            out.push_str(&text[copied..index + 1]);
            out.push(' ');
            index += 2;
            out.push_str(&text[index - 1..index]);
            copied = index;
        } else {
            index += 1;
        }
    }
    out.push_str(&text[copied..]);
    out
}
