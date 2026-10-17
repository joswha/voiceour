//! Swift `String`/`Character`, Foundation and ICU primitives as the production text
//! path observes them.
//!
//! Every property comes from `tables.rs`, which `swift-text-bench tables` generates by
//! asking the production runtime about each scalar. Two behaviours are not per-scalar
//! and come from crates pinned at the same Unicode version (17.0) as the Swift stdlib:
//! extended grapheme clusters (`unicode-segmentation`, Swift's `Character`) and
//! canonical equivalence (`unicode-normalization`, Swift's `String ==`, hashing and
//! `<`). `swift-text-bench oracle` cross-checks both on random strings.

use std::borrow::Cow;
use std::cmp::Ordering;
use std::sync::LazyLock;

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

use crate::tables;

#[inline]
fn in_ranges(table: &[(u32, u32)], value: u32) -> bool {
    table
        .binary_search_by(|&(lo, hi)| {
            if hi < value {
                Ordering::Less
            } else if lo > value {
                Ordering::Greater
            } else {
                Ordering::Equal
            }
        })
        .is_ok()
}

#[inline]
fn lookup(table: &'static [(u32, &'static str)], c: char) -> Option<&'static str> {
    table
        .binary_search_by_key(&(c as u32), |&(key, _)| key)
        .ok()
        .map(|index| table[index].1)
}

const LETTER: u16 = 1 << 0;
const NUMBER: u16 = 1 << 1;
const WHITESPACE: u16 = 1 << 2;
const UPPER: u16 = 1 << 3;
const LOWER: u16 = 1 << 4;
const FD_WS_NL: u16 = 1 << 5;
const FD_PUNCT: u16 = 1 << 6;
const FD_SYMBOL: u16 = 1 << 7;
const FD_DECIMAL: u16 = 1 << 8;
const FD_ALNUM: u16 = 1 << 9;
const FD_LETTER: u16 = 1 << 10;
const ICU_SPACE: u16 = 1 << 11;
const ICU_WORD: u16 = 1 << 12;

/// ASCII flags, derived from the same tables so the fast path cannot drift from them.
static ASCII: LazyLock<[u16; 128]> = LazyLock::new(|| {
    let mut flags = [0u16; 128];
    for (byte, slot) in flags.iter_mut().enumerate() {
        *slot = slow_flags(byte as u32);
    }
    flags
});

fn slow_flags(value: u32) -> u16 {
    let mut flags = 0;
    for (table, flag) in [
        (tables::CHAR_LETTER, LETTER),
        (tables::CHAR_NUMBER, NUMBER),
        (tables::CHAR_WHITESPACE, WHITESPACE),
        (tables::CHAR_UPPER, UPPER),
        (tables::CHAR_LOWER, LOWER),
        (tables::FD_WHITESPACE_NEWLINE, FD_WS_NL),
        (tables::FD_PUNCTUATION, FD_PUNCT),
        (tables::FD_SYMBOL, FD_SYMBOL),
        (tables::FD_DECIMAL_DIGIT, FD_DECIMAL),
        (tables::FD_ALPHANUMERIC, FD_ALNUM),
        (tables::FD_LETTER, FD_LETTER),
        (tables::ICU_SPACE, ICU_SPACE),
        (tables::ICU_WORD_CASE_INSENSITIVE, ICU_WORD),
    ] {
        if in_ranges(table, value) {
            flags |= flag;
        }
    }
    flags
}

#[inline]
fn has(c: char, flag: u16, table: &[(u32, u32)]) -> bool {
    let value = c as u32;
    if value < 128 {
        ASCII[value as usize] & flag != 0
    } else {
        in_ranges(table, value)
    }
}

// MARK: - One-scalar properties

