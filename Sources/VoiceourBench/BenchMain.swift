import CryptoKit
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
            if arguments.first == "repair-verify" {
                try RepairVerificationCommand.parse(Array(arguments.dropFirst())).run()
            } else if arguments.first == "granite-spot" {
                try GraniteSpotCommand.parse(Array(arguments.dropFirst())).run()
            } else if arguments.first == "granite-tokenize" {
                try GraniteTokenizeCommand.parse(Array(arguments.dropFirst())).run()
            } else if arguments.first == "detect-language" {
                try DetectLanguageCommand.parse(Array(arguments.dropFirst())).run()
            } else {
                let options = try BenchCLI.parse(arguments)
                try await BenchRunner(options: options).run()
            }
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
    var backend: String
    var timeoutMs: Int
    var vocabulary: URL?
}

enum BenchCLI {
    /// Interpolated from the registry so a new backend can never be missing
    /// here while the parser below already accepts it.
    static let usage = """
        Usage:
          voiceour-bench pipeline --input <manifest.jsonl> --output <results.jsonl>
              [--backend \(backendChoices)] [--timeout-ms 120000]
              [--vocabulary <repair.vocabulary.json>]
          voiceour-bench repair-verify --fixtures <directory>
              [--vocabulary <repair.vocabulary.json>] [--repetitions 20]
          voiceour-bench granite-spot --input <manifest.jsonl> --output <rows.jsonl>
              [--glossary <repair.vocabulary.json>] [--model <granite.gguf>]
          voiceour-bench granite-tokenize --input <texts.jsonl> --output <ids.jsonl> [--model <granite.gguf>]
          voiceour-bench detect-language --input <texts.jsonl> --output <languages.jsonl>
        """

    private static let backendChoices = ASRBackendRegistry.builtIn.descriptors.map(\.id).joined(separator: "|")

    static func parse(_ arguments: [String]) throws -> BenchOptions {
        guard let commandValue = arguments.first, let command = BenchCommand(rawValue: commandValue) else {
            throw BenchError.usage("expected subcommand: pipeline or repair-verify")
        }

        var input: URL?
        var output: URL?
        var backend: String?
        var timeoutMs = 120_000
        var vocabulary: URL?

        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let parsed = splitOption(arguments[index])
            switch parsed.name {
            case "--input":
                input = fileURL(try value(for: parsed, in: arguments, index: &index))
            case "--output":
                output = fileURL(try value(for: parsed, in: arguments, index: &index))
            case "--vocabulary":
                vocabulary = fileURL(try value(for: parsed, in: arguments, index: &index))
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
            backend: backend ?? ASRBackendRegistry.builtIn.defaultDescriptor.id,
            timeoutMs: timeoutMs,
            vocabulary: vocabulary
        )
    }

    static func splitOption(_ argument: String) -> (name: String, inlineValue: String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else {
            return (argument, nil)
        }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    static func value(
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

struct LoadedRepairEngine {
    var engine: VocabularyRepairEngine
    var sha256: String

    static func load(_ url: URL) throws -> LoadedRepairEngine {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchError.io("cannot read vocabulary \(url.path): \(BenchError.describe(error))")
        }

        let vocabulary: RepairVocabulary
        do {
            vocabulary = try JSONDecoder().decode(RepairVocabulary.self, from: data)
        } catch {
            throw BenchError.io("cannot decode vocabulary \(url.path): \(BenchError.describe(error))")
        }
        return LoadedRepairEngine(
            engine: VocabularyRepairEngine(vocabulary: vocabulary),
            sha256: try BenchRunner.sha256(of: url)
        )
    }
}

/// A glossary file read the way the app reads its vocabulary snapshot: the active terms, the app's
/// repair engine over them, and the spotting targets of their canonicals.
///
/// The file is a repair vocabulary (`surfaces` + `protected_surfaces`, no aliases) or the app's
/// word-list import shape, `[{"term": …, "heard_as": […]}]`, whose forms become heard-as aliases
/// for the text stage only: a heard-as form is never a spotting variant.
struct BenchGlossary {
    let terms: [ProtectedTerm]
    let engine: VocabularyRepairEngine
    let targets: TermSpotTargets
    let sha256: String

    static func load(_ url: URL) throws -> BenchGlossary {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchError.io("cannot read glossary \(url.path): \(BenchError.describe(error))")
        }
        let terms: [ProtectedTerm]
        if let list = try? JSONDecoder().decode([Entry].self, from: data) {
            terms = list.map { ProtectedTerm(canonical: $0.term, spokenAliases: $0.heardAs ?? []) }
        } else {
            do {
                let vocabulary = try JSONDecoder().decode(RepairVocabulary.self, from: data)
                terms = (vocabulary.surfaces + vocabulary.protectedSurfaces).map {
                    ProtectedTerm(canonical: $0, spokenAliases: [])
                }
            } catch {
                throw BenchError.io("cannot decode glossary \(url.path): \(BenchError.describe(error))")
            }
        }
        let ordinary = RepairVocabulary.bundledOrdinaryWords
        return BenchGlossary(
            terms: terms,
            engine: VocabularyRepairEngine(
                vocabulary: RepairVocabulary.fromActiveTerms(terms, ordinaryWords: ordinary)),
            targets: TermSpotTargets(terms: terms, ordinaryWords: ordinary),
            sha256: try BenchRunner.sha256(of: url)
        )
    }

    /// The app's text stage with cleanup enabled, spotting with `spotting` when given.
    func textStage(_ raw: String, spotting: TermSpotEvidence? = nil) -> String {
        DictationTextStage.apply(
            raw,
            spotting: spotting,
            cleanupEnabled: true,
            glossary: terms,
            repairEngine: engine
        ).text
    }

    private struct Entry: Decodable {
        var term: String
        var heardAs: [String]?

        enum CodingKeys: String, CodingKey {
            case term
            case heardAs = "heard_as"
        }
    }
}

struct RepairVerificationCommand {
    var fixtures: URL
    var vocabulary: URL
    var repetitions: Int

