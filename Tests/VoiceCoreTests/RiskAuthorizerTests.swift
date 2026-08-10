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

/// Evidence that clears every gate for a non-critical span: enabled elsewhere,
/// independent (n-best, no decoder bias), calibrated, confident, wide margin.
private func pristineEvidence(
    risk: TermRisk = .low,
    candidate: TermCandidate = makeCandidate()
) -> AuthorizerEvidence {
    AuthorizerEvidence(
        candidate: candidate,
        termRisk: risk,
        transcriptConfidence: 0.95,
        confidenceMode: .beamLogprob,
        appearsInNBest: true,
        decoderBiasEnabled: false,
        runnerUpMargin: 0.5
    )
}

// MARK: - RiskAuthorizer

@Suite("RiskAuthorizer")
struct RiskAuthorizerTests {
    // Veto: automatic replacement off.
    @Test func automaticDisabledNeverReplaces() {
        let evidence = pristineEvidence()
        // Explicit false.
        #expect(RiskAuthorizer.decide(evidence, automaticEnabled: false) == .suggest(termId: "term"))
        // Default parameter is also off.
        #expect(RiskAuthorizer.decide(evidence) == .suggest(termId: "term"))
    }

    // The one path that yields a replace.
    @Test func cleanNonCriticalCandidateReplacesWhenEnabled() {
        let evidence = pristineEvidence(risk: .medium)
        #expect(RiskAuthorizer.decide(evidence, automaticEnabled: true) == .replace(termId: "term"))
    }

    // Veto: decoder-biased support is circular.
    @Test func decoderBiasCapsAtSuggest() {
        var evidence = pristineEvidence()
        evidence = AuthorizerEvidence(
            candidate: evidence.candidate,
            termRisk: evidence.termRisk,
            transcriptConfidence: evidence.transcriptConfidence,
            confidenceMode: evidence.confidenceMode,
            appearsInNBest: evidence.appearsInNBest,
            decoderBiasEnabled: true,
            runnerUpMargin: evidence.runnerUpMargin
        )
        #expect(RiskAuthorizer.decide(evidence, automaticEnabled: true) == .suggest(termId: "term"))
    }

    // Veto: no independent acoustic support (homophone / common-word failure mode).
    @Test func absentFromNBestCapsAtSuggest() {
        let evidence = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .low,
            transcriptConfidence: 0.95,
            confidenceMode: .beamLogprob,
            appearsInNBest: false,
            decoderBiasEnabled: false,
            runnerUpMargin: 0.5
        )
        #expect(RiskAuthorizer.decide(evidence, automaticEnabled: true) == .suggest(termId: "term"))
    }

    // Veto: runner-up margin below the floor, and margin absent.
    @Test func lowOrMissingMarginCapsAtSuggest() {
        let narrow = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .low,
            transcriptConfidence: 0.95,
            confidenceMode: .beamLogprob,
            appearsInNBest: true,
            decoderBiasEnabled: false,
            runnerUpMargin: 0.10
        )
        #expect(RiskAuthorizer.decide(narrow, automaticEnabled: true) == .suggest(termId: "term"))

        let missing = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .low,
            transcriptConfidence: 0.95,
            confidenceMode: .beamLogprob,
            appearsInNBest: true,
            decoderBiasEnabled: false,
            runnerUpMargin: nil
        )
        #expect(RiskAuthorizer.decide(missing, automaticEnabled: true) == .suggest(termId: "term"))
    }

    // Veto: absolute confidence below the floor, and confidence absent.
    @Test func lowOrMissingConfidenceCapsAtSuggest() {
        let low = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .low,
            transcriptConfidence: 0.80,
            confidenceMode: .beamLogprob,
            appearsInNBest: true,
            decoderBiasEnabled: false,
            runnerUpMargin: 0.5
        )
        #expect(RiskAuthorizer.decide(low, automaticEnabled: true) == .suggest(termId: "term"))

        let missing = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .low,
            transcriptConfidence: nil,
            confidenceMode: .beamLogprob,
            appearsInNBest: true,
            decoderBiasEnabled: false,
            runnerUpMargin: 0.5
        )
        #expect(RiskAuthorizer.decide(missing, automaticEnabled: true) == .suggest(termId: "term"))
    }

    // Veto: uncalibrated / missing confidence mode cannot clear a calibrated bar.
    @Test func uncalibratedConfidenceModeCapsAtSuggest() {
        let none = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .low,
            transcriptConfidence: 0.99,
            confidenceMode: ASRConfidenceMode.none,
            appearsInNBest: true,
            decoderBiasEnabled: false,
            runnerUpMargin: 0.5
        )
        #expect(RiskAuthorizer.decide(none, automaticEnabled: true) == .suggest(termId: "term"))

        let missing = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .low,
            transcriptConfidence: 0.99,
            confidenceMode: nil,
            appearsInNBest: true,
            decoderBiasEnabled: false,
            runnerUpMargin: 0.5
        )
        #expect(RiskAuthorizer.decide(missing, automaticEnabled: true) == .suggest(termId: "term"))
    }

    // Veto: critical spans never auto-replace on any ambiguity. The same
    // borderline evidence replaces when the span is non-critical, proving the
    // difference is the risk class, not the acoustics.
    @Test func criticalNeverReplacesOnAmbiguity() {
        // Clears the base band (0.85 / 0.15) but not the critical band (0.97 / 0.40).
        func borderline(_ risk: TermRisk) -> AuthorizerEvidence {
            AuthorizerEvidence(
                candidate: makeCandidate(),
                termRisk: risk,
                transcriptConfidence: 0.90,
                confidenceMode: .beamLogprob,
                appearsInNBest: true,
                decoderBiasEnabled: false,
                runnerUpMargin: 0.30
            )
        }
        #expect(RiskAuthorizer.decide(borderline(.critical), automaticEnabled: true) == .suggest(termId: "term"))
        #expect(RiskAuthorizer.decide(borderline(.low), automaticEnabled: true) == .replace(termId: "term"))
    }

    // A critical span may auto-replace only when it clears the strict band.
    @Test func criticalReplacesOnlyAtStrictBand() {
        let strict = AuthorizerEvidence(
            candidate: makeCandidate(),
            termRisk: .critical,
            transcriptConfidence: 0.98,
            confidenceMode: .beamLogprob,
            appearsInNBest: true,
            decoderBiasEnabled: false,
            runnerUpMargin: 0.50
        )
        #expect(RiskAuthorizer.decide(strict, automaticEnabled: true) == .replace(termId: "term"))
    }

    // Plausibility boundary: a weak candidate keeps, a strong one suggests.
    @Test func weakCandidateKeepsPlausibleSuggests() {
        let weak = AuthorizerEvidence(
            candidate: makeCandidate(phone: 0.2, text: 0.1),
            termRisk: .low
        )
        #expect(RiskAuthorizer.decide(weak, automaticEnabled: false) == .keep)

        let strong = AuthorizerEvidence(candidate: makeCandidate(), termRisk: .low)
        #expect(RiskAuthorizer.decide(strong, automaticEnabled: false) == .suggest(termId: "term"))
    }

    // Purity: identical inputs yield identical outputs.
    @Test func decideIsDeterministic() {
        let evidence = pristineEvidence()
        let first = RiskAuthorizer.decide(evidence, automaticEnabled: true)
        let second = RiskAuthorizer.decide(evidence, automaticEnabled: true)
        #expect(first == second)
        #expect(first == .replace(termId: "term"))
    }
}

