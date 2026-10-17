import ASRSidecarCore
import Foundation
import VoiceCore

/// B4 paired harness: the encoder on identical mel, in one process. Arms are ggml on Metal (the
/// production encoder), its A/A replicate, and Rust `ve_` arms from one or more engine libraries.
///
/// For each pass and dump row, the harness stores the dump's mel with `parakeet_set_mel` and runs
/// one untimed production `parakeet_full` over it. That run sizes the native encoder graph to
/// this mel, which `parakeet_encode` takes from the last full decode. The arms then run in an
/// order rotated by row and pass:
///
/// - A native arm makes one `parakeet_encode` call and copies its states out.
/// - A Rust arm makes one `ve_encode` call.
///
/// Each arm's states are judged against the dump's `enc`, then decoded by the production Metal
/// tail through the external-encoder seam. The resulting tokens and transcript are judged
/// against the dump's `ref`.
struct EncoderBenchCommand {
    var options: RustBenchOptions
    var rustLibraries: [URL]

    static func parse(_ arguments: [String]) throws -> EncoderBenchCommand {
        var rustLibraries: [URL] = []
        let options = try RustBenchOptions.parse(arguments) { parsed, index in
            guard parsed.name == "--rust-encoder-lib" else { return false }
            let paths = try RustBench.list(
                try BenchCLI.value(for: parsed, in: arguments, index: &index),
                option: "--rust-encoder-lib"
            )
            rustLibraries += paths.map(BenchCLI.fileURL)
            return true
        }
        if options.rustArms != nil, rustLibraries.isEmpty {
            throw BenchError.usage("--rust-arms requires --rust-encoder-lib")
        }
        return EncoderBenchCommand(options: options, rustLibraries: rustLibraries)
    }

    /// `libencoder_<engine>.dylib` names engine `<engine>`; any other file name its stem.
    static func engineName(of url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("lib") { name.removeFirst("lib".count) }
        if name.hasPrefix("encoder_") { name.removeFirst("encoder_".count) }
        return name
    }

