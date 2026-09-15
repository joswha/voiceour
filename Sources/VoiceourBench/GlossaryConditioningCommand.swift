import ASRSidecarCore
import CryptoKit
import Foundation
import VoiceCore

/// Research-only state dump and cached replay for the `glossary-conditioned-decoding` track.
/// The product never calls either route.
///
/// `dump-states` is the track's only accelerator step: for each manifest row it encodes once
/// through the CoreML tier the sidecar's own environment selects, writes the frame-major
/// `[frames, 1024]` F32 states the tail then consumed, and records the unmodified
/// external-state tail result. `replay-states` decodes the same manifest rows from a supplied
/// state pack instead of encoding them, so an offline stage can perturb cached states and read
/// the unchanged TDT tail's answer without loading any acoustic model of its own.
///
/// Both routes fix `useGPU=false`, `tailBackendCPU=true`, and no weight arena, and both reach
/// the tail through `parakeet_full_with_external_encoder`. That is deliberate: the pilot's
/// identity control compares a replayed transcript byte for byte against the dumped one, and
/// two different tail backends would make the comparison meaningless.
enum GlossaryConditioningCommand {
    case dumpStates(GlossaryConditioningDumpStates)
    case replayStates(GlossaryConditioningReplayStates)

    static func parse(_ arguments: [String]) throws -> GlossaryConditioningCommand {
        guard let mode = arguments.first else {
            throw BenchError.usage(
                "expected glossary-conditioning subcommand: dump-states or replay-states"
            )
        }
        let rest = Array(arguments.dropFirst())
        switch mode {
        case "dump-states":
            return .dumpStates(try GlossaryConditioningDumpStates.parse(rest))
        case "replay-states":
            return .replayStates(try GlossaryConditioningReplayStates.parse(rest))
        default:
            throw BenchError.usage("unknown glossary-conditioning subcommand: \(mode)")
        }
    }

    func run() throws {
        switch self {
        case .dumpStates(let command):
            try command.run()
        case .replayStates(let command):
            try command.run()
        }
    }
}

/// Shared invariants of the two routes.
enum GlossaryConditioningContract {
    /// Mel frames per encoder frame. The tail rejects an external frame count that is not the
    /// stored mel length divided by this factor, rounded up (`parakeet.cpp:6236-6254`); both
    /// routes check it here first so a mismatch is reported with the numbers that disagree.
    static let melFramesPerEncoderFrame = 8

    /// Mel frames the native front end produces for `sampleCount` samples at hop 160
    /// (`ParakeetContext.decodeWithCoreMLEncoder`'s own contract check).
    static func melFrameCount(sampleCount: Int) -> Int {
        sampleCount / 160 + 1
    }

    static func encoderFrameCount(melFrameCount: Int) -> Int {
        (melFrameCount + melFramesPerEncoderFrame - 1) / melFramesPerEncoderFrame
    }

    /// Decodes a benchmark manifest and refuses it whole: duplicate ids and audio that is not
    /// the pinned recording are found before any model is loaded or any artifact created.
    ///
    /// Every route that reads a manifest row's audio shares this, so a run that measured a
    /// different recording than the manifest names stops instead of reporting a number.
    static func readManifest(at url: URL) throws -> [(row: PipelineInputRow, audio: URL)] {
        let reader = try JSONLLineReader(url: url)
        let decoder = JSONDecoder()
        var rows: [(row: PipelineInputRow, audio: URL)] = []
        var seenIDs = Set<String>()
        var lineNumber = 0
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
            guard seenIDs.insert(row.id).inserted else {
                throw BenchError.malformedInput(line: lineNumber, detail: "duplicate id \(row.id)")
            }
            rows.append((row, try BenchRunner.validatedAudioURL(for: row)))
        }
        guard !rows.isEmpty else { throw BenchError.io("\(url.path) has no rows") }
        return rows
    }

    /// One context per run, on the explicit `--model` file rather than the pinned product
    /// cache, with the accelerator dials fixed so dump and replay share one tail.
    static func makeContext(
        model: URL,
        coreMLEnvironment: [String: String]?
    ) throws -> ParakeetContext {
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw BenchError.io("model file missing: \(model.path)")
        }
        return try legible {
            if let coreMLEnvironment {
                return try ParakeetContext(
                    modelPath: model.path,
                    coreMLEnvironment: coreMLEnvironment,
                    useGPU: false,
                    tailBackendCPU: true,
                    log: { print("coreml: \($0)") }
                )
            }
            return try ParakeetContext(
                modelPath: model.path,
                weightArenaPath: nil,
                useGPU: false,
                tailBackendCPU: true
            )
        }
    }

    /// Keeps a sidecar error's own description. `ASRSidecarCore`'s CoreML errors describe
    /// themselves but are internal to that module, so `BenchError.describe` cannot name them
    /// and the bridged `NSError` would reduce a real contract violation to a numeric code.
    static func legible<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch let error as BenchError {
            throw error
        } catch {
            throw BenchError.io(String(describing: error))
        }
    }
}

