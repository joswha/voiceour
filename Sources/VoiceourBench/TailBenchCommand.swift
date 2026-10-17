import ASRSidecarCore
import Foundation
import VoiceCore

/// B1 paired harness: the TDT decode tail on identical encoder states, in one process. Arms are the
/// production ggml tail on Metal, its A/A replicate, the opt-in CPU tail, and Rust `vt_` arms.
///
/// For each pass and dump row, the harness loads the row's encoder states: the dump's `enc`, or
/// the same-named file under `--states-dir` when it evaluates an encoder candidate's states. It
/// then stores the dump's mel in both native contexts with `parakeet_set_mel`. That keeps the
/// external-encoder seam's frame contract without running the front end. The arms then run in
/// an order rotated by row and pass:
///
/// - A native arm makes one `parakeet_full_with_external_encoder` call over the stored mel, with
///   `transcribe`'s parameters, after `parakeet_reset_timings`.
/// - A Rust arm makes one `vt_decode` call over the same buffer.
///
/// Every arm's canonical token string is judged against the dump's `ref` (Metal tail).
struct TailBenchCommand {
    enum CppElapsed: String, CaseIterable {
        /// `t_decode_us`: the greedy step graphs alone.
        case decode
        /// `t_decode_us + t_predict_us + t_sample_us`: `stage-profile`'s tail.
        case tail
        /// Wall time of the whole external-encoder call.
        case wall
    }

    var options: RustBenchOptions
    var rustLibrary: URL?
    var statesDirectory: URL?
    var cppElapsed: CppElapsed

    static func parse(_ arguments: [String]) throws -> TailBenchCommand {
        var rustLibrary: URL?
        var statesDirectory: URL?
        var cppElapsed = CppElapsed.decode
        let options = try RustBenchOptions.parse(arguments) { parsed, index in
            switch parsed.name {
            case "--rust-tail-lib":
                rustLibrary = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--states-dir":
                statesDirectory = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--cpp-elapsed":
                let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
                guard let parsedElapsed = CppElapsed(rawValue: value) else {
                    let choices = CppElapsed.allCases.map(\.rawValue).joined(separator: ", ")
                    throw BenchError.usage("--cpp-elapsed must be one of: \(choices)")
                }
                cppElapsed = parsedElapsed
            default:
                return false
            }
            return true
        }
        if options.rustArms != nil, rustLibrary == nil {
            throw BenchError.usage("--rust-arms requires --rust-tail-lib")
        }
        return TailBenchCommand(
            options: options,
            rustLibrary: rustLibrary,
            statesDirectory: statesDirectory,
            cppElapsed: cppElapsed
        )
    }

