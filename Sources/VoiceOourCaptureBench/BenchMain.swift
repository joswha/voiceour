import Darwin
import Foundation
import VoiceCore
import VoiceMac

@main
struct VoiceOourCaptureBenchMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--list-modes"] {
                try CaptureBenchOutput.printModeList()
                exit(0)
            }
            if arguments == ["--help"] || arguments == ["-h"] {
                print(CaptureBenchCLI.usage)
                exit(0)
            }

            let options = try CaptureBenchCLI.parse(arguments)
            let result = try await CaptureBenchRunner(options: options).run()
            try CaptureBenchOutput.printJSON(result)
            exit(0)
        } catch let error as CaptureBenchError {
            fputs("voiceoour-capture-bench: \(error.description)\n", stderr)
            if error.isUsageError {
                fputs("\n\(CaptureBenchCLI.usage)\n", stderr)
            }
            exit(error.exitCode)
        } catch {
            fputs("voiceoour-capture-bench: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private enum CaptureBenchError: Error, CustomStringConvertible {
    case usage(String)
    case unavailable(String)
    case capture(String)
    case output(String)

    var description: String {
        switch self {
        case .usage(let detail), .unavailable(let detail), .capture(let detail), .output(let detail):
            return detail
        }
    }

    var isUsageError: Bool {
        if case .usage = self { return true }
        return false
    }

    var exitCode: Int32 {
        switch self {
        case .usage: return EX_USAGE
        case .unavailable: return EX_UNAVAILABLE
        case .capture, .output: return 1
        }
    }
}

private struct CaptureBenchOptions {
    var mode: CaptureProcessingMode
    var durationMs: Int
    var preRollMs: Int
    var postRollMs: Int
    var output: URL
}

private enum CaptureBenchCLI {
    static let usage = """
        Usage:
          voiceoour-capture-bench --mode <standard|native|voice-processing|voice-processing-no-agc|sound-isolation|sound-isolation-high-quality> --duration-ms N --pre-roll-ms N --post-roll-ms N --output PATH
          voiceoour-capture-bench --list-modes
        """

    static func parse(_ arguments: [String]) throws -> CaptureBenchOptions {
        guard !arguments.isEmpty else {
            throw CaptureBenchError.usage("missing capture options")
        }

        var mode: CaptureProcessingMode?
        var durationMs: Int?
        var preRollMs: Int?
        var postRollMs: Int?
        var output: URL?
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let option = splitOption(arguments[index])
            guard ["--mode", "--duration-ms", "--pre-roll-ms", "--post-roll-ms", "--output"].contains(option.name)
            else {
                throw CaptureBenchError.usage("unknown option: \(arguments[index])")
            }
            guard seen.insert(option.name).inserted else {
                throw CaptureBenchError.usage("duplicate option: \(option.name)")
            }
            let value = try value(for: option, arguments: arguments, index: &index)
            switch option.name {
            case "--mode":
                guard let parsed = CaptureProcessingMode(rawValue: value) else {
                    throw CaptureBenchError.usage("unsupported --mode value: \(value)")
                }
                mode = parsed
            case "--duration-ms":
                durationMs = try integer(value, option: option.name, minimum: 1, maximum: 600_000)
            case "--pre-roll-ms":
                preRollMs = try integer(value, option: option.name, minimum: 0, maximum: 60_000)
            case "--post-roll-ms":
                postRollMs = try integer(value, option: option.name, minimum: 0, maximum: 60_000)
            case "--output":
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CaptureBenchError.usage("--output must not be empty")
                }
                output = fileURL(value)
            default:
                break
            }
            index += 1
        }

        guard let mode else { throw CaptureBenchError.usage("missing --mode") }
        guard let durationMs else { throw CaptureBenchError.usage("missing --duration-ms") }
        guard let preRollMs else { throw CaptureBenchError.usage("missing --pre-roll-ms") }
        guard let postRollMs else { throw CaptureBenchError.usage("missing --post-roll-ms") }
        guard let output else { throw CaptureBenchError.usage("missing --output") }
        guard !output.hasDirectoryPath else { throw CaptureBenchError.usage("--output must be a file path") }

        return CaptureBenchOptions(
            mode: mode,
            durationMs: durationMs,
            preRollMs: preRollMs,
            postRollMs: postRollMs,
            output: output
        )
    }

    private static func splitOption(_ argument: String) -> (name: String, inlineValue: String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else {
            return (argument, nil)
        }
        return (
            String(argument[..<equals]),
            String(argument[argument.index(after: equals)...])
        )
    }

    private static func value(
        for option: (name: String, inlineValue: String?),
        arguments: [String],
        index: inout Int
    ) throws -> String {
        if let inlineValue = option.inlineValue {
            guard !inlineValue.isEmpty else {
                throw CaptureBenchError.usage("missing value for \(option.name)")
            }
            return inlineValue
        }
        let valueIndex = index + 1
        guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
            throw CaptureBenchError.usage("missing value for \(option.name)")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func integer(
        _ value: String,
        option: String,
        minimum: Int,
        maximum: Int
    ) throws -> Int {
        guard let parsed = Int(value), (minimum...maximum).contains(parsed) else {
            throw CaptureBenchError.usage("\(option) must be an integer from \(minimum) through \(maximum)")
        }
        return parsed
    }

    private static func fileURL(_ value: String) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }
}

