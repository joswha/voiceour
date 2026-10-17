import Foundation
import VoiceCore

/// The cleanup stage of `DictationCoordinator.processStop`
/// (Sources/Voiceour/TranscriptProcessingPipeline.swift:210-224) with
/// `settings.cleanupEnabled` at its default `true`, calling the shipped VoiceCore code.
///
/// `repairEngine(for:)` is the coordinator's `@MainActor` method (same file, :61-80), so it
/// is restated here verbatim around the public `RepairVocabulary`/`VocabularyRepairEngine`.
final class ProductionTextPath {
    private var cached: (canonicals: [String], engine: VocabularyRepairEngine)?

    func repairEngine(for activeTerms: [ProtectedTerm]) -> VocabularyRepairEngine? {
        guard !activeTerms.isEmpty else { return nil }
        let canonicals = activeTerms.map(\.canonical)
        if let cached, cached.canonicals == canonicals {
            return cached.engine
        }
        let vocabulary = RepairVocabulary.fromActiveTerms(
            activeTerms,
            ordinaryWords: RepairVocabulary.bundledOrdinaryWords
        )
        let engine = VocabularyRepairEngine(vocabulary: vocabulary)
        cached = (canonicals, engine)
        return engine
    }

    /// The timed unit: `LiteralComposition.apply`, `CleanupEngine.clean`, the cached
    /// engine's `repair`. Returns the inserted text (`deterministic`).
    @inline(never)
    func process(_ rawTranscript: String, activeTerms: [ProtectedTerm]) -> String {
        let composed = LiteralComposition.apply(rawTranscript)
        let cleaned = CleanupEngine.clean(composed, glossary: activeTerms)
        if let engine = repairEngine(for: activeTerms) {
            return engine.repair(cleaned).text
        }
        return cleaned
    }

    /// The same sequence keeping every intermediate, for parity records.
    func processStages(_ rawTranscript: String, activeTerms: [ProtectedTerm]) -> (
        composed: String, cleaned: String, outcome: RepairOutcome?
    ) {
        let composed = LiteralComposition.apply(rawTranscript)
        let cleaned = CleanupEngine.clean(composed, glossary: activeTerms)
        let outcome = repairEngine(for: activeTerms).map { $0.repair(cleaned) }
        return (composed, cleaned, outcome)
    }
}

enum Paths {
    /// The repository root, four directories above this source file's package.
    static let repoRoot: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.path
    }()

    static var ordinaryWords: String { repoRoot + "/Sources/VoiceCore/Resources/ordinary-words.txt" }
}
