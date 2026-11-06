import Foundation

/// Encodes text into Granite vocabulary ids the way the model's `tokenizer.json` does.
///
/// The pinned tokenizer is a SentencePiece-style BPE with byte fallback and no pre-tokenizer. Its
/// normalizer turns CRLF into two LFs, applies a precompiled character map (`normalize`), prepends
/// U+2581 and replaces every space with U+2581; the whole normalized string is then one BPE word.
/// Each scalar starts as its own piece, or as `<0xHH>` byte pieces when it is not in the vocabulary,
/// and the lowest-ranked adjacent merge is applied, leftmost first, until none applies.
///
/// The vocabulary and merges come from the GGUF, so the ids are the ones the CTC head emits.
public struct GraniteBPEEncoder: Sendable {
    public enum BuildError: Error, Equatable {
        /// A merge that is not two vocabulary pieces separated by one space.
        case malformedMerge(index: Int)
        /// A byte value without its `<0xHH>` fallback piece.
        case missingBytePiece(UInt8)
    }

    private struct Merge {
        let rank: Int32
        let result: Int32
    }

    private let ids: [String: Int32]
    private let merges: [UInt64: Merge]
    private let byteIds: [Int32]

    public init(pieces: [String], merges: [String]) throws {
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() where ids[piece] == nil {
            ids[piece] = Int32(index)
        }

        var byteIds: [Int32] = []
        byteIds.reserveCapacity(256)
        for byte in 0...255 {
            let piece = String(format: "<0x%02X>", byte)
            guard let id = ids[piece] else { throw BuildError.missingBytePiece(UInt8(byte)) }
            byteIds.append(id)
        }

        var table: [UInt64: Merge] = [:]
        table.reserveCapacity(merges.count)
        for (rank, merge) in merges.enumerated() {
            guard let space = merge.firstIndex(of: " ") else { throw BuildError.malformedMerge(index: rank) }
            let left = String(merge[..<space])
            let right = String(merge[merge.index(after: space)...])
            guard let leftId = ids[left], let rightId = ids[right], let result = ids[left + right] else {
                throw BuildError.malformedMerge(index: rank)
            }
            let key = Self.key(leftId, rightId)
            if table[key] == nil {
                table[key] = Merge(rank: Int32(rank), result: result)
            }
        }

        self.ids = ids
        self.merges = table
        self.byteIds = byteIds
    }

    /// The ids of `text`, normalized and merged exactly as the reference tokenizer does.
    public func encode(_ text: String) -> [Int32] {
        var symbols: [Int32] = []
        for scalar in Self.normalize(text).unicodeScalars {
            if let id = ids[String(scalar)] {
                symbols.append(id)
            } else {
                for byte in String(scalar).utf8 {
                    symbols.append(byteIds[Int(byte)])
                }
            }
        }

        while symbols.count > 1 {
            var bestIndex = -1
            var best = Merge(rank: .max, result: -1)
            for index in 0..<(symbols.count - 1) {
                if let merge = merges[Self.key(symbols[index], symbols[index + 1])], merge.rank < best.rank {
                    best = merge
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            symbols[bestIndex] = best.result
            symbols.remove(at: bestIndex + 1)
        }
        return symbols
    }

    /// The reference normalizer: CRLF to two LFs, the precompiled character map, then U+2581 before
    /// a non-empty result and in place of every space.
    ///
    /// The character map is NFKC except for the scalars below, found by comparing this encoder with
    /// the reference tokenizer over every scalar of planes 0–2: it deletes C0/C1 controls, turns line
    /// and zero-width separators into spaces, and leaves alone scalars whose NFKC mappings postdate it.
    ///
    /// Everything runs on scalars: Foundation's string search treats a space followed by a combining
    /// mark as one character, which would hide the spaces NFKC produces for spacing diacritics.
    static func normalize(_ text: String) -> String {
        let source = Array(text.unicodeScalars)
        var mapped = String.UnicodeScalarView()
        var pending = String.UnicodeScalarView()
        func flush() {
            guard !pending.isEmpty else { return }
            mapped.append(contentsOf: String(pending).precomposedStringWithCompatibilityMapping.unicodeScalars)
            pending.removeAll()
        }
        var index = 0
        while index < source.count {
            let scalar = source[index]
            index += 1
            if scalar == "\r", index < source.count, source[index] == "\n" {
                index += 1
                pending.append(contentsOf: [" ", " "] as [Unicode.Scalar])
                continue
            }
            let value = scalar.value
            if deletedScalars.contains(where: { $0.contains(value) }) { continue }
            if spaceScalars.contains(value) {
                pending.append(" ")
            } else if keptScalars.contains(where: { $0.contains(value) }) {
                flush()
                mapped.append(scalar)
            } else {
                pending.append(scalar)
            }
        }
        flush()
        guard !mapped.isEmpty else { return "" }
        var normalized = String.UnicodeScalarView()
        normalized.append("\u{2581}")
        for scalar in mapped {
            normalized.append(scalar == " " ? "\u{2581}" : scalar)
        }
        return String(normalized)
    }

    private static let deletedScalars: [ClosedRange<UInt32>] = [
        0x1...0x8, 0xB...0xB, 0xE...0x1F, 0x7F...0x7F,
        0x8F...0x8F, 0x9F...0x9F,
    ]
    private static let spaceScalars: Set<UInt32> = [
        0x9, 0xA, 0xC, 0xD, 0x1680, 0x200B, 0x200C, 0x200E, 0x200F,
        0x2028, 0x2029, 0xFEFF, 0xFFFD,
    ]
    private static let keptScalars: [ClosedRange<UInt32>] = [
        0xA7F1...0xA7F4, 0xFF5E...0xFF5E, 0x10781...0x10785,
        0x10787...0x107B0, 0x107B2...0x107BA, 0x16D68...0x16D6A, 0x1CCD6...0x1CCF9, 0x1E030...0x1E06D,
    ]

    private static func key(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
    }
}
