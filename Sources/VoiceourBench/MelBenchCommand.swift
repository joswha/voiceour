import ASRSidecarCore
import Foundation
import VoiceCore

/// B2 paired harness: the mel front end on identical samples, in one process. Arms are
/// parakeet.cpp's `parakeet_pcm_to_mel` at the production thread count, its A/A replicate, and
/// Rust `vm_` arms.
///
/// For each pass and dump row, the harness decodes the row's WAV with the sidecar's loader
/// (`WAVFile`), after checking the file against the dump's audio digest. It then computes an
/// untimed native reference mel. The arms run in an order rotated by row and pass, and each
/// output is judged against that reference: bitwise identity and the contract's error.
///
/// With `--transcripts`, each distinct mel an arm produced is stored with `parakeet_set_mel` and
/// decoded by the production encoder and Metal tail (`parakeet_full` with no samples). Its
/// tokens are then judged against the dump's `ref`.
struct MelBenchCommand {
    var options: RustBenchOptions
    var rustLibrary: URL?
    var transcripts: Bool

    static func parse(_ arguments: [String]) throws -> MelBenchCommand {
        var rustLibrary: URL?
        var transcripts = false
        let options = try RustBenchOptions.parse(arguments) { parsed, index in
            switch parsed.name {
            case "--rust-mel-lib":
                rustLibrary = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--transcripts":
                guard parsed.inlineValue == nil else {
                    throw BenchError.usage("--transcripts takes no value")
                }
                transcripts = true
            default:
                return false
            }
            return true
        }
        if options.rustArms != nil, rustLibrary == nil {
            throw BenchError.usage("--rust-arms requires --rust-mel-lib")
        }
        return MelBenchCommand(options: options, rustLibrary: rustLibrary, transcripts: transcripts)
    }