    func run() throws {
        let dump = try RustBenchDump.load(options.dumps, limit: options.limit)
        // Result rows carry transcript text so the decoded output can be scored.
        try dump.requirePublicText()
        let cache = try RustBench.pinnedModelCache()
        let libraries = try rustLibraries.map { url in
            (engine: Self.engineName(of: url), library: try RustArmLibrary(url: url, abi: .encoder))
        }
        let engineNames = libraries.map(\.engine)
        guard Set(engineNames).count == engineNames.count else {
            throw BenchError.usage("--rust-encoder-lib names one engine twice: \(engineNames.joined(separator: ", "))")
        }
        let selection = try Self.select(options.rustArms, from: libraries)
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let host = BenchHost.snapshot()

        // The sidecar's own construction: pinned artifact, its weight arena, Metal, 6 threads.
        let context = try ParakeetContext(modelPath: cache.modelURL.path, weightArenaPath: cache.weightArenaURL.path)
        var libraryInfo: [RustBenchLibraryInfo] = []
        var engines: [(label: String, engine: RustEncoderEngine)] = []
        for (engine, library) in libraries {
            let arms = selection[engine] ?? []
            var engineInitUs: [String: Double] = [:]
            for arm in arms {
                let start = BenchClock.mark()
                let opened = try RustEncoderEngine(library: library, arm: arm, modelPath: cache.modelURL.path)
                engineInitUs[arm] = RustBench.microseconds(from: start, to: BenchClock.mark())
                engines.append((label: "rust:\(engine):\(arm)", engine: opened))
            }
            libraryInfo.append(
                RustBenchLibraryInfo(library, engine: engine, selected: arms, engineInitUs: engineInitUs)
            )
        }
        let arms: [EncoderArm] =
            [.native(label: "ggml-metal"), .native(label: "ggml-metal@aa")]
            + engines.map { .rust(label: $0.label, engine: $0.engine) }

        let writer = try JSONLWriter(url: options.output)
        try writer.write(
            RustBenchRunMeta(
                bet: "B4",
                harness: "voiceour-bench encoder-bench",
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
                libraries: libraryInfo,
                provenance: try RustBenchProvenance.capture(),
                config: EncoderBenchConfig(tail: "metal")
            )
        )

        let stateWidth = ParakeetContext.encoderStateWidth
        var transcriptCache: [String: RustBenchTranscript] = [:]
        var primeMismatches = 0
        var seq = 0
        var summary = RustBenchSummary(arms: arms.map(\.label))
        for pass in 0...options.passes {
            for (rowIndex, row) in dump.rows.enumerated() {
                let validate = pass == 0
                let mel = try dump.mel(row, validate: validate)
                let reference = try dump.enc(row, validate: validate)
                try mel.withUnsafeBufferPointer { try context.setStoredMel($0, frameCount: row.melFrameCount) }
                try context.decodeStoredMel()
                if !RustBenchTranscript(collectingFrom: context, reference: row.ref).tokensEqualRef {
                    primeMismatches += 1
                    print("PRIME MISMATCH \(row.id) pass \(pass): parakeet_full over the dump mel missed ref")
                }
                let maxFrames = row.encoderFrameCount + RustBench.frameSlack
                let output = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * stateWidth)
                output.initialize(repeating: .nan, count: maxFrames * stateWidth)
                defer { output.deallocate() }

                for arm in RustBench.ordered(arms, pass: pass, row: rowIndex) {
                    var outcome = try mel.withUnsafeBufferPointer { buffer in
                        switch arm {
                        case .native:
                            return try measure(context, row: row)
                        case .rust(_, let engine):
                            return measure(engine, mel: buffer, row: row, output: output, maxFrames: maxFrames)
                        }
                    }
                    var comparison: RustBenchComparison?
                    var outputSHA256: String?
                    if let states = outcome.states {
                        outputSHA256 = states.withUnsafeBufferPointer { RustBench.hex($0) }
                        if states.count == reference.count {
                            comparison = states.withUnsafeBufferPointer { candidate in
                                reference.withUnsafeBufferPointer { RustBenchComparison(candidate, reference: $0) }
                            }
                        } else {
                            outcome.work.error =
                                "\(states.count / stateWidth) encoder frames, expected \(row.encoderFrameCount)"
                            outcome.elapsedUs = nil
                        }
                    }
                    if let comparison, comparison.nonFinite > 0 {
                        outcome.work.error = "\(comparison.nonFinite) non-finite encoder state values"
                        outcome.elapsedUs = nil
                    }
                    outcome.work.nonFinite = comparison?.nonFinite
                    if outcome.work.error == nil, let states = outcome.states, let outputSHA256 {
                        if let cached = transcriptCache["\(row.id)|\(outputSHA256)"] {
                            outcome.work.transcript = cached
                        } else {
                            let transcript = try states.withUnsafeBufferPointer { buffer in
                                try context.decodeExternalStatesOverStoredMel(
                                    buffer,
                                    frameCount: row.encoderFrameCount
                                )
                                return RustBenchTranscript(collectingFrom: context, reference: row.ref)
                            }
                            transcriptCache["\(row.id)|\(outputSHA256)"] = transcript
                            outcome.work.transcript = transcript
                        }
                    }
                    let equalRef = comparison?.identical ?? false
                    try writer.write(
                        RustBenchTimingRow(
                            bet: "B4",
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
            print("encoder-bench pass \(pass) done: \(dump.rows.count) rows")
        }
        try summary.finish(
            to: writer,
            bet: "B4",
            output: options.output,
            expectedTimingRows: dump.rows.count * arms.count * (options.passes + 1),
            writtenTimingRows: seq,
            extraFailures: ["prime_mismatches": primeMismatches]
        )
    }

    /// `engine:arm` selections grouped by engine, each checked against its library's arms; every
    /// advertised arm of every library when `requested` is nil.
    private static func select(
        _ requested: [String]?,
        from libraries: [(engine: String, library: RustArmLibrary)]
    ) throws -> [String: [String]] {
        guard let requested else {
            return Dictionary(uniqueKeysWithValues: libraries.map { ($0.engine, $0.library.arms) })
        }
        var grouped: [String: [String]] = [:]
        for item in requested {
            guard let colon = item.firstIndex(of: ":") else {
                throw BenchError.usage("--rust-arms takes engine:arm entries for encoder-bench, got '\(item)'")
            }
            grouped[String(item[..<colon]), default: []].append(String(item[item.index(after: colon)...]))
        }
        for (engine, arms) in grouped {
            guard let library = libraries.first(where: { $0.engine == engine })?.library else {
                let known = libraries.map(\.engine).joined(separator: ", ")
                throw BenchError.usage("--rust-arms names engine '\(engine)'; loaded engines: \(known)")
            }
            _ = try library.select(arms)
        }
        return grouped
    }

    /// One native encode over the stored mel; the states are copied out after the clock stops,
    /// and that copy is timed apart as `readback_us`.
    private func measure(_ context: ParakeetContext, row: RustBenchDumpRow) throws -> EncoderOutcome {
        context.resetStageTimings()
        let start = BenchClock.mark()
        try context.encodeStoredMel()
        let end = BenchClock.mark()
        let timings = context.stageTimings()
        let readbackStart = BenchClock.mark()
        guard let stored = context.storedEncoderStates() else {
            throw BenchError.io("\(row.id): parakeet_encode stored no encoder output")
        }
        let readbackEnd = BenchClock.mark()
        var work = EncoderWork(wallUs: RustBench.microseconds(from: start, to: end), melFrames: row.melFrameCount)
        work.encoderFrames = stored.frameCount
        work.encodeUs = timings?.encodeMicroseconds
        work.readbackUs = RustBench.microseconds(from: readbackStart, to: readbackEnd)
        return EncoderOutcome(elapsedUs: work.wallUs, states: stored.values, work: work)
    }

    /// One `ve_encode` call into a NaN-filled buffer, so values an arm claims but never writes
    /// surface as non-finite.
    private func measure(
        _ engine: RustEncoderEngine,
        mel: UnsafeBufferPointer<Float>,
        row: RustBenchDumpRow,
        output: UnsafeMutablePointer<Float>,
        maxFrames: Int
    ) -> EncoderOutcome {
        let stateWidth = ParakeetContext.encoderStateWidth
        guard let base = mel.baseAddress else {
            return EncoderOutcome(failure: "no mel", work: EncoderWork(wallUs: 0, melFrames: 0))
        }
        output.update(repeating: .nan, count: maxFrames * stateWidth)
        engine.error.clear()
        let start = BenchClock.mark()
        let frames = engine.encode(
            mel: base,
            melFrames: Int32(row.melFrameCount),
            melBins: Int32(row.melBins),
            output: output,
            maxFrames: Int32(maxFrames),
            stateWidth: Int32(stateWidth)
        )
        let end = BenchClock.mark()
        var work = EncoderWork(wallUs: RustBench.microseconds(from: start, to: end), melFrames: row.melFrameCount)
        guard frames >= 0 else {
            return EncoderOutcome(failure: engine.error.message(fallback: "ve_encode returned \(frames)"), work: work)
        }
        guard frames <= maxFrames else {
            return EncoderOutcome(
                failure: "ve_encode returned \(frames) frames for a \(maxFrames)-frame buffer",
                work: work
            )
        }
        work.encoderFrames = Int(frames)
        return EncoderOutcome(
            elapsedUs: work.wallUs,
            states: Array(UnsafeBufferPointer(start: output, count: Int(frames) * stateWidth)),
            work: work
        )
    }

    private static let notes = """
        elapsed_us: ggml-metal arms = wall time of one parakeet_encode call (the default state's \
        parakeet_encode_with_state) at 6 threads on the sidecar's context, over the dump mel stored with \
        parakeet_set_mel (work.t_encode_us = the native counter; work.readback_us = the untimed \
        parakeet_copy_encoder_states copy-out the Metal tail itself never pays); rust:<engine>:<arm> arms = \
        wall time of one ve_encode call over the same mel, including its own device transfers and copy into \
        the host buffer. Before each row's arms, one untimed parakeet_full over the stored mel (samples NULL) \
        sizes the encoder graph to it, as parakeet_encode needs; a run stops with an error if that decode \
        misses ref. equal_ref = the arm's states are bitwise identical to the dump enc; err = max_abs / rel_l2 \
        against it; output_sha256 = sha256 of the states' F32 bytes [frames][1024]. work.tokens_equal_ref / \
        text_equal_ref / tokens_sha256 / text_sha256 = the production Metal tail \
        (parakeet_full_with_external_encoder over the stored mel) on those states, against the dump's ref; \
        identical states share one tail decode per row; work.transcript is that decode's raw transcript text \
        (public benchmark corpora only, so WER can be scored). A failed call, an output with the wrong frame \
        count, or one with non-finite values has elapsed_us null and work.error, and the command exits nonzero.
        """
}

private enum EncoderArm {
    case native(label: String)
    case rust(label: String, engine: RustEncoderEngine)

    var label: String {
        switch self {
        case .native(let label), .rust(let label, _): label
        }
    }
}

private struct EncoderOutcome {
    var elapsedUs: Double?
    var states: [Float]?
    var work: EncoderWork

    init(elapsedUs: Double, states: [Float], work: EncoderWork) {
        self.elapsedUs = elapsedUs
        self.states = states
        self.work = work
    }

    init(failure: String, work: EncoderWork) {
        var work = work
        work.error = failure
        self.work = work
    }
}

private struct EncoderWork: Encodable {
    var wallUs: Double
    var melFrames: Int
    var encoderFrames: Int?
    var encodeUs: Int64?
    var readbackUs: Double?
    var nonFinite: Int?
    var transcript: RustBenchTranscript?
    var error: String?

    init(wallUs: Double, melFrames: Int) {
        self.wallUs = wallUs
        self.melFrames = melFrames
    }

    enum CodingKeys: String, CodingKey {
        case wallUs = "wall_us"
        case melFrames = "n_mel_frames"
        case encoderFrames = "n_enc_frames"
        case encodeUs = "t_encode_us"
        case readbackUs = "readback_us"
        case nonFinite = "non_finite"
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
        try container.encode(melFrames, forKey: .melFrames)
        try container.encode(encoderFrames, forKey: .encoderFrames)
        try container.encode(encodeUs, forKey: .encodeUs)
        try container.encode(readbackUs, forKey: .readbackUs)
        try container.encode(nonFinite, forKey: .nonFinite)
        try container.encode(transcript?.tokensEqualRef, forKey: .tokensEqualRef)
        try container.encode(transcript?.textEqualRef, forKey: .textEqualRef)
        try container.encode(transcript?.tokensSHA256, forKey: .tokensSHA256)
        try container.encode(transcript?.textSHA256, forKey: .textSHA256)
        try container.encode(transcript?.text, forKey: .transcriptText)
        try container.encode(transcript?.tokenCount, forKey: .tokenCount)
        try container.encode(error, forKey: .error)
    }
}

private struct EncoderBenchConfig: Encodable {
    var tail: String
}
