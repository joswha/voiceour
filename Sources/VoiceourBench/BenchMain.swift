import Darwin
import Dispatch
import Foundation
import VoiceCore
import VoiceMac

@main
struct VoiceourBenchMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--help" || arguments.first == "-h" {
                print(BenchCLI.usage)
                exit(0)
            }
            let options = try BenchCLI.parse(arguments)
            try await BenchRunner(options: options).run()
            exit(0)
        } catch let error as BenchError {
            fputs("voiceour-bench: \(error.description)\n", stderr)
            if error.isUsageError {
                fputs("\n\(BenchCLI.usage)\n", stderr)
            }
            exit(error.exitCode)
        } catch {
            fputs("voiceour-bench: \(BenchError.describe(error))\n", stderr)
            exit(1)
        }
    }
}

enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    case io(String)
    case malformedInput(line: Int, detail: String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .io(let message):
            return message
        case .malformedInput(let line, let detail):
            return "malformed input line \(line): \(detail)"
        }
    }

    var isUsageError: Bool {
        if case .usage = self { return true }
        return false
    }

    var exitCode: Int32 {
        isUsageError ? 64 : 1
    }

    static func describe(_ error: Error) -> String {
        if let benchError = error as? BenchError {
            return benchError.description
        }
        if let asrError = error as? ASRErrorMessage {
            if let detail = asrError.detail, !detail.isEmpty {
                return "\(asrError.code.rawValue): \(detail)"
            }
            return asrError.code.rawValue
        }
        if let sidecarError = error as? SidecarASRClientError {
            switch sidecarError {
            case .launchFailed(let detail):
                return "sidecar launch failed: \(detail)"
            case .noHello:
                return "sidecar did not send hello"
            case .incompatibleHello:
                return "sidecar protocol version is incompatible"
            case .protocolError(let asrError):
                return describe(asrError)
            case .unexpectedMessage(let type):
                return "sidecar sent unexpected message: \(type)"
            case .timeout:
                return "sidecar request timed out"
            case .processExited(let detail):
                return "sidecar process exited: \(detail)"
            case .writeFailed(let detail):
                return "sidecar write failed: \(detail)"
            }
        }
        if error is CancellationError {
            return "cancelled"
        }
        let nsError = error as NSError
        let detail = nsError.localizedDescription
        return detail.isEmpty ? String(describing: error) : detail
    }
}

enum BenchCommand: String {
    case pipeline
}

struct BenchOptions {
    var command: BenchCommand
    var input: URL
    var output: URL
    var backend: String?
    var timeoutMs: Int
}

enum BenchCLI {
    /// Interpolated from the registry so a new backend can never be missing
    /// here while the parser below already accepts it.
    static let usage = """
        Usage:
          voiceour-bench pipeline --input <manifest.jsonl> --output <results.jsonl>
              [--backend \(backendChoices)] [--timeout-ms 120000]
        """

    private static let backendChoices = ASRBackendRegistry.builtIn.descriptors.map(\.id).joined(separator: "|")

    static func parse(_ arguments: [String]) throws -> BenchOptions {
        guard let commandValue = arguments.first, let command = BenchCommand(rawValue: commandValue) else {
            throw BenchError.usage("expected subcommand: pipeline")
        }

        var input: URL?
        var output: URL?
        var backend = ASRBackendRegistry.builtIn.defaultDescriptor.id
        var timeoutMs = 120_000

        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let parsed = splitOption(arguments[index])
            switch parsed.name {
            case "--input":
                input = fileURL(try value(for: parsed, in: arguments, index: &index))
            case "--output":
                output = fileURL(try value(for: parsed, in: arguments, index: &index))
            case "--backend":
                let value = try value(for: parsed, in: arguments, index: &index)
                guard
                    let normalized = VoiceCore.LaunchOptions.validBackend(
                        value,
                        validBackendIDs: ASRBackendRegistry.builtIn.backendIDs
                    )
                else {
                    let ids = ASRBackendRegistry.builtIn.descriptors.map(\.id).joined(separator: ", ")
                    throw BenchError.usage("--backend must be one of: \(ids)")
                }
                backend = normalized
            case "--timeout-ms":
                let value = try value(for: parsed, in: arguments, index: &index)
                guard let parsedTimeout = Int(value), parsedTimeout > 0 else {
                    throw BenchError.usage("--timeout-ms must be a positive integer")
                }
                timeoutMs = parsedTimeout
            default:
                throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }

        guard let input else { throw BenchError.usage("missing --input") }
        guard let output else { throw BenchError.usage("missing --output") }

        return BenchOptions(
            command: command,
            input: input,
            output: output,
            backend: backend,
            timeoutMs: timeoutMs
        )
    }

    private static func splitOption(_ argument: String) -> (name: String, inlineValue: String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else {
            return (argument, nil)
        }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    private static func value(
        for parsed: (name: String, inlineValue: String?), in arguments: [String], index: inout Int
    ) throws -> String {
        if let inlineValue = parsed.inlineValue {
            guard !inlineValue.isEmpty else { throw BenchError.usage("missing value for \(parsed.name)") }
            return inlineValue
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw BenchError.usage("missing value for \(parsed.name)")
        }
        let candidate = arguments[valueIndex]
        guard !candidate.hasPrefix("--") else {
            throw BenchError.usage("missing value for \(parsed.name)")
        }
        index = valueIndex
        return candidate
    }

    static func fileURL(_ value: String) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }
}

