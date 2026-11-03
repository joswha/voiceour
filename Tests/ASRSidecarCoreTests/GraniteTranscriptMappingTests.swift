import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

@Suite("GraniteTranscriptMappingTests")
struct GraniteTranscriptMappingTests {
    private static let nospeech: Int32 = 7
    private static let msPerFrame = 80

    private func token(
        _ bytes: [UInt8],
        _ probability: Float = 0.9,
        frames: (Int32, Int32) = (0, 1),
        id: Int32 = 100,
        special: Bool = false
    ) -> GraniteRawToken {
        GraniteRawToken(
            id: id,
            frameBegin: frames.0,
            frameEnd: frames.1,
            probability: probability,
            isSpecial: special,
            bytes: bytes
        )
    }

    private func token(
        _ text: String,
        _ probability: Float = 0.9,
        frames: (Int32, Int32) = (0, 1),
        id: Int32 = 100,
        special: Bool = false
    ) -> GraniteRawToken {
        token(Array(text.utf8), probability, frames: frames, id: id, special: special)
    }

    private var nospeechToken: GraniteRawToken {
        token("<|nospeech|>", 0.99, id: Self.nospeech, special: true)
    }

    private func map(_ tokens: [GraniteRawToken]) -> ASRTranscript {
        GraniteTranscriptMapping.transcript(
            from: GraniteRawResult(tokens: tokens, msPerFrame: Self.msPerFrame, nospeechTokenId: Self.nospeech)
        )
    }

    private func isClose(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-6
    }

    /// The empty shape is the one `TokenMapping` already produces, so the client cannot tell
    /// which backend found nothing to transcribe.
    @Test func noTokensProduceTheSameEmptyTranscriptAsParakeet() {
        let transcript = map([])

        #expect(transcript == TokenMapping.transcript(from: []))
        #expect(transcript.text == "")
        #expect(transcript.language == "en")
        #expect(transcript.segments == nil)
        #expect(transcript.confidence == nil)
        #expect(transcript.confidenceMode == nil)
    }

    @Test func onlySpecialTokensAreEmpty() {
        let transcript = map([token("<|en|>", 0.8, id: 3, special: true)])

        #expect(transcript == GraniteTranscriptMapping.emptyTranscript)
    }

    @Test func nospeechAloneIsEmpty() {
        #expect(map([nospeechToken]) == GraniteTranscriptMapping.emptyTranscript)
    }

    /// Punctuation beside the silence marker is not speech.
    @Test func nospeechWithOnlyPunctuationIsEmpty() {
        let transcript = map([nospeechToken, token("."), token(" ,")])

        #expect(transcript == GraniteTranscriptMapping.emptyTranscript)
    }

    /// The marker is evidence, not a veto: real words beside it are kept.
    @Test func nospeechWithRealWordsKeepsTheWords() {
        let transcript = map([nospeechToken, token(" yes", 0.5, frames: (2, 4)), token(".", 0.7, frames: (4, 5))])

        #expect(transcript.text == "yes.")
        #expect(transcript.segments?.first?.words?.map(\.text) == ["yes."])
        // The special marker contributes neither text nor confidence.
        #expect(isClose(transcript.confidence, 0.6))
    }

    @Test func nospeechWithOnlyANumberKeepsIt() {
        #expect(map([nospeechToken, token(" 42")]).text == "42")
    }

    /// Without the marker, punctuation alone is still transcript text.
    @Test func punctuationWithoutNospeechIsKept() {
        #expect(map([token(".")]).text == ".")
    }

    @Test func wordsStartAtALeadingSpaceByteAndSpanTheirTokens() throws {
        let transcript = map([
            token(" Hel", 0.9, frames: (1, 2)),
            token("lo", 0.8, frames: (2, 3)),
            token(" world", 0.7, frames: (4, 6)),
            token(",", 0.6, frames: (6, 7)),
        ])

        #expect(transcript.text == "Hello world,")
        let words = try #require(transcript.segments?.first?.words)
        #expect(words.map(\.text) == ["Hello", "world,"])
        #expect(words[0].startMs == 80)
        #expect(words[0].endMs == 240)
        #expect(words[1].startMs == 320)
        #expect(words[1].endMs == 560)
    }

    /// The first text token starts a word even without a leading space.
    @Test func theFirstTextTokenStartsAWord() {
        let transcript = map([token("Hi", 0.9, frames: (0, 1)), token("!", 0.9, frames: (1, 2))])

        #expect(transcript.segments?.first?.words?.map(\.text) == ["Hi!"])
    }

