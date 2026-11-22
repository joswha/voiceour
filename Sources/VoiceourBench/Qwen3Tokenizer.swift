import Foundation

/// Encodes text into Qwen3 vocabulary ids the way the model's `tokenizer.json` does, and decodes ids back to the
/// bytes llama.cpp's `common_detokenize(_, _, special: false)` produces.
///
/// The reference tokenizer splits out its added tokens, normalizes every other span to NFC, pre-tokenizes with
/// the Qwen2 split regex, maps each pre-token's UTF-8 bytes through GPT-2's byte-to-unicode table, and merges
/// adjacent pieces lowest rank first, leftmost first among equal ranks, until no merge applies.
///
/// Added tokens follow llama.cpp's `parse_special = false`: only user-defined tokens (`<think>`, `<tool_call>`…)
/// are matched in the text, leftmost and longest first; control tokens such as `<|endoftext|>` are ordinary text,
/// as the reference tokenizer encodes them with `encode_special_tokens`. llama.cpp skips the NFC step for this
/// GGUF, so the two differ only on text that NFC changes.
struct Qwen3Tokenizer: Sendable {
    /// `tokenizer.ggml.token_type` numbering.
    enum Kind: Int32, Sendable {
        case normal = 1
        case unknown = 2
        case control = 3
        case userDefined = 4
        case unused = 5
        case byte = 6
    }

    struct Token: Sendable {
        var id: Int32
        var piece: String
        var kind: Kind
    }

    /// A merge as stored, `"left right"`, at its rank.
    struct Merge: Sendable {
        var rank: Int
        var text: String
    }

    enum BuildError: Error, Equatable {
        /// A merge that is not two vocabulary pieces separated by one space, or whose result is not a piece.
        case malformedMerge(rank: Int)
        /// A byte without its single-character byte-level piece.
        case missingBytePiece(UInt8)
    }

    private struct MergeEntry {
        let rank: Int32
        let result: Int32
    }

    private let byteIds: [Int32]
    private let merges: [UInt64: MergeEntry]
    /// User-defined pieces as UTF-8, longest first.
    private let userTokens: [(bytes: [UInt8], id: Int32)]
    /// What each id decodes to; ids without an entry decode to nothing.
    private let decoded: [Int32: [UInt8]]

    /// `tokens` may be a subset of the vocabulary and `merges` a subset of the merge list, as long as the subsets
    /// hold every piece and merge the encoded texts reach: ranks keep the full list's order.
    init(tokens: [Token], merges: [Merge]) throws {
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(tokens.count)
        var decoded: [Int32: [UInt8]] = [:]
        decoded.reserveCapacity(tokens.count)
        var userTokens: [(bytes: [UInt8], id: Int32)] = []
        for token in tokens {
            if ids[token.piece] == nil {
                ids[token.piece] = token.id
            }
            switch token.kind {
            case .normal:
                decoded[token.id] = Self.bytes(ofPiece: token.piece)
            case .userDefined:
                decoded[token.id] = Array(token.piece.utf8)
                userTokens.append((Array(token.piece.utf8), token.id))
            case .unknown, .control, .unused, .byte:
                break
            }
        }

        var byteIds: [Int32] = []
        byteIds.reserveCapacity(256)
        for byte in 0...255 {
            guard let id = ids[String(Character(Self.byteScalars[byte]))] else {
                throw BuildError.missingBytePiece(UInt8(byte))
            }
            byteIds.append(id)
        }

        var table: [UInt64: MergeEntry] = [:]
        table.reserveCapacity(merges.count)
        for merge in merges {
            guard let space = merge.text.firstIndex(of: " ") else { throw BuildError.malformedMerge(rank: merge.rank) }
            let left = String(merge.text[..<space])
            let right = String(merge.text[merge.text.index(after: space)...])
            guard let leftId = ids[left], let rightId = ids[right], let result = ids[left + right],
                let rank = Int32(exactly: merge.rank)
            else {
                throw BuildError.malformedMerge(rank: merge.rank)
            }
            let key = Self.key(leftId, rightId)
            if let existing = table[key], existing.rank <= rank { continue }
            table[key] = MergeEntry(rank: rank, result: result)
        }

        self.byteIds = byteIds
        self.merges = table
        self.userTokens = userTokens.sorted { $0.bytes.count > $1.bytes.count }
        self.decoded = decoded
    }