    func run() throws {
        let dump = try RustBenchDump.load(options.dumps, limit: options.limit)
        if transcripts {
            try dump.requirePublicText()
        }
        let cache = try RustBench.pinnedModelCache()
        let library = try rustLibrary.map { try RustArmLibrary(url: $0, abi: .mel) }
        let rustArms = try library?.select(options.rustArms) ?? []
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let host = BenchHost.snapshot()

        // The sidecar's own construction; its front end is the measured native arm, and its encoder
        // and Metal tail decode `--transcripts`.
        let context = try ParakeetContext(modelPath: cache.modelURL.path, weightArenaPath: cache.weightArenaURL.path)
        var engineInitUs: [String: Double] = [:]
        var engines: [RustMelEngine] = []
        if let library {
            for arm in rustArms {
                let start = BenchClock.mark()
                engines.append(try RustMelEngine(library: library, arm: arm, modelPath: cache.modelURL.path))
                engineInitUs[arm] = RustBench.microseconds(from: start, to: BenchClock.mark())
            }
        }
        let arms: [MelArm] =
            [.native(label: "cpp"), .native(label: "cpp@aa")]
            + engines.map { .rust(label: "rust:\($0.arm)", engine: $0) }

        let writer = try JSONLWriter(url: options.output)
        try writer.write(
            RustBenchRunMeta(
                bet: "B2",
                harness: "voiceour-bench mel-bench",
                startedAt: startedAt,
                host: host,
                arms: arms.map(\.label),
                passes: options.passes,
                corpus: dump.corpus,
                notes: Self.notes,
                dump: dump.provenance,
                model: cache.modelURL.path,
                weightArena: cache.weightArenaURL.path,
                threads: Int(context.decodeThreadCount),
                libraries: library.map {
                    [RustBenchLibraryInfo($0, selected: rustArms, engineInitUs: engineInitUs)]
                } ?? [],
                provenance: try RustBenchProvenance.capture(),
                config: MelBenchConfig(transcripts: transcripts)
            )
        )

        let melBins = ParakeetContext.NativeMel.melBins
        var transcriptCache: [String: RustBenchTranscript] = [:]
        var seq = 0
        var summary = RustBenchSummary(arms: arms.map(\.label))
        for pass in 0...options.passes {
            for (rowIndex, row) in dump.rows.enumerated() {
                let audioURL = BenchCLI.fileURL(row.audioPath)
                if pass == 0 {
                    let digest = try BenchRunner.sha256(of: audioURL)
                    guard digest == row.audioSHA256 else {
                        throw BenchError.io(
                            "\(row.id): \(audioURL.path) sha256 \(digest) is not the dump's \(row.audioSHA256)"
                        )
                    }
                }
                let samples = try WAVFile.readSamples(at: audioURL)
                guard samples.count == row.sampleCount else {
                    throw BenchError.io("\(row.id): decoded \(samples.count) samples, the dump has \(row.sampleCount)")
                }
                try samples.withUnsafeBufferPointer { _ = try context.computeMel(samples: $0) }
                guard let reference = context.storedMel(), reference.frameCount == row.melFrameCount else {
                    throw BenchError.io("\(row.id): the reference mel does not have \(row.melFrameCount) frames")
                }
                let referenceSHA256 = reference.values.withUnsafeBufferPointer { RustBench.hex($0) }
                let maxFrames = row.melFrameCount + RustBench.frameSlack
                let output = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * melBins)
                output.initialize(repeating: .nan, count: maxFrames * melBins)
                defer { output.deallocate() }

                for arm in RustBench.ordered(arms, pass: pass, row: rowIndex) {
                    var outcome = try samples.withUnsafeBufferPointer { buffer in
                        switch arm {
                        case .native:
                            return try measure(context, samples: buffer)
                        case .rust(_, let engine):
                            return measure(engine, samples: buffer, output: output, maxFrames: maxFrames)
                        }
                    }
                    var comparison: RustBenchComparison?
                    var outputSHA256: String?
                    if let mel = outcome.mel {
                        outputSHA256 = mel.withUnsafeBufferPointer { RustBench.hex($0) }
                        if mel.count == reference.values.count {
                            comparison = mel.withUnsafeBufferPointer { candidate in
                                reference.values.withUnsafeBufferPointer {
                                    RustBenchComparison(candidate, reference: $0)
                                }
                            }
                        } else {
                            outcome.work.error = "\(mel.count / melBins) frames, expected \(row.melFrameCount)"
                            outcome.elapsedUs = nil
                        }
                    }
                    if let comparison, comparison.nonFinite > 0 {
                        outcome.work.error = "\(comparison.nonFinite) non-finite mel values"
                        outcome.elapsedUs = nil
                    }
                    outcome.work.nonFinite = comparison?.nonFinite
                    outcome.work.referenceEqualDump = referenceSHA256 == row.melSHA256
                    if transcripts, outcome.work.error == nil, let mel = outcome.mel, let outputSHA256 {
                        if let cached = transcriptCache["\(row.id)|\(outputSHA256)"] {
                            outcome.work.transcript = cached
                        } else {
                            let transcript = try mel.withUnsafeBufferPointer { buffer in
                                try context.setStoredMel(buffer, frameCount: row.melFrameCount)
                                try context.decodeStoredMel()
                                return RustBenchTranscript(collectingFrom: context, reference: row.ref)
                            }
                            transcriptCache["\(row.id)|\(outputSHA256)"] = transcript
                            outcome.work.transcript = transcript
                        }
                    }
                    let equalRef = comparison?.identical ?? false
                    try writer.write(
                        RustBenchTimingRow(
                            bet: "B2",
                            arm: arm.label,
                            rowID: row.id,
                            pass: pass,
                            seq: seq,
                            elapsedUs: outcome.elapsedUs,
                            outputSHA256: outputSHA256,
                            equalRef: equalRef,
                            audioS: row.audioS,
                            work: outcome.work,
                            err: comparison?.err
                        )
                    )
                    summary.record(arm: arm.label, pass: pass, elapsedUs: outcome.elapsedUs, equalRef: equalRef)
                    seq += 1
                }
            }
            print("mel-bench pass \(pass) done: \(dump.rows.count) rows")
        }
        try summary.finish(
            to: writer,
            bet: "B2",
            output: options.output,
            expectedTimingRows: dump.rows.count * arms.count * (options.passes + 1),
            writtenTimingRows: seq
        )
    }

    /// One native front-end run; the mel is copied out after the clock stops.
    private func measure(_ context: ParakeetContext, samples: UnsafeBufferPointer<Float>) throws -> MelOutcome {
        context.resetStageTimings()
        let start = BenchClock.mark()
        try context.computeMel(samples: samples)
        let end = BenchClock.mark()
        let timings = context.stageTimings()
        guard let mel = context.storedMel() else {
            throw BenchError.io("parakeet_pcm_to_mel stored no mel")
        }
        var work = MelWork(wallUs: RustBench.microseconds(from: start, to: end), sampleCount: samples.count)
        work.frameCount = mel.frameCount
        work.melUs = timings?.melMicroseconds
        work.threads = Int(context.decodeThreadCount)
        return MelOutcome(elapsedUs: work.wallUs, mel: mel.values, work: work)
    }

    /// One `vm_compute` call into a NaN-filled buffer, so values an arm claims but never writes
    /// surface as non-finite.
    private func measure(
        _ engine: RustMelEngine,
        samples: UnsafeBufferPointer<Float>,
        output: UnsafeMutablePointer<Float>,
        maxFrames: Int
    ) -> MelOutcome {
        let melBins = ParakeetContext.NativeMel.melBins
        guard let base = samples.baseAddress else {
            return MelOutcome(failure: "no samples", work: MelWork(wallUs: 0, sampleCount: 0))
        }
        output.update(repeating: .nan, count: maxFrames * melBins)
        engine.error.clear()
        let start = BenchClock.mark()
        let frames = engine.compute(
            samples: base,
            sampleCount: Int32(samples.count),
            output: output,
            maxFrames: Int32(maxFrames),
            melBins: Int32(melBins)
        )
        let end = BenchClock.mark()
        var work = MelWork(wallUs: RustBench.microseconds(from: start, to: end), sampleCount: samples.count)
        guard frames >= 0 else {
            return MelOutcome(failure: engine.error.message(fallback: "vm_compute returned \(frames)"), work: work)
        }
        guard frames <= maxFrames else {
            return MelOutcome(
                failure: "vm_compute returned \(frames) frames for a \(maxFrames)-frame buffer", work: work)
        }
        work.frameCount = Int(frames)
        return MelOutcome(
            elapsedUs: work.wallUs,
            mel: Array(UnsafeBufferPointer(start: output, count: Int(frames) * melBins)),
            work: work
        )
    }

    private static let notes = """
        elapsed_us: cpp arms = wall time of one parakeet_pcm_to_mel call on the sidecar's context at its \
        6-thread production count (work.t_mel_us = the native counter for that call); rust:* arms = wall time \
        of one vm_compute call over the same samples. Samples: WAVFile.readSamples, the sidecar's loader, \
        after the warmup pass checks the file against the dump's audio_sha256. Reference: an untimed \
        parakeet_pcm_to_mel of the same samples just before the row's arms; equal_ref = the arm's mel is \
        bitwise identical to it; err = max_abs / rel_l2 against it (null for a frame-count mismatch or \
        non-finite values); work.ref_equal_dump = the reference's digest equals the dump's mel_sha256. \
        output_sha256 = sha256 of the mel's little-endian F32 bytes [frames][128]. With --transcripts: each \
        distinct mel per row is stored with parakeet_set_mel and decoded with parakeet_full (samples NULL; \
        production encoder and Metal tail); work.tokens_equal_ref / text_equal_ref judge that decode against \
        the dump's ref; work.transcript is that decode's raw transcript text (public corpora only). A failed \
        call, an output with the wrong frame count, or one with non-finite values has elapsed_us null and \
        work.error, and the command exits nonzero.
        """
}

