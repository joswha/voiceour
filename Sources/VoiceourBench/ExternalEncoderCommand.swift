import ASRSidecarCore
import CoreML
import CryptoKit
import Foundation
import VoiceCore

/// Benchmark-only external encoders over the same native mel and fixed CPU TDT tail.
/// CoreML lends states through its observer; Core AI consumes `ParakeetContext.nativeMel`.
///
/// Timing boundaries differ: CoreML `encode_ms` includes mel, while Core AI `tail_ms`
/// includes mel recomputation. Both hash states outside stage timers; `encoder_meta.note`
/// records these boundaries and the chosen artifact.
struct ExternalEncoderCommand {
    enum Engine: String, CaseIterable {
        case coreml
        case coreai
    }

    /// Fixed by both native hybrid routes; recorded to identify the measured tail.
    static let tailThreads = 4

    /// Shared window so both candidates accept the same filtered manifest.
    static let maximumSampleCount = CoreAIEncoderConfiguration.maximumSampleCount

    /// The error every row past the window carries, in both engines.
    static let windowErrorMessage = "exceeds the 15 s window"

    /// The CoreML tier keys this route reads, in the order `CoreMLEncoderConfigurationSet`
    /// consults them. A run may configure exactly one: with two tiers set, rows would route by
    /// duration through different artifacts and a single `encoder_meta` could not name the tree
    /// that encoded them.
    static let coreMLTierKeys = [
        "VOICEOUR_COREML_ENCODER_TINY",
        "VOICEOUR_COREML_ENCODER_SHORT",
        "VOICEOUR_COREML_ENCODER",
    ]

    var engine: Engine
    var input: URL
    var output: URL
    var model: URL
    var coreAI: CoreAIEncoderConfiguration?
    var vocabulary: URL?

    /// Keep CLI refusals aligned with the adapter's accepted cases.
    private static func spellings<Dial: CaseIterable & RawRepresentable>(
        of dial: Dial.Type
    ) -> String where Dial.RawValue == String {
        Dial.allCases.map(\.rawValue).joined(separator: ", ")
    }

