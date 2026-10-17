//! `CleanupEngine` (CleanupEngine.swift): filler removal, repeat collapsing, sentence
//! case repair and glossary canonicalization.

use std::collections::HashSet;

use crate::glossary;
use crate::uni;
use crate::vocabulary::ProtectedTerm;

const FILLERS: [&str; 6] = ["um", "uh", "uhm", "erm", "mmm", "hmm"];

/// `CleanupEngine.clean(_:glossary:)` with the production `repairEngine: nil`.
pub fn clean(raw: &str, glossary: &[&ProtectedTerm]) -> String {
    let normalized = normalize(raw);
    if normalized.is_empty() {
        return String::new();
    }
    let fragile = fragile_surfaces(glossary);
    let no_fillers = remove_fillers(&normalized, glossary, &fragile);
    let deduped = collapse_adjacent_repeats(&no_fillers, &fragile);
    let recased = restore_sentence_case(&deduped, &normalized, glossary, &fragile);
    let canonical = glossary::canonicalize(&recased, glossary);
    uni::trim_whitespace_newline(&canonical).to_owned()
}

/// `replacingOccurrences(of:with:)` for a needle of `\r\n` or `\r`, as CoreFoundation
/// performs it: an occurrence followed by a non-base scalar ends inside a composed
/// character sequence and is not replaced.
fn replace_line_break(text: &str, needle: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut copied = 0;
    let mut search = 0;
    while let Some(found) = text[search..].find(needle) {
        let start = search + found;
        let end = start + needle.len();
        if text[end..].chars().next().is_some_and(uni::cf_non_base) {
            search = start + 1;
            continue;
        }
        out.push_str(&text[copied..start]);
        out.push('\n');
        copied = end;
        search = end;
    }
    out.push_str(&text[copied..]);
    out
}

/// `CleanupEngine.normalize(_:)`.
pub fn normalize(raw: &str) -> String {
    let crlf = if raw.contains('\r') {
        replace_line_break(raw, "\r\n")
    } else {
        raw.to_owned()
    };
    let lf = if crlf.contains('\r') {
        replace_line_break(&crlf, "\r")
    } else {
        crlf
    };
    let mut out = String::with_capacity(lf.len());
    for component in lf
        .split(uni::fd_whitespace_newline)
        .filter(|component| !component.is_empty())
    {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(component);
    }
    uni::trim_whitespace_newline(&out).to_owned()
}

fn is_filler(stripped: &str) -> bool {
    FILLERS.iter().any(|filler| uni::canon_eq(stripped, filler))
}

/// `strippedToken`: trims punctuation and symbols, then lowercases.
fn stripped_token(token: &str) -> String {
    uni::lowercased(token.trim_matches(|c| uni::fd_punctuation(c) || uni::fd_symbol(c)))
}

fn remove_fillers(text: &str, glossary: &[&ProtectedTerm], fragile: &[Vec<String>]) -> String {
    let tokens = uni::split_on_space(text);
    let sheltered = sheltered_indices(&tokens, fragile);
    let mut out = String::with_capacity(text.len());
    let mut first = true;
    for (index, value) in tokens.iter().enumerate() {
        let keep = sheltered.contains(&index)
            || should_skip_token(value, glossary)
            || !is_filler(&stripped_token(value));
        if keep {
            if !first {
                out.push(' ');
            }
            out.push_str(value);
            first = false;
        }
    }
    out
}

/// Glossary surfaces the deletion passes would themselves damage, tokenized.
fn fragile_surfaces(glossary: &[&ProtectedTerm]) -> Vec<Vec<String>> {
    let mut fragile = Vec::new();
    for term in glossary {
        for surface in std::iter::once(term.canonical.clone()).chain(glossary::user_aliases(term)) {
            let normalized = normalize(&surface);
            if !uni::contains_char(&normalized, " ") {
                continue;
            }
            if uni::canon_eq(&remove_fillers(&normalized, &[], &[]), &normalized)
                && uni::canon_eq(&collapse_adjacent_repeats(&normalized, &[]), &normalized)
            {
                continue;
            }
            let words: Vec<String> = uni::split_on_space(&normalized)
                .into_iter()
                .map(stripped_token)
                .collect();
            if words.iter().any(String::is_empty) {
                continue;
            }
            fragile.push(words);
        }
    }
    fragile
}

/// Token positions covered by an occurrence of a fragile surface.
fn sheltered_indices(tokens: &[&str], fragile: &[Vec<String>]) -> HashSet<usize> {
    let mut sheltered = HashSet::new();
    if fragile.is_empty() {
        return sheltered;
    }
    let haystack: Vec<String> = tokens.iter().map(|token| stripped_token(token)).collect();
    for words in fragile {
        if haystack.len() < words.len() {
            continue;
        }
        for start in 0..=(haystack.len() - words.len()) {
            if haystack[start..start + words.len()]
                .iter()
                .zip(words)
                .all(|(a, b)| uni::canon_eq(a, b))
            {
                sheltered.extend(start..start + words.len());
            }
        }
    }
    sheltered
}