/// Stage 1: one CoreML encode and one unchanged-tail decode per manifest row, with the states
/// that tail consumed written out beside its result.
struct GlossaryConditioningDumpStates {
    var input: URL
    var outputDirectory: URL
    var model: URL
    var lattice: URL?
    var vocabulary: URL?

    static func parse(_ arguments: [String]) throws -> GlossaryConditioningDumpStates {
        var input: URL?
        var outputDirectory: URL?
        var model: URL?
        var lattice: URL?
        var vocabulary: URL?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--input":
                input = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--output-dir":
                outputDirectory = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            case "--model":
                model = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--lattice":
                lattice = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--vocabulary":
                vocabulary = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            default:
                throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }
        guard let input else { throw BenchError.usage("missing --input") }
        guard let outputDirectory else { throw BenchError.usage("missing --output-dir") }
        guard let model else { throw BenchError.usage("missing --model") }
        return GlossaryConditioningDumpStates(
            input: input,
            outputDirectory: outputDirectory,
            model: model,
            lattice: lattice,
            vocabulary: vocabulary
        )
    }

    func run() throws {
        // Stage 1 is one exclusive pass over the whole manifest, so every cheap refusal is
        // paid before the first decode: a bad row 300 must not cost 299 good encodes.
        let rows = try GlossaryConditioningContract.readManifest(at: input)
        print("validated \(rows.count) manifest rows")

        let statesURL = outputDirectory.appendingPathComponent("states.f32")
        let indexURL = outputDirectory.appendingPathComponent("index.jsonl")
        let baselineURL = outputDirectory.appendingPathComponent("baseline-rows.jsonl")
        let commandURL = outputDirectory.appendingPathComponent("command.txt")

        // The dump is one exclusive pass whose digests become downstream inputs, so a second
        // pass into the same directory has to be a new directory, not a silent replacement.
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw BenchError.io(
                "cannot create \(outputDirectory.path): \(BenchError.describe(error))"
            )
        }
        for url in [statesURL, indexURL, baselineURL, commandURL] {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw BenchError.io("refusing to overwrite \(url.path)")
            }
        }

        let repair = try vocabulary.map(LoadedRepairEngine.load)
        let latticeTranscripts = try lattice.map(Self.readLatticeTranscripts)
        try Self.writeCommandRecord(to: commandURL)

        let context = try GlossaryConditioningContract.makeContext(
            model: model,
            coreMLEnvironment: ProcessInfo.processInfo.environment
        )

        FileManager.default.createFile(atPath: statesURL.path, contents: nil)
        let statesHandle: FileHandle
        do {
            statesHandle = try FileHandle(forWritingTo: statesURL)
        } catch {
            throw BenchError.io("cannot open \(statesURL.path): \(BenchError.describe(error))")
        }
        defer { try? statesHandle.close() }

        let indexWriter = try JSONLWriter(url: indexURL)
        let baselineWriter = try JSONLWriter(url: baselineURL)
        var byteOffset = 0
        var totalFrames = 0
        var latticeMatches = 0

        for (row, audioURL) in rows {
            let samples = try WAVFile.readSamples(at: audioURL)
            let melFrameCount = GlossaryConditioningContract.melFrameCount(
                sampleCount: samples.count
            )

            var stateBytes = Data()
            var frameCount = 0
            let inferenceStart = BenchClock.mark()
            let segments = try GlossaryConditioningContract.legible {
                try context.transcribeCapturingCoreMLStates(
                    samples: samples,
                    isCancelled: { false }
                ) { states, encoderFrameCount in
                    let expectedFrameCount = GlossaryConditioningContract.encoderFrameCount(
                        melFrameCount: melFrameCount
                    )
                    guard encoderFrameCount == expectedFrameCount,
                        states.count == encoderFrameCount * ParakeetContext.encoderStateWidth
                    else {
                        throw BenchError.io(
                            "\(row.id): encoder lent \(states.count) floats over \(encoderFrameCount) frames, expected \(expectedFrameCount) x \(ParakeetContext.encoderStateWidth)"
                        )
                    }
                    if let offending = states.firstIndex(where: { !$0.isFinite }) {
                        throw BenchError.io(
                            "\(row.id): non-finite encoder state at frame \(offending / ParakeetContext.encoderStateWidth), channel \(offending % ParakeetContext.encoderStateWidth)"
                        )
                    }
                    frameCount = encoderFrameCount
                    stateBytes = Data(buffer: states)
                }
            }
            let inferenceMs = BenchClock.elapsedMilliseconds(since: inferenceStart)

            do {
                try statesHandle.write(contentsOf: stateBytes)
            } catch {
                throw BenchError.io(
                    "cannot write \(statesURL.path): \(BenchError.describe(error))"
                )
            }

            let rawText = segments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedText = CleanupEngine.clean(rawText, glossary: [])
            let finalText = repair?.engine.repair(cleanedText).text ?? cleanedText
            let latticeMatch = latticeTranscripts.map { transcripts -> Bool in
                guard let cached = transcripts[row.id] else { return false }
                return cached.utf8.elementsEqual(rawText.utf8)
            }
            if latticeMatch == true { latticeMatches += 1 }

            try indexWriter.write(
                GlossaryConditioningIndexRow(
                    id: row.id,
                    byteOffset: byteOffset,
                    byteCount: stateBytes.count,
                    frameCount: frameCount,
                    width: ParakeetContext.encoderStateWidth,
                    audioSHA256: row.audioSHA256.lowercased(),
                    stateSHA256: GlossaryConditioningDigest.hex(stateBytes),
                    baselineRawText: rawText,
                    baselineFinalText: finalText,
                    transcriptSHA256: GlossaryConditioningDigest.hex(rawText),
                    baselineFinalSHA256: GlossaryConditioningDigest.hex(finalText),
                    audioPath: row.audioPath,
                    audioS: row.audioS,
                    melFrameCount: melFrameCount,
                    latticeTranscriptMatch: latticeMatch
                )
            )
            try baselineWriter.write(
                GlossaryConditioningBaselineRow(
                    id: row.id,
                    frameCount: frameCount,
                    rawText: rawText,
                    cleanedText: cleanedText,
                    finalText: finalText,
                    transcriptSHA256: GlossaryConditioningDigest.hex(rawText),
                    inferenceMs: inferenceMs,
                    tokens: segments.flatMap(\.tokens).map(GlossaryConditioningToken.init),
                    segments: segments.map(GlossaryConditioningSegment.init)
                )
            )

            print(
                "dumped \(row.id) frames=\(frameCount) offset=\(byteOffset) bytes=\(stateBytes.count) inference_ms=\(inferenceMs)"
            )
            byteOffset += stateBytes.count
            totalFrames += frameCount
        }

        try? statesHandle.close()
        print(
            "wrote \(rows.count) rows, \(totalFrames) encoder frames, \(byteOffset) state bytes to \(outputDirectory.path)"
        )
        print("states.f32 sha256=\(try BenchRunner.sha256(of: statesURL))")
        print("index.jsonl sha256=\(try BenchRunner.sha256(of: indexURL))")
        print("baseline-rows.jsonl sha256=\(try BenchRunner.sha256(of: baselineURL))")
        if latticeTranscripts != nil {
            print("lattice raw-text agreement \(latticeMatches)/\(rows.count)")
        }
    }

    /// Records the invocation beside its output: the dump is not reproducible from the
    /// artifacts alone, because tier routing lives in the environment.
    private static func writeCommandRecord(to url: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        var text = ProcessInfo.processInfo.arguments.joined(separator: " ") + "\n"
        for key in environment.keys.sorted() where key.hasPrefix("VOICEOUR_") {
            text += "\(key)=\(environment[key] ?? "")\n"
        }
        text += "fixed: use_gpu=false tail_backend=cpu tail_threads=4 weight_arena=none\n"
        do {
            try Data(text.utf8).write(to: url)
        } catch {
            throw BenchError.io("cannot write \(url.path): \(BenchError.describe(error))")
        }
    }

    private static func readLatticeTranscripts(_ url: URL) throws -> [String: String] {
        let reader = try JSONLLineReader(url: url)
        let decoder = JSONDecoder()
        var transcripts: [String: String] = [:]
        var lineNumber = 0
        while let line = try reader.nextLine() {
            lineNumber += 1
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let row: GlossaryConditioningLatticeRow
            do {
                row = try decoder.decode(
                    GlossaryConditioningLatticeRow.self,
                    from: Data(line.utf8)
                )
            } catch {
                throw BenchError.malformedInput(line: lineNumber, detail: BenchError.describe(error))
            }
            transcripts[row.id] = row.transcript
        }
        return transcripts
    }
}

