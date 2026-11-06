import Foundation
import Testing

@testable import ASRSidecarCore

/// The spotter over small synthetic logit matrices: vocabulary 4, blank 0, every frame's greedy
/// label at 0 nats and every other label 5 nats below it unless a case says otherwise.
@Suite("CTCWordSpotterTests")
struct CTCWordSpotterTests {
    private static let vocabulary = 4

    /// Frame-major logits whose greedy label at frame `t` is `greedy[t]`; `overrides` sets single
    /// cells, as (frame, label, value) with the greedy label at 0.
    private func logits(greedy: [Int], overrides: [(Int, Int, Float)] = []) -> [Float] {
        var values = [Float](repeating: -5, count: greedy.count * Self.vocabulary)
        for (frame, label) in greedy.enumerated() {
            values[frame * Self.vocabulary + label] = 0
        }
        for (frame, label, value) in overrides {
            values[frame * Self.vocabulary + label] = value
        }
        return values
    }

    private func candidates(_ values: [Float], frames: Int, patterns: [[Int32]]) -> [CTCSpotCandidate] {
        values.withUnsafeBufferPointer {
            CTCWordSpotter.candidates(
                logits: $0,
                frames: frames,
                vocabulary: Self.vocabulary,
                blank: 0,
                patterns: patterns.enumerated().map { CTCSpotPattern(term: $0.offset, variant: 0, tokens: $0.element) }
            )
        }
    }

    /// The greedy path spells `1 2` over frames 1...2: that window scores 0, and every
    /// overlapping window of the same term is suppressed behind it.
    @Test func findsTheWindowTheGreedyPathSpells() throws {
        let found = candidates(logits(greedy: [0, 1, 2, 0, 3, 0]), frames: 6, patterns: [[1, 2]])

        #expect(found.count == 1)
        let spot = try #require(found.first)
        #expect(spot.startFrame == 1)
        #expect(spot.endFrame == 2)
        #expect(spot.score == 0)
        #expect(spot.tokenCount == 2)
    }

    /// `1 1 2` and `1 2` both spell the pattern at score 0: the later start wins, so the window
    /// is minimal.
    @Test func aTieTakesTheLaterStart() {
        let found = candidates(logits(greedy: [1, 1, 2, 0]), frames: 4, patterns: [[1, 2]])

        #expect(found.map(\.startFrame) == [1])
        #expect(found.map(\.endFrame) == [2])
    }

    /// Three tokens 5 nats down each total −15, under the −12 floor; one token 4 nats down is
    /// within −12 but under the −3 per-token floor. Neither is a candidate.
    @Test func theFloorsRejectWeakPaths() {
        let total = candidates(logits(greedy: [0, 0, 0, 0]), frames: 4, patterns: [[1, 2, 3]])
        let perToken = candidates(
            logits(greedy: [0, 0], overrides: [(1, 3, -4)]),
            frames: 2,
            patterns: [[3]]
        )

        #expect(total.isEmpty)
        #expect(perToken.isEmpty)
    }

    /// Just inside both floors: two tokens 3 nats down each are −6 total and −3 per token.
    @Test func aPathOnTheFloorsIsKept() {
        let found = candidates(
            logits(greedy: [0, 0, 0], overrides: [(1, 1, -3), (2, 2, -3)]),
            frames: 3,
            patterns: [[1, 2]]
        )

        #expect(found.map(\.score) == [-6])
        #expect(found.map(\.startFrame) == [1])
    }
}