    static func parse(_ arguments: [String]) throws -> RepairVerificationCommand {
        var fixtures: URL?
        var vocabulary = BenchCLI.fileURL("bench/autoresearch/repair.vocabulary.json")
        var repetitions = 20
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--fixtures":
                fixtures = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            case "--vocabulary":
                vocabulary = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            case "--repetitions":
                let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
                guard let parsedRepetitions = Int(value), parsedRepetitions > 0 else {
                    throw BenchError.usage("--repetitions must be a positive integer")
                }
                repetitions = parsedRepetitions
            default:
                throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }
        guard let fixtures else { throw BenchError.usage("missing --fixtures") }
        return RepairVerificationCommand(
            fixtures: fixtures,
            vocabulary: vocabulary,
            repetitions: repetitions
        )
    }

    func run() throws {
        let loaded = try LoadedRepairEngine.load(vocabulary)
        let jargon = try readRows(fixtures.appendingPathComponent("expected-jargon.jsonl"))
        let general = try readRows(fixtures.appendingPathComponent("expected-general.jsonl"))
        let rows = jargon + general
        var changed = 0
        var eventCount = 0

        for row in rows {
            let outcome = loaded.engine.repair(row.input)
            guard outcome.text.utf8.elementsEqual(row.expected.utf8) else {
                throw BenchError.io(
                    "repair mismatch for \(row.id): got \(quoted(outcome.text)), expected \(quoted(row.expected))"
                )
            }
            guard eventsEqual(outcome.events, row.events) else {
                throw BenchError.io("repair event mismatch for \(row.id)")
            }
            if !outcome.text.utf8.elementsEqual(row.input.utf8) {
                changed += 1
            }
            eventCount += outcome.events.count
        }

        var elapsed: [UInt64] = []
        elapsed.reserveCapacity(jargon.count * repetitions)
        var checksum: UInt64 = 0
        for _ in 0..<repetitions {
            for row in jargon {
                let start = DispatchTime.now().uptimeNanoseconds
                let outcome = loaded.engine.repair(row.input)
                let end = DispatchTime.now().uptimeNanoseconds
                elapsed.append(end >= start ? end - start : 0)
                checksum =
                    checksum &* 16_777_619
                    &+ UInt64(outcome.text.utf8.count)
                    &+ UInt64(outcome.events.count)
            }
        }

        elapsed.sort()
        let p50 = percentile(elapsed, percent: 50)
        let p95 = percentile(elapsed, percent: 95)
        let maximum = Double(elapsed.last ?? 0) / 1_000
        print(
            "repair_verify exact=\(rows.count)/\(rows.count) changed=\(changed) "
                + "events=\(eventCount) samples=\(elapsed.count) "
                + "p50_us=\(format(p50)) p95_us=\(format(p95)) max_us=\(format(maximum)) "
                + "checksum=\(checksum) vocabulary_sha256=\(loaded.sha256)"
        )
    }

