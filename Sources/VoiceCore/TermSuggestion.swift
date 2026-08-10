/// A suggestion-only proposal that a span of dictated text may be a
/// misrecognition of a known vocabulary term.
///
/// Surfaced to the user after a completed dictation. Accepting or rejecting a
/// suggestion is an explicit user action; a `TermSuggestion` never drives
/// automatic text replacement and never mutates an already-inserted target.
public struct TermSuggestion: Identifiable, Equatable, Sendable {
    /// Stable identity for one suggestion within a dictation (term + span).
    public let id: String
    /// The transcript span the retriever flagged as a plausible misrecognition.
    public let misheard: String
    /// The known term the span may resolve to.
    public let canonical: String
    /// Identifier of the backing `ProtectedTerm` the suggestion points at.
    public let termId: String

    public init(id: String, misheard: String, canonical: String, termId: String) {
        self.id = id
        self.misheard = misheard
        self.canonical = canonical
        self.termId = termId
    }
}