    func run() throws {
        let dump = try RustBenchDump.load(options.dumps, limit: options.limit)
        if let statesDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: statesDirectory.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw BenchError.io("--states-dir is not a directory: \(statesDirectory.path)")
            }
        }
        let cache = try RustBench.pinnedModelCache()
        let library = try rustLibrary.map { try RustArmLibrary(url: $0, abi: .tail) }
        let rustArms = try library?.select(options.rustArms) ?? []
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let host = BenchHost.snapshot()

        // The sidecar's own construction: pinned artifact, its weight arena, Metal tail, 6 threads.
        let metal = try ParakeetContext(modelPath: cache.modelURL.path, weightArenaPath: cache.weightArenaURL.path)
        // `VOICEOUR_TAIL_BACKEND=cpu` with `VOICEOUR_CPU_POOL=persistent`. No weight arena: the
        // sidecar's `.tail-cpu` arena would be created inside the app's model cache, and an arena
        // only places weights, so the tail's arithmetic is the same.
        let cpu = try ParakeetContext(
            modelPath: cache.modelURL.path,
            weightArenaPath: nil,
            tailBackendCPU: true,
            persistentCPUPool: true
        )
        var engineInitUs: [String: Double] = [:]
        var engines: [RustTailEngine] = []
        if let library {
            for arm in rustArms {
                let start = BenchClock.mark()
                engines.append(try RustTailEngine(library: library, arm: arm, modelPath: cache.modelURL.path))
                engineInitUs[arm] = RustBench.microseconds(from: start, to: BenchClock.mark())
            }
        }
        let arms: [TailArm] =
            [
                .native(label: "cpp-metal", context: metal),
                .native(label: "cpp-metal@aa", context: metal),
                .native(label: "cpp-cpu", context: cpu),
            ] + engines.map { .rust(label: "rust:\($0.arm)", engine: $0) }

        let writer = try JSONLWriter(url: options.output)
        try writer.write(
            RustBenchRunMeta(
                bet: "B1",
                harness: "voiceour-bench tail-bench",
                startedAt: startedAt,
                host: host,
                arms: arms.map(\.label),
                passes: options.passes,
                corpus: dump.corpus,
                notes: Self.notes(cppElapsed),
                dump: dump.provenance,
                model: cache.modelURL.path,
                weightArena: cache.weightArenaURL.path,
                threads: Int(metal.decodeThreadCount),
                libraries: library.map {
                    [RustBenchLibraryInfo($0, selected: rustArms, engineInitUs: engineInitUs)]
                } ?? [],
                provenance: try RustBenchProvenance.capture(),
                config: TailBenchConfig(
                    cppElapsed: cppElapsed.rawValue,
                    statesDirectory: statesDirectory?.path,
                    cpuTailThreads: Int(cpu.decodeThreadCount),
                    cpuTailPersistentPool: true
                )
            )
        )

        var seq = 0
        var summary = RustBenchSummary(arms: arms.map(\.label))
        // Per row, the digest of the states every arm decoded: the dump's verified enc_sha256, or
        // the --states-dir file's own digest, both taken in the warmup pass.
        var statesSHA256: [String] = []
        for pass in 0...options.passes {
            for (rowIndex, row) in dump.rows.enumerated() {
                // Digests are checked once, in the warmup pass.
                let validate = pass == 0
                let mel = try dump.mel(row, validate: validate)
                let states =
                    try statesDirectory.map {
                        try RustBench.readFloats(
                            $0.appendingPathComponent(row.encFile),
                            count: row.encoderFrameCount * row.stateWidth,
                            expectedSHA256: nil
                        )
                    } ?? dump.enc(row, validate: validate)
                if pass == 0 {
                    statesSHA256.append(
                        statesDirectory == nil ? row.encSHA256 : states.withUnsafeBufferPointer { RustBench.hex($0) }
                    )
                }
                try mel.withUnsafeBufferPointer { buffer in
                    try metal.setStoredMel(buffer, frameCount: row.melFrameCount)
                    try cpu.setStoredMel(buffer, frameCount: row.melFrameCount)
                }
                let maxTokens = row.encoderFrameCount * RustBench.maxTokensPerFrame + 1
                let tokenBuffer = UnsafeMutableRawPointer.allocate(
                    byteCount: maxTokens * RustTailToken.stride,
                    alignment: MemoryLayout<Int32>.alignment
                )
                defer { tokenBuffer.deallocate() }

                for arm in RustBench.ordered(arms, pass: pass, row: rowIndex) {
                    let outcome = try states.withUnsafeBufferPointer { buffer in
                        switch arm {
                        case .native(_, let context):
                            return try measure(context, states: buffer, row: row)
                        case .rust(_, let engine):
                            return measure(
                                engine,
                                states: buffer,
                                row: row,
                                tokens: tokenBuffer,
                                maxTokens: maxTokens
                            )
                        }
                    }
                    let comparison = outcome.tokens.map { RustBenchTokenComparison($0, reference: row.ref) }
                    var work = outcome.work
                    work.tokenCount = outcome.tokens?.count
                    work.equalRefCPU = comparison.map { $0.tokensSHA256 == row.refCPU.tokensSHA256 }
                    work.identicalRef = comparison?.identicalRef
                    work.firstDifference = comparison?.firstDifference
                    work.pMaxAbs = comparison?.pMaxAbs
                    work.statesSHA256 = statesSHA256[rowIndex]
                    try writer.write(
                        RustBenchTimingRow(
                            bet: "B1",
                            arm: arm.label,
                            rowID: row.id,
                            pass: pass,
                            seq: seq,
                            elapsedUs: outcome.elapsedUs,
                            outputSHA256: comparison?.tokensSHA256,
                            equalRef: comparison?.equalRef ?? false,
                            audioS: row.audioS,
                            work: work,
                            err: comparison?.plogErr
                        )
                    )
                    summary.record(
                        arm: arm.label,
                        pass: pass,
                        elapsedUs: outcome.elapsedUs,
                        equalRef: comparison?.equalRef ?? false
                    )
                    seq += 1
                }
            }
            print("tail-bench pass \(pass) done: \(dump.rows.count) rows")
        }
        try summary.finish(
            to: writer,
            bet: "B1",
            output: options.output,
            expectedTimingRows: dump.rows.count * arms.count * (options.passes + 1),
            writtenTimingRows: seq
        )
    }

    /// One native external-encoder tail over the stored mel.
    private func measure(
        _ context: ParakeetContext,
        states: UnsafeBufferPointer<Float>,
        row: RustBenchDumpRow
    ) throws -> TailOutcome {
        context.resetStageTimings()
        let start = BenchClock.mark()
        try context.decodeExternalStatesOverStoredMel(states, frameCount: row.encoderFrameCount)
        let end = BenchClock.mark()
        guard let timings = context.stageTimings() else {
            throw BenchError.io("\(row.id): native stage timings are unavailable")
        }
        let wallUs = RustBench.microseconds(from: start, to: end)
        let elapsedUs: Double
        switch cppElapsed {
        case .decode:
            elapsedUs = Double(timings.decodeMicroseconds)
        case .tail:
            elapsedUs = Double(timings.decodeMicroseconds + timings.predictMicroseconds + timings.sampleMicroseconds)
        case .wall:
            elapsedUs = wallUs
        }
        var work = TailWork(wallUs: wallUs, encoderFrames: row.encoderFrameCount)
        work.native = timings
        return TailOutcome(
            elapsedUs: elapsedUs,
            tokens: context.decodedNativeTokens().flatMap { $0 }.map(RustBenchToken.init),
            work: work
        )
    }

    /// One `vt_decode` call; a failed call keeps its wall time in `work` but has no `elapsed_us`.
    private func measure(
        _ engine: RustTailEngine,
        states: UnsafeBufferPointer<Float>,
        row: RustBenchDumpRow,
        tokens: UnsafeMutableRawPointer,
        maxTokens: Int
    ) -> TailOutcome {
        guard let base = states.baseAddress else {
            return TailOutcome(failure: "no encoder states", work: TailWork(wallUs: 0, encoderFrames: 0))
        }
        engine.error.clear()
        let start = BenchClock.mark()
        let count = engine.decode(
            states: base,
            frameCount: Int32(row.encoderFrameCount),
            stateWidth: Int32(row.stateWidth),
            tokens: tokens,
            maxTokens: Int32(maxTokens)
        )
        let end = BenchClock.mark()
        let work = TailWork(wallUs: RustBench.microseconds(from: start, to: end), encoderFrames: row.encoderFrameCount)
        guard count >= 0 else {
            return TailOutcome(failure: engine.error.message(fallback: "vt_decode returned \(count)"), work: work)
        }
        guard count <= maxTokens else {
            return TailOutcome(
                failure: "vt_decode returned \(count) tokens for a \(maxTokens)-token buffer", work: work)
        }
        return TailOutcome(
            elapsedUs: work.wallUs,
            tokens: RustTailEngine.tokens(in: tokens, count: Int(count)).map(RustBenchToken.init),
            work: work
        )
    }

    private static func notes(_ cppElapsed: CppElapsed) -> String {
        let nativeElapsed =
            switch cppElapsed {
            case .decode: "t_decode_us (the greedy step graphs only)"
            case .tail: "t_decode_us + t_predict_us + t_sample_us (stage-profile's tail)"
            case .wall: "the wall time of the call"
            }
        return """
            elapsed_us: cpp-* arms = \(nativeElapsed) of one parakeet_full_with_external_encoder call over the \
            stored dump mel (samples NULL) with transcribe's parameters (6 threads, cancellation callbacks), \
            counters reset before the call; rust:* arms = wall time of one vt_decode call over the same states \
            buffer. work.wall_us = wall time of the arm's call (native: enc upload into enc_out, the greedy TDT \
            loop, result construction); work.t_*_us/n_* = native stage counters of that call. cpp-metal = the \
            sidecar's context (pinned model, weight arena, Metal tail); cpp-metal@aa = the same context; \
            cpp-cpu = tail_backend_cpu with a persistent 6-thread CPU pool and no weight arena. Before each \
            row's arms, both contexts store the dump mel via parakeet_set_mel; states come from the dump enc \
            (or --states-dir), digest in work.states_sha256. output_sha256 = sha256 of the canonical token \
            string; equal_ref = that digest equals the dump's ref (Metal tail); work.equal_ref_cpu against \
            ref_cpu; work.identical_ref = every token field equal, p/plog bitwise; err = plog error against ref \
            when the canonical sequences agree. \
            A failed rust call has elapsed_us null and work.error, and the command exits nonzero. This is an \
            isolated-stage measurement: no correction for GPU or cache state a neighbouring arm left behind is \
            applied; the combined-bench command (B7) is the end-to-end measurement.
            """
    }
}