/// Stage 2: decode manifest rows from a state pack, through the same unchanged tail, with no
/// encoder of any kind involved.
struct GlossaryConditioningReplayStates {
    var input: URL
    var states: URL
    var index: URL
    var output: URL
    var model: URL
    var vocabulary: URL?

    static func parse(_ arguments: [String]) throws -> GlossaryConditioningReplayStates {
        var input: URL?
        var states: URL?
        var stateIndex: URL?
        var output: URL?
        var model: URL?
        var vocabulary: URL?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--input":
                input = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--states":
                states = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--index":
                stateIndex = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            case "--output":
                output = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--model":
                model = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--vocabulary":
                vocabulary = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            default:
                throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }
        guard let input else { throw BenchError.usage("missing --input") }
        guard let states else { throw BenchError.usage("missing --states") }
        guard let stateIndex else { throw BenchError.usage("missing --index") }
        guard let output else { throw BenchError.usage("missing --output") }
        guard let model else { throw BenchError.usage("missing --model") }
        return GlossaryConditioningReplayStates(
            input: input,
            states: states,
            index: stateIndex,
            output: output,
            model: model,
            vocabulary: vocabulary
        )
    }

    func run() throws {
        let entries = try readIndex()
        let packByteCount = try Self.byteCount(of: states)
        let repair = try vocabulary.map(LoadedRepairEngine.load)
        // No CoreML environment: replay never encodes, so it must not load a tier's model, and
        // its result must not depend on which tiers happen to be configured.
        let context = try GlossaryConditioningContract.makeContext(
            model: model,
            coreMLEnvironment: nil
        )

        let statesHandle: FileHandle
        do {
            statesHandle = try FileHandle(forReadingFrom: states)
        } catch {
            throw BenchError.io("cannot open \(states.path): \(BenchError.describe(error))")
        }
        defer { try? statesHandle.close() }

        let writer = try JSONLWriter(url: output)
        let reader = try JSONLLineReader(url: input)
        let decoder = JSONDecoder()
        var lineNumber = 0
        var rowCount = 0

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
            guard let entry = entries[row.id] else {
                throw BenchError.io("\(row.id): no state-pack index entry")
            }

            let audioURL = try BenchRunner.validatedAudioURL(for: row)
            let samples = try WAVFile.readSamples(at: audioURL)
            let melFrameCount = GlossaryConditioningContract.melFrameCount(
                sampleCount: samples.count
            )
            let expectedFrameCount = GlossaryConditioningContract.encoderFrameCount(
                melFrameCount: melFrameCount
            )
            guard entry.width == ParakeetContext.encoderStateWidth else {
                throw BenchError.io(
                    "\(row.id): index width \(entry.width), expected \(ParakeetContext.encoderStateWidth)"
                )
            }
            guard entry.frameCount == expectedFrameCount else {
                throw BenchError.io(
                    "\(row.id): index frame_count \(entry.frameCount), mel of \(melFrameCount) frames expects \(expectedFrameCount)"
                )
            }
            let expectedByteCount = entry.frameCount * entry.width * 4
            guard entry.byteCount == expectedByteCount else {
                throw BenchError.io(
                    "\(row.id): index byte_count \(entry.byteCount), expected \(expectedByteCount)"
                )
            }
            guard entry.byteOffset >= 0, entry.byteOffset + entry.byteCount <= packByteCount else {
                throw BenchError.io(
                    "\(row.id): index range \(entry.byteOffset)+\(entry.byteCount) exceeds the \(packByteCount)-byte pack"
                )
            }

            let stateBytes = try Self.read(
                handle: statesHandle,
                offset: entry.byteOffset,
                byteCount: entry.byteCount,
                id: row.id
            )
            if let expected = entry.stateSHA256 {
                let digest = GlossaryConditioningDigest.hex(stateBytes)
                guard digest == expected.lowercased() else {
                    throw BenchError.io(
                        "\(row.id): state sha256 \(digest), index says \(expected.lowercased())"
                    )
                }
            }

            let floatCount = entry.frameCount * entry.width
            var copiedBytes = 0
            let floats = [Float](unsafeUninitializedCapacity: floatCount) { buffer, initialized in
                copiedBytes = stateBytes.copyBytes(to: buffer)
                initialized = floatCount
            }
            guard copiedBytes == entry.byteCount else {
                throw BenchError.io(
                    "\(row.id): copied \(copiedBytes) of \(entry.byteCount) state bytes"
                )
            }
            if let offending = floats.firstIndex(where: { !$0.isFinite }) {
                throw BenchError.io(
                    "\(row.id): non-finite injected state at frame \(offending / entry.width), channel \(offending % entry.width)"
                )
            }

            let segments = try floats.withUnsafeBufferPointer { buffer in
                try context.transcribeWithExternalStates(
                    samples: samples,
                    states: buffer,
                    frameCount: entry.frameCount,
                    isCancelled: { false }
                )
            }
            let rawText = segments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedText = CleanupEngine.clean(rawText, glossary: [])
            let finalText = repair.map { $0.engine.repair(cleanedText).text }
            try writer.write(
                GlossaryConditioningReplayRow(
                    id: row.id,
                    rawText: rawText,
                    cleanedText: cleanedText,
                    transcriptSHA256: GlossaryConditioningDigest.hex(rawText),
                    frameCount: entry.frameCount,
                    tokens: segments.flatMap(\.tokens).map(GlossaryConditioningToken.init),
                    finalText: finalText,
                    finalSHA256: finalText.map(GlossaryConditioningDigest.hex)
                )
            )
            rowCount += 1
            print("replayed \(row.id) frames=\(entry.frameCount)")
        }

        print("wrote \(rowCount) replay rows to \(output.path)")
    }

    private func readIndex() throws -> [String: GlossaryConditioningIndexEntry] {
        let reader = try JSONLLineReader(url: index)
        let decoder = JSONDecoder()
        var entries: [String: GlossaryConditioningIndexEntry] = [:]
        var lineNumber = 0
        while let line = try reader.nextLine() {
            lineNumber += 1
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let entry: GlossaryConditioningIndexEntry
            do {
                entry = try decoder.decode(
                    GlossaryConditioningIndexEntry.self,
                    from: Data(line.utf8)
                )
            } catch {
                throw BenchError.malformedInput(line: lineNumber, detail: BenchError.describe(error))
            }
            guard entries.updateValue(entry, forKey: entry.id) == nil else {
                throw BenchError.malformedInput(
                    line: lineNumber,
                    detail: "duplicate index id \(entry.id)"
                )
            }
        }
        return entries
    }

    private static func byteCount(of url: URL) throws -> Int {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw BenchError.io("cannot stat \(url.path): \(BenchError.describe(error))")
        }
    }

    private static func read(
        handle: FileHandle,
        offset: Int,
        byteCount: Int,
        id: String
    ) throws -> Data {
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
                throw BenchError.io("\(id): state pack ended before \(byteCount) bytes")
            }
            return data
        } catch let error as BenchError {
            throw error
        } catch {
            throw BenchError.io("\(id): cannot read state pack: \(BenchError.describe(error))")
        }
    }
}