    static func parse(_ arguments: [String]) throws -> ExternalEncoderCommand {
        var engine: Engine?
        var input: URL?
        var output: URL?
        var model: URL?
        var coreAIModel: URL?
        var computeUnits: CoreAIEncoderConfiguration.ComputeUnits?
        var cachePolicy: CoreAIEncoderConfiguration.CachePolicy?
        var vocabulary: URL?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--engine":
                let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
                guard let parsedEngine = Engine(rawValue: value) else {
                    throw BenchError.usage(
                        "--engine must be one of: \(Self.spellings(of: Engine.self))"
                    )
                }
                engine = parsedEngine
            case "--input":
                input = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--output":
                output = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--model":
                model = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--coreai-model":
                coreAIModel = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            case "--coreai-compute":
                let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
                guard let parsedCompute = CoreAIEncoderConfiguration.ComputeUnits(rawValue: value)
                else {
                    throw BenchError.usage(
                        "--coreai-compute must be one of: \(Self.spellings(of: CoreAIEncoderConfiguration.ComputeUnits.self))"
                    )
                }
                computeUnits = parsedCompute
            case "--coreai-cache":
                let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
                guard let parsedCache = CoreAIEncoderConfiguration.CachePolicy(rawValue: value)
                else {
                    throw BenchError.usage(
                        "--coreai-cache must be one of: \(Self.spellings(of: CoreAIEncoderConfiguration.CachePolicy.self))"
                    )
                }
                cachePolicy = parsedCache
            case "--vocabulary":
                vocabulary = BenchCLI.fileURL(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index)
                )
            default:
                throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }

        guard let engine else { throw BenchError.usage("missing --engine") }
        guard let input else { throw BenchError.usage("missing --input") }
        guard let output else { throw BenchError.usage("missing --output") }
        guard let model else { throw BenchError.usage("missing --model") }

        var coreAI: CoreAIEncoderConfiguration?
        switch engine {
        case .coreml:
            // CoreML uses environment-selected tiers, not Core AI command-line options.
            guard coreAIModel == nil, computeUnits == nil, cachePolicy == nil else {
                throw BenchError.usage(
                    "--coreai-model, --coreai-compute and --coreai-cache are only valid with --engine coreai"
                )
            }
        case .coreai:
            guard let coreAIModel else {
                throw BenchError.usage("--engine coreai requires --coreai-model")
            }
            coreAI = CoreAIEncoderConfiguration(
                modelURL: coreAIModel,
                computeUnits: computeUnits ?? .default,
                cachePolicy: cachePolicy ?? .default
            )
        }

        // Reports cite these rows by digest; refuse overwrite before loading a model.
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw BenchError.io("refusing to overwrite \(output.path)")
        }

        return ExternalEncoderCommand(
            engine: engine,
            input: input,
            output: output,
            model: model,
            coreAI: coreAI,
            vocabulary: vocabulary
        )
    }

    func run() async throws {
        // One exclusive pass whose row set must match the other candidates', so the whole
        // manifest is validated — ids, audio sizes, audio digests — before any model loads.
        let rows = try GlossaryConditioningContract.readManifest(at: input)
        print("validated \(rows.count) manifest rows")

        let repair = try vocabulary.map(LoadedRepairEngine.load)
        let manifestSHA256 = try BenchRunner.sha256(of: input)
        let audioManifestSHA256 = try BenchRunner.audioManifestSHA256(of: input)
        let meta = BenchMeta(
            mode: "external-encoder",
            backend: engine.rawValue,
            // No registry descriptor: the weight filename and encoder_meta pin the artifacts.
            modelId: engine.rawValue,
            modelRevision: engine.rawValue,
            modelFile: model.lastPathComponent,
            manifestSHA256: manifestSHA256,
            audioManifestSHA256: audioManifestSHA256,
            vocabularySHA256: repair?.sha256,
            startedAt: ISO8601DateFormatter().string(from: Date())
        )

        // Do not create output until the encoder and its provenance are available.
        switch engine {
        case .coreml:
            try runCoreML(rows: rows, meta: meta, repair: repair)
        case .coreai:
            guard let coreAI else {
                throw BenchError.usage("--engine coreai requires --coreai-model")
            }
            try await runCoreAI(coreAI, rows: rows, meta: meta, repair: repair)
        }
    }

    // MARK: - CoreML tier

    private func runCoreML(
        rows: [(row: PipelineInputRow, audio: URL)],
        meta: BenchMeta,
        repair: LoadedRepairEngine?
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        let tier = try Self.selectedCoreMLTier(environment: environment)
        let artifact = try Self.artifactDigest(at: tier.modelURL)
        let preflightMs = try Self.timedPreflightLoad(of: tier.modelURL)
        let context = try GlossaryConditioningContract.makeContext(
            model: model,
            coreMLEnvironment: environment
        )
        let writer = try JSONLWriter(url: output)
        try writer.write(meta)
        try writer.write(
            ExternalEncoderMeta(
                engine: engine.rawValue,
                modelPath: tier.modelURL.path,
                modelTreeSHA256: artifact.sha256,
                modelTreeBytes: artifact.byteCount,
                modelTreeFiles: artifact.fileCount,
                // The tier's own `MLModelConfiguration` is not observable from here; this names
                // the units the preflight load above used, which mirror the tier's.
                compute: "cpu-and-neural-engine",
                cachePolicy: nil,
                deviceArchitecture: nil,
                availableComputeUnits: nil,
                specializationMs: nil,
                loadFunctionMs: preflightMs,
                tailThreads: Self.tailThreads,
                note: """
                    \(tier.environmentKey)=\(tier.modelURL.path) is the only configured tier, so \
                    every row encoded through this tree. load_function_ms is a benchmark-only \
                    preflight MLModel load of that artifact with computeUnits = \
                    .cpuAndNeuralEngine, the units Sources/ASRSidecarCore/CoreMLEncoder.swift \
                    configures; it is not the sidecar tier's own load, which stays lazy and is \
                    paid inside the first row's encode_ms. mel_ms is null because the tier's \
                    encode computes the native mel internally.
                    """
            )
        )

        var measuredRows = 0
        var firstFailure: String?
        for (row, audioURL) in rows {
            let totalStart = BenchClock.mark()
            do {
                let samples = try WAVFile.readSamples(at: audioURL)
                try Self.checkWindow(sampleCount: samples.count, id: row.id)
                let measured = try Self.measureCoreML(
                    samples: samples,
                    id: row.id,
                    context: context
                )
                try writer.write(
                    outputRow(row, measured: measured, repair: repair, totalStart: totalStart)
                )
                measuredRows += 1
                print(
                    "processed \(row.id) encode_ms=\(measured.encodeMs) tail_ms=\(measured.tailMs) frames=\(measured.frameCount)"
                )
            } catch {
                let detail = BenchError.describe(error)
                firstFailure = firstFailure ?? "\(row.id): \(detail)"
                try writer.write(Self.errorRow(row, detail: detail, totalStart: totalStart))
                print("failed \(row.id): \(detail)")
            }
        }
        try Self.report(measuredRows: measuredRows, rows: rows.count, firstFailure: firstFailure)
    }

    /// Runs the configured tier's encode and the unchanged tail over one row, stamping the
    /// encoder/tail boundary from inside the state observer.
    ///
    /// The digest and the finiteness scan run between the two stamps, so neither `encode_ms` nor
    /// `tail_ms` carries the benchmark's own bookkeeping — the Core AI route hashes outside its
    /// timed sections too, and the two `tail_ms` columns have to stay comparable.
    private static func measureCoreML(
        samples: [Float],
        id: String,
        context: ParakeetContext
    ) throws -> MeasuredEncode {
        let expectedFrameCount = GlossaryConditioningContract.encoderFrameCount(
            melFrameCount: GlossaryConditioningContract.melFrameCount(sampleCount: samples.count)
        )
        var encoderStamp: UInt64?
        var tailStamp: UInt64?
        var frameCount = 0
        var statesSHA256 = ""
        let start = BenchClock.mark()
        let segments = try GlossaryConditioningContract.legible {
            try context.transcribeCapturingCoreMLStates(
                samples: samples,
                isCancelled: { false }
            ) { states, encoderFrameCount in
                encoderStamp = BenchClock.mark()
                guard encoderFrameCount == expectedFrameCount,
                    states.count == encoderFrameCount * ParakeetContext.encoderStateWidth
                else {
                    throw BenchError.io(
                        "\(id): encoder lent \(states.count) floats over \(encoderFrameCount) frames, expected \(expectedFrameCount) x \(ParakeetContext.encoderStateWidth)"
                    )
                }
                if let offending = states.firstIndex(where: { !$0.isFinite }) {
                    throw BenchError.io(
                        "\(id): non-finite encoder state at frame \(offending / ParakeetContext.encoderStateWidth), channel \(offending % ParakeetContext.encoderStateWidth)"
                    )
                }
                frameCount = encoderFrameCount
                statesSHA256 = GlossaryConditioningDigest.hex(Data(buffer: states))
                tailStamp = BenchClock.mark()
            }
        }
        let end = BenchClock.mark()
        guard let encoderStamp, let tailStamp else {
            throw BenchError.io("\(id): the CoreML tier decoded without lending its states")
        }
        return MeasuredEncode(
            melMs: nil,
            encodeMs: BenchClock.milliseconds(from: start, to: encoderStamp),
            tailMs: BenchClock.milliseconds(from: tailStamp, to: end),
            frameCount: frameCount,
            statesSHA256: statesSHA256,
            segments: segments
        )
    }

    /// The one tier this run may measure, with the key that selected it.
    private static func selectedCoreMLTier(
        environment: [String: String]
    ) throws -> (environmentKey: String, modelURL: URL) {
        let configured = coreMLTierKeys.compactMap { key -> (String, String)? in
            guard let path = environment[key], !path.isEmpty else { return nil }
            return (key, path)
        }
        guard let first = configured.first else {
            throw BenchError.io(
                "--engine coreml needs exactly one of \(coreMLTierKeys.joined(separator: ", ")) set to a compiled .mlmodelc"
            )
        }
        guard configured.count == 1 else {
            throw BenchError.io(
                """
                --engine coreml refuses \(configured.count) configured CoreML tiers \
                (\(configured.map(\.0).joined(separator: ", "))): rows would route by duration \
                through different artifacts and one encoder_meta could not name the tree that \
                encoded them; configure exactly one tier
                """
            )
        }
        return (first.0, BenchCLI.fileURL(first.1))
    }

    /// Independent preflight load, not the lazy tier's own load; recorded as such in metadata.
    private static func timedPreflightLoad(of url: URL) throws -> Int {
        guard url.pathExtension.lowercased() == "mlmodelc" else {
            throw BenchError.io(
                "--engine coreml needs a compiled .mlmodelc tier so the preflight load measures a load and not a compilation: \(url.path)"
            )
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let start = BenchClock.mark()
        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw BenchError.io(
                "cannot load \(url.path): \(BenchError.describe(error))"
            )
        }
        let elapsed = withExtendedLifetime(loaded) { BenchClock.elapsedMilliseconds(since: start) }
        print("preflight load of \(url.lastPathComponent) took \(elapsed) ms")
        return elapsed
    }

    // MARK: - Core AI artifact

    private func runCoreAI(
        _ options: CoreAIEncoderConfiguration,
        rows: [(row: PipelineInputRow, audio: URL)],
        meta: BenchMeta,
        repair: LoadedRepairEngine?
    ) async throws {
        let artifact = try Self.artifactDigest(at: options.modelURL)
        let context = try GlossaryConditioningContract.makeContext(
            model: model,
            coreMLEnvironment: nil
        )
        // The encoder is not `Sendable` and stays in this one nonisolated async frame: it is
        // created, awaited and dropped here, never stored anywhere an actor could reach it.
        let (encoder, load) = try await CoreAIEncoder.load(configuration: options)
        let writer = try JSONLWriter(url: output)
        try writer.write(meta)
        try writer.write(
            ExternalEncoderMeta(
                engine: engine.rawValue,
                modelPath: options.modelURL.path,
                modelTreeSHA256: artifact.sha256,
                modelTreeBytes: artifact.byteCount,
                modelTreeFiles: artifact.fileCount,
                compute: options.computeUnits.rawValue,
                cachePolicy: options.cachePolicy.rawValue,
                deviceArchitecture: load.deviceArchitecture,
                availableComputeUnits: load.availableComputeUnits,
                specializationMs: load.specializationMs,
                loadFunctionMs: load.loadFunctionMs,
                tailThreads: Self.tailThreads,
                note: """
                    specialization_ms and load_function_ms measure this process's own \
                    specialization and function load; a fresh process does not prove a cold \
                    system cache. compute records the requested preference, not measured device \
                    residency. mel_ms is the native front end, encode_ms is Core AI alone, \
                    and tail_ms includes the external-state tail's extra mel recomputation.
                    """
            )
        )

        var measuredRows = 0
        var firstFailure: String?
        for (row, audioURL) in rows {
            let totalStart = BenchClock.mark()
            do {
                let samples = try WAVFile.readSamples(at: audioURL)
                try Self.checkWindow(sampleCount: samples.count, id: row.id)

                let melStart = BenchClock.mark()
                let mel = try GlossaryConditioningContract.legible {
                    try context.nativeMel(samples: samples)
                }
                let melMs = BenchClock.elapsedMilliseconds(since: melStart)

                let encodeStart = BenchClock.mark()
                let states = try await encoder.encode(mel)
                let encodeMs = BenchClock.elapsedMilliseconds(since: encodeStart)

                let expectedFrameCount = GlossaryConditioningContract.encoderFrameCount(
                    melFrameCount: mel.frameCount
                )
                guard states.frameCount == expectedFrameCount,
                    states.values.count == states.frameCount * ParakeetContext.encoderStateWidth
                else {
                    throw BenchError.io(
                        "\(row.id): encoder returned \(states.values.count) floats over \(states.frameCount) frames, expected \(expectedFrameCount) x \(ParakeetContext.encoderStateWidth)"
                    )
                }

                let tailStart = BenchClock.mark()
                let segments = try states.values.withUnsafeBufferPointer { buffer in
                    try GlossaryConditioningContract.legible {
                        try context.transcribeWithExternalStates(
                            samples: samples,
                            states: buffer,
                            frameCount: states.frameCount,
                            isCancelled: { false }
                        )
                    }
                }
                let tailMs = BenchClock.elapsedMilliseconds(since: tailStart)

                // Hashed outside every timed section, exactly as the CoreML route does, so the
                // two runs' stage timings stay comparable.
                let statesSHA256 = states.values.withUnsafeBufferPointer { buffer in
                    GlossaryConditioningDigest.hex(Data(buffer: buffer))
                }
                let measured = MeasuredEncode(
                    melMs: melMs,
                    encodeMs: encodeMs,
                    tailMs: tailMs,
                    frameCount: states.frameCount,
                    statesSHA256: statesSHA256,
                    segments: segments
                )
                try writer.write(
                    outputRow(row, measured: measured, repair: repair, totalStart: totalStart)
                )
                measuredRows += 1
                print(
                    "processed \(row.id) mel_ms=\(melMs) encode_ms=\(encodeMs) tail_ms=\(tailMs) frames=\(states.frameCount)"
                )
            } catch {
                let detail = BenchError.describe(error)
                firstFailure = firstFailure ?? "\(row.id): \(detail)"
                try writer.write(Self.errorRow(row, detail: detail, totalStart: totalStart))
                print("failed \(row.id): \(detail)")
            }
        }
        try Self.report(measuredRows: measuredRows, rows: rows.count, firstFailure: firstFailure)
    }

    // MARK: - Rows

    /// One row's encoder measurement, engine-independent so both branches emit one row shape.
    private struct MeasuredEncode {
        var melMs: Int?
        var encodeMs: Int
        var tailMs: Int
        var frameCount: Int
        var statesSHA256: String
        var segments: [ParakeetSegmentRaw]
    }

    /// The pipeline's own deterministic text stage: cleanup with an empty glossary, then the
    /// optional repair vocabulary. No assist arbitration — one decoder produced one transcript.
    private func outputRow(
        _ input: PipelineInputRow,
        measured: MeasuredEncode,
        repair: LoadedRepairEngine?,
        totalStart: UInt64
    ) -> BenchOutputRow {
        let rawTranscript = measured.segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanupStart = BenchClock.mark()
        let cleanedText = CleanupEngine.clean(rawTranscript, glossary: [])
        let finalText = repair?.engine.repair(cleanedText).text ?? cleanedText
        let cleanupMs = BenchClock.elapsedMilliseconds(since: cleanupStart)
        let inferenceMs = (measured.melMs ?? 0) + measured.encodeMs + measured.tailMs
        return BenchOutputRow(
            id: input.id,
            rawTranscript: rawTranscript,
            cleanedText: cleanedText,
            finalText: finalText,
            timingsMs: BenchOutputTimings(
                asr: inferenceMs,
                asrLoad: nil,
                asrInference: inferenceMs,
                cleanup: cleanupMs,
                total: BenchClock.elapsedMilliseconds(since: totalStart)
            ),
            audioS: input.audioS,
            encoder: EncoderRowTimings(
                melMs: measured.melMs,
                encodeMs: measured.encodeMs,
                tailMs: measured.tailMs,
                encoderFrames: measured.frameCount,
                statesSHA256: measured.statesSHA256
            )
        )
    }

    /// The experiment's window, applied identically by both engines so one filtered manifest
    /// yields one row set per candidate. The refusal detail goes to stdout; the row carries the
    /// pinned message, which the summary reports verbatim.
    private static func checkWindow(sampleCount: Int, id: String) throws {
        guard sampleCount > maximumSampleCount else { return }
        print(
            "refused \(id): \(sampleCount) samples exceed the \(maximumSampleCount)-sample window"
        )
        throw BenchError.io(windowErrorMessage)
    }

    /// A refused or failed row still occupies its manifest line: the candidates are compared row
    /// by row, and a missing id would look like a different corpus instead of a failure.
    private static func errorRow(
        _ input: PipelineInputRow,
        detail: String,
        totalStart: UInt64
    ) -> BenchOutputRow {
        BenchOutputRow(
            id: input.id,
            rawTranscript: "",
            cleanedText: "",
            finalText: "",
            timingsMs: BenchOutputTimings(
                asr: nil,
                asrLoad: nil,
                asrInference: nil,
                cleanup: 0,
                total: BenchClock.elapsedMilliseconds(since: totalStart)
            ),
            audioS: input.audioS,
            error: detail
        )
    }

    /// Refuses a run that measured nothing. The rows are already written for inspection, but a
    /// zero exit would report an empty measurement as a successful one.
    private static func report(measuredRows: Int, rows: Int, firstFailure: String?) throws {
        print("wrote \(rows) external-encoder rows, \(measuredRows) measured")
        guard measuredRows > 0 else {
            throw BenchError.io(
                "no row produced a measurement; first failure was \(firstFailure ?? "not recorded")"
            )
        }
    }

    // MARK: - Artifact digest

    /// SHA-256 of sorted UTF-8 "<relative path> <file sha256>\n" records, excluding symlinks.
    /// Matches `bench/coreai/convert_encoder.py`'s `artifact_digest`; a lone file uses its name.
    static func artifactDigest(at url: URL) throws -> (sha256: String, byteCount: Int, fileCount: Int) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BenchError.io("encoder artifact missing: \(url.path)")
        }

        var files: [(relativePath: String, url: URL)] = []
        if isDirectory.boolValue {
            guard let walker = manager.enumerator(atPath: url.path) else {
                throw BenchError.io("cannot enumerate \(url.path)")
            }
            for case let relativePath as String in walker {
                let child = url.appendingPathComponent(relativePath)
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    )
                } catch {
                    throw BenchError.io(
                        "cannot stat \(child.path): \(BenchError.describe(error))"
                    )
                }
                guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                files.append(
                    (relativePath: relativePath, url: child)
                )
            }
            // Byte ordering, which is what the Python side's code-point sort produces for the
            // same names.
            files.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        } else {
            files = [(relativePath: url.lastPathComponent, url: url)]
        }
        guard !files.isEmpty else {
            throw BenchError.io("no regular files to digest under \(url.path)")
        }

        var hasher = SHA256()
        var byteCount = 0
        for file in files {
            let digest = try BenchRunner.sha256(of: file.url)
            hasher.update(data: Data("\(file.relativePath) \(digest)\n".utf8))
            do {
                let attributes = try manager.attributesOfItem(atPath: file.url.path)
                byteCount += (attributes[.size] as? NSNumber)?.intValue ?? 0
            } catch {
                throw BenchError.io(
                    "cannot stat \(file.url.path): \(BenchError.describe(error))"
                )
            }
        }
        return (
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: byteCount,
            fileCount: files.count
        )
    }
}