    // MARK: Encoding

    /// The ids of `text`.
    func encode(_ text: String) -> [Int32] {
        let bytes = Array(text.utf8)
        var ids: [Int32] = []
        var spanStart = 0
        var index = 0
        while index < bytes.count {
            if let match = userTokens.first(where: { Self.hasPrefix(bytes, at: index, $0.bytes) }) {
                encodeSpan(bytes[spanStart..<index], into: &ids)
                ids.append(match.id)
                index += match.bytes.count
                spanStart = index
            } else {
                index += 1
            }
        }
        encodeSpan(bytes[spanStart..<bytes.count], into: &ids)
        return ids
    }

    private func encodeSpan(_ bytes: ArraySlice<UInt8>, into ids: inout [Int32]) {
        guard !bytes.isEmpty else { return }
        let normalized = String(decoding: bytes, as: UTF8.self).precomposedStringWithCanonicalMapping
        let scalars = Array(normalized.unicodeScalars)
        var symbols: [Int32] = []
        for word in Self.preTokenize(scalars) {
            symbols.removeAll(keepingCapacity: true)
            for scalar in scalars[word] {
                UTF8.encode(scalar) { symbols.append(byteIds[Int($0)]) }
            }
            merge(&symbols)
            ids.append(contentsOf: symbols)
        }
    }