enum GlossaryConditioningDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ text: String) -> String {
        hex(Data(text.utf8))
    }
}

private struct GlossaryConditioningLatticeRow: Decodable {
    var id: String
    var transcript: String
}

/// The index rows `dump-states` writes. The first ten keys are the pack's contract; the rest
/// are provenance a consumer may ignore.
private struct GlossaryConditioningIndexRow: Encodable {
    var id: String
    var byteOffset: Int
    var byteCount: Int
    var frameCount: Int
    var width: Int
    var audioSHA256: String
    var stateSHA256: String
    var baselineRawText: String
    var baselineFinalText: String
    var transcriptSHA256: String
    var baselineFinalSHA256: String
    var audioPath: String
    var audioS: Double?
    var melFrameCount: Int
    var latticeTranscriptMatch: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case byteOffset = "byte_offset"
        case byteCount = "byte_count"
        case frameCount = "frame_count"
        case width
        case audioSHA256 = "audio_sha256"
        case stateSHA256 = "state_sha256"
        case baselineRawText = "baseline_raw_text"
        case baselineFinalText = "baseline_final_text"
        case transcriptSHA256 = "transcript_sha256"
        case baselineFinalSHA256 = "baseline_final_sha256"
        case audioPath = "audio_path"
        case audioS = "audio_s"
        case melFrameCount = "mel_frame_count"
        case latticeTranscriptMatch = "lattice_transcript_match"
    }
}

