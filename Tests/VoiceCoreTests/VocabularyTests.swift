import Foundation
import Testing

@testable import VoiceCore

@Suite("ProtectedTerm back-compat")
struct ProtectedTermCodableTests {
    @Test func decodesLegacyJSONWithoutNewKeys() throws {
        let legacy = """
            {"canonical":"NSPasteboard","spoken_aliases":["n s pasteboard","ns paste board"],"case_policy":"exact","protected":true}
            """
        let term = try JSONDecoder().decode(ProtectedTerm.self, from: Data(legacy.utf8))

        #expect(term.canonical == "NSPasteboard")
        #expect(term.termId == "NSPasteboard")
        #expect(term.id == "NSPasteboard")
        #expect(term.spokenAliases == ["n s pasteboard", "ns paste board"])
        #expect(term.source == .bundled)
        #expect(term.labeledAliases.isEmpty)
        #expect(term.tombstonedAt == nil)
    }

    @Test func decodesSparseLegacyJSON() throws {
        let sparse = """
            {"canonical":"kubectl","spoken_aliases":["cube cuddle"]}
            """
        let term = try JSONDecoder().decode(ProtectedTerm.self, from: Data(sparse.utf8))

        #expect(term.termId == "kubectl")
        #expect(term.casePolicy == .exact)
        #expect(term.protected)
    }

    @Test func roundTripsNewFields() throws {
        let original = ProtectedTerm(
            canonical: "NSPasteboard",
            spokenAliases: ["ns paste board"],
            termId: "term-1",
            source: .explicitCorrection,
            labeledAliases: [AliasLabel(surface: "ns paste board", confirmedAt: Date(timeIntervalSince1970: 100))]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProtectedTerm.self, from: data)

        #expect(decoded == original)
    }
}

@Suite("VocabularyCompiler")
struct VocabularyCompilerTests {
    private func term(
        _ canonical: String,
        source: TermSource = .bundled,
        protected: Bool = false,
        tombstonedAt: Date? = nil
    ) -> ProtectedTerm {
        ProtectedTerm(
            canonical: canonical,
            spokenAliases: [],
            protected: protected,
            source: source,
            tombstonedAt: tombstonedAt
        )
    }

    @Test func excludesTombstonedTerms() {
        let terms = [
            term("Alive"),
            term("Dead", tombstonedAt: Date(timeIntervalSince1970: 10)),
        ]
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: []
        )
        #expect(snapshot.terms.map(\.canonical) == ["Alive"])
    }

    /// The two rules compose in the right order: a tombstoned term is gone even
    /// when its source outranks a live one, so trust cannot resurrect it.
    @Test func tombstonedTermsAreDroppedRegardlessOfTrust() {
        let terms = [
            term("bundled", source: .bundled),
            term("explicit", source: .explicitCorrection),
            term("dead", source: .manualImport, tombstonedAt: Date(timeIntervalSince1970: 1)),
        ]
        let snapshot = VocabularyCompiler.compile(persistent: terms, ephemeral: [])
        #expect(snapshot.terms.map(\.canonical) == ["explicit", "bundled"])
    }

    @Test func ordersByTrustThenRecency() {
        let terms = [
            term("bundled", source: .bundled),
            term("explicit", source: .explicitCorrection),
            term("manual", source: .manualImport),
            term("profile", source: .appProfile),
        ]
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: []
        )
        #expect(snapshot.terms.map(\.canonical) == ["explicit", "manual", "profile", "bundled"])
    }

    @Test func capsToLimitReservingPriority() {
        var terms = [term("pinned", protected: true)]
        for index in 0..<10 {
            terms.append(term("t\(index)", source: .bundled, protected: false))
        }
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: [],
            limit: 3
        )
        #expect(snapshot.terms.count == 3)
        #expect(snapshot.terms.contains { $0.canonical == "pinned" })
    }

    @Test func explicitCorrectionSurvivesLimitPressure() {
        var terms: [ProtectedTerm] = []
        for index in 0..<10 {
            terms.append(term("b\(index)", source: .bundled, protected: false))
        }
        terms.append(term("correction", source: .explicitCorrection, protected: false))
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: [],
            limit: 2
        )
        #expect(snapshot.terms.contains { $0.canonical == "correction" })
    }

    @Test func hardCapsPriorityTermsInTrustOrder() {
        let terms = (0..<150).map { index in
            let source: TermSource =
                switch index % 3 {
                case 0: .explicitCorrection
                case 1: .manualImport
                default: .bundled
                }
            return term("term-\(index)", source: source, protected: true)
        }
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: [],
            limit: 100
        )
        let expectedIDs =
            terms.filter { $0.source == .explicitCorrection }.map(\.termId)
            + terms.filter { $0.source == .manualImport }.map(\.termId)

        #expect(snapshot.terms.count == 100)
        #expect(snapshot.terms.map(\.termId) == expectedIDs)
    }

    @Test func futureDatedTombstonesRemainActiveUntilTheirDate() {
        let now = Date(timeIntervalSince1970: 100)
        let terms = [
            term("alive"),
            term("future", tombstonedAt: Date(timeIntervalSince1970: 101)),
            term("expired", tombstonedAt: now),
        ]
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: [],
            now: now
        )

        #expect(snapshot.terms.map(\.canonical) == ["alive", "future"])
    }

    /// Ephemeral candidates bypass the term budget entirely: they are live context
    /// for one utterance, not persisted authority, so a glossary large enough to
    /// exhaust the budget must not crowd them out.
    @Test func passesEphemeralCandidatesThroughUntouched() {
        let candidates = [
            EphemeralContextCandidate(id: "e1", surface: "Zephyr"),
            EphemeralContextCandidate(id: "e2", surface: "Nimbus"),
        ]
        let snapshot = VocabularyCompiler.compile(
            persistent: [term("cloudy")],
            ephemeral: candidates,
            limit: 0
        )
        #expect(snapshot.terms.isEmpty)
        #expect(snapshot.ephemeral == candidates)
    }

    @Test func isDeterministic() {
        let terms = [
            term("a", source: .bundled),
            term("b", source: .manualImport),
            term("c", source: .explicitCorrection),
        ]
        let now = Date(timeIntervalSince1970: 42)
        let first = VocabularyCompiler.compile(persistent: terms, ephemeral: [], now: now)
        let second = VocabularyCompiler.compile(persistent: terms, ephemeral: [], now: now)
        #expect(first == second)
    }
}

