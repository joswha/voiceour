/// The deterministic text stage between the recognizer and delivery, in the app's order: literal
/// composition, then, with cleanup enabled, cleanup and vocabulary repair.
///
/// The recognizer takes no language prompt, so the raw transcript's own words decide which rules
/// apply (`DictationLanguage.usesEnglishRules`). Another language keeps whitespace normalization,
/// repeat collapse and Glossary canonicalization, and skips the English-only rules: spoken
/// formatting commands, filler removal and phonetic repair.
public enum DictationTextStage {
    public struct Outcome: Equatable, Sendable {
        public var text: String
        public var language: DictationLanguage?
    }

    public static func apply(
        _ raw: String,
        cleanupEnabled: Bool,
        glossary: [ProtectedTerm],
        repairEngine: VocabularyRepairEngine?
    ) -> Outcome {
        let language = DictationLanguage.detect(raw)
        let englishRules = DictationLanguage.usesEnglishRules(language)
        let composed = englishRules ? LiteralComposition.apply(raw) : raw
        guard cleanupEnabled else { return Outcome(text: composed, language: language) }
        let cleaned = CleanupEngine.clean(composed, glossary: glossary, language: language)
        guard englishRules, let repairEngine else { return Outcome(text: cleaned, language: language) }
        return Outcome(text: repairEngine.repair(cleaned).text, language: language)
    }
}