private enum MelArm {
    case native(label: String)
    case rust(label: String, engine: RustMelEngine)

    var label: String {
        switch self {
        case .native(let label), .rust(let label, _): label
        }
    }
}

private struct MelOutcome {
    var elapsedUs: Double?
    var mel: [Float]?
    var work: MelWork

    init(elapsedUs: Double, mel: [Float], work: MelWork) {
        self.elapsedUs = elapsedUs
        self.mel = mel
        self.work = work
    }

    init(failure: String, work: MelWork) {
        var work = work
        work.error = failure
        self.work = work
    }
}

private struct MelWork: Encodable {
    var wallUs: Double
    var sampleCount: Int
    var frameCount: Int?
    var melUs: Int64?
    var threads: Int?
    var nonFinite: Int?
    var referenceEqualDump = false
    var transcript: RustBenchTranscript?
    var error: String?

    init(wallUs: Double, sampleCount: Int) {
        self.wallUs = wallUs
        self.sampleCount = sampleCount
    }

    enum CodingKeys: String, CodingKey {
        case wallUs = "wall_us"
        case sampleCount = "n_samples"
        case frameCount = "n_frames"
        case melUs = "t_mel_us"
        case threads
        case nonFinite = "non_finite"
        case referenceEqualDump = "ref_equal_dump"
        case tokensEqualRef = "tokens_equal_ref"
        case textEqualRef = "text_equal_ref"
        case tokensSHA256 = "tokens_sha256"
        case textSHA256 = "text_sha256"
        case transcriptText = "transcript"
        case tokenCount = "n_tokens"
        case error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallUs, forKey: .wallUs)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(frameCount, forKey: .frameCount)
        try container.encode(melUs, forKey: .melUs)
        try container.encode(threads, forKey: .threads)
        try container.encode(nonFinite, forKey: .nonFinite)
        try container.encode(referenceEqualDump, forKey: .referenceEqualDump)
        try container.encode(transcript?.tokensEqualRef, forKey: .tokensEqualRef)
        try container.encode(transcript?.textEqualRef, forKey: .textEqualRef)
        try container.encode(transcript?.tokensSHA256, forKey: .tokensSHA256)
        try container.encode(transcript?.textSHA256, forKey: .textSHA256)
        try container.encode(transcript?.text, forKey: .transcriptText)
        try container.encode(transcript?.tokenCount, forKey: .tokenCount)
        try container.encode(error, forKey: .error)
    }
}

private struct MelBenchConfig: Encodable {
    var transcripts: Bool
}
