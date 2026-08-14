import Foundation

public enum WAVFileError: Error, Equatable, CustomStringConvertible {
    case notRIFF
    case truncated(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .notRIFF: return "not a RIFF/WAVE file"
        case .truncated(let detail): return "truncated: \(detail)"
        case .unsupported(let detail): return "unsupported: \(detail)"
        }
    }
}

/// Strict reader for the one audio format this sidecar accepts.
///
/// 16 kHz mono 16-bit PCM is exactly what `CaptureWAVTarget` writes, and that recorder is the
/// only producer of files the sidecar is asked to read. There is deliberately no transcode
/// fallback: anything else is a bug upstream, and silently resampling it would hide the bug
/// behind a worse transcript.
public enum WAVFile {
    public static let requiredSampleRate = 16000
    public static let requiredChannels = 1
    public static let requiredBitsPerSample = 16

    /// Decodes to the normalized `[-1, 1)` float samples parakeet.cpp expects.
    public static func readSamples(at url: URL) throws -> [Float] {
        try readSamples(from: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func readSamples(from data: Data) throws -> [Float] {
        guard data.count >= 12 else { throw WAVFileError.truncated("RIFF header") }
        guard fourCC(data, 0) == "RIFF", fourCC(data, 8) == "WAVE" else { throw WAVFileError.notRIFF }

        var sawFormat = false
        var pcm: Range<Int>?
        var offset = 12

        while offset + 8 <= data.count {
            let chunkId = fourCC(data, offset)
            let declared = Int(readUInt32(data, offset + 4))
            let body = offset + 8
            // A final chunk whose declared size overruns the file is a truncated recording,
            // which the crash-recovery path can legitimately produce; clamp rather than reject.
            let size = min(declared, data.count - body)

            switch chunkId {
            case "fmt ":
                guard size >= 16 else { throw WAVFileError.truncated("fmt chunk") }
                try validateFormat(data, at: body)
                sawFormat = true
            case "data":
                pcm = body..<(body + size)
            default:
                break
            }

            offset = body + declared + (declared % 2)
        }

        guard sawFormat else { throw WAVFileError.truncated("missing fmt chunk") }
        guard let pcm else { throw WAVFileError.truncated("missing data chunk") }
        return decodeInt16(data, in: pcm)
    }

    private static func validateFormat(_ data: Data, at offset: Int) throws {
        let audioFormat = Int(readUInt16(data, offset))
        let channels = Int(readUInt16(data, offset + 2))
        let sampleRate = Int(readUInt32(data, offset + 4))
        let bitsPerSample = Int(readUInt16(data, offset + 14))

        guard audioFormat == 1 else {
            throw WAVFileError.unsupported("audio format \(audioFormat), expected PCM (1)")
        }
        guard channels == requiredChannels else {
            throw WAVFileError.unsupported("\(channels) channels, expected \(requiredChannels)")
        }
        guard sampleRate == requiredSampleRate else {
            throw WAVFileError.unsupported("\(sampleRate) Hz, expected \(requiredSampleRate) Hz")
        }
        guard bitsPerSample == requiredBitsPerSample else {
            throw WAVFileError.unsupported("\(bitsPerSample)-bit, expected \(requiredBitsPerSample)-bit")
        }
    }

    private static func decodeInt16(_ data: Data, in range: Range<Int>) -> [Float] {
        let count = range.count / 2
        guard count > 0 else { return [] }
        let scale = Float(1.0 / 32768.0)
        return data.withUnsafeBytes { raw -> [Float] in
            [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                for index in 0..<count {
                    // Unaligned: the data chunk starts wherever the preceding chunks leave it.
                    let bits = raw.loadUnaligned(fromByteOffset: range.lowerBound + index * 2, as: UInt16.self)
                    buffer[index] = Float(Int16(bitPattern: UInt16(littleEndian: bits))) * scale
                }
                initialized = count
            }
        }
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return "" }
        return String(bytes: data[base..<(base + 4)], encoding: .ascii) ?? ""
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        guard base + 2 <= data.endIndex else { return 0 }
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return 0 }
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8) | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
