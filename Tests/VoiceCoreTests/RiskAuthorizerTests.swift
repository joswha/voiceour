import Testing

@testable import VoiceCore

// MARK: - Fixtures

private func makeCandidate(
    termId: String = "term",
    canonical: String = "Term",
    spanStart: Int = 0,
    spanLength: Int = 4,
    phone: Double = 0.9,
    text: Double = 0.9
) -> TermCandidate {
    TermCandidate(
        termId: termId,
        canonical: canonical,
        spanStart: spanStart,
        spanLength: spanLength,
        source: .bundled,
        phoneSimilarity: phone,
        textSimilarity: text
    )
}

// MARK: - RiskAuthorizer

@Suite("RiskAuthorizer")
struct RiskAuthorizerTests {
    // Plausibility boundary: a weak candidate keeps, a strong one suggests.
    @Test func weakCandidateKeepsPlausibleSuggests() {
        let weak = AuthorizerEvidence(candidate: makeCandidate(phone: 0.2, text: 0.1), termRisk: .low)
        #expect(RiskAuthorizer.decide(weak) == .keep)

        let strong = AuthorizerEvidence(candidate: makeCandidate(), termRisk: .low)
        #expect(RiskAuthorizer.decide(strong) == .suggest(termId: "term"))
    }

    /// Confidence, its basis and the runner-up margin are recorded, but they cannot
    /// authorize anything on their own: the strongest possible evidence still only
    /// yields a suggestion, and a critical span is no different from a low-risk one.
    /// This is the deleted automatic-replacement path, asserted as absent.
    @Test func noEvidenceEverAuthorizesAnAutomaticEdit() {
        for risk in [TermRisk.low, .medium, .critical] {
            let pristine = AuthorizerEvidence(
                candidate: makeCandidate(),
                termRisk: risk,
                transcriptConfidence: 0.99,
                confidenceMode: .greedyTokenProb,
                runnerUpMargin: 0.9
            )
            #expect(RiskAuthorizer.decide(pristine) == .suggest(termId: "term"))
        }
    }

    /// The verdict follows the candidate's own signal, not the transcript's confidence:
    /// a weak candidate stays `.keep` however certain the recognizer claims to be.
    @Test func transcriptConfidenceDoesNotRescueAWeakCandidate() {
        let evidence = AuthorizerEvidence(
            candidate: makeCandidate(phone: 0.2, text: 0.1),
            termRisk: .low,
            transcriptConfidence: 1.0,
            confidenceMode: .greedyTokenProb,
            runnerUpMargin: 1.0
        )
        #expect(RiskAuthorizer.decide(evidence) == .keep)
    }

    // Purity: identical inputs yield identical outputs.
    @Test func decideIsDeterministic() {
        let evidence = AuthorizerEvidence(candidate: makeCandidate(), termRisk: .low)
        let first = RiskAuthorizer.decide(evidence)
        let second = RiskAuthorizer.decide(evidence)
        #expect(first == second)
        #expect(first == .suggest(termId: "term"))
    }
}