/// `Character(c).isLetter`.
#[inline]
pub fn scalar_is_letter(c: char) -> bool {
    has(c, LETTER, tables::CHAR_LETTER)
}
/// `Character(c).isNumber`.
#[inline]
pub fn scalar_is_number(c: char) -> bool {
    has(c, NUMBER, tables::CHAR_NUMBER)
}
/// `Character(c).isWhitespace`.
#[inline]
pub fn scalar_is_whitespace(c: char) -> bool {
    has(c, WHITESPACE, tables::CHAR_WHITESPACE)
}
/// `Character(c).isUppercase` for a one-scalar Character.
#[inline]
pub fn scalar_is_uppercase(c: char) -> bool {
    has(c, UPPER, tables::CHAR_UPPER)
}
/// `Character(c).isLowercase` for a one-scalar Character.
#[inline]
pub fn scalar_is_lowercase(c: char) -> bool {
    has(c, LOWER, tables::CHAR_LOWER)
}
/// `CharacterSet.whitespacesAndNewlines.contains(c)`.
#[inline]
pub fn fd_whitespace_newline(c: char) -> bool {
    has(c, FD_WS_NL, tables::FD_WHITESPACE_NEWLINE)
}
/// `CharacterSet.punctuationCharacters.contains(c)`.
#[inline]
pub fn fd_punctuation(c: char) -> bool {
    has(c, FD_PUNCT, tables::FD_PUNCTUATION)
}
/// `CharacterSet.symbols.contains(c)`.
#[inline]
pub fn fd_symbol(c: char) -> bool {
    has(c, FD_SYMBOL, tables::FD_SYMBOL)
}
/// `CharacterSet.decimalDigits.contains(c)`.
#[inline]
pub fn fd_decimal_digit(c: char) -> bool {
    has(c, FD_DECIMAL, tables::FD_DECIMAL_DIGIT)
}
/// `CharacterSet.alphanumerics.contains(c)`.
#[inline]
pub fn fd_alphanumeric(c: char) -> bool {
    has(c, FD_ALNUM, tables::FD_ALPHANUMERIC)
}
/// `CharacterSet.letters.contains(c)`.
#[inline]
pub fn fd_letter(c: char) -> bool {
    has(c, FD_LETTER, tables::FD_LETTER)
}
/// ICU `\s`.
#[inline]
pub fn icu_space(c: char) -> bool {
    has(c, ICU_SPACE, tables::ICU_SPACE)
}
/// ICU `(?i)[A-Za-z0-9_]`: the alias pattern's look-behind and look-ahead class.
#[inline]
pub fn icu_word_ci(c: char) -> bool {
    has(c, ICU_WORD, tables::ICU_WORD_CASE_INSENSITIVE)
}
/// Scalars that CoreFoundation's composed-sequence boundary attaches to a preceding
/// `\r`/`\n`, so `replacingOccurrences` refuses a match ending right before them.
#[inline]
pub fn cf_non_base(c: char) -> bool {
    (c as u32) >= 128 && in_ranges(tables::CF_NON_BASE, c as u32)
}

// MARK: - Case mapping and folding

/// `String.lowercased()`: the per-scalar full lowercase mapping, without context.
pub fn push_lowercased(out: &mut String, s: &str) {
    if s.is_ascii() {
        out.extend(s.bytes().map(|b| b.to_ascii_lowercase() as char));
        return;
    }
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c.to_ascii_lowercase());
        } else if let Some(mapped) = lookup(tables::LOWER_MAP, c) {
            out.push_str(mapped);
        } else {
            out.push(c);
        }
    }
}

pub fn lowercased(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    push_lowercased(&mut out, s);
    out
}

/// `String.uppercased()`: the per-scalar full uppercase mapping.
pub fn push_uppercased(out: &mut String, s: &str) {
    if s.is_ascii() {
        out.extend(s.bytes().map(|b| b.to_ascii_uppercase() as char));
        return;
    }
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c.to_ascii_uppercase());
        } else if let Some(mapped) = lookup(tables::UPPER_MAP, c) {
            out.push_str(mapped);
        } else {
            out.push(c);
        }
    }
}

pub fn uppercased(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    push_uppercased(&mut out, s);
    out
}

/// `String.folding(options: .caseInsensitive, locale: en_US_POSIX)`.
pub fn cf_fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c.to_ascii_lowercase());
        } else if let Some(mapped) = lookup(tables::CF_FOLD, c) {
            out.push_str(mapped);
        } else {
            out.push(c);
        }
    }
    out
}

/// ICU simple case folding (`u_foldCase(c, U_FOLD_CASE_DEFAULT)`).
#[inline]
pub fn icu_simple_fold(c: char) -> char {
    if c.is_ascii() {
        return c.to_ascii_lowercase();
    }
    match tables::ICU_SIMPLE_FOLD.binary_search_by_key(&(c as u32), |&(key, _)| key) {
        Ok(index) => char::from_u32(tables::ICU_SIMPLE_FOLD[index].1).unwrap_or(c),
        Err(_) => c,
    }
}

/// Appends ICU's full case folding of one scalar (`u_strFoldCase`, default options).
#[inline]
pub fn push_icu_full_fold(out: &mut Vec<char>, c: char) {
    match icu_full_fold(c) {
        FullFold::One(folded) => out.push(folded),
        FullFold::Many(folded) => out.extend(folded.chars()),
    }
}