struct BenchRunner {
    var options: BenchOptions

    func run() async throws {
        switch options.command {
        case .pipeline:
            try await runPipeline()
        }
    }

    /// Uses the registry's batch factory, not its live one: the live Apple
    /// backend is the fused recording engine, which is not what a file-driven
    /// benchmark should measure.
    private static func makeASRClient(backend: String) -> any ASRClienting {
        ASRBackendRegistry.builtIn.client(
            for: backend,
            context: ASRBackendContext(
                sidecarExecutableURL: ASRBackendContext.siblingSidecarURL(),
                speechLocale: "en_US"
            )
        )
    }

    private func runPipeline() async throws {
        let writer = try JSONLWriter(url: options.output)
        try writer.write(meta(mode: .pipeline))
        let reader = try JSONLLineReader(url: options.input)
        let asr = Self.makeASRClient(backend: options.backend ?? ASRBackendRegistry.builtIn.defaultDescriptor.id)
        let decoder = JSONDecoder()
        var lineNumber = 0
        var rowCount = 0

        while let line = try reader.nextLine() {
            lineNumber += 1
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchError.malformedInput(line: lineNumber, detail: "empty line")
            }
            let inputRow: PipelineInputRow
            do {
                inputRow = try decoder.decode(PipelineInputRow.self, from: Data(line.utf8))
            } catch {
                throw BenchError.malformedInput(line: lineNumber, detail: BenchError.describe(error))
            }

            let outputRow = await processPipelineRow(inputRow, asr: asr)
            try writer.write(outputRow)
            rowCount += 1
            print("processed \(inputRow.id)")
        }
        print("wrote \(rowCount) pipeline rows to \(options.output.path)")
    }

    private func meta(mode: BenchCommand) -> BenchMeta {
        let model = Self.modelIdentity(for: options.backend)
        return BenchMeta(
            mode: mode.rawValue,
            backend: options.backend,
            modelId: model.id,
            modelRevision: model.revision,
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Model identity is read from the backend's descriptor, never branched on
    /// here: a stale branch would stamp Parakeet's identity onto every other
    /// backend's rows and make the whole record untrustworthy.
    ///
    /// A descriptor with a model but no pinned revision is system-managed (Apple
    /// Speech ships with the OS), so the OS version is the only revision that
    /// means anything. A backend with no model at all — `fake` — reports its own
    /// name rather than borrowing another backend's model.
    private static func modelIdentity(for backend: String?) -> (id: String, revision: String) {
        guard
            let backend,
            let descriptor = ASRBackendRegistry.builtIn.descriptor(for: backend),
            let modelId = descriptor.modelId
        else {
            let name = backend ?? "none"
            return (name, name)
        }
        return (modelId, descriptor.modelRevision ?? ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private func processPipelineRow(
        _ input: PipelineInputRow,
        asr: any ASRClienting
    ) async -> BenchOutputRow {
        let totalStart = BenchClock.mark()
        var rawTranscript = ""
        var cleanedText = ""
        var finalText = ""
        var timings = BenchOutputTimings(asr: nil, asrLoad: nil, asrInference: nil, cleanup: 0, total: 0)
        var rowError: String?
        var confidence: Double?
        var confidenceMode: String?

        do {
            let audio = try recordedAudio(for: input)
            let asrStart = BenchClock.mark()
            let result: ASRResult
            do {
                result = try await asr.transcribe(audio, timeoutMs: options.timeoutMs)
                timings.asr = BenchClock.elapsedMilliseconds(since: asrStart)
            } catch {
                timings.asr = BenchClock.elapsedMilliseconds(since: asrStart)
                throw error
            }

            timings.asrLoad = result.timingsMs.load
            timings.asrInference = result.timingsMs.inference
            rawTranscript = result.transcript.text
            confidence = result.transcript.confidence
            confidenceMode = result.transcript.confidenceMode?.rawValue

            let cleanupStart = BenchClock.mark()
            cleanedText = CleanupEngine.clean(rawTranscript, glossary: [])
            timings.cleanup = BenchClock.elapsedMilliseconds(since: cleanupStart)
            finalText = cleanedText
        } catch {
            rowError = BenchError.describe(error)
        }

        timings.total = BenchClock.elapsedMilliseconds(since: totalStart)
        return BenchOutputRow(
            id: input.id,
            rawTranscript: rawTranscript,
            cleanedText: cleanedText,
            finalText: finalText,
            timingsMs: timings,
            audioS: input.audioS,
            error: rowError,
            confidence: confidence,
            confidenceMode: confidenceMode
        )
    }

    private func recordedAudio(for input: PipelineInputRow) throws -> RecordedAudio {
        let audioURL = BenchCLI.fileURL(input.audioPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let durationMs = input.audioS.map { max(0, Int(($0 * 1000.0).rounded())) } ?? 0
        let meta = ASRAudioMeta(
            path: audioURL.path,
            format: audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension,
            sampleRateHz: 16_000,
            channels: 1,
            durationMs: durationMs,
            byteCount: byteCount
        )
        return RecordedAudio(url: audioURL, meta: meta)
    }
}

struct BenchClock {
    static func mark() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> Int {
        let end = DispatchTime.now().uptimeNanoseconds
        guard end >= start else { return 0 }
        return Int((end - start) / 1_000_000)
    }
}

final class JSONLLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false

    init(url: URL) throws {
        do {
            self.handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BenchError.io("cannot open input \(url.path): \(BenchError.describe(error))")
        }
    }

    deinit {
        try? handle.close()
    }

    func nextLine() throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return try decodeLine(Data(lineData))
            }
            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                let lineData = buffer
                buffer.removeAll(keepingCapacity: true)
                return try decodeLine(lineData)
            }
            do {
                if let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    reachedEOF = true
                }
            } catch {
                throw BenchError.io("cannot read input: \(BenchError.describe(error))")
            }
        }
    }

    private func decodeLine(_ data: Data) throws -> String {
        var line = data
        if line.last == 0x0D {
            line.removeLast()
        }
        guard let string = String(data: line, encoding: .utf8) else {
            throw BenchError.io("input is not valid UTF-8")
        }
        return string
    }
}

