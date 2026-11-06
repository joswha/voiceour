import Foundation

/// Acoustic evidence that the recognizer's own posteriors spell a glossary term over some words.
///
/// Produced by the sidecar from CTC logits; scored against the greedy path over the same frames.
/// It is evidence, not an edit: `TermSpotting.apply` alone decides whether text changes.
public struct TermSpot: Codable, Equatable, Sendable {
    /// Index of the term in the list the spotter searched for.
    public var term: Int
    /// Index of the spelling variant (`TermSpotting.variants(for:)`) that matched.
    public var variant: Int
    /// First and last transcript word the match covers, inclusive; nil when it covers no word or a
    /// non-contiguous set of words, which cannot be rendered by replacement.
    public var firstWord: Int?
    public var lastWord: Int?
    public var startMs: Int
    public var endMs: Int
    /// The variant's best CTC path score minus the greedy path's over the same frames, in nats: ≤ 0,
    /// and 0 exactly when greedy decoding already spelled the variant there.
    public var score: Double
    /// Tokens in the matched variant.
    public var tokenCount: Int

    public init(
        term: Int,
        variant: Int,
        firstWord: Int?,
        lastWord: Int?,
        startMs: Int,
        endMs: Int,
        score: Double,
        tokenCount: Int
    ) {
        self.term = term
        self.variant = variant
        self.firstWord = firstWord
        self.lastWord = lastWord
        self.startMs = startMs
        self.endMs = endMs
        self.score = score
        self.tokenCount = tokenCount
    }
}

/// When a spot may replace words: `score ≥ −total·m` and `score/tokens ≥ −perToken·m`, where `m` is
/// `ordinaryScale` when every covered word is ordinary English and 1 otherwise.
public struct TermSpottingPolicy: Equatable, Sendable {
    public var total: Double
    public var perToken: Double
    public var ordinaryScale: Double

    public init(total: Double, perToken: Double, ordinaryScale: Double) {
        self.total = total
        self.perToken = perToken
        self.ordinaryScale = ordinaryScale
    }
}