/// Per-stage encoder timings and the state digest for one row. Only the `external-encoder` mode
/// emits this object; `BenchOutputRow` encodes it only when present.
struct EncoderRowTimings: Encodable {
    /// Null for the CoreML tier, whose encode computes the native mel internally.
    var melMs: Int?
    var encodeMs: Int
    var tailMs: Int
    var encoderFrames: Int
    /// SHA-256 of the frame-major `[frames, 1024]` F32 states the tail consumed. Both engines
    /// hash the same layout, so the value compares across engines and across repeat runs.
    var statesSHA256: String

    enum CodingKeys: String, CodingKey {
        case melMs = "mel_ms"
        case encodeMs = "encode_ms"
        case tailMs = "tail_ms"
        case encoderFrames = "encoder_frames"
        case statesSHA256 = "states_sha256"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(melMs, forKey: .melMs)
        try container.encode(encodeMs, forKey: .encodeMs)
        try container.encode(tailMs, forKey: .tailMs)
        try container.encode(encoderFrames, forKey: .encoderFrames)
        try container.encode(statesSHA256, forKey: .statesSHA256)
    }
}

/// The run's encoder provenance: which artifact encoded every row, how it was loaded, and under
/// which dials. One line per run, beside the `bench_meta` line.
struct ExternalEncoderMeta: Encodable {
    var type = "encoder_meta"
    var engine: String
    var modelPath: String
    var modelTreeSHA256: String
    var modelTreeBytes: Int
    var modelTreeFiles: Int
    var compute: String?
    var cachePolicy: String?
    var deviceArchitecture: String?
    var availableComputeUnits: [String]?
    var specializationMs: Int?
    var loadFunctionMs: Int?
    var tailThreads: Int
    /// What the timings above do and do not contain. The two engines measure different seams;
    /// the record states it rather than leaving a reader to assume symmetry.
    var note: String