    /// A multi-byte character split across tokens decodes whole, and its continuation bytes
    /// never start a word.
    @Test func partialUTF8AcrossTokensDecodesWhole() {
        let e = Array("é".utf8)
        #expect(e.count == 2)
        let transcript = map([
            token(Array(" caf".utf8) + [e[0]], 0.9, frames: (0, 2)),
            token([e[1]], 0.4, frames: (2, 3)),
            token(" au", 0.8, frames: (3, 4)),
            token(" lait", 0.8, frames: (4, 5)),
        ])

        #expect(transcript.text == "café au lait")
        let words = transcript.segments?.first?.words
        #expect(words?.map(\.text) == ["café", "au", "lait"])
        #expect(words?.first?.endMs == 240)
        #expect(isClose(words?.first?.confidence, Double(Float(0.4))))
    }

    /// Bytes that never complete a scalar are replaced, not dropped and not fatal.
    @Test func invalidUTF8DecodesLossily() {
        let transcript = map([token(Array(" ok".utf8) + [0xFF])])

        #expect(transcript.text == "ok\u{FFFD}")
    }

    @Test func whitespaceRunsCollapseAndTrim() {
        let transcript = map([
            token("  Hello", 0.9, frames: (0, 1)),
            token(" \t", 0.9, frames: (1, 2)),
            token("\n world\r\n", 0.9, frames: (2, 3)),
            token(" ", 0.9, frames: (3, 4)),
        ])

        #expect(transcript.text == "Hello world")
        let words = transcript.segments?.first?.words
        // " \t" opens a word that "\n world\r\n" (no leading space) continues; the trailing " "
        // opens one that collapses to nothing and is dropped.
        #expect(words?.map(\.text) == ["Hello", "world"])
        #expect(words?[1].startMs == 80)
        #expect(words?[1].endMs == 240)
        #expect(transcript.segments?.first?.endMs == 240)
    }

    @Test func whitespaceOnlyTextIsEmpty() {
        #expect(map([token(" "), token("\t\n")]) == GraniteTranscriptMapping.emptyTranscript)
    }

    /// Word confidence is the minimum of its tokens; transcript confidence is the mean over
    /// every text token; timing is frame index times the encoder frame duration.
    @Test func timingAndConfidenceFollowTheFormulas() throws {
        let transcript = map([
            token(" un", 0.95, frames: (3, 4)),
            token("like", 0.25, frames: (5, 6)),
            token("ly", 0.875, frames: (7, 9)),
            token(" so", 0.5, frames: (10, 12)),
        ])

        let segment = try #require(transcript.segments?.first)
        #expect(transcript.segments?.count == 1)
        #expect(segment.text == "unlikely so")
        #expect(segment.startMs == 3 * 80)
        #expect(segment.endMs == 12 * 80)
        #expect(segment.words?.map(\.startMs) == [240, 800])
        #expect(segment.words?.map(\.endMs) == [720, 960])
        #expect(isClose(segment.words?[0].confidence, Double(Float(0.25))))
        #expect(isClose(segment.words?[1].confidence, Double(Float(0.5))))
        let mean = (Double(Float(0.95)) + Double(Float(0.25)) + Double(Float(0.875)) + Double(Float(0.5))) / 4
        #expect(isClose(transcript.confidence, mean))
        #expect(transcript.confidenceMode == .greedyTokenProb)
        #expect(transcript.language == "en")
    }

    /// Special tokens carry no text, start no word, and do not enter the mean.
    @Test func specialTokensAreExcludedFromTextWordsAndConfidence() {
        let transcript = map([
            token("<|en|>", 0.01, frames: (0, 1), id: 3, special: true),
            token(" good", 0.8, frames: (1, 2)),
            token("<|pause|>", 0.02, frames: (2, 3), id: 4, special: true),
            token("bye", 0.6, frames: (3, 4)),
        ])

        #expect(transcript.text == "goodbye")
        #expect(transcript.segments?.first?.words?.map(\.text) == ["goodbye"])
        #expect(transcript.segments?.first?.startMs == 80)
        #expect(transcript.segments?.first?.endMs == 320)
        #expect(isClose(transcript.confidence, (Double(Float(0.8)) + Double(Float(0.6))) / 2))
    }

    /// A vocabulary without the marker (`-1`) never triggers the silence rule.
    @Test func aMissingNospeechIdNeverEmptiesPunctuation() {
        let transcript = GraniteTranscriptMapping.transcript(
            from: GraniteRawResult(tokens: [token(".", id: -1)], msPerFrame: 80, nospeechTokenId: -1)
        )

        #expect(transcript.text == ".")
    }
}
