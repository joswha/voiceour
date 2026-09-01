import Testing

@testable import VoiceCore

@Suite("Vocabulary repair")
struct VocabularyRepairTests {
    @Test func ordinaryIAMSpanIsRejected() {
        let engine = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["IAM"],
                ordinaryWords: ["am", "i"]
            )
        )

        #expect(engine.repair("I am denied access") == RepairOutcome(text: "I am denied access", events: []))
    }

    @Test func ordinaryHashCutSpanIsRejected() {
        let engine = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["Hashcat"],
                ordinaryWords: ["cut", "hash"]
            )
        )

        #expect(engine.repair("Throttle hash cut jobs") == RepairOutcome(text: "Throttle hash cut jobs", events: []))
    }

    @Test func multiwordLexicalAliasIsAcceptedBeforeTheOrdinarySpanGuard() {
        let engine = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["SwiftUI"],
                ordinaryWords: ["swift", "ui"]
            )
        )

        let outcome = engine.repair("Build this in swift ui today")
        #expect(outcome.text == "Build this in SwiftUI today")
        #expect(outcome.events.map(\.kind) == ["alias"])
    }

    @Test func protectedSurfaceIsUntouched() {
        let engine = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["Trust"],
                protectedSurfaces: ["Rust"],
                threshold: 0.60
            )
        )

        #expect(engine.repair("Rust") == RepairOutcome(text: "Rust", events: []))
    }

    @Test func thresholdComparisonUsesTheFrozenEpsilon() {
        let withinEpsilon = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["Hashcat"],
                threshold: 0.95 + 0.5e-12
            )
        )
        let outsideEpsilon = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["Hashcat"],
                threshold: 0.95 + 2e-12
            )
        )

        #expect(withinEpsilon.repair("hashcut").text == "Hashcat")
        #expect(outsideEpsilon.repair("hashcut").text == "hashcut")
    }

    @Test func repeatedRepairIsDeterministic() {
        let engine = VocabularyRepairEngine(
            vocabulary: vocabulary(surfaces: ["Jupyter", "Wireshark"])
        )
        let input = "Open Wirashark, then start Jupiter."

        #expect(engine.repair(input) == engine.repair(input))
    }

    @Test func emptyVocabularyIsANoOp() {
        let engine = VocabularyRepairEngine(vocabulary: vocabulary(surfaces: []))
        let input = "Leave every byte exactly as it arrived."

        #expect(engine.repair(input) == RepairOutcome(text: input, events: []))
    }

    @Test func cleanupCanOptIntoRepairAfterGlossaryCanonicalization() {
        let engine = VocabularyRepairEngine(vocabulary: vocabulary(surfaces: ["SwiftUI"]))

        #expect(
            CleanupEngine.clean("Build with swift ui", glossary: [], repairEngine: engine)
                == "Build with SwiftUI"
        )
    }

    private func vocabulary(
        surfaces: [String],
        protectedSurfaces: [String] = [],
        threshold: Double = 0.95,
        ordinaryWords: [String] = []
    ) -> RepairVocabulary {
        RepairVocabulary(
            surfaces: surfaces,
            protectedSurfaces: protectedSurfaces,
            phoneticThreshold: threshold,
            ordinaryWords: ordinaryWords,
            singleLetterWords: ["a", "i"]
        )
    }
}
