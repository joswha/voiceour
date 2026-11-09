import Foundation

/// Decides whether a bound agent session sent a dictation as a prompt.
///
/// Only the bound session's own prompts are considered, so this never infers
/// which session a dictation went to: it only checks whether the session the
/// dictation was pasted into sent it. The earliest prompt sent no later than
/// `sendWindow` after the binding whose words carry the dictation's matches.
/// Alignment is an approximate substring match over lower-cased word tokens,
/// so a prompt that wraps the dictation in other text, or edits a few of its
/// words, still matches. Pure and deterministic.
public enum AgentPromptSendMatcher {
    /// How long after the binding its prompt may be sent.
    public static let sendWindow: TimeInterval = 1_800
    /// The smallest alignment score, `1 - editDistance / dictationTokens`,
    /// that matches.
    public static let minimumScore = 0.6
    /// Dictations with fewer tokens match only a prompt that starts or ends
    /// with exactly their tokens: a short phrase aligns inside almost any
    /// prompt.
    public static let exactBelowTokens = 3

    /// The dictation's send state given the bound session's `prompts`.
    ///
    /// Returns `.sent` for the earliest matching prompt; `.notSent` when the
    /// dictation has no words, or when no prompt matches and the send window
    /// has closed at `now`; nil while the window is still open.
    public static func resolve(
        dictation: String,
        boundAt: Date,
        prompts: [AgentSessionPrompt],
        now: Date
    ) -> AgentPromptSend? {
        let words = tokens(of: dictation).map(\.text)
        guard !words.isEmpty else { return .notSent }
        var ids: [String: Int] = [:]
        let dictationIds = words.map { word in
            if let id = ids[word] { return id }
            let id = ids.count
            ids[word] = id
            return id
        }

        let latest = boundAt.addingTimeInterval(sendWindow)
        let candidates = prompts.enumerated()
            .filter { $0.element.sentAt <= latest }
            .sorted { lhs, rhs in
                if lhs.element.sentAt != rhs.element.sentAt { return lhs.element.sentAt < rhs.element.sentAt }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        for prompt in candidates {
            let candidate = tokens(of: prompt.text)
            let span: Range<Int>
            if words.count < exactBelowTokens {
                guard let edge = edgeSpan(words, in: candidate.map(\.text)) else { continue }
                span = edge
            } else {
                let promptIds = candidate.map { ids[$0.text] ?? -1 }
                guard let aligned = align(dictationIds, in: promptIds) else { continue }
                span = aligned
            }
            return .sent(
                sentAt: prompt.sentAt,
                text: sentText(prompt.text, tokens: candidate, span: span, dictation: dictation)
            )
        }
        return now >= latest ? .notSent : nil
    }

    private struct Token {
        var text: String
        var range: Range<String.Index>
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "'"
            || character == "\u{2019}"
    }

    /// Maximal runs of token characters, lower-cased, with their ranges.
    private static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if isTokenCharacter(text[index]) {
                if start == nil { start = index }
            } else if let tokenStart = start {
                tokens.append(Token(text: text[tokenStart..<index].lowercased(), range: tokenStart..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let tokenStart = start {
            tokens.append(Token(text: text[tokenStart...].lowercased(), range: tokenStart..<text.endIndex))
        }
        return tokens
    }

    /// The prompt's leading tokens when they are exactly `words`, else its
    /// trailing tokens when they are, else nil.
    private static func edgeSpan(_ words: [String], in prompt: [String]) -> Range<Int>? {
        let count = words.count
        guard prompt.count >= count else { return nil }
        if prompt.prefix(count).elementsEqual(words) { return 0..<count }
        if prompt.suffix(count).elementsEqual(words) { return (prompt.count - count)..<prompt.count }
        return nil
    }

    /// Sellers' approximate substring alignment: the prompt token span with
    /// the smallest edit distance to the whole dictation, earliest end on ties.
    /// Returns the span when it is non-empty and scores at least
    /// `minimumScore`.
    private static func align(_ dictation: [Int], in prompt: [Int]) -> Range<Int>? {
        let n = dictation.count
        let m = prompt.count
        guard m > 0 else { return nil }
        var previous = [Int](repeating: 0, count: m + 1)
        var previousStart = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        var currentStart = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = i
            currentStart[0] = 0
            for j in 1...m {
                let diagonal = previous[j - 1] + (dictation[i - 1] == prompt[j - 1] ? 0 : 1)
                let up = previous[j] + 1
                let left = current[j - 1] + 1
                if diagonal <= up, diagonal <= left {
                    current[j] = diagonal
                    currentStart[j] = previousStart[j - 1]
                } else if up <= left {
                    current[j] = up
                    currentStart[j] = previousStart[j]
                } else {
                    current[j] = left
                    currentStart[j] = currentStart[j - 1]
                }
            }
            swap(&previous, &current)
            swap(&previousStart, &currentStart)
        }

        var end = 0
        for j in 1...m where previous[j] < previous[end] {
            end = j
        }
        let start = previousStart[end]
        let score = 1 - Double(previous[end]) / Double(n)
        guard start < end, score >= minimumScore else { return nil }
        return start..<end
    }

    /// The prompt text covering `span`, widened over adjoining punctuation,
    /// or nil when it equals the dictation up to whitespace.
    private static func sentText(
        _ prompt: String,
        tokens: [Token],
        span: Range<Int>,
        dictation: String
    ) -> String? {
        var lower = tokens[span.lowerBound].range.lowerBound
        var upper = tokens[span.upperBound - 1].range.upperBound
        func isPunctuation(_ character: Character) -> Bool {
            !character.isWhitespace && !isTokenCharacter(character)
        }
        while lower > prompt.startIndex {
            let before = prompt.index(before: lower)
            guard isPunctuation(prompt[before]) else { break }
            lower = before
        }
        while upper < prompt.endIndex, isPunctuation(prompt[upper]) {
            upper = prompt.index(after: upper)
        }
        let sent = String(prompt[lower..<upper])
        return collapse(sent) == collapse(dictation) ? nil : sent
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
