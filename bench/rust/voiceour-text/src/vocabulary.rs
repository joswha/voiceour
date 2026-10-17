//! `ProtectedTerm` (Models.swift) and `VocabularyCompiler` (Vocabulary.swift).

use serde::Deserialize;

use crate::uni;

/// `Date` as `timeIntervalSinceReferenceDate`, the default `JSONDecoder` date encoding.
pub type Date = f64;

/// `Date.distantPast.timeIntervalSinceReferenceDate`.
pub const DISTANT_PAST: Date = -63_114_076_800.0;

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub enum TermSource {
    ExplicitCorrection,
    ManualImport,
    AppProfile,
    #[default]
    Bundled,
}

impl TermSource {
    pub fn trust_rank(self) -> u8 {
        match self {
            Self::ExplicitCorrection => 3,
            Self::ManualImport => 2,
            Self::AppProfile => 1,
            Self::Bundled => 0,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CasePolicy {
    #[default]
    Exact,
    Lower,
    Title,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct AliasLabel {
    #[serde(default)]
    pub surface: String,
    #[serde(default)]
    pub confirmed_at: Option<Date>,
    #[serde(default)]
    pub rejected_at: Option<Date>,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize)]
pub struct ProtectedTerm {
    #[serde(default)]
    pub term_id: Option<String>,
    pub canonical: String,
    #[serde(default)]
    pub spoken_aliases: Vec<String>,
    #[serde(default)]
    pub case_policy: CasePolicy,
    #[serde(default = "default_true")]
    pub protected: bool,
    #[serde(default)]
    pub source: TermSource,
    #[serde(default)]
    pub labeled_aliases: Vec<AliasLabel>,
    #[serde(default)]
    pub tombstoned_at: Option<Date>,
}

impl ProtectedTerm {
    pub fn term_id(&self) -> &str {
        self.term_id.as_deref().unwrap_or(&self.canonical)
    }

    /// `renderedCanonical`.
    pub fn rendered_canonical(&self) -> String {
        match self.case_policy {
            CasePolicy::Exact => self.canonical.clone(),
            CasePolicy::Lower => uni::lowercased(&self.canonical),
            CasePolicy::Title => {
                let mut out = String::with_capacity(self.canonical.len());
                for (index, word) in uni::split_on_space(&self.canonical).into_iter().enumerate() {
                    if index > 0 {
                        out.push(' ');
                    }
                    let lower = uni::lowercased(word);
                    let first_len = uni::graphemes(&lower).next().map_or(0, str::len);
                    uni::push_uppercased(&mut out, &lower[..first_len]);
                    out.push_str(&lower[first_len..]);
                }
                out
            }
        }
    }
}

const LIMIT: usize = 100;

fn quota(source: TermSource) -> usize {
    match source {
        TermSource::ExplicitCorrection => usize::MAX,
        TermSource::ManualImport => 60,
        TermSource::AppProfile => 40,
        TermSource::Bundled => 40,
    }
}

fn is_priority(term: &ProtectedTerm) -> bool {
    term.source == TermSource::ExplicitCorrection || term.protected
}

/// Latest confirmation across the term's unrejected labels.
fn recency(term: &ProtectedTerm) -> Date {
    let mut latest = DISTANT_PAST;
    for alias in &term.labeled_aliases {
        if alias.rejected_at.is_none() {
            if let Some(confirmed) = alias.confirmed_at {
                if confirmed > latest {
                    latest = confirmed;
                }
            }
        }
    }
    latest
}

/// `VocabularyCompiler.compile(persistent:ephemeral: [], limit: 100, now:)`: the
/// per-utterance snapshot, as references into `persistent`.
pub fn compile(persistent: &[ProtectedTerm], now: Date) -> Vec<&ProtectedTerm> {
    compile_with_limit(persistent, now, LIMIT)
}

pub fn compile_with_limit(
    persistent: &[ProtectedTerm],
    now: Date,
    limit: usize,
) -> Vec<&ProtectedTerm> {
    let mut ordered: Vec<(usize, &ProtectedTerm, Date)> = persistent
        .iter()
        .enumerate()
        .filter(|(_, term)| term.tombstoned_at.is_none_or(|tombstoned| tombstoned > now))
        .map(|(index, term)| (index, term, recency(term)))
        .collect();
    ordered.sort_by(|lhs, rhs| {
        let (lt, rt) = (lhs.1.source.trust_rank(), rhs.1.source.trust_rank());
        if lt != rt {
            return rt.cmp(&lt);
        }
        if lhs.2 != rhs.2 {
            return if lhs.2 > rhs.2 {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            };
        }
        lhs.0.cmp(&rhs.0)
    });

    let mut selected: Vec<&ProtectedTerm> = Vec::with_capacity(limit.min(ordered.len()));
    let mut per_source = [0usize; 4];
    let mut deferred: Vec<&ProtectedTerm> = Vec::new();

    for &(_, term, _) in &ordered {
        if !is_priority(term) {
            continue;
        }
        if selected.len() >= limit {
            break;
        }
        selected.push(term);
    }
    for &(_, term, _) in &ordered {
        if is_priority(term) {
            continue;
        }
        if selected.len() >= limit {
            break;
        }
        let slot = term.source.trust_rank() as usize;
        if per_source[slot] < quota(term.source) {
            per_source[slot] += 1;
            selected.push(term);
        } else {
            deferred.push(term);
        }
    }
    if selected.len() < limit {
        for term in deferred {
            if selected.len() >= limit {
                break;
            }
            selected.push(term);
        }
    }
    selected
}