/// The index rows `replay-states` reads. Only the pack geometry is required, so an offline
/// stage can write an adapted pack without restating audio or state digests; a `state_sha256`
/// that is present is verified.
private struct GlossaryConditioningIndexEntry: Decodable {
    var id: String
    var byteOffset: Int
    var byteCount: Int
    var frameCount: Int
    var width: Int
    var stateSHA256: String?

    enum CodingKeys: String, CodingKey {
        case id
        case byteOffset = "byte_offset"
        case byteCount = "byte_count"
        case frameCount = "frame_count"
        case width
        case stateSHA256 = "state_sha256"
    }
}

private struct GlossaryConditioningBaselineRow: Encodable {
    var id: String
    var frameCount: Int
    var rawText: String
    var cleanedText: String
    var finalText: String
    var transcriptSHA256: String
    var inferenceMs: Int
    /// Every returned token in decode order, so a consumer can map an encoder frame onto the
    /// character span it produced without realigning a differently configured decode.
    var tokens: [GlossaryConditioningToken]
    var segments: [GlossaryConditioningSegment]

    enum CodingKeys: String, CodingKey {
        case id
        case frameCount = "frame_count"
        case rawText = "raw_text"
        case cleanedText = "cleaned_text"
        case finalText = "final_text"
        case transcriptSHA256 = "transcript_sha256"
        case inferenceMs = "inference_ms"
        case tokens
        case segments
    }
}