private struct CaptureBenchResult: Codable {
    var mode: CaptureProcessingMode
    var implementation: String
    var outputPath: String
    var requestedDurationMs: Int
    var capturedDurationMs: Int
    var preRollMs: Int
    var postRollMs: Int
    var endpointBoundingApplied: Bool
    var telemetry: CaptureTelemetry
}

private struct CaptureBenchModeList: Codable {
    var modes: [CaptureBenchMode]
}

private struct CaptureBenchMode: Codable {
    var mode: CaptureProcessingMode
    var implementation: String
    var available: Bool
    var unavailableReason: String?
}

private struct CaptureBenchRunner {
    var options: CaptureBenchOptions

    func run() async throws -> CaptureBenchResult {
        let availability = ExperimentalAudioEngineRecorder.availability(for: options.mode)
        guard availability.available else {
            throw CaptureBenchError.unavailable(
                "capture mode \(options.mode.rawValue) is unavailable: \(availability.unavailableReason ?? "unsupported")"
            )
        }

        let recorded: RecordedAudio
        let implementation: String
        let endpointBoundingApplied: Bool
        if options.mode == .standard {
            recorded = try await runProductionBaseline()
            implementation = "production-av-audio-recorder"
            endpointBoundingApplied = false
        } else {
            recorded = try await runExperimentalEngine()
            implementation = "experimental-av-audio-engine"
            endpointBoundingApplied = true
        }

        guard let telemetry = recorded.telemetry else {
            try? FileManager.default.removeItem(at: options.output)
            throw CaptureBenchError.capture("capture completed without required telemetry")
        }
        return CaptureBenchResult(
            mode: options.mode,
            implementation: implementation,
            outputPath: options.output.path,
            requestedDurationMs: options.durationMs,
            capturedDurationMs: recorded.meta.durationMs,
            preRollMs: options.preRollMs,
            postRollMs: options.postRollMs,
            endpointBoundingApplied: endpointBoundingApplied,
            telemetry: telemetry
        )
    }

    private func runProductionBaseline() async throws -> RecordedAudio {
        let recorder = AVAudioEngineRecorder()
        do {
            try recorder.start()
            try await sleepForCapture()
            let temporaryRecording = try await recorder.stop()
            return try installProductionOutput(temporaryRecording)
        } catch {
            await recorder.discardRecording()
            try? FileManager.default.removeItem(at: options.output)
            throw CaptureBenchError.capture(error.localizedDescription)
        }
    }

    private func runExperimentalEngine() async throws -> RecordedAudio {
        let recorder: ExperimentalAudioEngineRecorder
        do {
            recorder = try ExperimentalAudioEngineRecorder(
                mode: options.mode,
                outputURL: options.output,
                preRollMs: options.preRollMs,
                postRollMs: options.postRollMs,
                expectedDurationMs: options.durationMs
            )
        } catch let error as ExperimentalAudioEngineRecorderError {
            throw CaptureBenchError.unavailable(error.localizedDescription)
        } catch {
            throw CaptureBenchError.capture(error.localizedDescription)
        }

        do {
            try recorder.start()
            try await sleepForCapture()
            return try await recorder.stop()
        } catch let error as ExperimentalAudioEngineRecorderError {
            recorder.discardRecording()
            switch error {
            case .unsupportedMode, .soundIsolationInstantiationFailed, .invalidInputFormat:
                throw CaptureBenchError.unavailable(error.localizedDescription)
            default:
                throw CaptureBenchError.capture(error.localizedDescription)
            }
        } catch {
            recorder.discardRecording()
            throw CaptureBenchError.capture(error.localizedDescription)
        }
    }

    private func sleepForCapture() async throws {
        try await Task.sleep(nanoseconds: UInt64(options.durationMs) * 1_000_000)
    }

    private func installProductionOutput(_ recording: RecordedAudio) throws -> RecordedAudio {
        let fileManager = FileManager.default
        let temporaryURL = recording.url
        defer { try? fileManager.removeItem(at: temporaryURL) }
        do {
            try fileManager.createDirectory(
                at: options.output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: options.output.path) {
                try fileManager.removeItem(at: options.output)
            }
            try fileManager.moveItem(at: temporaryURL, to: options.output)
            let attributes = try fileManager.attributesOfItem(atPath: options.output.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            var meta = recording.meta
            meta.path = options.output.path
            meta.byteCount = byteCount
            return RecordedAudio(url: options.output, meta: meta, telemetry: recording.telemetry)
        } catch {
            try? fileManager.removeItem(at: options.output)
            throw CaptureBenchError.output("could not install output WAV: \(error.localizedDescription)")
        }
    }
}

private enum CaptureBenchOutput {
    static func printModeList() throws {
        let modes = CaptureProcessingMode.allCases.map { mode -> CaptureBenchMode in
            let availability = ExperimentalAudioEngineRecorder.availability(for: mode)
            return CaptureBenchMode(
                mode: mode,
                implementation: mode == .standard
                    ? "production-av-audio-recorder"
                    : "experimental-av-audio-engine",
                available: availability.available,
                unavailableReason: availability.unavailableReason
            )
        }
        try printJSON(CaptureBenchModeList(modes: modes))
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            guard let line = String(data: data, encoding: .utf8) else {
                throw CaptureBenchError.output("JSON result was not UTF-8")
            }
            print(line)
        } catch let error as CaptureBenchError {
            throw error
        } catch {
            throw CaptureBenchError.output("could not encode JSON result: \(error.localizedDescription)")
        }
    }
}
