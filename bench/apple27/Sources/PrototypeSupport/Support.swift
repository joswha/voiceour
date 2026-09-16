import CryptoKit
import Foundation
import VoiceCore

/// The existing pipeline-manifest contract, shared by every prototype.
package struct PrototypeInput: Decodable, Sendable {
    package let id: String
    let audioPath: String
    let reference: String
    package let audioS: Double?
    let audioBytes: Int
    let audioSHA256: String

    enum CodingKeys: String, CodingKey {
        case id, reference
        case audioPath = "audio_path"
        case audioS = "audio_s"
        case audioBytes = "audio_bytes"
        case audioSHA256 = "audio_sha256"
    }
}

/// Pipeline-shaped output with an optional, separately measured language-model stage.
package struct PrototypeOutput: Encodable, Sendable {
    private let type = "row"
    private let id: String
    private let rawTranscript: String
    private let cleanedText: String
    private let finalText: String
    private let audioS: Double?
    private let timingsMs: [String: Double?]
    private let error: String?
    private let details: [String: String]

    package init(
        id: String,
        rawTranscript: String,
        audioS: Double?,
        asrMs: Double? = nil,
        postprocessMs: Double? = nil,
        cleanedText: String? = nil,
        finalText: String? = nil,
        error: String? = nil,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.rawTranscript = rawTranscript
        self.audioS = audioS
        let cleanupStart = PrototypeClock.now()
        self.cleanedText = cleanedText ?? CleanupEngine.clean(rawTranscript, glossary: [])
        let cleanupMs = PrototypeClock.milliseconds(since: cleanupStart)
        self.finalText = finalText ?? self.cleanedText
        self.timingsMs = [
            "asr": asrMs,
            "asr_inference": asrMs,
            "asr_load": nil,
            "cleanup": cleanupMs,
            "postprocess": postprocessMs,
            "total": (asrMs ?? 0) + (postprocessMs ?? 0) + cleanupMs,
        ]
        self.error = error
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case type, id, error, details
        case rawTranscript = "raw_transcript"
        case cleanedText = "cleaned_text"
        case finalText = "final_text"
        case audioS = "audio_s"
        case timingsMs = "timings_ms"
    }
}

/// Monotonic wall-clock timing, in fractional milliseconds.
package enum PrototypeClock {
    package static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    package static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

/// Strict option parsing without introducing another command-line dependency.
package struct PrototypeArguments {
    private var values: [String: String] = [:]
    private var switches: Set<String> = []

    package init(
        _ arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        values allowedValues: Set<String>,
        flags allowedFlags: Set<String> = []
    ) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if allowedFlags.contains(argument) {
                guard switches.insert(argument).inserted else {
                    throw PrototypeError.message("Duplicate option: \(argument)")
                }
                index += 1
            } else if allowedValues.contains(argument), index + 1 < arguments.count {
                guard values[argument] == nil, !arguments[index + 1].hasPrefix("--") else {
                    throw PrototypeError.message("Missing or duplicate value: \(argument)")
                }
                values[argument] = arguments[index + 1]
                index += 2
            } else {
                throw PrototypeError.message("Unknown option or missing value: \(argument)")
            }
        }
    }

    package subscript(_ name: String) -> String? { values[name] }
    package func contains(_ flag: String) -> Bool { switches.contains(flag) }
    package func require(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw PrototypeError.message("Required option: \(name)")
        }
        return value
    }
}

package enum PrototypeError: Error, CustomStringConvertible {
    case message(String)
    package var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

/// Only public benchmark fixtures belong in these manifests; reference text is scoring-only.
package enum PrototypeIO {
    package static func inputs(at url: URL) throws -> [PrototypeInput] {
        let rows = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()
        let result = try rows.map { try decoder.decode(PrototypeInput.self, from: Data($0.utf8)) }
        guard Set(result.map(\.id)).count == result.count else {
            throw PrototypeError.message("Duplicate input ids")
        }
        return result
    }

    package static func objects(at url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            guard let object = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw PrototypeError.message("Expected a JSON object")
            }
            return object
        }
    }

    package static func audioURL(for row: PrototypeInput) throws -> URL {
        let url = URL(fileURLWithPath: row.audioPath)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == row.audioBytes, digest(data) == row.audioSHA256 else {
            throw PrototypeError.message("Audio pin mismatch: \(row.id)")
        }
        return url
    }

    package static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    package static func digest(of url: URL) throws -> String {
        digest(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    package static func vocabulary(at url: URL) throws -> [String] {
        let words = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        guard words.count <= 100, words.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw PrototypeError.message("Vocabulary requires at most 100 nonempty phrases")
        }
        return words
    }

    package static func diagnostic(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// One ordered NDJSON output owner. Existing result files are never overwritten.
package final class PrototypeWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder

    package init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit { try? handle.close() }

    package func write(_ row: PrototypeOutput) throws {
        try handle.write(contentsOf: encoder.encode(row))
        try handle.write(contentsOf: Data([10]))
    }

    package func writeObject(_ object: [String: Any]) throws {
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        try handle.write(contentsOf: Data([10]))
    }

    package func close() throws { try handle.close() }
}