/// Deterministic rendering of acoustic term spots into a transcript's words. Pure: no I/O, no clock.
public enum TermSpotting {
    /// Characters kept in front of a replaced span when its first word starts with them.
    static let leadingPunctuation: Set<Character> = ["(", "[", "{", "\"", "'", "«", "“", "‘", "¿", "¡"]
    /// Characters kept after a replaced span when its last word ends with them.
    static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "\"", "'", "»", "”", "’",
    ]

    /// Whether a canonical may be spotted: the same rule that makes it a repair target. Ordinary
    /// words and canonicals of at most two characters are protected instead.
    public static func isTarget(_ canonical: String, ordinaryWords: Set<String>) -> Bool {
        !(ordinaryWords.contains(canonical.lowercased()) || canonical.count <= 2)
    }

    /// The spellings searched for a target, in a fixed order; the caller keeps one per distinct token
    /// sequence. The canonical, it with its first scalar uppercased, it lowercased, each derived alias
    /// and that alias with its first scalar uppercased, then each of the user's own heard-as forms
    /// and that form with its first scalar uppercased. Every variant renders as the canonical.
    public static func variants(for canonical: String, heardAs: [String] = []) -> [String] {
        var variants = [canonical, uppercasedFirst(canonical), canonical.lowercased()]
        for alias in Glossary.derivedAliases(for: canonical) + heardAs {
            variants.append(alias)
            variants.append(uppercasedFirst(alias))
        }
        return variants
    }

    /// Whether `policy`'s thresholds admit `spot` over `words`: it names a contiguous word range,
    /// `score ≥ −total·m` and `score/tokens ≥ −perToken·m`, with `m = ordinaryScale` when every
    /// covered word is ordinary English and 1 otherwise. Surface checks are `apply`'s.
    public static func accepts(
        _ spot: TermSpot,
        words: [String],
        ordinaryWords: Set<String>,
        policy: TermSpottingPolicy
    ) -> Bool {
        guard let first = spot.firstWord, let last = spot.lastWord, first >= 0, first <= last, last < words.count
        else { return false }
        let ordinary = words[first...last].allSatisfy { isOrdinary($0, ordinaryWords: ordinaryWords) }
        let scale = ordinary ? policy.ordinaryScale : 1
        return spot.score >= -policy.total * scale
            && spot.score / Double(max(1, spot.tokenCount)) >= -policy.perToken * scale
    }

    /// The words after applying every accepted spot, or nil when none changes them.
    ///
    /// A spot is applied only if `accepts` admits it and its covered words hold neither a protected
    /// surface (case-insensitive, whole words) nor any target's exact canonical, its own included.
    /// Accepted spots are suppressed across terms by score, then more tokens, then lower term index,
    /// over covered word ranges, then applied right to left. Each replaced span keeps its first
    /// word's leading and its last word's trailing punctuation around the canonical.
    public static func apply(
        words: [String],
        spots: [TermSpot],
        canonicals: [String],
        protectedSurfaces: [String],
        ordinaryWords: Set<String>,
        policy: TermSpottingPolicy
    ) -> [String]? {
        let accepted = spots.filter { spot in
            guard canonicals.indices.contains(spot.term),
                accepts(spot, words: words, ordinaryWords: ordinaryWords, policy: policy),
                let first = spot.firstWord, let last = spot.lastWord
            else { return false }
            let span = words[first...last].joined(separator: " ")
            if protectedSurfaces.contains(where: { containsWholeWord(span, $0, caseInsensitive: true) }) {
                return false
            }
            // A span already holding a target's exact canonical, this spot's own included, is left
            // alone: rewriting it can only drop text around the term.
            return !canonicals.contains { containsWholeWord(span, $0, caseInsensitive: false) }
        }
        let ordered = accepted.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.tokenCount != rhs.tokenCount { return lhs.tokenCount > rhs.tokenCount }
            return lhs.term < rhs.term
        }
        var kept: [(first: Int, last: Int, term: Int)] = []
        for spot in ordered {
            guard let first = spot.firstWord, let last = spot.lastWord,
                !kept.contains(where: { $0.first <= last && first <= $0.last })
            else { continue }
            kept.append((first, last, spot.term))
        }
        guard !kept.isEmpty else { return nil }

        var result = words
        for span in kept.sorted(by: { $0.first > $1.first }) {
            let leading = String(result[span.first].prefix { leadingPunctuation.contains($0) })
            let trailing = String(result[span.last].reversed().prefix { trailingPunctuation.contains($0) }.reversed())
            result.replaceSubrange(span.first...span.last, with: [leading + canonicals[span.term] + trailing])
        }
        return result == words ? nil : result
    }

    /// Ordinary English: the word's letters, lowercased with edge punctuation stripped, form an
    /// ordinary word, or `a` or `i`. Anything holding a digit is not ordinary.
    static func isOrdinary(_ word: String, ordinaryWords: Set<String>) -> Bool {
        var core = Substring(word)
        while let first = core.first, leadingPunctuation.contains(first) || trailingPunctuation.contains(first) {
            core = core.dropFirst()
        }
        while let last = core.last, trailingPunctuation.contains(last) || leadingPunctuation.contains(last) {
            core = core.dropLast()
        }
        let lowered = core.lowercased()
        guard !lowered.isEmpty, !lowered.contains(where: \.isNumber) else { return false }
        return lowered == "a" || lowered == "i" || ordinaryWords.contains(lowered)
    }

    /// The `contains_exact_term` rule: a surface bounded by non-word characters where its own edge
    /// is a word character.
    static func containsWholeWord(_ text: String, _ surface: String, caseInsensitive: Bool) -> Bool {
        guard let head = surface.first, let tail = surface.last else { return false }
        let prefix = head.isLetter || head.isNumber || head == "_" ? "(?<!\\w)" : ""
        let suffix = tail.isLetter || tail.isNumber || tail == "_" ? "(?!\\w)" : ""
        let pattern = prefix + NSRegularExpression.escapedPattern(for: surface) + suffix
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: caseInsensitive ? [.caseInsensitive] : []
            )
        else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func uppercasedFirst(_ text: String) -> String {
        guard let first = text.unicodeScalars.first else { return text }
        return String(first).uppercased() + String(text.unicodeScalars.dropFirst())
    }
}