/// ICU's full case folding of one scalar as a short sequence.
#[inline]
pub fn icu_full_fold(c: char) -> FullFold {
    if c.is_ascii() {
        return FullFold::One(c.to_ascii_lowercase());
    }
    match lookup(tables::ICU_FULL_FOLD, c) {
        Some(folded) => {
            let mut chars = folded.chars();
            match (chars.next(), chars.next()) {
                (Some(only), None) => FullFold::One(only),
                _ => FullFold::Many(folded),
            }
        }
        None => FullFold::One(c),
    }
}

pub enum FullFold {
    One(char),
    Many(&'static str),
}

/// Appends the ASCII scalars of `decomposedStringWithCompatibilityMapping`.
///
/// Canonical reordering only moves non-starters and every ASCII scalar is a starter,
/// so the ASCII projection of a string's NFKD is the concatenation of its scalars'.
pub fn push_nfkd_ascii(out: &mut Vec<u8>, s: &str) {
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c as u8);
        } else if let Some(mapped) = lookup(tables::NFKD_ASCII, c) {
            out.extend_from_slice(mapped.as_bytes());
        }
    }
}

// MARK: - Canonical equivalence (`String ==`, hashing, `<`)

/// Swift `String ==`: canonical equivalence.
#[inline]
pub fn canon_eq(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    if a.is_ascii() && b.is_ascii() {
        return false;
    }
    a.chars().nfd().eq(b.chars().nfd())
}

/// Swift `String <`: lexicographic order of the NFC-normalized scalars.
pub fn swift_cmp(a: &str, b: &str) -> Ordering {
    if a.is_ascii() && b.is_ascii() {
        return a.cmp(b);
    }
    a.chars().nfc().cmp(b.chars().nfc())
}

/// A key that hashes and compares like a Swift `String` in a `Set`/`Dictionary`.
pub fn canon_key(s: &str) -> Cow<'_, str> {
    if s.is_ascii() || unicode_normalization::is_nfd(s) {
        Cow::Borrowed(s)
    } else {
        Cow::Owned(s.chars().nfd().collect())
    }
}

// MARK: - Characters (extended grapheme clusters)

#[inline]
pub fn graphemes(s: &str) -> unicode_segmentation::Graphemes<'_> {
    s.graphemes(true)
}

#[inline]
pub fn grapheme_indices(s: &str) -> unicode_segmentation::GraphemeIndices<'_> {
    s.grapheme_indices(true)
}

/// `String.count`.
pub fn grapheme_count(s: &str) -> usize {
    if s.is_ascii() {
        // CR LF is the only cluster of more than one ASCII scalar.
        let bytes = s.as_bytes();
        return bytes.len() - bytes.windows(2).filter(|pair| pair == b"\r\n").count();
    }
    s.graphemes(true).count()
}

#[inline]
fn first_scalar(g: &str) -> char {
    g.chars().next().unwrap_or('\0')
}

#[inline]
fn is_single_scalar(g: &str) -> bool {
    let mut chars = g.chars();
    chars.next().is_some() && chars.next().is_none()
}

/// `Character.isLetter`: the first scalar decides.
#[inline]
pub fn ch_is_letter(g: &str) -> bool {
    scalar_is_letter(first_scalar(g))
}
/// `Character.isNumber`.
#[inline]
pub fn ch_is_number(g: &str) -> bool {
    scalar_is_number(first_scalar(g))
}
/// `Character.isWhitespace`.
#[inline]
pub fn ch_is_whitespace(g: &str) -> bool {
    scalar_is_whitespace(first_scalar(g))
}

/// `Character.isUppercase`. A multi-scalar Character is uppercase when uppercasing
/// leaves it canonically unchanged and lowercasing does not.
pub fn ch_is_uppercase(g: &str) -> bool {
    if is_single_scalar(g) {
        return scalar_is_uppercase(first_scalar(g));
    }
    let is_uppercased = canon_eq(g, &uppercased(g));
    is_uppercased && !canon_eq(g, &lowercased(g))
}

/// `Character.isLowercase`.
pub fn ch_is_lowercase(g: &str) -> bool {
    if is_single_scalar(g) {
        return scalar_is_lowercase(first_scalar(g));
    }
    let is_lowercased = canon_eq(g, &lowercased(g));
    is_lowercased && !canon_eq(g, &uppercased(g))
}

/// `Character == "<ascii>"` for a needle no other cluster is canonically equivalent to.
#[inline]
pub fn ch_is(g: &str, ascii: &str) -> bool {
    debug_assert!(ascii.len() == 1 && !matches!(ascii, ";" | "`" | "K"));
    g == ascii
}