private struct GlossaryConditioningSegment: Encodable {
    var startMs: Int
    var endMs: Int
    var text: String
    var tokens: [GlossaryConditioningToken]

    init(_ segment: ParakeetSegmentRaw) {
        startMs = segment.startMs
        endMs = segment.endMs
        text = segment.text
        tokens = segment.tokens.map(GlossaryConditioningToken.init)
    }

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
        case tokens
    }
}

private struct GlossaryConditioningToken: Encodable {
    var piece: String
    var text: String
    var probability: Float
    var startMs: Int
    var endMs: Int
    var isWordStart: Bool

    init(_ token: ParakeetToken) {
        piece = token.piece
        text = token.text
        probability = token.probability
        startMs = token.startMs
        endMs = token.endMs
        isWordStart = token.isWordStart
    }

    enum CodingKeys: String, CodingKey {
        case piece
        case text
        case probability
        case startMs = "start_ms"
        case endMs = "end_ms"
        case isWordStart = "is_word_start"
    }
}

private struct GlossaryConditioningReplayRow: Encodable {
    var id: String
    var rawText: String
    var cleanedText: String
    var transcriptSHA256: String
    var frameCount: Int
    /// Every returned token in decode order: the adapted decode's own encoder-frame to
    /// character-span map, which no other artifact can supply for a perturbed state pack.
    var tokens: [GlossaryConditioningToken]
    var finalText: String?
    var finalSHA256: String?

    enum CodingKeys: String, CodingKey {
        case id
        case rawText = "raw_text"
        case cleanedText = "cleaned_text"
        case transcriptSHA256 = "transcript_sha256"
        case frameCount = "frame_count"
        case tokens
        case finalText = "final_text"
        case finalSHA256 = "final_sha256"
    }
}
