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

/// All the independent evidence the authorizer weighs for one candidate.
///
/// The struct is a pure value: it carries a retrieved `TermCandidate`, its risk
/// class, and the acoustic/ASR signals needed to decide whether the candidate
/// has *independent* support strong enough to justify an automatic edit. It
/// deliberately separates decoder-biased support (`decoderBiasEnabled`) from
/// genuine n-best support (`appearsInNBest`) so the authorizer can refuse to
/// treat the decoder's own preference as evidence for itself.
public struct AuthorizerEvidence: Equatable, Sendable {
    /// The suggestion-only match produced by retrieval.
    public let candidate: TermCandidate
    /// How harmful an incorrect automatic edit of this span would be.
    public let termRisk: TermRisk
    /// Calibrated confidence of the transcript at the span, if available.
    public let transcriptConfidence: Double?
    /// The mode the confidence was produced under. `.none` or `nil` means the
    /// number is not a calibrated probability and cannot clear a calibrated bar.
    public let confidenceMode: ASRConfidenceMode?
    /// Whether the candidate's surface appears in the ASR n-best list — i.e. the
    /// acoustic model independently entertained it.
    public let appearsInNBest: Bool
    /// Whether decoder-side biasing was active for this term. Biased support is
    /// circular (the decoder was told to prefer the term), never independent.
    /// `nil` means the backend did not report it, which is NOT the same as
    /// "unbiased": a backend that biases but omits the field would otherwise
    /// have its circular support accepted as independent evidence.
    public let decoderBiasEnabled: Bool?
    /// Gap between the winning hypothesis and its runner-up at the span. A small
    /// margin means the recognition was ambiguous.
    public let runnerUpMargin: Double?

    public init(
        candidate: TermCandidate,
        termRisk: TermRisk,
        transcriptConfidence: Double? = nil,
        confidenceMode: ASRConfidenceMode? = nil,
        appearsInNBest: Bool = false,
        decoderBiasEnabled: Bool? = nil,
        runnerUpMargin: Double? = nil
    ) {
        self.candidate = candidate
        self.termRisk = termRisk
        self.transcriptConfidence = transcriptConfidence
        self.confidenceMode = confidenceMode
        self.appearsInNBest = appearsInNBest
        self.decoderBiasEnabled = decoderBiasEnabled
        self.runnerUpMargin = runnerUpMargin
    }
}

/// The authorizer's verdict for a single candidate.
///
/// - `keep`: no action; the candidate is too weak to even surface.
/// - `suggest`: surface a suggestion-only proposal for explicit user action.
/// - `replace`: perform an automatic edit. Only ever returned when automatic
///   replacement is explicitly enabled and every threshold passes on
///   independent evidence with no veto.
public enum AuthorizerDecision: Equatable, Sendable {
    case keep
    case suggest(termId: String)
    case replace(termId: String)
}

/// Calibrated absolute-confidence and runner-up-margin floors, split by risk
/// class. Critical spans demand the strict (`critical*`) band; everything else
/// uses the base band. All values are on the same calibrated scale as the ASR
/// confidence/margin signals in `AuthorizerEvidence`.
public struct RiskThresholds: Equatable, Sendable {
    public var absolute: Double
    public var margin: Double
    public var criticalAbsolute: Double
    public var criticalMargin: Double

    public init(absolute: Double, margin: Double, criticalAbsolute: Double, criticalMargin: Double) {
        self.absolute = absolute
        self.margin = margin
        self.criticalAbsolute = criticalAbsolute
        self.criticalMargin = criticalMargin
    }

    /// Deliberately conservative defaults: a non-critical span must be strongly
    /// confident with a clear margin, and a critical span must be near-certain
    /// with a wide margin before any automatic edit is permitted.
    public static var conservativeDefault: RiskThresholds {
        RiskThresholds(absolute: 0.85, margin: 0.15, criticalAbsolute: 0.97, criticalMargin: 0.40)
    }
}

/// Deterministic, pure risk authorizer for term candidates.
///
/// `decide` is a total function of its inputs with no side effects and no
/// hidden state. It fails safe toward `.keep`: automatic replacement is off by
/// default and is only ever granted when it is explicitly enabled *and* the
/// evidence is independent (not decoder-biased, present in the acoustic n-best)
/// *and* clears the calibrated absolute + margin thresholds for the candidate's
/// risk class *and* no veto applies. Any doubt collapses to at most `.suggest`,
/// never `.replace`.
public enum RiskAuthorizer {

    /// Minimum blended acoustic/textual signal for a candidate to be surfaced as
    /// a suggestion. Below it the candidate is dropped (`.keep`).
    private static let suggestionFloor = 0.55

    /// Returns the authorizer's verdict for `evidence`.
    ///
    /// - Parameters:
    ///   - evidence: independent evidence for one candidate.
    ///   - thresholds: calibrated floors, per risk class.
    ///   - automaticEnabled: master switch; when `false`, `.replace` is never
    ///     returned regardless of how strong the evidence is.
    public static func decide(
        _ evidence: AuthorizerEvidence,
        thresholds: RiskThresholds = .conservativeDefault,
        automaticEnabled: Bool = false
    ) -> AuthorizerDecision {
        let termId = evidence.candidate.termId

        // The safe fallback whenever automatic replacement is not warranted:
        // surface a suggestion if the candidate is plausible, otherwise keep the
        // text untouched. A suggestion never mutates text.
        let fallback: AuthorizerDecision =
            isPlausible(evidence.candidate) ? .suggest(termId: termId) : .keep

        // Veto: automatic replacement must be explicitly enabled.
        guard automaticEnabled else { return fallback }

        // Veto: decoder biasing makes the ASR's support for the term circular —
        // it was told to prefer the term, so its preference is not independent
        // evidence and can never justify an automatic edit. An UNREPORTED bias
        // state vetoes for the same reason: we cannot show the support is
        // independent, and "the backend did not say" must never read as "no".
        guard evidence.decoderBiasEnabled == false else { return fallback }

        // Veto: no independent acoustic support. A candidate absent from the
        // n-best list only survives because a language model or the decoder
        // preferred it; this is exactly the homophone / common-word failure mode,
        // so it is capped at a suggestion.
        guard evidence.appearsInNBest else { return fallback }

        // Select the threshold band. Critical spans require the strict band, so a
        // critical candidate is vetoed on *any* miss against the tighter floors.
        let absoluteFloor: Double
        let marginFloor: Double
        switch evidence.termRisk {
        case .critical:
            absoluteFloor = thresholds.criticalAbsolute
            marginFloor = thresholds.criticalMargin
        case .medium, .low:
            absoluteFloor = thresholds.absolute
            marginFloor = thresholds.margin
        }

        // Veto: absolute confidence must be present, calibrated, and clear the
        // floor. An absent value or an uncalibrated mode cannot clear a
        // calibrated bar.
        guard let confidence = evidence.transcriptConfidence,
            let mode = evidence.confidenceMode, mode != .none,
            confidence >= absoluteFloor
        else { return fallback }

        // Veto: the runner-up margin must be present and clear the floor. A small
        // or absent margin means the recognition was ambiguous.
        guard let margin = evidence.runnerUpMargin, margin >= marginFloor
        else { return fallback }

        // Enabled, independent, calibrated, and unambiguous with no veto: the
        // only path to an automatic edit.
        return .replace(termId: termId)
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
