import Foundation

/// Links dictations to the agent prompts they were sent as.
///
/// A dictation links to the earliest prompt sent from `earlySendTolerance`
/// before it to `sendWindow` after it whose words align with the dictation's
/// at `minimumScore` or better. Alignment is an approximate substring match
/// over lower-cased word tokens, so a prompt that wraps the dictation in other
/// text, or edits a few of its words, still links. Pure and deterministic.
public enum AgentSessionLinker {
    /// How long after a dictation its prompt may be sent.
    public static let sendWindow: TimeInterval = 1_800
    /// How long before a dictation's row was written its prompt may carry as
    /// a timestamp: the row is written after delivery.
    public static let earlySendTolerance: TimeInterval = 5
    /// The smallest alignment score, `1 - editDistance / dictationTokens`,
    /// that links.
    public static let minimumScore = 0.6
    /// Dictations with fewer tokens link only to a prompt with exactly their
    /// tokens: a short phrase aligns inside almost any prompt.
    public static let wholePromptBelowTokens = 3

    public struct Dictation: Equatable, Sendable {
        public var id: UUID
        public var createdAt: Date
        public var text: String

        public init(id: UUID, createdAt: Date, text: String) {
            self.id = id
            self.createdAt = createdAt
            self.text = text
        }
    }

    /// The earliest send time any of `dictations` can link to, or nil when
    /// there are none.
    public static func earliestSend(for dictations: [Dictation]) -> Date? {
        dictations.map(\.createdAt).min().map { $0.addingTimeInterval(-earlySendTolerance) }
    }

    /// Each dictation's link, keyed by its id. A dictation with no matching
    /// prompt is `.unmatched` once its send window has closed at `now`, and
    /// absent from the result while it is still open.
    public static func resolve(
        _ dictations: [Dictation],
        prompts: [AgentPrompt],
        now: Date
    ) -> [UUID: AgentSessionLink] {
        let agentOrder = Dictionary(
            uniqueKeysWithValues: CodingAgent.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        let sorted = prompts.sorted { lhs, rhs in
            if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
            if lhs.agent != rhs.agent { return agentOrder[lhs.agent]! < agentOrder[rhs.agent]! }
            return lhs.sessionId < rhs.sessionId
        }
        var promptTokens = [[Token]?](repeating: nil, count: sorted.count)
        var results: [UUID: AgentSessionLink] = [:]

        for dictation in dictations {
            let words = tokens(of: dictation.text).map(\.text)
            guard !words.isEmpty else {
                results[dictation.id] = .unmatched
                continue
            }
            var ids: [String: Int] = [:]
            let dictationIds = words.map { word in
                if let id = ids[word] { return id }
                let id = ids.count
                ids[word] = id
                return id
            }

            let earliest = dictation.createdAt.addingTimeInterval(-earlySendTolerance)
            let latest = dictation.createdAt.addingTimeInterval(sendWindow)
            var index = firstIndex(in: sorted, sentAtOrAfter: earliest)
            var link: AgentSessionLink?
            while index < sorted.count, sorted[index].sentAt <= latest {
                let prompt = sorted[index]
                let candidate: [Token]
                if let cached = promptTokens[index] {
                    candidate = cached
                } else {
                    candidate = tokens(of: prompt.text)
                    promptTokens[index] = candidate
                }
                index += 1

                let span: Range<Int>
                if words.count < wholePromptBelowTokens {
                    guard candidate.map(\.text) == words else { continue }
                    span = 0..<candidate.count
                } else {
                    let promptIds = candidate.map { ids[$0.text] ?? -1 }
                    guard let aligned = align(dictationIds, in: promptIds) else { continue }
                    span = aligned
                }

                link = .linked(
                    AgentSessionMatch(
                        agent: prompt.agent,
                        sessionId: prompt.sessionId,
                        workingDirectory: prompt.workingDirectory,
                        sessionTitle: prompt.sessionTitle,
                        sentAt: prompt.sentAt,
                        sentText: sentText(prompt.text, tokens: candidate, span: span, dictation: dictation.text)
                    )
                )
                break
            }

            if let link {
                results[dictation.id] = link
            } else if now >= latest {
                results[dictation.id] = .unmatched
            }
        }
        return results
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

    private static func firstIndex(in prompts: [AgentPrompt], sentAtOrAfter date: Date) -> Int {
        var low = 0
        var high = prompts.count
        while low < high {
            let mid = (low + high) / 2
            if prompts[mid].sentAt < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
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
