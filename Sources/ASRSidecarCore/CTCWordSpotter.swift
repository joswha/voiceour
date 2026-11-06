import Accelerate
import Foundation
import VoiceCore

/// One token sequence to look for: variant `variant` of term `term`.
public struct CTCSpotPattern: Equatable, Sendable {
    public var term: Int
    public var variant: Int
    public var tokens: [Int32]

    public init(term: Int, variant: Int, tokens: [Int32]) {
        self.term = term
        self.variant = variant
        self.tokens = tokens
    }
}

/// A frame window where a pattern's best CTC path scores within the floors of the greedy path.
public struct CTCSpotCandidate: Equatable, Sendable {
    public var term: Int
    public var variant: Int
    /// First frame of the path's first label, inclusive.
    public var startFrame: Int
    /// Frame where the path ends in its last label, inclusive.
    public var endFrame: Int
    /// Path score minus the greedy path's over the same frames: ≤ 0, and 0 exactly when the
    /// greedy path itself spells the pattern there.
    public var score: Float
    public var tokenCount: Int
}

/// CTC word spotting over a model's own logits, for a caller's list of terms.
///
/// Scores are greedy-normalized: `A[t][v] = Z[t][v] − max_u Z[t][u]`, so the log-softmax normalizer
/// cancels and a pattern's score is how much worse its best path is than whatever the greedy decode
/// emitted over the same frames. Each pattern runs CTC Viterbi over its labels with blanks between
/// them: a free start at any frame, the standard stay and advance moves, the blank skip only between
/// differing labels, and an end at the last label. Ties take the later start, so windows are minimal.
public enum CTCWordSpotter {
    public static let scoreFloor: Float = -12
    public static let perTokenFloor: Float = -3

    /// Every pattern's candidates above the floors, suppressed within each term: by score, then
    /// shorter window, then lower variant index, a candidate survives unless its window shares a
    /// frame with one already kept. Sorted by start frame, then term.
    public static func candidates(
        logits: UnsafeBufferPointer<Float>,
        frames: Int,
        vocabulary: Int,
        blank: Int32,
        patterns: [CTCSpotPattern]
    ) -> [CTCSpotCandidate] {
        guard let grid = NormalizedLogits(logits: logits, frames: frames, vocabulary: vocabulary, blank: blank) else {
            return []
        }
        var raw: [Int: [CTCSpotCandidate]] = [:]
        for pattern in patterns where !pattern.tokens.isEmpty {
            let found = run(pattern, over: grid)
            if !found.isEmpty {
                raw[pattern.term, default: []].append(contentsOf: found)
            }
        }
        var kept: [CTCSpotCandidate] = []
        for term in raw.keys.sorted() {
            kept.append(contentsOf: suppressed(raw[term] ?? []))
        }
        return kept.sorted { ($0.startFrame, $0.term) < ($1.startFrame, $1.term) }
    }

    private static func suppressed(_ candidates: [CTCSpotCandidate]) -> [CTCSpotCandidate] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsLength = lhs.endFrame - lhs.startFrame
            let rhsLength = rhs.endFrame - rhs.startFrame
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            if lhs.variant != rhs.variant { return lhs.variant < rhs.variant }
            return lhs.startFrame < rhs.startFrame
        }
        var kept: [CTCSpotCandidate] = []
        for candidate in ordered where !kept.contains(where: { $0.overlaps(candidate) }) {
            kept.append(candidate)
        }
        return kept
    }

    private static func run(_ pattern: CTCSpotPattern, over grid: NormalizedLogits) -> [CTCSpotCandidate] {
        let tokens = pattern.tokens
        guard tokens.allSatisfy({ $0 >= 0 && Int($0) < grid.vocabulary }) else { return [] }
        let stateCount = 2 * tokens.count - 1
        var previous = [Float](repeating: -.infinity, count: stateCount)
        var previousStart = [Int](repeating: -1, count: stateCount)
        var current = previous
        var currentStart = previousStart
        var found: [CTCSpotCandidate] = []

        for frame in 0..<grid.frames {
            for state in 0..<stateCount {
                var best: Float
                var bestStart: Int
                if state == 0 {
                    // A fresh start scores 0 before its first label; every running path is ≤ 0, so
                    // the fresh start is never worse and wins ties as the later start.
                    best = 0
                    bestStart = frame
                } else {
                    best = previous[state]
                    bestStart = previousStart[state]
                    consider(previous[state - 1], previousStart[state - 1], &best, &bestStart)
                    if state % 2 == 0, tokens[state / 2] != tokens[state / 2 - 1] {
                        consider(previous[state - 2], previousStart[state - 2], &best, &bestStart)
                    }
                }
                let label = state % 2 == 0 ? tokens[state / 2] : grid.blank
                current[state] = best == -.infinity ? -.infinity : best + grid.emission(frame, label)
                currentStart[state] = bestStart
            }
            let score = current[stateCount - 1]
            if score >= scoreFloor, score / Float(tokens.count) >= perTokenFloor {
                found.append(
                    CTCSpotCandidate(
                        term: pattern.term,
                        variant: pattern.variant,
                        startFrame: currentStart[stateCount - 1],
                        endFrame: frame,
                        score: score,
                        tokenCount: tokens.count
                    )
                )
            }
            swap(&previous, &current)
            swap(&previousStart, &currentStart)
        }
        return found
    }

    private static func consider(_ score: Float, _ start: Int, _ best: inout Float, _ bestStart: inout Int) {
        if score > best || (score == best && start > bestStart) {
            best = score
            bestStart = start
        }
    }
}

