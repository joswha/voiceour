import Testing

@testable import VoiceCore

@Suite("Vocabulary repair")
struct VocabularyRepairTests {
    @Test func activeTermsUseTheFrozenRiskPartition() {
        let activeTerms = [
            ProtectedTerm(canonical: "Rust", spokenAliases: []),
            ProtectedTerm(canonical: "Go", spokenAliases: []),
            ProtectedTerm(canonical: "semaphore", spokenAliases: []),
            ProtectedTerm(canonical: "kubectl", spokenAliases: []),
            ProtectedTerm(canonical: "SwiftUI", spokenAliases: []),
            ProtectedTerm(canonical: "a", spokenAliases: []),
            ProtectedTerm(canonical: "i", spokenAliases: []),
        ]
        let ordinaryWords: Set<String> = ["rust", "semaphore"]

        let vocabulary = RepairVocabulary.fromActiveTerms(
            activeTerms,
            ordinaryWords: ordinaryWords
        )

        #expect(vocabulary.surfaces == ["kubectl", "SwiftUI"])
        #expect(vocabulary.protectedSurfaces == ["Rust", "Go", "semaphore", "a", "i"])
        #expect(vocabulary.phoneticThreshold == 0.95)
        #expect(Set(vocabulary.ordinaryWords) == ordinaryWords)
        #expect(vocabulary.singleLetterWords == ["a", "i"])
    }

    @Test func bundledOrdinaryWordsComeFromTheFrozenVocabulary() {
        #expect(
            RepairVocabulary.bundledOrdinaryWords.isSuperset(
                of: ["rust", "semaphore", "a", "i"]
            )
        )
    }

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

    @Test func exactCasedLongerAliasSupersedesProtectedPrefix() {
        let engine = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["SwiftUI"],
                protectedSurfaces: ["Swift"]
            )
        )

        #expect(engine.repair("Build the panel with Swift UI.").text == "Build the panel with SwiftUI.")
    }

    @Test func ordinaryPhraseDoesNotSupersedeProtectedInitial() {
        let engine = VocabularyRepairEngine(
            vocabulary: vocabulary(
                surfaces: ["IAM"],
                protectedSurfaces: ["I"]
            )
        )

        #expect(engine.repair("I am ready.").text == "I am ready.")
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
