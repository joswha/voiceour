//! The cleanup stage of `DictationCoordinator.processStop`
//! (TranscriptProcessingPipeline.swift), with `settings.cleanupEnabled` at its default.

use std::borrow::Cow;

use crate::cleanup;
use crate::literal;
use crate::repair::OrdinaryWords;
use crate::repair::{RepairOutcome, RepairVocabulary, VocabularyRepairEngine};
use crate::uni;
use crate::vocabulary::ProtectedTerm;

/// The coordinator's `cachedVocabularyRepairEngine`.
pub struct Pipeline<'w> {
    ordinary_words: &'w OrdinaryWords,
    cache: Option<(Vec<String>, VocabularyRepairEngine<'w>)>,
}

pub struct Processed<'r> {
    pub composed: Cow<'r, str>,
    pub cleaned: String,
    pub repaired: Option<RepairOutcome>,
}

impl Processed<'_> {
    /// `deterministic`: the text that is inserted.
    pub fn text(&self) -> &str {
        self.repaired
            .as_ref()
            .map_or(&self.cleaned, |outcome| &outcome.text)
    }
}

impl<'w> Pipeline<'w> {
    pub fn new(ordinary_words: &'w OrdinaryWords) -> Self {
        Self {
            ordinary_words,
            cache: None,
        }
    }

    /// Builds the engine as a cache miss does.
    pub fn build_engine(
        active_terms: &[&ProtectedTerm],
        ordinary_words: &'w OrdinaryWords,
    ) -> VocabularyRepairEngine<'w> {
        VocabularyRepairEngine::new(&RepairVocabulary::from_active_terms(
            active_terms,
            ordinary_words,
        ))
    }

    /// `repairEngine(for:)`: reused while the active canonicals are unchanged.
    pub fn repair_engine(
        &mut self,
        active_terms: &[&ProtectedTerm],
    ) -> Option<&VocabularyRepairEngine<'w>> {
        if active_terms.is_empty() {
            return None;
        }
        let hit = self.cache.as_ref().is_some_and(|(canonicals, _)| {
            canonicals.len() == active_terms.len()
                && canonicals
                    .iter()
                    .zip(active_terms)
                    .all(|(cached, term)| uni::canon_eq(cached, &term.canonical))
        });
        if !hit {
            let canonicals = active_terms
                .iter()
                .map(|term| term.canonical.clone())
                .collect();
            self.cache = Some((
                canonicals,
                Self::build_engine(active_terms, self.ordinary_words),
            ));
        }
        self.cache.as_ref().map(|(_, engine)| engine)
    }

    /// `LiteralComposition.apply`, `CleanupEngine.clean`, then the cached engine's repair.
    pub fn process<'r>(&mut self, raw: &'r str, active_terms: &[&ProtectedTerm]) -> Processed<'r> {
        let composed = literal::apply(raw);
        let cleaned = cleanup::clean(&composed, active_terms);
        let repaired = self
            .repair_engine(active_terms)
            .map(|engine| engine.repair(&cleaned));
        Processed {
            composed,
            cleaned,
            repaired,
        }
    }

    /// The same call sequence returning only the inserted text: intermediates are
    /// dropped inside the call, as Swift releases them inside the timed region.
    pub fn process_text(&mut self, raw: &str, active_terms: &[&ProtectedTerm]) -> String {
        let composed = literal::apply(raw);
        let cleaned = cleanup::clean(&composed, active_terms);
        drop(composed);
        match self.repair_engine(active_terms) {
            Some(engine) => engine.repair(&cleaned).text,
            None => cleaned,
        }
    }
}
