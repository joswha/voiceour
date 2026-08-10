/// A ranked, suggestion-only match between a span of transcript text and an
/// active vocabulary term. Retrieval never mutates text; it only proposes which
/// term a span *might* be a misrecognition of, leaving any edit decision to a
/// downstream resolver.
///
/// `spanStart` and `spanLength` are measured in `Character` offsets into the
/// transcript that was scanned (grapheme clusters), not UTF-8/UTF-16 units.
public struct TermCandidate: Equatable, Sendable {
    public let termId: String
    public let canonical: String
    public let spanStart: Int
    public let spanLength: Int
    public let source: TermSource
    public let phoneSimilarity: Double
    public let textSimilarity: Double

    public init(
        termId: String,
        canonical: String,
        spanStart: Int,
        spanLength: Int,
        source: TermSource,
        phoneSimilarity: Double,
        textSimilarity: Double
    ) {
        self.termId = termId
        self.canonical = canonical
        self.spanStart = spanStart
        self.spanLength = spanLength
        self.source = source
        self.phoneSimilarity = phoneSimilarity
        self.textSimilarity = textSimilarity
    }
}

/// Deterministic, pure retrieval over a compiled vocabulary snapshot.
///
/// The retriever enumerates every bounded, contiguous run of 1...5 transcript
/// words, scores each active (non-tombstoned) snapshot term against the span
/// using phonetic similarity, a normalized character-level text similarity, and
/// a source-trust prior, and returns ranked suggestion-only candidates. It has
/// no edit authority: it never rewrites the transcript and only reports spans
/// that plausibly resolve to a known term.
public enum CandidateRetriever {
    /// Longest contiguous word run considered for a single span.
    private static let maxSpanWords = 5

    /// Blend weights for the core matching signal (phone + text). The prior is
    /// applied separately, and only as a ranking tie-breaker, so source trust
    /// can never manufacture a match that the acoustics do not support.
    private static let phoneWeight = 0.6
    private static let textWeight = 0.4

    /// Small ranking nudge for higher-trust sources; scaled so it can reorder
    /// near-ties without lifting a below-threshold match over the bar.
    private static let priorWeight = 0.05

    /// Minimum phone+text signal a span/term pair must reach to be emitted.
    /// Calibrated so genuine near-misses surface while ordinary prose does not.
    private static let minSimilarity = 0.6

    /// Scans `transcript` for spans that plausibly resolve to a term in
    /// `snapshot`, returning at most `maxPerSpan` candidates per span, ranked
    /// suggestion-only and never mutating the input.
    public static func retrieve(
        in transcript: String,
        snapshot: VocabularySnapshot,
        maxPerSpan: Int = 5
    ) -> [TermCandidate] {
        let cap = max(0, maxPerSpan)
        guard cap > 0 else { return [] }

        let characters = Array(transcript)
        let tokens = wordTokens(in: characters)
        guard !tokens.isEmpty else { return [] }

        // Only active terms participate; snapshots from the compiler are already
        // trust-ordered and tombstone-free, but we filter defensively.
        let scored = snapshot.terms
            .filter { $0.tombstonedAt == nil }
            .map { (term: $0, surfaces: Glossary.matchingAliases(for: $0)) }
        guard !scored.isEmpty else { return [] }

        var results: [TermCandidate] = []

        for start in tokens.indices {
            for length in 1...maxSpanWords {
                let lastToken = start + length - 1
                guard lastToken < tokens.count else { break }

                let spanStart = tokens[start].start
                let spanEnd = tokens[lastToken].end
                let spanText = String(characters[spanStart..<spanEnd])

                var spanCandidates: [TermCandidate] = []
                for entry in scored {
                    guard let match = bestMatch(spanText: spanText, surfaces: entry.surfaces)
                    else { continue }
                    spanCandidates.append(
                        TermCandidate(
                            termId: entry.term.termId,
                            canonical: entry.term.canonical,
                            spanStart: spanStart,
                            spanLength: spanEnd - spanStart,
                            source: entry.term.source,
                            phoneSimilarity: match.phone,
                            textSimilarity: match.text
                        )
                    )
                }

                // Rank within the span (one candidate per term, so termId is a
                // total tie-breaker) and keep the strongest `cap`.
                spanCandidates.sort(by: rankedBefore)
                if spanCandidates.count > cap {
                    spanCandidates.removeLast(spanCandidates.count - cap)
                }
                results.append(contentsOf: spanCandidates)
            }
        }

        // Global deterministic ordering. (spanStart, spanLength, termId) is
        // unique across all candidates, so ties resolve totally and stably.
        results.sort(by: rankedBefore)
        return results
    }

    // MARK: - Scoring

    private static func bestMatch(spanText: String, surfaces: [String]) -> (phone: Double, text: Double)? {
        var best: (phone: Double, text: Double)?
        var bestSignal = -1.0
        for surface in surfaces {
            let phone = Phonetics.similarity(spanText, surface)
            let text = textSimilarity(spanText, surface)
            let signal = matchSignal(phone: phone, text: text)
            if signal > bestSignal {
                bestSignal = signal
                best = (phone, text)
            }
        }
        guard let match = best, bestSignal >= minSimilarity else { return nil }
        return match
    }

    static func matchSignal(phone: Double, text: Double) -> Double {
        phoneWeight * phone + textWeight * text
    }

    private static func rankScore(_ candidate: TermCandidate) -> Double {
        matchSignal(phone: candidate.phoneSimilarity, text: candidate.textSimilarity)
            + priorWeight * prior(for: candidate.source)
    }

    /// Source-trust prior normalized to `0...1`.
    private static func prior(for source: TermSource) -> Double {
        let maxRank = TermSource.explicitCorrection.trustRank
        guard maxRank > 0 else { return 0 }
        return Double(source.trustRank) / Double(maxRank)
    }

    /// Total, deterministic ordering: score desc, then span position, then term.
    private static func rankedBefore(_ lhs: TermCandidate, _ rhs: TermCandidate) -> Bool {
        let ls = rankScore(lhs)
        let rs = rankScore(rhs)
        if ls != rs { return ls > rs }
        if lhs.spanStart != rhs.spanStart { return lhs.spanStart < rhs.spanStart }
        if lhs.spanLength != rhs.spanLength { return lhs.spanLength < rhs.spanLength }
        return lhs.termId < rhs.termId
    }

    /// Normalized character-level similarity in `0...1` (case-insensitive).
    private static func textSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased())
        let y = Array(b.lowercased())
        if x.isEmpty && y.isEmpty { return 1 }
        let scale = max(x.count, y.count)
        guard scale > 0 else { return 1 }
        return 1 - Double(levenshtein(x, y)) / Double(scale)
    }

    static func levenshtein(_ x: [Character], _ y: [Character]) -> Int {
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    // MARK: - Tokenization

    /// A single word token addressed by `Character` offsets, `end` exclusive.
    private struct WordToken {
        let start: Int
        let end: Int
    }

    /// Splits `characters` into maximal runs of letters/digits, tracking their
    /// `Character` offsets. Punctuation and whitespace act as separators; interior
    /// separators between two selected words remain part of the reconstructed span.
    private static func wordTokens(in characters: [Character]) -> [WordToken] {
        var tokens: [WordToken] = []
        var wordStart: Int?
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                tokens.append(WordToken(start: start, end: index))
                wordStart = nil
            }
        }
        if let start = wordStart {
            tokens.append(WordToken(start: start, end: characters.count))
        }
        return tokens
    }
}
