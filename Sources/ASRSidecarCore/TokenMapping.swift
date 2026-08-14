import Foundation
import VoiceCore

/// Turns decoder output into the wire transcript. Pure: no C, no I/O, no clock.
public enum TokenMapping {
    /// Maps decoded segments 1:1 onto `ASRSegment`, grouping tokens into words.
    ///
    /// Words break at `isWordStart`, which parakeet.cpp sets from the SentencePiece
    /// meta-space marker. A word spans its first token's start to its last token's end and
    /// carries the *minimum* of its token posteriors: a word is only as trustworthy as its
    /// least certain piece, and averaging would let one confident piece mask a guessed one.
    public static func transcript(from segments: [ParakeetSegmentRaw]) -> ASRTranscript {
        let allTokens = segments.flatMap(\.tokens)
        guard !allTokens.isEmpty else {
            return ASRTranscript(text: "", language: "en", segments: nil, confidence: nil, confidenceMode: nil)
        }

        let wireSegments = segments.map { segment in
            let words = self.words(from: segment.tokens)
            return ASRSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                words: words.isEmpty ? nil : words
            )
        }

        let mean = allTokens.reduce(0.0) { $0 + Double($1.probability) } / Double(allTokens.count)
        return ASRTranscript(
            text: segments.map(\.text).joined(),
            language: "en",
            segments: wireSegments,
            confidence: mean,
            confidenceMode: .greedyTokenProb
        )
    }

    static func words(from tokens: [ParakeetToken]) -> [ASRWord] {
        var words: [ASRWord] = []
        for token in tokens {
            // Pieces before the first word-start token (rare, but possible when a decode
            // resumes mid-word) attach to a leading word rather than being dropped.
            if token.isWordStart || words.isEmpty {
                words.append(
                    ASRWord(
                        text: token.text,
                        startMs: token.startMs,
                        endMs: token.endMs,
                        confidence: Double(token.probability)
                    )
                )
                continue
            }
            var last = words[words.count - 1]
            last.text += token.text
            last.endMs = token.endMs
            last.confidence = min(last.confidence ?? 1, Double(token.probability))
            words[words.count - 1] = last
        }
        return
            words
            .map { word in
                var trimmed = word
                trimmed.text = word.text.trimmingCharacters(in: .whitespaces)
                return trimmed
            }
            .filter { !$0.text.isEmpty }
    }
}
