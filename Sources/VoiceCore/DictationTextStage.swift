/// The deterministic text stage between the recognizer and delivery, in the app's order: with
/// cleanup enabled, term spotting; literal composition; then, with cleanup enabled, cleanup and
/// vocabulary repair.
///
/// The recognizer takes no language prompt, so the raw transcript's own words decide which rules
/// apply (`DictationLanguage.usesEnglishRules`). Another language keeps whitespace normalization,
/// repeat collapse and Glossary canonicalization, and skips the English-only rules: term spotting,
/// spoken formatting commands, filler removal and phonetic repair.
///
/// Term spotting renders the spots `TermSpottingPolicy.frozen` accepts into the recognizer's words,
/// and only when those words joined by single spaces are the raw transcript. The later stages then
/// run on the spotted text under the raw transcript's language: it is detected once per utterance.
public enum DictationTextStage {
    public struct Outcome: Equatable, Sendable {
        public var text: String
        public var language: DictationLanguage?
    }

    public static func apply(
        _ raw: String,
        spotting: TermSpotEvidence? = nil,
        cleanupEnabled: Bool,
        glossary: [ProtectedTerm],
        repairEngine: VocabularyRepairEngine?
    ) -> Outcome {
        let language = DictationLanguage.detect(raw)
        var text = raw
        if cleanupEnabled, DictationLanguage.usesEnglishRules(language), let spotted = spotting?.render(over: raw) {
            text = spotted
        }
        return Outcome(
            text: stages(
                text, language: language, cleanupEnabled: cleanupEnabled, glossary: glossary, repairEngine: repairEngine
            ),
            language: language
        )
    }

    /// The stages after spotting — literal composition, then with cleanup enabled cleanup and
    /// repair — on `text` under `language`, the raw transcript's detected language.
    public static func stages(
        _ text: String,
        language: DictationLanguage?,
        cleanupEnabled: Bool,
        glossary: [ProtectedTerm],
        repairEngine: VocabularyRepairEngine?
    ) -> String {
        let englishRules = DictationLanguage.usesEnglishRules(language)
        let composed = englishRules ? LiteralComposition.apply(text) : text
        guard cleanupEnabled else { return composed }
        let cleaned = CleanupEngine.clean(composed, glossary: glossary, language: language)
        guard englishRules, let repairEngine else { return cleaned }
        return repairEngine.repair(cleaned).text
    }
}
