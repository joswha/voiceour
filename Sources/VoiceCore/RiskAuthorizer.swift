/// How dangerous it is to auto-replace a given span. The caller classifies each
/// candidate up front; the authorizer never downgrades a risk, it only reacts to
/// it. `critical` covers spans whose meaning is executable or addressable —
/// shell commands, flags, filesystem paths, version strings — where a wrong
/// automatic edit is materially harmful.
public enum TermRisk: Equatable, Sendable {
    case low
    case medium
    case critical
}

/// The evidence the authorizer weighs for one candidate.
///
/// A pure value: a retrieved `TermCandidate`, its risk class, and the ASR signals
/// available for the span it covers.
public struct AuthorizerEvidence: Equatable, Sendable {
    /// The suggestion-only match produced by retrieval.
    public let candidate: TermCandidate
    /// How harmful an incorrect automatic edit of this span would be.
    public let termRisk: TermRisk
    /// Confidence of the transcript at the span, if the backend reported one.
    public let transcriptConfidence: Double?
    /// What that number is. No mode this decoder produces is calibrated.
    public let confidenceMode: ASRConfidenceMode?
    /// Gap between the winning candidate and its runner-up at the span. A small
    /// margin means retrieval was ambiguous.
    public let runnerUpMargin: Double?

    public init(
        candidate: TermCandidate,
        termRisk: TermRisk,
        transcriptConfidence: Double? = nil,
        confidenceMode: ASRConfidenceMode? = nil,
        runnerUpMargin: Double? = nil
    ) {
        self.candidate = candidate
        self.termRisk = termRisk
        self.transcriptConfidence = transcriptConfidence
        self.confidenceMode = confidenceMode
        self.runnerUpMargin = runnerUpMargin
    }
}

/// The authorizer's verdict for a single candidate.
///
/// - `keep`: no action; the candidate is too weak to even surface.
/// - `suggest`: surface a suggestion-only proposal for explicit user action.
///
/// There is deliberately no automatic-replacement verdict. See `RiskAuthorizer`.
public enum AuthorizerDecision: Equatable, Sendable {
    case keep
    case suggest(termId: String)
}

/// Deterministic, pure risk authorizer for term candidates.
///
/// `decide` is a total function of its inputs with no side effects and no hidden
/// state. Its whole output space is "surface a suggestion" or "do nothing"; it
/// never edits text.
///
/// **This used to be able to authorize an automatic replacement, and that path was
/// deleted rather than left switched off.** Measured 2026-08-14, two of its three
/// independence gates could not discriminate:
///
/// - *N-best support was vacuous.* The gate asked whether the candidate appeared in
///   an ASR hypothesis list. Under greedy decoding that list held exactly one entry:
///   the transcript the candidate had just been extracted from. The question was
///   always answered yes. Only an opt-in beam decoder produced a real n-best list,
///   and the runtime this app now ships (`Vendor/parakeet`) is greedy-only with no
///   beam and no decoder-bias hook, so the gate could not be repaired in place.
/// - *The confidence floors were described as calibrated and were not.* Committed
///   benchmark reports put the expected calibration error of the greedy confidence
///   signal between **0.235 and 0.419** (`benchmarks/results/*-techterms-stt.json`,
///   `ece`), where 0 is perfect. The replacement for it, `greedy_token_prob`, is a
///   mean of per-token posteriors and is equally uncalibrated.
/// - Relatedly, `runnerUpMargin` is a margin between the *retriever's own* blended
///   phonetic/textual similarity scores, not an acoustic margin between competing
///   recognitions. It is still useful for ranking suggestions; it was never an
///   acoustic independence signal.
///
/// `docs/performance-roadmap.md` records where decode-time biasing would have to
/// live if this capability is ever wanted back. Until an independent acoustic
/// signal exists, a term correction is something the user accepts, not something
/// the app performs.
public enum RiskAuthorizer {

    /// Minimum blended acoustic/textual signal for a candidate to be surfaced as
    /// a suggestion. Below it the candidate is dropped (`.keep`).
    private static let suggestionFloor = 0.55

    /// Returns the authorizer's verdict for `evidence`.
    public static func decide(_ evidence: AuthorizerEvidence) -> AuthorizerDecision {
        isPlausible(evidence.candidate) ? .suggest(termId: evidence.candidate.termId) : .keep
    }

    /// A candidate is worth surfacing when its blended acoustic/textual signal
    /// reaches the suggestion floor.
    private static func isPlausible(_ candidate: TermCandidate) -> Bool {
        blendedSignal(candidate) >= suggestionFloor
    }

    private static func blendedSignal(_ candidate: TermCandidate) -> Double {
        CandidateRetriever.matchSignal(phone: candidate.phoneSimilarity, text: candidate.textSimilarity)
    }
}