extension CTCSpotCandidate {
    /// Whether the two windows share a frame.
    func overlaps(_ other: CTCSpotCandidate) -> Bool {
        startFrame <= other.endFrame && other.startFrame <= endFrame
    }
}

/// Frame-major logits with each frame's maximum precomputed, read as greedy-normalized scores.
private struct NormalizedLogits {
    let base: UnsafePointer<Float>
    let frames: Int
    let vocabulary: Int
    let blank: Int32
    let rowMax: [Float]

    init?(logits: UnsafeBufferPointer<Float>, frames: Int, vocabulary: Int, blank: Int32) {
        guard frames > 0, vocabulary > 0, logits.count >= frames * vocabulary, let base = logits.baseAddress,
            blank >= 0, Int(blank) < vocabulary
        else { return nil }
        var rowMax = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            vDSP_maxv(base + frame * vocabulary, 1, &rowMax[frame], vDSP_Length(vocabulary))
        }
        self.base = base
        self.frames = frames
        self.vocabulary = vocabulary
        self.blank = blank
        self.rowMax = rowMax
    }

    /// `Z[frame][label] − max_u Z[frame][u]`: 0 for the greedy choice, negative otherwise.
    func emission(_ frame: Int, _ label: Int32) -> Float {
        base[frame * vocabulary + Int(label)] - rowMax[frame]
    }
}

/// Places CTC spot candidates on a Granite transcript's words.
public enum GraniteTermSpotting {
    /// A word is covered when at least half of its tokens' CTC-run frames lie inside the window. A
    /// candidate covering no word, a non-contiguous set, or a word with a letter- or digit-bearing
    /// token entirely outside the window keeps a nil word range: replacing whole words would drop
    /// that token's text, as in `CSRF-protected`, so the spot cannot be rendered.
    public static func spots(from candidates: [CTCSpotCandidate], raw: GraniteRawResult) -> [TermSpot] {
        let groups = GraniteTranscriptMapping.wordGroups(from: raw.tokens.filter { !$0.isSpecial })
        return candidates.map { candidate in
            var covered: [Int] = []
            var partial = false
            for (index, group) in groups.enumerated() {
                var total = 0
                var inside = 0
                var outsideText = false
                for token in group.tokens {
                    let begin = Int(token.frameBegin)
                    let end = Int(token.frameEnd)
                    let overlap = max(0, min(end, candidate.endFrame + 1) - max(begin, candidate.startFrame))
                    total += max(0, end - begin)
                    inside += overlap
                    if overlap == 0, bearsText(token.bytes) { outsideText = true }
                }
                if inside > 0, 2 * inside >= total {
                    covered.append(index)
                    partial = partial || outsideText
                }
            }
            let renderable = !partial && !covered.isEmpty && covered.last! - covered.first! + 1 == covered.count
            return TermSpot(
                term: candidate.term,
                variant: candidate.variant,
                firstWord: renderable ? covered.first : nil,
                lastWord: renderable ? covered.last : nil,
                startMs: candidate.startFrame * raw.msPerFrame,
                endMs: (candidate.endFrame + 1) * raw.msPerFrame,
                score: Double(candidate.score),
                tokenCount: candidate.tokenCount
            )
        }
    }

    /// Whether a token's bytes hold a letter or digit, rather than only spaces and punctuation.
    private static func bearsText(_ bytes: [UInt8]) -> Bool {
        GraniteTranscriptMapping.containsLetterOrNumber(String(decoding: bytes, as: UTF8.self))
    }
}