    private func readRows(_ url: URL) throws -> [RepairFixtureRow] {
        let reader = try JSONLLineReader(url: url)
        let decoder = JSONDecoder()
        var rows: [RepairFixtureRow] = []
        var lineNumber = 0
        while let line = try reader.nextLine() {
            lineNumber += 1
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchError.malformedInput(line: lineNumber, detail: "empty line")
            }
            do {
                rows.append(try decoder.decode(RepairFixtureRow.self, from: Data(line.utf8)))
            } catch {
                throw BenchError.malformedInput(
                    line: lineNumber,
                    detail: "\(url.lastPathComponent): \(BenchError.describe(error))"
                )
            }
        }
        return rows
    }

    private func eventsEqual(_ actual: [RepairEvent], _ expected: [RepairEvent]) -> Bool {
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { actual, expected in
            actual.start == expected.start
                && actual.end == expected.end
                && actual.before.utf8.elementsEqual(expected.before.utf8)
                && actual.after.utf8.elementsEqual(expected.after.utf8)
                && actual.kind == expected.kind
                && roundedEventScore(actual.score) == expected.score
        }
    }

    private func roundedEventScore(_ score: Double) -> Double {
        (score * 1_000_000_000).rounded(.toNearestOrEven) / 1_000_000_000
    }

    private func percentile(_ sorted: [UInt64], percent: Int) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(1, (sorted.count * percent + 99) / 100)
        return Double(sorted[rank - 1]) / 1_000
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func quoted(_ value: String) -> String {
        String(reflecting: value)
    }
}

struct RepairFixtureRow: Decodable {
    var id: String
    var input: String
    var expected: String
    var events: [RepairEvent]
}

struct BenchRunner {
    var options: BenchOptions

    func run() async throws {
        switch options.command {
        case .pipeline:
            try await runPipeline()
        }
    }

    /// The registry's client for `backend`, which for every registered backend is
    /// the sidecar client: this benchmark transcribes files and never records.
    static func makeASRClient(backend: String) -> any ASRClienting {
        ASRBackendRegistry.builtIn.client(
            for: backend,
            context: ASRBackendContext(sidecarExecutableURL: ASRBackendContext.siblingSidecarURL())
        )
    }

