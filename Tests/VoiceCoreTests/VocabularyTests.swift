import Foundation
import Testing

@testable import VoiceCore

@Suite("ProtectedTerm back-compat")
struct ProtectedTermCodableTests {
    @Test func decodesLegacyJSONWithoutNewKeys() throws {
        let legacy = """
            {"canonical":"OMPi","spoken_aliases":["oh m pi","om pi"],"case_policy":"exact","protected":true}
            """
        let term = try JSONDecoder().decode(ProtectedTerm.self, from: Data(legacy.utf8))

        #expect(term.canonical == "OMPi")
        #expect(term.termId == "OMPi")
        #expect(term.id == "OMPi")
        #expect(term.spokenAliases == ["oh m pi", "om pi"])
        #expect(term.source == .bundled)
        #expect(term.scope == .global)
        #expect(term.cloudEligible)
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
            scope: .bundleID("com.example.app"),
            cloudEligible: false,
            labeledAliases: [AliasLabel(surface: "ns paste board", confirmedAt: Date(timeIntervalSince1970: 100))]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProtectedTerm.self, from: data)

        #expect(decoded == original)
    }

    @Test func defaultGlossaryUsesCanonicalAsTermId() {
        for term in Settings.defaultGlossary {
            #expect(term.termId == term.canonical)
            #expect(term.source == .bundled)
            #expect(term.scope == .global)
        }
    }
}

@Suite("VocabularyCompiler")
struct VocabularyCompilerTests {
    private func term(
        _ canonical: String,
        source: TermSource = .bundled,
        scope: VocabularyScope = .global,
        protected: Bool = false,
        tombstonedAt: Date? = nil
    ) -> ProtectedTerm {
        ProtectedTerm(
            canonical: canonical,
            spokenAliases: [],
            protected: protected,
            source: source,
            scope: scope,
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
            ephemeral: [],
            capturedBundleId: nil,
            activeProjectId: nil
        )
        #expect(snapshot.terms.map(\.canonical) == ["Alive"])
    }

    @Test func activatesGlobalAndMatchingScopes() {
        let terms = [
            term("G", scope: .global),
            term("A", scope: .bundleID("com.a")),
            term("B", scope: .bundleID("com.b")),
            term("P", scope: .projectID("proj-1")),
            term("Q", scope: .projectID("proj-2")),
        ]
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: [],
            capturedBundleId: "com.a",
            activeProjectId: "proj-1"
        )
        #expect(Set(snapshot.terms.map(\.canonical)) == Set(["G", "A", "P"]))
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
            ephemeral: [],
            capturedBundleId: nil,
            activeProjectId: nil
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
            capturedBundleId: nil,
            activeProjectId: nil,
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
            capturedBundleId: nil,
            activeProjectId: nil,
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
            capturedBundleId: nil,
            activeProjectId: nil,
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
            capturedBundleId: nil,
            activeProjectId: nil,
            now: now
        )

        #expect(snapshot.terms.map(\.canonical) == ["alive", "future"])
        #expect(Glossary.activeTerms(terms, now: now).map(\.canonical) == ["alive", "future"])
    }

    @Test func passesEphemeralThroughAndComputesCloudEligible() {
        let candidate = EphemeralContextCandidate(id: "e1", surface: "Zephyr")
        let terms = [
            term("cloudy"),
            {
                var t = term("local")
                t.cloudEligible = false
                return t
            }(),
        ]
        let snapshot = VocabularyCompiler.compile(
            persistent: terms,
            ephemeral: [candidate],
            capturedBundleId: "com.a",
            activeProjectId: nil
        )
        #expect(snapshot.ephemeral == [candidate])
        #expect(snapshot.capturedBundleId == "com.a")
        #expect(snapshot.terms.filter(\.cloudEligible).map(\.canonical) == ["cloudy"])
    }

    @Test func isDeterministic() {
        let terms = [
            term("a", source: .bundled),
            term("b", source: .manualImport),
            term("c", source: .explicitCorrection),
        ]
        let now = Date(timeIntervalSince1970: 42)
        let first = VocabularyCompiler.compile(
            persistent: terms, ephemeral: [], capturedBundleId: nil, activeProjectId: nil, now: now
        )
        let second = VocabularyCompiler.compile(
            persistent: terms, ephemeral: [], capturedBundleId: nil, activeProjectId: nil, now: now
        )
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

@Suite("Glossary active terms and labeled aliases")
struct GlossaryVocabularyTests {
    @Test func activeTermsDropsTombstonedAndOrdersByTrust() {
        let terms = [
            ProtectedTerm(canonical: "bundled", spokenAliases: [], source: .bundled),
            ProtectedTerm(canonical: "explicit", spokenAliases: [], source: .explicitCorrection),
            ProtectedTerm(
                canonical: "dead", spokenAliases: [], source: .manualImport,
                tombstonedAt: Date(timeIntervalSince1970: 1)
            ),
        ]
        let active = Glossary.activeTerms(terms)
        #expect(active.map(\.canonical) == ["explicit", "bundled"])
    }

    @Test func activeTermsRespectsScope() {
        let terms = [
            ProtectedTerm(canonical: "g", spokenAliases: [], scope: .global),
            ProtectedTerm(canonical: "a", spokenAliases: [], scope: .bundleID("com.a")),
            ProtectedTerm(canonical: "p", spokenAliases: [], scope: .projectID("proj-1")),
        ]
        let active = Glossary.activeTerms(terms, bundleId: "com.a", projectId: nil)
        #expect(Set(active.map(\.canonical)) == Set(["g", "a"]))
    }

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

@Suite("RefinerPrivacy")
struct RefinerPrivacyTests {
    @Test func cloudEligibleFiltersEveryScopeFlagAndTombstoneCombination() {
        let tombstone = Date(timeIntervalSince1970: 1)
        let terms = [
            ProtectedTerm(canonical: "GlobalCloud", spokenAliases: [], scope: .global, cloudEligible: true),
            ProtectedTerm(
                canonical: "BundleCloud", spokenAliases: [], scope: .bundleID("com.example.app"), cloudEligible: true),
            ProtectedTerm(
                canonical: "ProjectCloud", spokenAliases: [], scope: .projectID("project"), cloudEligible: true),
            ProtectedTerm(canonical: "GlobalLocal", spokenAliases: [], scope: .global, cloudEligible: false),
            ProtectedTerm(
                canonical: "BundleLocal", spokenAliases: [], scope: .bundleID("com.example.app"), cloudEligible: false),
            ProtectedTerm(
                canonical: "ProjectLocal", spokenAliases: [], scope: .projectID("project"), cloudEligible: false),
            ProtectedTerm(
                canonical: "GlobalDead", spokenAliases: [], scope: .global, cloudEligible: true, tombstonedAt: tombstone
            ),
            ProtectedTerm(
                canonical: "BundleDead", spokenAliases: [], scope: .bundleID("com.example.app"), cloudEligible: true,
                tombstonedAt: tombstone),
            ProtectedTerm(
                canonical: "ProjectDead", spokenAliases: [], scope: .projectID("project"), cloudEligible: true,
                tombstonedAt: tombstone),
        ]

        #expect(
            RefinerPrivacy.cloudEligible(terms).map(\.canonical) == [
                "GlobalCloud",
                "BundleCloud",
            ])
    }
}
