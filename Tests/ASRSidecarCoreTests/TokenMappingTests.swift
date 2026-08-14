import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

@Suite("TokenMappingTests")
struct TokenMappingTests {
    private func token(
        _ text: String,
        _ probability: Float,
        _ startMs: Int,
        _ endMs: Int,
        wordStart: Bool
    ) -> ParakeetToken {
        ParakeetToken(
            piece: wordStart ? "\u{2581}" + text.trimmingCharacters(in: .whitespaces) : text,
            text: text,
            probability: probability,
            startMs: startMs,
            endMs: endMs,
            isWordStart: wordStart
        )
    }

    private func isClose(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-6
    }

    @Test func wordsBreakAtWordStartAndSpanTheirPieces() {
        let tokens = [
            token("Hello", 0.9, 0, 80, wordStart: true),
            token(" wor", 0.7, 80, 160, wordStart: true),
            token("ld", 0.5, 160, 240, wordStart: false),
        ]

        let words = TokenMapping.words(from: tokens)

        #expect(words.count == 2)
        #expect(words[0].text == "Hello")
        #expect(words[0].startMs == 0)
        #expect(words[0].endMs == 80)
        #expect(words[1].text == "world")
        #expect(words[1].startMs == 80)
        #expect(words[1].endMs == 240)
    }

    @Test func wordConfidenceIsTheMinimumOfItsTokens() {
        let tokens = [
            token(" un", 0.95, 0, 80, wordStart: true),
            token("like", 0.25, 80, 160, wordStart: false),
            token("ly", 0.875, 160, 240, wordStart: false),
        ]

        let words = TokenMapping.words(from: tokens)

        #expect(words.count == 1)
        #expect(words[0].text == "unlikely")
        // A word is only as trustworthy as its least certain piece.
        #expect(isClose(words[0].confidence, 0.25))
    }

    @Test func transcriptConfidenceIsTheMeanTokenProbabilityAcrossSegments() {
        let segments = [
            ParakeetSegmentRaw(
                startMs: 0,
                endMs: 240,
                text: "Hello world",
                tokens: [
                    token("Hello", 1.0, 0, 80, wordStart: true),
                    token(" world", 0.5, 80, 240, wordStart: true),
                ]
            ),
            ParakeetSegmentRaw(
                startMs: 240,
                endMs: 320,
                text: " again",
                tokens: [token(" again", 0.0, 240, 320, wordStart: true)]
            ),
        ]

        let transcript = TokenMapping.transcript(from: segments)

        #expect(transcript.text == "Hello world again")
        #expect(transcript.language == "en")
        #expect(transcript.confidenceMode == .greedyTokenProb)
        #expect(isClose(transcript.confidence, 0.5))
        #expect(transcript.segments?.count == 2)
        #expect(transcript.segments?[0].words?.count == 2)
        #expect(transcript.segments?[1].startMs == 240)
    }

    @Test func emptyDecodeReportsNoConfidenceAndNoMode() {
        let transcript = TokenMapping.transcript(from: [])

        #expect(transcript.text.isEmpty)
        #expect(transcript.segments == nil)
        #expect(transcript.confidence == nil)
        #expect(transcript.confidenceMode == nil)
    }

    @Test func segmentWithoutWordStartStillProducesAWord() {
        // A decode can begin mid-word; dropping those pieces would silently lose text.
        let tokens = [
            token("ld", 0.6, 0, 80, wordStart: false),
            token(" next", 0.7, 80, 160, wordStart: true),
        ]

        let words = TokenMapping.words(from: tokens)

        #expect(words.map(\.text) == ["ld", "next"])
    }
}