/// `string.contains("<one-Character needle>")`: Character-wise, so a needle followed
/// by a combining mark is a different Character and does not count.
pub fn contains_char(s: &str, needle: &str) -> bool {
    if s.is_ascii() {
        return s.contains(needle);
    }
    graphemes(s).any(|g| ch_is(g, needle))
}

/// `string.hasPrefix(prefix)`: Character-wise with canonical equivalence.
pub fn has_prefix(s: &str, prefix: &str) -> bool {
    if s.is_ascii() && prefix.is_ascii() {
        // ASCII graphemes are bytes except CR LF; a prefix ending in CR must not cut a CR LF.
        return s.starts_with(prefix)
            && !(prefix.ends_with('\r') && s.as_bytes().get(prefix.len()) == Some(&b'\n'));
    }
    let mut own = graphemes(s);
    for expected in graphemes(prefix) {
        match own.next() {
            Some(actual) if canon_eq(actual, expected) => {}
            _ => return false,
        }
    }
    true
}

/// `string.split(separator: " ")` (Character-wise, empty pieces omitted).
pub fn split_on_space(s: &str) -> Vec<&str> {
    if s.is_ascii() {
        return s.split(' ').filter(|piece| !piece.is_empty()).collect();
    }
    let mut pieces = Vec::new();
    let mut start = 0;
    for (index, g) in grapheme_indices(s) {
        if ch_is(g, " ") {
            if index > start {
                pieces.push(&s[start..index]);
            }
            start = index + g.len();
        }
    }
    if s.len() > start {
        pieces.push(&s[start..]);
    }
    pieces
}

/// `string.split(whereSeparator: \.isWhitespace)` (empty pieces omitted).
pub fn split_on_whitespace(s: &str) -> Vec<&str> {
    let mut pieces = Vec::new();
    let mut start = 0;
    for (index, g) in grapheme_indices(s) {
        if ch_is_whitespace(g) {
            if index > start {
                pieces.push(&s[start..index]);
            }
            start = index + g.len();
        }
    }
    if s.len() > start {
        pieces.push(&s[start..]);
    }
    pieces
}

/// `value.split(whereSeparator: \.isWhitespace).joined(separator: " ")`.
pub fn normalized_whitespace(s: &str) -> String {
    split_on_whitespace(s).join(" ")
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`: scalar-wise from both ends.
#[inline]
pub fn trim_whitespace_newline(s: &str) -> &str {
    s.trim_matches(fd_whitespace_newline)
}

// MARK: - UTF-16 positions (NSRange)

/// Byte offset of every UTF-16 offset that falls on a scalar boundary.
pub struct Utf16Index<'a> {
    text: &'a str,
    /// `None` for ASCII text, where both offsets coincide.
    starts: Option<Vec<(u32, u32)>>,
    utf16_len: usize,
}

impl<'a> Utf16Index<'a> {
    pub fn new(text: &'a str) -> Self {
        if text.is_ascii() {
            return Self {
                text,
                starts: None,
                utf16_len: text.len(),
            };
        }
        let mut starts = Vec::with_capacity(text.len() + 1);
        let mut unit = 0u32;
        for (byte, c) in text.char_indices() {
            starts.push((unit, byte as u32));
            unit += c.len_utf16() as u32;
        }
        starts.push((unit, text.len() as u32));
        Self {
            text,
            starts: Some(starts),
            utf16_len: unit as usize,
        }
    }

    pub fn utf16_len(&self) -> usize {
        self.utf16_len
    }

    pub fn text(&self) -> &'a str {
        self.text
    }

    /// Byte offset for a scalar-aligned UTF-16 offset.
    pub fn byte(&self, unit: usize) -> usize {
        match &self.starts {
            None => unit,
            Some(starts) => {
                let index = starts
                    .binary_search_by_key(&(unit as u32), |&(u, _)| u)
                    .expect("UTF-16 offset on a scalar boundary");
                starts[index].1 as usize
            }
        }
    }

    /// UTF-16 offset of a byte offset on a scalar boundary.
    pub fn unit(&self, byte: usize) -> usize {
        match &self.starts {
            None => byte,
            Some(starts) => {
                let index = starts
                    .binary_search_by_key(&(byte as u32), |&(_, b)| b)
                    .expect("byte offset on a scalar boundary");
                starts[index].0 as usize
            }
        }
    }

    /// `String(text[Range(NSRange(start..<end), in: text)!])`.
    pub fn slice(&self, start: usize, end: usize) -> &'a str {
        &self.text[self.byte(start)..self.byte(end)]
    }
}

pub fn utf16_len(s: &str) -> usize {
    if s.is_ascii() {
        s.len()
    } else {
        s.chars().map(char::len_utf16).sum()
    }
}