private enum TailArm {
    case native(label: String, context: ParakeetContext)
    case rust(label: String, engine: RustTailEngine)

    var label: String {
        switch self {
        case .native(let label, _), .rust(let label, _): label
        }
    }
}

private struct TailOutcome {
    var elapsedUs: Double?
    var tokens: [RustBenchToken]?
    var work: TailWork

    init(elapsedUs: Double, tokens: [RustBenchToken], work: TailWork) {
        self.elapsedUs = elapsedUs
        self.tokens = tokens
        self.work = work
    }

    init(failure: String, work: TailWork) {
        var work = work
        work.error = failure
        self.work = work
    }
}

private struct TailWork: Encodable {
    var wallUs: Double
    var encoderFrames: Int
    var tokenCount: Int?
    var equalRefCPU: Bool?
    var identicalRef: Bool?
    var firstDifference: Int?
    var pMaxAbs: Double?
    var native: ParakeetStageTimings?
    var statesSHA256: String?
    var error: String?

    init(wallUs: Double, encoderFrames: Int) {
        self.wallUs = wallUs
        self.encoderFrames = encoderFrames
    }

    enum CodingKeys: String, CodingKey {
        case wallUs = "wall_us"
        case encoderFrames = "n_enc_frames"
        case statesSHA256 = "states_sha256"
        case tokenCount = "n_tokens"
        case equalRefCPU = "equal_ref_cpu"
        case identicalRef = "identical_ref"
        case firstDifference = "first_diff"
        case pMaxAbs = "p_max_abs"
        case decodeUs = "t_decode_us"
        case predictUs = "t_predict_us"
        case sampleUs = "t_sample_us"
        case decodeCount = "n_decode"
        case predictCount = "n_predict"
        case sampleCount = "n_sample"
        case error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallUs, forKey: .wallUs)
        try container.encode(encoderFrames, forKey: .encoderFrames)
        try container.encode(statesSHA256, forKey: .statesSHA256)
        try container.encode(tokenCount, forKey: .tokenCount)
        try container.encode(equalRefCPU, forKey: .equalRefCPU)
        try container.encode(identicalRef, forKey: .identicalRef)
        try container.encode(firstDifference, forKey: .firstDifference)
        try container.encode(pMaxAbs, forKey: .pMaxAbs)
        try container.encode(native?.decodeMicroseconds, forKey: .decodeUs)
        try container.encode(native?.predictMicroseconds, forKey: .predictUs)
        try container.encode(native?.sampleMicroseconds, forKey: .sampleUs)
        try container.encode(native?.decodeCount, forKey: .decodeCount)
        try container.encode(native?.predictCount, forKey: .predictCount)
        try container.encode(native?.sampleCount, forKey: .sampleCount)
        try container.encode(error, forKey: .error)
    }
}

private struct TailBenchConfig: Encodable {
    var cppElapsed: String
    var statesDirectory: String?
    var cpuTailThreads: Int
    var cpuTailPersistentPool: Bool

    enum CodingKeys: String, CodingKey {
        case cppElapsed = "cpp_elapsed"
        case statesDirectory = "states_dir"
        case cpuTailThreads = "cpu_tail_threads"
        case cpuTailPersistentPool = "cpu_tail_persistent_pool"
        case cpuTailWeightArena = "cpu_tail_weight_arena"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cppElapsed, forKey: .cppElapsed)
        try container.encode(statesDirectory, forKey: .statesDirectory)
        try container.encode(cpuTailThreads, forKey: .cpuTailThreads)
        try container.encode(cpuTailPersistentPool, forKey: .cpuTailPersistentPool)
        try container.encodeNil(forKey: .cpuTailWeightArena)
    }
}