    enum CodingKeys: String, CodingKey {
        case type
        case engine
        case modelPath = "model_path"
        case modelTreeSHA256 = "model_tree_sha256"
        case modelTreeBytes = "model_tree_bytes"
        case modelTreeFiles = "model_tree_files"
        case compute
        case cachePolicy = "cache_policy"
        case deviceArchitecture = "device_architecture"
        case availableComputeUnits = "available_compute_units"
        case specializationMs = "specialization_ms"
        case loadFunctionMs = "load_function_ms"
        case tailThreads = "tail_threads"
        case note
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(engine, forKey: .engine)
        try container.encode(modelPath, forKey: .modelPath)
        try container.encode(modelTreeSHA256, forKey: .modelTreeSHA256)
        try container.encode(modelTreeBytes, forKey: .modelTreeBytes)
        try container.encode(modelTreeFiles, forKey: .modelTreeFiles)
        // Every field is written, null included: a reader comparing two engines' lines must see
        // which numbers are absent rather than guess whether a key was forgotten.
        try container.encode(compute, forKey: .compute)
        try container.encode(cachePolicy, forKey: .cachePolicy)
        try container.encode(deviceArchitecture, forKey: .deviceArchitecture)
        try container.encode(availableComputeUnits, forKey: .availableComputeUnits)
        try container.encode(specializationMs, forKey: .specializationMs)
        try container.encode(loadFunctionMs, forKey: .loadFunctionMs)
        try container.encode(tailThreads, forKey: .tailThreads)
        try container.encode(note, forKey: .note)
    }
}