fn collapse_adjacent_repeats(text: &str, fragile: &[Vec<String>]) -> String {
    let pieces = uni::split_on_space(text);
    let sheltered = sheltered_indices(&pieces, fragile);
    let mut result: Vec<&str> = Vec::with_capacity(pieces.len());
    let mut index = 0;

    while index < pieces.len() {
        let maximum_length = 4.min((pieces.len() - index) / 2);
        let mut repeated_length = None;
        for length in (1..=maximum_length).rev() {
            if (index..index + 2 * length).any(|position| sheltered.contains(&position)) {
                continue;
            }
            let first: Vec<String> = pieces[index..index + length]
                .iter()
                .map(|token| normalized_repeat_token(token, length))
                .collect();
            if first.iter().any(String::is_empty) {
                continue;
            }
            let second = pieces[index + length..index + 2 * length]
                .iter()
                .map(|token| normalized_repeat_token(token, length));
            if first.iter().zip(second).all(|(a, b)| uni::canon_eq(a, &b)) {
                repeated_length = Some(length);
                break;
            }
        }
        match repeated_length {
            Some(length) => {
                result.extend_from_slice(&pieces[index + length..index + 2 * length]);
                index += 2 * length;
            }
            None => {
                result.push(pieces[index]);
                index += 1;
            }
        }
    }
    result.join(" ")
}

fn normalized_repeat_token(token: &str, phrase_length: usize) -> String {
    if phrase_length <= 1 {
        let mut normalized = uni::lowercased(token);
        // `while normalized.last == "," || normalized.last == "."`: Character-wise.
        loop {
            let cut = match uni::graphemes(&normalized).last() {
                Some(g) if uni::ch_is(g, ",") || uni::ch_is(g, ".") => normalized.len() - g.len(),
                _ => break,
            };
            normalized.truncate(cut);
        }
        return normalized;
    }
    let mut stripped = String::with_capacity(token.len());
    for piece in token.split(uni::fd_punctuation) {
        stripped.push_str(piece);
    }
    uni::lowercased(&stripped)
}

fn should_skip_token(token: &str, glossary: &[&ProtectedTerm]) -> bool {
    if uni::has_prefix(token, "-") {
        return true;
    }
    if uni::contains_char(token, "/")
        || uni::contains_char(token, "~")
        || uni::contains_char(token, "_")
    {
        return true;
    }
    if token.chars().any(uni::fd_decimal_digit) {
        return true;
    }
    if has_internal_capital(token) {
        return true;
    }
    let stripped = stripped_token(token);
    for term in glossary {
        // Both alias stores count, as in Swift: `[canonical] + userAliases(for:)`.
        if uni::canon_eq(&uni::lowercased(&term.canonical), &stripped) {
            return true;
        }
        if glossary::user_aliases(term)
            .iter()
            .any(|surface| uni::canon_eq(&uni::lowercased(surface), &stripped))
        {
            return true;
        }
    }
    false
}

fn has_internal_capital(token: &str) -> bool {
    let mut characters = uni::graphemes(token);
    if characters.next().is_none() {
        return false;
    }
    characters.any(uni::ch_is_uppercase)
}

fn ends_sentence(token: &str) -> bool {
    match uni::graphemes(token)
        .filter(|g| !uni::ch_is_whitespace(g))
        .last()
    {
        Some(last) => uni::ch_is(last, ".") || uni::ch_is(last, "?") || uni::ch_is(last, "!"),
        None => false,
    }
}

fn sentence_opener<'a>(index: usize, source: &[&'a str]) -> Option<&'a str> {
    let mut start = index;
    while start > 0 && !ends_sentence(source[start - 1]) {
        start -= 1;
    }
    source.get(start).copied()
}

fn starts_capitalized(token: Option<&str>) -> bool {
    token
        .and_then(|token| uni::graphemes(token).find(|g| uni::ch_is_letter(g)))
        .is_some_and(uni::ch_is_uppercase)
}

fn capitalizing_first_letter(token: &str) -> String {
    match uni::grapheme_indices(token).find(|(_, g)| uni::ch_is_letter(g)) {
        None => token.to_owned(),
        Some((position, letter)) => {
            let mut out = String::with_capacity(token.len() + 4);
            out.push_str(&token[..position]);
            uni::push_uppercased(&mut out, letter);
            out.push_str(&token[position + letter.len()..]);
            out
        }
    }
}

/// Re-capitalizes a word that a deletion pass promoted to the start of a sentence.
fn restore_sentence_case(
    text: &str,
    original: &str,
    glossary: &[&ProtectedTerm],
    fragile: &[Vec<String>],
) -> String {
    let mut tokens: Vec<String> = uni::split_on_space(text)
        .into_iter()
        .map(str::to_owned)
        .collect();
    if tokens.is_empty() {
        return text.to_owned();
    }
    let source = uni::split_on_space(original);
    let token_refs: Vec<&str> = tokens.iter().map(String::as_str).collect();
    let sheltered = sheltered_indices(&token_refs, fragile);

    let mut source_index = 0;
    for index in 0..tokens.len() {
        while source_index < source.len() && !uni::canon_eq(source[source_index], &tokens[index]) {
            source_index += 1;
        }
        if source_index >= source.len() {
            break;
        }
        let origin = source_index;
        source_index += 1;

        let initial_now = index == 0 || ends_sentence(&tokens[index - 1]);
        let initial_before = origin == 0 || ends_sentence(source[origin - 1]);
        if !initial_now || initial_before || sheltered.contains(&index) {
            continue;
        }
        if !starts_capitalized(sentence_opener(origin, &source)) {
            continue;
        }
        let token = &tokens[index];
        if should_skip_token(token, glossary) {
            continue;
        }
        if !uni::graphemes(token).any(uni::ch_is_lowercase)
            || uni::graphemes(token).any(uni::ch_is_uppercase)
        {
            continue;
        }
        tokens[index] = capitalizing_first_letter(token);
    }
    tokens.join(" ")
}
