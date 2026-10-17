//! `Glossary` (Glossary.swift): alias derivation and canonicalization.

use std::collections::HashSet;

use crate::icu::{self, AliasMatcher};
use crate::uni;
use crate::vocabulary::ProtectedTerm;

/// `aliasKey`: trimmed, lowercased.
pub fn alias_key(value: &str) -> String {
    uni::lowercased(uni::trim_whitespace_newline(value))
}

/// A `Set<String>`: membership by canonical equivalence.
#[derive(Default)]
pub struct StringSet(HashSet<String>);

impl StringSet {
    pub fn insert(&mut self, value: &str) -> bool {
        let key = uni::canon_key(value);
        if self.0.contains(key.as_ref()) {
            return false;
        }
        self.0.insert(key.into_owned());
        true
    }

    pub fn contains(&self, value: &str) -> bool {
        self.0.contains(uni::canon_key(value).as_ref())
    }
}

/// `canonicalTokens(in:)`.
pub fn canonical_tokens(canonical: &str) -> Vec<String> {
    let tokenized = icu::canonical_token_boundaries(canonical);
    uni::split_on_whitespace(&tokenized)
        .into_iter()
        .map(str::to_owned)
        .collect()
}

/// `Glossary.derivedAliases(for:)`.
pub fn derived_aliases(canonical: &str) -> Vec<String> {
    let tokens = canonical_tokens(canonical);
    if tokens.len() < 2 {
        return Vec::new();
    }
    let spaced = uni::lowercased(&tokens.join(" "));
    let letter_spaced = tokens
        .iter()
        .map(|token| {
            if uni::grapheme_count(token) >= 2 && uni::graphemes(token).all(uni::ch_is_uppercase) {
                uni::lowercased(&uni::graphemes(token).collect::<Vec<_>>().join(" "))
            } else {
                uni::lowercased(token)
            }
        })
        .collect::<Vec<_>>()
        .join(" ");

    let canonical_key = uni::lowercased(canonical);
    let mut seen = StringSet::default();
    [spaced, letter_spaced]
        .into_iter()
        .filter(|alias| {
            let key = uni::lowercased(alias);
            !uni::canon_eq(&key, &canonical_key) && seen.insert(&key)
        })
        .collect()
}

/// `Glossary.userAliases(for:)`.
pub fn user_aliases(term: &ProtectedTerm) -> Vec<String> {
    let canonical_key = alias_key(&term.canonical);
    let labeled = term
        .labeled_aliases
        .iter()
        .filter(|label| label.rejected_at.is_none())
        .map(|label| &label.surface);
    let mut aliases = Vec::new();
    let mut seen = StringSet::default();
    for alias in term.spoken_aliases.iter().chain(labeled) {
        let trimmed = uni::trim_whitespace_newline(alias);
        if trimmed.is_empty() {
            continue;
        }
        let key = alias_key(alias);
        if uni::canon_eq(&key, &canonical_key) || !seen.insert(&key) {
            continue;
        }
        aliases.push(trimmed.to_owned());
    }
    aliases
}

/// `Glossary.aliasCanGeneralize(_:canonical:)`.
pub fn alias_can_generalize(alias: &str, canonical: &str) -> bool {
    let trimmed_alias = uni::trim_whitespace_newline(alias);
    if uni::grapheme_count(trimmed_alias) <= 1 {
        return false;
    }
    let trimmed_canonical = uni::trim_whitespace_newline(canonical);
    if !trimmed_canonical.is_empty() && uni::graphemes(trimmed_canonical).all(uni::ch_is_number) {
        return false;
    }
    true
}

/// `Glossary.generalizableAliases(for:)`.
pub fn generalizable_aliases(term: &ProtectedTerm) -> Vec<String> {
    let mut aliases = user_aliases(term);
    aliases.extend(derived_aliases(&term.canonical));
    aliases.retain(|alias| alias_can_generalize(alias, &term.canonical));
    aliases
}

/// `Glossary.matchingAliases(for:)`: canonical first, de-duplicated by key, then
/// longest (in Characters) first with the original order breaking ties.
pub fn matching_aliases(term: &ProtectedTerm) -> Vec<String> {
    let mut aliases: Vec<String> = Vec::new();
    let mut seen = StringSet::default();
    for alias in std::iter::once(term.canonical.clone()).chain(generalizable_aliases(term)) {
        let trimmed = uni::trim_whitespace_newline(&alias);
        if trimmed.is_empty() {
            continue;
        }
        if seen.insert(&alias_key(&alias)) {
            aliases.push(trimmed.to_owned());
        }
    }
    let mut keyed: Vec<(usize, String)> = aliases
        .into_iter()
        .map(|alias| (uni::grapheme_count(&alias), alias))
        .collect();
    // Stable: equal lengths keep their original order, as the offset tie-break does.
    keyed.sort_by(|lhs, rhs| rhs.0.cmp(&lhs.0));
    keyed.into_iter().map(|(_, alias)| alias).collect()
}

struct Replacement {
    /// UTF-16 location and length, as `NSRange`.
    location: usize,
    length: usize,
    template: usize,
    discovery: usize,
}

/// `Glossary.canonicalize(_:terms:)`.
pub fn canonicalize(text: &str, terms: &[&ProtectedTerm]) -> String {
    let index = uni::Utf16Index::new(text);
    let mut replacements: Vec<Replacement> = Vec::new();
    let mut templates: Vec<String> = Vec::with_capacity(terms.len());
    let mut spans = Vec::new();

    // Every match comes from the original text, so a replacement can never trigger
    // another rule in the same pass.
    for term in terms {
        templates.push(term.rendered_canonical());
        let template = templates.len() - 1;
        for alias in matching_aliases(term) {
            let matcher = AliasMatcher::new(&alias);
            if matcher.is_empty() {
                continue;
            }
            spans.clear();
            matcher.find_all(text, &mut spans);
            for &(start, end) in &spans {
                let location = index.unit(start);
                let discovery = replacements.len();
                replacements.push(Replacement {
                    location,
                    length: index.unit(end) - location,
                    template,
                    discovery,
                });
            }
        }
    }

    // Longest original span, then leftmost, then discovery order.
    replacements.sort_by(|lhs, rhs| {
        rhs.length
            .cmp(&lhs.length)
            .then(lhs.location.cmp(&rhs.location))
            .then(lhs.discovery.cmp(&rhs.discovery))
    });
    let mut accepted: Vec<&Replacement> = Vec::new();
    for replacement in &replacements {
        let overlaps = accepted.iter().any(|other| {
            replacement.location < other.location + other.length
                && other.location < replacement.location + replacement.length
        });
        if !overlaps {
            accepted.push(replacement);
        }
    }
    accepted.sort_by(|lhs, rhs| rhs.location.cmp(&lhs.location));

    // Splice right to left; offsets to the left of each splice are unchanged.
    let mut result = text.to_owned();
    for replacement in accepted {
        let start = index.byte(replacement.location);
        let end = index.byte(replacement.location + replacement.length);
        result.replace_range(start..end, &templates[replacement.template]);
    }
    result
}