// MARK: - TermDecisionApplier

private func makeTerm(
    termId: String,
    canonical: String,
    casePolicy: CasePolicy = .exact
) -> ProtectedTerm {
    ProtectedTerm(
        canonical: canonical,
        spokenAliases: [],
        casePolicy: casePolicy,
        termId: termId
    )
}

@Suite("TermDecisionApplier")
struct TermDecisionApplierTests {
    // Resolves the stored canonical exactly — not the candidate's raw canonical
    // and not the misheard surface.
    @Test func resolvesStoredCanonicalExactly() {
        // "deploy on kubernaties now": misheard span "kubernaties" = [10, 21).
        let transcript = "deploy on kubernaties now"
        let candidate = makeCandidate(
            termId: "kubernetes",
            canonical: "kubernetes",
            spanStart: 10,
            spanLength: 11
        )
        let terms = [makeTerm(termId: "kubernetes", canonical: "Kubernetes")]

        let result = TermDecisionApplier.apply(
            decisions: [.replace(termId: "kubernetes")],
            candidates: [candidate],
            terms: terms,
            to: transcript
        )
        #expect(result == "deploy on Kubernetes now")
    }

    // Only .replace mutates; .keep and .suggest are inert.
    @Test func nonReplaceDecisionsDoNotMutate() {
        let transcript = "deploy on kubernaties now"
        let candidate = makeCandidate(
            termId: "kubernetes",
            canonical: "kubernetes",
            spanStart: 10,
            spanLength: 11
        )
        let terms = [makeTerm(termId: "kubernetes", canonical: "Kubernetes")]

        #expect(
            TermDecisionApplier.apply(
                decisions: [.suggest(termId: "kubernetes")],
                candidates: [candidate],
                terms: terms,
                to: transcript
            ) == transcript
        )
        #expect(
            TermDecisionApplier.apply(
                decisions: [.keep],
                candidates: [candidate],
                terms: terms,
                to: transcript
            ) == transcript
        )
    }

    // Stale span, out of range on a shortened transcript: rejected, original returned.
    @Test func rejectsOutOfRangeStaleSpan() {
        let candidate = makeCandidate(
            termId: "kubernetes",
            canonical: "kubernetes",
            spanStart: 10,
            spanLength: 11
        )
        let terms = [makeTerm(termId: "kubernetes", canonical: "Kubernetes")]
        let mutated = "deploy on k8s"  // span [10,21) is out of range now

        #expect(
            TermDecisionApplier.apply(
                decisions: [.replace(termId: "kubernetes")],
                candidates: [candidate],
                terms: terms,
                to: mutated
            ) == mutated
        )
    }

    // Stale span whose current substring cuts into a word: rejected.
    @Test func rejectsMidWordStaleSpan() {
        let candidate = makeCandidate(
            termId: "kubernetes",
            canonical: "kubernetes",
            spanStart: 10,
            spanLength: 11
        )
        let terms = [makeTerm(termId: "kubernetes", canonical: "Kubernetes")]
        // Space before "now" removed: span end (21) now lands mid-word.
        let mutated = "deploy on kubernatiesnow"

        #expect(
            TermDecisionApplier.apply(
                decisions: [.replace(termId: "kubernetes")],
                candidates: [candidate],
                terms: terms,
                to: mutated
            ) == mutated
        )
    }

    // Retrieval emits overlapping word runs around a real match. The applier
    // keeps the strongest authorized patch and passes a non-overlapping set to
    // the fail-safe renderer instead of losing every correction.
    @Test func overlappingDecisionsKeepStrongestPatch() {
        // "the cat sat": [0,7)="the cat", [4,11)="cat sat" overlap on [4,7).
        let transcript = "the cat sat"
        let first = makeCandidate(
            termId: "t1",
            canonical: "t1",
            spanStart: 0,
            spanLength: 7,
            phone: 0.95,
            text: 0.95
        )
        let second = makeCandidate(
            termId: "t2",
            canonical: "t2",
            spanStart: 4,
            spanLength: 7,
            phone: 0.7,
            text: 0.7
        )
        let terms = [
            makeTerm(termId: "t1", canonical: "ALPHA"),
            makeTerm(termId: "t2", canonical: "BETA"),
        ]

        let result = TermDecisionApplier.apply(
            decisions: [.replace(termId: "t1"), .replace(termId: "t2")],
            candidates: [first, second],
            terms: terms,
            to: transcript
        )
        #expect(result == "ALPHA sat")
    }

    // Unresolvable term id: dropped rather than authored.
    @Test func unresolvableTermIsDropped() {
        let transcript = "deploy on kubernaties now"
        let candidate = makeCandidate(
            termId: "ghost",
            canonical: "ghost",
            spanStart: 10,
            spanLength: 11
        )
        #expect(
            TermDecisionApplier.apply(
                decisions: [.replace(termId: "ghost")],
                candidates: [candidate],
                terms: [],  // no term to resolve canonical from
                to: transcript
            ) == transcript
        )
    }

    // Misaligned decision/candidate counts are an inconsistency: no change.
    @Test func mismatchedCountsReturnOriginal() {
        let transcript = "deploy on kubernaties now"
        let candidate = makeCandidate(termId: "kubernetes", spanStart: 10, spanLength: 11)
        let terms = [makeTerm(termId: "kubernetes", canonical: "Kubernetes")]

        #expect(
            TermDecisionApplier.apply(
                decisions: [.replace(termId: "kubernetes")],
                candidates: [candidate, candidate],
                terms: terms,
                to: transcript
            ) == transcript
        )
    }

    // A decision whose termId disagrees with its paired candidate is skipped.
    @Test func decisionTermIdMustMatchCandidate() {
        let transcript = "deploy on kubernaties now"
        let candidate = makeCandidate(termId: "kubernetes", spanStart: 10, spanLength: 11)
        let terms = [
            makeTerm(termId: "kubernetes", canonical: "Kubernetes"),
            makeTerm(termId: "other", canonical: "Other"),
        ]

        #expect(
            TermDecisionApplier.apply(
                decisions: [.replace(termId: "other")],
                candidates: [candidate],
                terms: terms,
                to: transcript
            ) == transcript
        )
    }

    // Mixed batch: only the valid replace applies.
    @Test func appliesOnlyValidReplaceInMixedBatch() {
        let transcript = "deploy on kubernaties now"
        let suggestCandidate = makeCandidate(termId: "a", spanStart: 0, spanLength: 6)
        let replaceCandidate = makeCandidate(
            termId: "kubernetes",
            canonical: "kubernetes",
            spanStart: 10,
            spanLength: 11
        )
        let keepCandidate = makeCandidate(termId: "b", spanStart: 22, spanLength: 3)
        let terms = [makeTerm(termId: "kubernetes", canonical: "Kubernetes")]

        let result = TermDecisionApplier.apply(
            decisions: [.suggest(termId: "a"), .replace(termId: "kubernetes"), .keep],
            candidates: [suggestCandidate, replaceCandidate, keepCandidate],
            terms: terms,
            to: transcript
        )
        #expect(result == "deploy on Kubernetes now")
    }
}