    private func runPipeline() async throws {
        let manifestSHA256 = try Self.sha256(of: options.input)
        let audioManifestSHA256 = try Self.audioManifestSHA256(of: options.input)
        let glossary = try options.vocabulary.map(BenchGlossary.load)
        let spotTerms = glossary?.targets.spotTerms ?? []
        let writer = try JSONLWriter(url: options.output)
        try writer.write(
            meta(
                mode: .pipeline,
                manifestSHA256: manifestSHA256,
                audioManifestSHA256: audioManifestSHA256,
                vocabularySHA256: glossary?.sha256
            )
        )
        let reader = try JSONLLineReader(url: options.input)
        let asr = Self.makeASRClient(backend: options.backend)
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

            let outputRow = await processPipelineRow(inputRow, asr: asr, glossary: glossary, spotTerms: spotTerms)
            try writer.write(outputRow)
            rowCount += 1
            print("processed \(inputRow.id)")
        }
        print("wrote \(rowCount) pipeline rows to \(options.output.path)")
    }

    private func meta(
        mode: BenchCommand,
        manifestSHA256: String,
        audioManifestSHA256: String,
        vocabularySHA256: String?
    ) -> BenchMeta {
        let model = Self.modelIdentity(for: options.backend)
        return BenchMeta(
            mode: mode.rawValue,
            backend: options.backend,
            modelId: model.id,
            modelRevision: model.revision,
            modelFile: model.file,
            manifestSHA256: manifestSHA256,
            audioManifestSHA256: audioManifestSHA256,
            vocabularySHA256: vocabularySHA256,
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Model identity is the backend's own artifact, read from its descriptor and never
    /// branched on here: a stale branch would stamp one backend's identity onto another
    /// backend's rows and make the whole record untrustworthy.
    ///
    /// A backend with no model at all — `fake` — reports its own name rather than
    /// borrowing another backend's model, and names no file.
    static func modelIdentity(for backend: String) -> (id: String, revision: String, file: String?) {
        guard let artifact = ASRBackendRegistry.builtIn.descriptor(for: backend)?.modelArtifact else {
            return (backend, backend, nil)
        }
        return (artifact.modelId, artifact.revision, artifact.file)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The row-identity digest every mode's `bench_meta` carries: the manifest's ids, audio
    /// sizes and audio digests, independent of the file's formatting.
    static func audioManifestSHA256(of url: URL) throws -> String {
        let reader = try JSONLLineReader(url: url)
        let decoder = JSONDecoder()
        var hasher = SHA256()
        hasher.update(data: Data("voiceour-audio-manifest-v1\u{0}".utf8))
        var lineNumber = 0
        var rowCount: UInt64 = 0
        while let line = try reader.nextLine() {
            lineNumber += 1
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchError.malformedInput(line: lineNumber, detail: "empty line")
            }
            let row: PipelineInputRow
            do {
                row = try decoder.decode(PipelineInputRow.self, from: Data(line.utf8))
            } catch {
                throw BenchError.malformedInput(line: lineNumber, detail: BenchError.describe(error))
            }
            guard !row.id.isEmpty, row.audioBytes >= 0, let audioDigest = data(fromHex: row.audioSHA256) else {
                throw BenchError.malformedInput(
                    line: lineNumber,
                    detail: "id, audio_bytes, or audio_sha256 is invalid"
                )
            }
            let id = Data(row.id.utf8)
            update(UInt64(id.count), in: &hasher)
            hasher.update(data: id)
            update(UInt64(row.audioBytes), in: &hasher)
            hasher.update(data: audioDigest)
            rowCount += 1
        }
        update(rowCount, in: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ value: UInt64, in hasher: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            hasher.update(data: Data(bytes))
        }
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.utf8.count == 64 else { return nil }
        var data = Data()
        data.reserveCapacity(32)
        var index = hex.startIndex
        for _ in 0..<32 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Without a glossary, `final_text` is `cleaned_text`: glossary-free cleanup under the
    /// transcript's detected language. With one, the request spots its targets and `final_text` is
    /// the app's text stage over the result, exactly as a dictation with that vocabulary.
    private func processPipelineRow(
        _ input: PipelineInputRow,
        asr: any ASRClienting,
        glossary: BenchGlossary?,
        spotTerms: [ASRSpotTerm]
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
            let audio = try Self.recordedAudio(for: input)
            let asrStart = BenchClock.mark()
            let result: ASRResult
            do {
                result = try await asr.transcribe(audio, timeoutMs: options.timeoutMs, spotTerms: spotTerms)
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
            cleanedText = CleanupEngine.clean(
                rawTranscript, glossary: [], language: DictationLanguage.detect(rawTranscript))
            finalText =
                glossary.map {
                    $0.textStage(
                        rawTranscript, spotting: TermSpotEvidence(transcript: result.transcript, targets: $0.targets))
                } ?? cleanedText
            timings.cleanup = BenchClock.elapsedMilliseconds(since: cleanupStart)
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

    /// Resolves a manifest row's audio and refuses it unless the file on disk is byte-for-byte
    /// the one the manifest pinned. Every command that reads audio from a manifest goes through
    /// here: a benchmark that silently measured a different recording than the manifest names
    /// would be worse than one that stopped.
    static func validatedAudioURL(for input: PipelineInputRow) throws -> URL {
        let audioURL = BenchCLI.fileURL(input.audioPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount == input.audioBytes else {
            throw BenchError.io(
                "audio size mismatch for \(input.id): got \(byteCount), expected \(input.audioBytes)"
            )
        }
        let digest = try Self.sha256(of: audioURL)
        guard digest == input.audioSHA256.lowercased() else {
            throw BenchError.io(
                "audio SHA-256 mismatch for \(input.id): got \(digest), expected \(input.audioSHA256)"
            )
        }
        return audioURL
    }

    static func recordedAudio(for input: PipelineInputRow) throws -> RecordedAudio {
        let audioURL = try Self.validatedAudioURL(for: input)
        let durationMs = input.audioS.map { max(0, Int(($0 * 1000.0).rounded())) } ?? 0
        let meta = ASRAudioMeta(
            path: audioURL.path,
            format: audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension,
            sampleRateHz: 16_000,
            channels: 1,
            durationMs: durationMs,
            byteCount: input.audioBytes
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
    var audioBytes: Int
    var audioSHA256: String

    enum CodingKeys: String, CodingKey {
        case id
        case audioPath = "audio_path"
        case reference
        case audioS = "audio_s"
        case audioBytes = "audio_bytes"
        case audioSHA256 = "audio_sha256"
    }
}

struct BenchMeta: Encodable {
    var type = "bench_meta"
    var mode: String
    var backend: String
    var modelId: String
    var modelRevision: String
    /// The loaded weight file, absent for a backend that has no model. A pinned repository
    /// can hold several artifacts under one `model_id` and `model_revision`, so this is the
    /// field that tells two artifacts' runs apart.
    var modelFile: String?
    var manifestSHA256: String
    var audioManifestSHA256: String
    var vocabularySHA256: String?
    var startedAt: String

    enum CodingKeys: String, CodingKey {
        case type
        case mode
        case backend
        case modelId = "model_id"
        case modelRevision = "model_revision"
        case modelFile = "model_file"
        case manifestSHA256 = "manifest_sha256"
        case audioManifestSHA256 = "audio_manifest_sha256"
        case vocabularySHA256 = "vocabulary_sha256"
        case startedAt = "started_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(mode, forKey: .mode)
        try container.encode(backend, forKey: .backend)
        try container.encode(modelId, forKey: .modelId)
        try container.encode(modelRevision, forKey: .modelRevision)
        if let modelFile {
            try container.encode(modelFile, forKey: .modelFile)
        } else {
            try container.encodeNil(forKey: .modelFile)
        }
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
        try container.encode(audioManifestSHA256, forKey: .audioManifestSHA256)
        if let vocabularySHA256 {
            try container.encode(vocabularySHA256, forKey: .vocabularySHA256)
        }
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