    private func merge(_ symbols: inout [Int32]) {
        while symbols.count > 1 {
            var bestIndex = -1
            var best = MergeEntry(rank: .max, result: -1)
            for index in 0..<(symbols.count - 1) {
                if let entry = merges[Self.key(symbols[index], symbols[index + 1])], entry.rank < best.rank {
                    best = entry
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { return }
            symbols[bestIndex] = best.result
            symbols.remove(at: bestIndex + 1)
        }
    }

    // MARK: Decoding

    /// The bytes `ids` decode to: normal tokens through the inverse byte map, user-defined tokens as written,
    /// control, unknown, unused and byte tokens as nothing. May hold partial UTF-8 at the ends.
    func decodeBytes(_ ids: some Sequence<Int32>) -> [UInt8] {
        var bytes: [UInt8] = []
        for id in ids {
            if let piece = decoded[id] {
                bytes.append(contentsOf: piece)
            }
        }
        return bytes
    }

    /// `decodeBytes` as text, malformed UTF-8 replaced.
    func decode(_ ids: some Sequence<Int32>) -> String {
        String(decoding: decodeBytes(ids), as: UTF8.self)
    }

    /// Whether `id` is a normal vocabulary piece, plain text: never a control, user-defined, unknown, unused or
    /// byte token.
    func isNormalToken(_ id: Int32) -> Bool {
        decoded[id] != nil && !userTokens.contains { $0.id == id }
    }

    // MARK: Qwen2 pre-tokenizer

    /// Splits `scalars` into the pre-tokens of the Qwen2 regex
    /// `(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+`,
    /// as llama.cpp's `unicode_regex_split_custom_qwen2` walks it. Contractions match ASCII letters of either case.
    static func preTokenize(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        let end = scalars.count
        var words: [Range<Int>] = []
        var previousEnd = 0
        func add(_ upTo: Int) {
            if upTo > previousEnd { words.append(previousEnd..<upTo) }
            previousEnd = upTo
        }
        func scalar(_ position: Int) -> Unicode.Scalar? { position < end ? scalars[position] : nil }
        func flags(_ position: Int) -> Flags { position < end ? Flags(scalars[position]) : Flags() }
        func lowered(_ position: Int) -> UInt32? {
            guard let value = scalar(position)?.value else { return nil }
            return (0x41...0x5A).contains(value) ? value + 0x20 : value
        }

        var position = 0
        while position < end {
            let current = scalars[position]
            let currentFlags = Flags(current)

            // (?i:'s|'t|'re|'ve|'m|'ll|'d)
            if current == "'", position + 1 < end, let next = lowered(position + 1) {
                if next == 0x73 || next == 0x74 || next == 0x6D || next == 0x64 {  // s t m d
                    position += 2
                    add(position)
                    continue
                }
                if position + 2 < end, let nextNext = lowered(position + 2),
                    (next == 0x72 && nextNext == 0x65) || (next == 0x76 && nextNext == 0x65)
                        || (next == 0x6C && nextNext == 0x6C)  // re ve ll
                {
                    position += 3
                    add(position)
                    continue
                }
            }

            // [^\r\n\p{L}\p{N}]?\p{L}+
            if !(current == "\r" || current == "\n" || currentFlags.isNumber),
                currentFlags.isLetter || flags(position + 1).isLetter
            {
                position += 1
                while flags(position).isLetter { position += 1 }
                add(position)
                continue
            }

            // \p{N}
            if currentFlags.isNumber {
                position += 1
                add(position)
                continue
            }

            // <space>?[^\s\p{L}\p{N}]+[\r\n]*
            var flags2 = current == " " ? flags(position + 1) : currentFlags
            if !(flags2.isWhitespace || flags2.isLetter || flags2.isNumber), currentFlags.isDefined {
                if current == " " { position += 1 }
                while !(flags2.isWhitespace || flags2.isLetter || flags2.isNumber), flags2.isDefined {
                    position += 1
                    flags2 = flags(position)
                }
                while let next = scalar(position), next == "\r" || next == "\n" { position += 1 }
                add(position)
                continue
            }

            var whitespaceCount = 0
            var lastLineBreakEnd = 0
            while flags(position + whitespaceCount).isWhitespace {
                let next = scalars[position + whitespaceCount]
                if next == "\r" || next == "\n" { lastLineBreakEnd = position + whitespaceCount + 1 }
                whitespaceCount += 1
            }
            // \s*[\r\n]+
            if lastLineBreakEnd > 0 {
                position = lastLineBreakEnd
                add(position)
                continue
            }
            // \s+(?!\S)
            if whitespaceCount > 1, position + whitespaceCount < end {
                position += whitespaceCount - 1
                add(position)
                continue
            }
            // \s+
            if whitespaceCount > 0 {
                position += whitespaceCount
                add(position)
                continue
            }
            position += 1
            add(position)
        }
        return words
    }

    /// The character classes the split regex tests. Every scalar in range is defined; only a position past the
    /// end has no class, which ends the punctuation run.
    private struct Flags {
        var isLetter = false
        var isNumber = false
        var isWhitespace = false
        var isDefined = false

        init() {}

        init(_ scalar: Unicode.Scalar) {
            isDefined = true
            isWhitespace = scalar.properties.isWhitespace
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                isLetter = true
            case .decimalNumber, .letterNumber, .otherNumber:
                isNumber = true
            default:
                break
            }
        }
    }

    // MARK: GPT-2 byte map

    /// GPT-2's `bytes_to_unicode`: printable Latin-1 bytes map to themselves, the other 68 to U+0100 onwards.
    static let byteScalars: [Unicode.Scalar] = {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(256)
        var next: UInt32 = 256
        for byte in UInt32(0)...255 {
            let printable = (0x21...0x7E).contains(byte) || (0xA1...0xAC).contains(byte) || (0xAE...0xFF).contains(byte)
            if printable {
                scalars.append(Unicode.Scalar(byte)!)
            } else {
                scalars.append(Unicode.Scalar(next)!)
                next += 1
            }
        }
        return scalars
    }()

    private static let scalarBytes: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        for (byte, scalar) in byteScalars.enumerated() {
            map[scalar.value] = UInt8(byte)
        }
        return map
    }()

    /// A normal piece's bytes. A scalar outside the byte map, which no byte-level vocabulary holds, passes
    /// through as its own UTF-8.
    private static func bytes(ofPiece piece: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(piece.utf8.count)
        for scalar in piece.unicodeScalars {
            if let byte = scalarBytes[scalar.value] {
                bytes.append(byte)
            } else {
                UTF8.encode(scalar) { bytes.append($0) }
            }
        }
        return bytes
    }

    private static func hasPrefix(_ bytes: [UInt8], at index: Int, _ prefix: [UInt8]) -> Bool {
        guard bytes.count - index >= prefix.count else { return false }
        for offset in 0..<prefix.count where bytes[index + offset] != prefix[offset] {
            return false
        }
        return true
    }

    private static func key(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
    }
}