final class JSONLWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.handle = try FileHandle(forWritingTo: url)
        } catch {
            throw BenchError.io("cannot open output \(url.path): \(BenchError.describe(error))")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    deinit {
        try? handle.close()
    }

    func write<T: Encodable>(_ value: T) throws {
        do {
            var data = try encoder.encode(value)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            throw BenchError.io("cannot write output: \(BenchError.describe(error))")
        }
    }
}

struct PipelineInputRow: Decodable {
    var id: String
    var audioPath: String
    // Non-optional so decoding continues to enforce the pipeline manifest schema.
    var reference: String
    var audioS: Double?
    var canonicalTerm: String?

    enum CodingKeys: String, CodingKey {
        case id
        case audioPath = "audio_path"
        case reference
        case audioS = "audio_s"
        case canonicalTerm = "canonical_term"
    }
}

struct BenchMeta: Encodable {
    var type = "bench_meta"
    var mode: String
    var backend: String?
    var modelId: String
    var modelRevision: String
    var startedAt: String

    enum CodingKeys: String, CodingKey {
        case type
        case mode
        case backend
        case modelId = "model_id"
        case modelRevision = "model_revision"
        case startedAt = "started_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(mode, forKey: .mode)
        if let backend {
            try container.encode(backend, forKey: .backend)
        } else {
            try container.encodeNil(forKey: .backend)
        }
        try container.encode(modelId, forKey: .modelId)
        try container.encode(modelRevision, forKey: .modelRevision)
        try container.encode(startedAt, forKey: .startedAt)
    }
}

struct BenchOutputTimings: Encodable {
    var asr: Int?
    var asrLoad: Int?
    var asrInference: Int?
    var cleanup: Int
    var total: Int

    enum CodingKeys: String, CodingKey {
        case asr
        case asrLoad = "asr_load"
        case asrInference = "asr_inference"
        case cleanup
        case total
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let asr {
            try container.encode(asr, forKey: .asr)
        } else {
            try container.encodeNil(forKey: .asr)
        }
        if let asrLoad {
            try container.encode(asrLoad, forKey: .asrLoad)
        } else {
            try container.encodeNil(forKey: .asrLoad)
        }
        if let asrInference {
            try container.encode(asrInference, forKey: .asrInference)
        } else {
            try container.encodeNil(forKey: .asrInference)
        }
        try container.encode(cleanup, forKey: .cleanup)
        try container.encode(total, forKey: .total)
    }
}

struct BenchOutputRow: Encodable {
    var type = "row"
    var id: String
    var rawTranscript: String
    var cleanedText: String
    var finalText: String
    var timingsMs: BenchOutputTimings
    var audioS: Double?
    var error: String?
    var confidence: Double?
    var confidenceMode: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case rawTranscript = "raw_transcript"
        case cleanedText = "cleaned_text"
        case finalText = "final_text"
        case timingsMs = "timings_ms"
        case audioS = "audio_s"
        case error
        case confidence
        case confidenceMode = "confidence_mode"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(rawTranscript, forKey: .rawTranscript)
        try container.encode(cleanedText, forKey: .cleanedText)
        try container.encode(finalText, forKey: .finalText)
        try container.encode(timingsMs, forKey: .timingsMs)
        if let audioS {
            try container.encode(audioS, forKey: .audioS)
        } else {
            try container.encodeNil(forKey: .audioS)
        }
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encodeNil(forKey: .error)
        }
        if let confidence {
            try container.encode(confidence, forKey: .confidence)
        }
        if let confidenceMode {
            try container.encode(confidenceMode, forKey: .confidenceMode)
        }
    }
}
