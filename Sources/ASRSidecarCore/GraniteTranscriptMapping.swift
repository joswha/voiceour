import Foundation
import VoiceCore

/// One token of a Granite CTC decode, copied out of `granite_token` plus its decoded bytes.
public struct GraniteRawToken: Equatable, Sendable {
    /// Vocabulary id. The CTC blank never appears.
    public var id: Int32
    /// First encoder frame of this token's CTC run.
    public var frameBegin: Int32
    /// One past the last encoder frame of the run.
    public var frameEnd: Int32
    /// Softmax probability of `id` at `frameBegin`: the CTC first-frame posterior.
    public var probability: Float
    /// A tokenizer special token (for example `<|nospeech|>`), never transcript text.
    public var isSpecial: Bool
    /// This token's decoded bytes alone. May be a partial UTF-8 sequence: only the
    /// concatenation of consecutive tokens' bytes is guaranteed to be valid text.
    public var bytes: [UInt8]

    public init(id: Int32, frameBegin: Int32, frameEnd: Int32, probability: Float, isSpecial: Bool, bytes: [UInt8]) {
        self.id = id
        self.frameBegin = frameBegin
        self.frameEnd = frameEnd
        self.probability = probability
        self.isSpecial = isSpecial
        self.bytes = bytes
    }
}

/// Everything one Granite decode produced, with the model constants needed to interpret it.
public struct GraniteRawResult: Equatable, Sendable {
    public var tokens: [GraniteRawToken]
    /// Encoder frame duration: hop length times temporal subsampling (80 ms for the pin).
    public var msPerFrame: Int
    /// Vocabulary id of `<|nospeech|>`, or -1 when the vocabulary has none.
    public var nospeechTokenId: Int32

    public init(tokens: [GraniteRawToken], msPerFrame: Int, nospeechTokenId: Int32) {
        self.tokens = tokens
        self.msPerFrame = msPerFrame
        self.nospeechTokenId = nospeechTokenId
    }
}

/// Turns Granite CTC output into the wire transcript. Pure: no C, no I/O, no clock.
///
/// The text follows the upstream full-text semantics: the concatenated bytes of every
/// non-special token, decoded as UTF-8 (lossily), with runs of ASCII whitespace collapsed to one
/// space and trimmed at both ends. Words start at a token whose bytes begin with a space (the
/// SentencePiece meta-space the native side already rendered) and carry the *minimum* of their
/// tokens' posteriors.
public enum GraniteTranscriptMapping {
    public static func transcript(from raw: GraniteRawResult) -> ASRTranscript {
        let textTokens = raw.tokens.filter { !$0.isSpecial }
        let text = collapsedText(textTokens.flatMap(\.bytes))

        // The model marks silence with `<|nospeech|>`; whatever punctuation rides along with it
        // is not speech. Real words beside the marker are kept: the marker is evidence, not a veto.
        let emittedNospeech = raw.nospeechTokenId >= 0 && raw.tokens.contains { $0.id == raw.nospeechTokenId }
        if emittedNospeech, !containsLetterOrNumber(text) {
            return emptyTranscript
        }

        // Whitespace-only text tokens leave no text and no word, so they are as empty as no
        // text tokens at all: a segment needs a first and a last word to have bounds.
        let words = self.words(from: textTokens, msPerFrame: raw.msPerFrame)
        guard !text.isEmpty, let first = words.first, let last = words.last else {
            return emptyTranscript
        }

        let mean = textTokens.reduce(0.0) { $0 + Double($1.probability) } / Double(textTokens.count)
        // Granite emits no language tag; the text's own words name it, or nothing does.
        return ASRTranscript(
            text: text,
            language: DictationLanguage.detect(text)?.rawValue,
            segments: [ASRSegment(startMs: first.startMs, endMs: last.endMs, text: text, words: words)],
            confidence: mean,
            confidenceMode: .greedyTokenProb
        )
    }

    /// The transcript of a decode without tokens.
    static var emptyTranscript: ASRTranscript {
        ASRTranscript(text: "", language: nil, segments: nil, confidence: nil, confidenceMode: nil)
    }

    static func words(from textTokens: [GraniteRawToken], msPerFrame: Int) -> [ASRWord] {
        wordGroups(from: textTokens).map { group in
            ASRWord(
                text: group.text,
                startMs: Int(group.tokens[0].frameBegin) * msPerFrame,
                endMs: Int(group.tokens[group.tokens.count - 1].frameEnd) * msPerFrame,
                confidence: group.tokens.map { Double($0.probability) }.min()
            )
        }
    }

    /// The transcript's words as token groups, in order: a word starts at a token whose bytes begin
    /// with a space, and groups whose collapsed text is empty are dropped. Index `i` here is word `i`
    /// of the transcript, which is what lets frame-level evidence name words.
    static func wordGroups(from textTokens: [GraniteRawToken]) -> [(tokens: [GraniteRawToken], text: String)] {
        var groups: [[GraniteRawToken]] = []
        for token in textTokens {
            if groups.isEmpty || token.bytes.first == asciiSpace {
                groups.append([token])
            } else {
                groups[groups.count - 1].append(token)
            }
        }
        return groups.compactMap { group in
            let text = collapsedText(group.flatMap(\.bytes))
            return text.isEmpty ? nil : (group, text)
        }
    }

    /// Decodes `bytes` as UTF-8, replacing invalid sequences, after collapsing every run of
    /// ASCII space, tab, LF and CR to one space and trimming them at both ends.
    ///
    /// Collapsing on bytes is exact: those four bytes never occur inside a multi-byte UTF-8
    /// sequence, so no scalar can be split or merged by it.
    static func collapsedText(_ bytes: [UInt8]) -> String {
        var collapsed: [UInt8] = []
        collapsed.reserveCapacity(bytes.count)
        var pendingSpace = false
        for byte in bytes {
            if isCollapsibleWhitespace(byte) {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            if pendingSpace {
                collapsed.append(asciiSpace)
                pendingSpace = false
            }
            collapsed.append(byte)
        }
        return String(decoding: collapsed, as: UTF8.self)
    }

    private static let asciiSpace: UInt8 = 0x20

    private static func isCollapsibleWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Whether any scalar of `text` is a Unicode letter (L*) or number (N*).
    static func containsLetterOrNumber(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }
    }
}