@Suite("VocabularySanitizer")
struct VocabularySanitizerTests {
    @Test func acceptsPlainText() {
        #expect(VocabularySanitizer.isSafe("NSPasteboard"))
        #expect(VocabularySanitizer.sanitize("NSPasteboard") == "NSPasteboard")
    }

    @Test func rejectsBidiControls() {
        let bidi = "safe\u{202E}evil"
        #expect(!VocabularySanitizer.isSafe(bidi))
        #expect(VocabularySanitizer.sanitize(bidi) == "safeevil")
    }

    @Test func rejectsC0AndC1Controls() {
        #expect(!VocabularySanitizer.isSafe("a\u{0007}b"))
        #expect(!VocabularySanitizer.isSafe("a\u{0085}b"))
        #expect(VocabularySanitizer.sanitize("a\u{0007}b") == "ab")
    }

    @Test func rejectsDefaultIgnorable() {
        let zwsp = "in\u{200B}visible"
        #expect(!VocabularySanitizer.isSafe(zwsp))
        #expect(VocabularySanitizer.sanitize(zwsp) == "invisible")
    }

    @Test func rejectsPromptDelimiterRuns() {
        let delimited = "ignore <system prompt> now"
        #expect(!VocabularySanitizer.isSafe(delimited))
        #expect(VocabularySanitizer.sanitize(delimited) == "ignore  now")

        let backticked = "run `rm -rf` please"
        #expect(!VocabularySanitizer.isSafe(backticked))
        #expect(VocabularySanitizer.sanitize(backticked) == "run rm -rf please")
    }

    @Test func returnsNilWhenNothingRemains() {
        #expect(VocabularySanitizer.sanitize("\u{202E}\u{200B}") == nil)
        #expect(VocabularySanitizer.sanitize("<>") == nil)
        #expect(VocabularySanitizer.sanitize("   ") == nil)
    }
}

@Suite("Glossary labeled aliases")
struct GlossaryVocabularyTests {
    @Test func labeledAliasParticipatesOnlyWhenNotRejected() {
        let confirmed = ProtectedTerm(
            canonical: "kubectl",
            spokenAliases: [],
            labeledAliases: [AliasLabel(surface: "cube control", confirmedAt: Date(timeIntervalSince1970: 5))]
        )
        #expect(Glossary.canonicalize("run cube control now", terms: [confirmed]) == "run kubectl now")

        let rejected = ProtectedTerm(
            canonical: "kubectl",
            spokenAliases: [],
            labeledAliases: [AliasLabel(surface: "cube control", rejectedAt: Date(timeIntervalSince1970: 5))]
        )
        #expect(Glossary.canonicalize("run cube control now", terms: [rejected]) == "run cube control now")
    }

    @Test func mutationHelpersSetTimestampsExplicitly() {
        let base = ProtectedTerm(canonical: "kubectl", spokenAliases: [])
        #expect(base.labeledAliases.isEmpty)

        let confirmed = TermMutation.confirmingAlias("cube control", on: base, at: Date(timeIntervalSince1970: 7))
        #expect(confirmed.labeledAliases.first?.confirmedAt == Date(timeIntervalSince1970: 7))
        #expect(confirmed.labeledAliases.first?.surface == "cube control")
        #expect(confirmed.labeledAliases.first?.rejectedAt == nil)

        let rejected = TermMutation.rejectingAlias("cube control", on: confirmed, at: Date(timeIntervalSince1970: 8))
        #expect(rejected.labeledAliases.first?.rejectedAt == Date(timeIntervalSince1970: 8))
        #expect(rejected.labeledAliases.first?.confirmedAt == nil)
    }

    @Test func aliasMutationTransitionsAreCaseInsensitiveAndConflictFree() throws {
        let initiallyRejectedAt = Date(timeIntervalSince1970: 6)
        let confirmedAt = Date(timeIntervalSince1970: 7)
        let rejectedAgainAt = Date(timeIntervalSince1970: 8)
        let base = ProtectedTerm(
            canonical: "kubectl",
            spokenAliases: [],
            labeledAliases: [AliasLabel(surface: "Cube Control", rejectedAt: initiallyRejectedAt)]
        )

        let confirmed = TermMutation.confirmingAlias("CUBE CONTROL", on: base, at: confirmedAt)
        try #require(confirmed.labeledAliases.count == 1)
        let confirmedLabel = confirmed.labeledAliases[0]
        #expect(confirmedLabel.surface == "Cube Control")
        #expect(confirmedLabel.confirmedAt == confirmedAt)
        #expect(confirmedLabel.rejectedAt == nil)

        let rejectedAgain = TermMutation.rejectingAlias("cube control", on: confirmed, at: rejectedAgainAt)
        try #require(rejectedAgain.labeledAliases.count == 1)
        let rejectedLabel = rejectedAgain.labeledAliases[0]
        #expect(rejectedLabel.surface == confirmedLabel.surface)
        #expect(rejectedLabel.confirmedAt == nil)
        #expect(rejectedLabel.rejectedAt == rejectedAgainAt)
    }
}
