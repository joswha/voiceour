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
/// and only when those words joined by single spaces are the raw transcript. The rest of the stage
/// then runs on the spotted text exactly as on a raw transcript, which is the path wave 2 measured.
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
        if cleanupEnabled, DictationLanguage.usesEnglishRules(language),
            let spotted = spotting?.render(over: raw)
        {
            return apply(spotted, cleanupEnabled: cleanupEnabled, glossary: glossary, repairEngine: repairEngine)
        }
        let englishRules = DictationLanguage.usesEnglishRules(language)
        let composed = englishRules ? LiteralComposition.apply(raw) : raw
        guard cleanupEnabled else { return Outcome(text: composed, language: language) }
        let cleaned = CleanupEngine.clean(composed, glossary: glossary, language: language)
        guard englishRules, let repairEngine else { return Outcome(text: cleaned, language: language) }
        return Outcome(text: repairEngine.repair(cleaned).text, language: language)
    }
}
