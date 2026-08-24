import Foundation
import Testing

@testable import VoiceCore

/// The Glossary tab could only show the ledger in arrival order and offered no
/// way to narrow it, because searching and ordering a term list existed nowhere
/// outside a SwiftUI body. These are the cases the readable list rests on.
@Suite("Glossary query")
struct GlossaryQueryTests {
    private func term(
        _ canonical: String,
        aliases: [String] = [],
        termId: String? = nil,
        source: TermSource = .explicitCorrection,
        scope: VocabularyScope = .global,
        tombstonedAt: Date? = nil
    ) -> ProtectedTerm {
        ProtectedTerm(
            canonical: canonical,
            spokenAliases: aliases,
            termId: termId,
            source: source,
            scope: scope,
            tombstonedAt: tombstonedAt
        )
    }

    // MARK: Origin

    /// Only a shipped term is built in. Every other provenance — a correction,
    /// an import, an app profile — is a term the reader is answerable for, so it
    /// reads as theirs.
    @Test func onlyBundledTermsAreBuiltIn() {
        #expect(GlossaryQuery.origin(of: term("kubectl", source: .bundled)) == .builtIn)
        #expect(GlossaryQuery.origin(of: term("NeuroDock", source: .explicitCorrection)) == .yours)
        #expect(GlossaryQuery.origin(of: term("VoiceourBench", source: .manualImport)) == .yours)
        #expect(GlossaryQuery.origin(of: term("Xcode", source: .appProfile)) == .yours)
    }

    // MARK: Order

    /// The ledger's order is arrival order. The list is alphabetical and case
    /// blind, so `alfred` precedes `Zed` where a byte comparison would not.
    @Test func matchesAreAlphabeticalWhateverTheLedgerOrder() {
        let terms = [term("zsh"), term("Zed"), term("alfred")]

        let matches = GlossaryQuery.matches(in: terms, query: "", origin: nil)

        #expect(matches.map(\.canonical) == ["alfred", "Zed", "zsh"])
    }

    /// Two records can hold one spelling in different scopes; the id breaks the
    /// tie so the list does not reshuffle between reloads.
    @Test func equalSpellingsOrderByTermId() {
        let terms = [
            term("kubectl", termId: "kubectl-project", scope: .projectID("proj-voiceour")),
            term("kubectl", termId: "kubectl-global"),
        ]

        let matches = GlossaryQuery.matches(in: terms, query: "", origin: nil)

        #expect(matches.map(\.termId) == ["kubectl-global", "kubectl-project"])
    }

    // MARK: Search

    @Test func aQueryMatchesTheCanonicalCaseInsensitively() {
        let terms = [term("NeuroDock"), term("kubectl")]

        let matches = GlossaryQuery.matches(in: terms, query: "neurodock", origin: nil)

        #expect(matches.map(\.canonical) == ["NeuroDock"])
    }

    /// A spoken form the user typed is searchable: what they remember is what
    /// dictation kept hearing, not the spelling they were trying to reach.
    @Test func aQueryMatchingOnlyAUserAliasReturnsTheTerm() {
        let terms = [term("kubectl", aliases: ["cube cuddle"]), term("NeuroDock")]

        let matches = GlossaryQuery.matches(in: terms, query: "cuddle", origin: nil)

        #expect(matches.map(\.canonical) == ["kubectl"])
    }

    /// Derived variants are matched by dictation but never searched: a hit on a
    /// string the user never typed cannot be explained by the row it returns.
    @Test func aQueryMatchingOnlyADerivedVariantReturnsNothing() throws {
        let derived = Glossary.derivedAliases(for: "NeuroDock")
        try #require(derived == ["neuro dock"])
        let terms = [term("NeuroDock")]

        let matches = GlossaryQuery.matches(in: terms, query: "neuro dock", origin: nil)

        #expect(matches.isEmpty)
    }

    // MARK: Origin filter

    @Test func theOriginFilterKeepsOnlyThatOrigin() {
        let terms = [
            term("kubectl", source: .bundled),
            term("NeuroDock"),
            term("VoiceourBench", source: .manualImport),
        ]

        let yours = GlossaryQuery.matches(in: terms, query: "", origin: .yours)
        #expect(yours.map(\.canonical) == ["NeuroDock", "VoiceourBench"])

        let builtIn = GlossaryQuery.matches(in: terms, query: "", origin: .builtIn)
        #expect(builtIn.map(\.canonical) == ["kubectl"])
    }

    /// Two lenses, not two lists: a filtered search shows the terms that satisfy
    /// both.
    @Test func theOriginFilterAndTheQueryAreAnded() {
        let terms = [
            term("kubectl", aliases: ["cube cuddle"], source: .bundled),
            term("kubeconfig"),
        ]

        let unfiltered = GlossaryQuery.matches(in: terms, query: "kube", origin: nil)
        #expect(unfiltered.map(\.canonical) == ["kubeconfig", "kubectl"])

        let yours = GlossaryQuery.matches(in: terms, query: "kube", origin: .yours)
        #expect(yours.map(\.canonical) == ["kubeconfig"])
    }

    // MARK: Tombstones

    /// A removed term is gone from the reader's view of the ledger: it is
    /// neither listed, nor findable, nor counted toward a filter.
    @Test func tombstonedTermsAreNeitherMatchedNorCounted() {
        let terms = [
            term("kubectl", source: .bundled),
            term("NeuroDock", tombstonedAt: Date(timeIntervalSince1970: 1)),
        ]

        #expect(GlossaryQuery.matches(in: terms, query: "", origin: nil).map(\.canonical) == ["kubectl"])
        #expect(GlossaryQuery.matches(in: terms, query: "neuro", origin: nil).isEmpty)
        #expect(GlossaryQuery.matches(in: terms, query: "", origin: .yours).isEmpty)
        #expect(GlossaryQuery.originFacets(in: terms) == [TermOriginFacet(origin: .builtIn, count: 1)])
    }

    // MARK: Origin facets

    @Test func facetsCountEachOriginAndOfferYoursFirst() {
        let terms = [
            term("kubectl", source: .bundled),
            term("zsh", source: .bundled),
            term("NeuroDock"),
        ]

        let facets = GlossaryQuery.originFacets(in: terms)

        #expect(
            facets == [
                TermOriginFacet(origin: .yours, count: 1),
                TermOriginFacet(origin: .builtIn, count: 2),
            ]
        )
    }

    /// A facet no term can fill is not offered: a filter whose only effect is to
    /// empty the list is not a choice.
    @Test func anAbsentOriginIsOmittedFromTheFacets() {
        let terms = [term("kubectl", source: .bundled), term("zsh", source: .bundled)]

        let facets = GlossaryQuery.originFacets(in: terms)

        #expect(facets == [TermOriginFacet(origin: .builtIn, count: 2)])
    }
}
