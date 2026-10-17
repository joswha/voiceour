import ASRSidecarCore
import Foundation
import VoiceCore

/// B7 paired harness: the complete warm ASR computation on identical raw PCM, in one process,
/// proved as one timed unit instead of a sum of stage estimates.
///
/// For each pass and dump row the harness reads the row's WAV with the sidecar's loader
/// (`WAVFile`) once, outside every timer, and hands the same `[Float]` samples to every arm. The
/// dump supplies the audio path, its digest and the reference tokens and text only; no dumped mel
/// or encoder state ever feeds a candidate. The arms then run in a Williams order rotated by row
/// and pass, and each one times raw PCM through the final cleaned text:
///
/// - `native`, `native@aa`: `ParakeetContext.transcribe` (mel, encoder, Metal tail, segment
///   collection), `TokenMapping.transcript`, `LiteralComposition.apply`, `CleanupEngine.clean`.
/// - `rust-tail`: native mel, the native encoder through `parakeet_encode_stored_mel`, a copy of
///   its states to the host, a Rust `vt_` tail, token-to-segment assembly, then the same text stage.
/// - `rust-mel`: a Rust `vm_` mel, `parakeet_set_mel`, the native `parakeet_full` over the stored
///   mel (native encoder and Metal tail), then the same assembly and text stage.
/// - `rust-mel-tail`: Rust mel, native encoder, Rust tail, assembly, text stage.
/// - `c-control`: `rust-mel-tail` with the C-backend tail arm, which isolates the language from
///   the design.
///
/// No arm is primed with an untimed decode: the native encoder prepares each row's variable shape
/// inside its own timed call, and the first pass is a discarded warmup of the whole grid.
struct CombinedBenchCommand {
    static let bet = "B7"

    var options: RustBenchOptions
    var melLibrary: URL
    var tailLibrary: URL
    var melArm: String
    var tailArm: String
    var controlArm: String
    var requestedArms: [CombinedArmKind]?

    static func parse(_ arguments: [String]) throws -> CombinedBenchCommand {
        var melLibrary: URL?
        var tailLibrary: URL?
        var melArm = "best"
        var tailArm = "best"
        var controlArm = "c-best"
        var requestedArms: [CombinedArmKind]?
        let options = try RustBenchOptions.parse(arguments) { parsed, index in
            switch parsed.name {
            case "--rust-mel-lib":
                melLibrary = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--rust-tail-lib":
                tailLibrary = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--rust-mel-arm":
                melArm = try BenchCLI.value(for: parsed, in: arguments, index: &index)
            case "--rust-tail-arm":
                tailArm = try BenchCLI.value(for: parsed, in: arguments, index: &index)
            case "--c-tail-arm":
                controlArm = try BenchCLI.value(for: parsed, in: arguments, index: &index)
            case "--arms":
                let names = try RustBench.list(
                    try BenchCLI.value(for: parsed, in: arguments, index: &index), option: "--arms")
                requestedArms = try names.map { name in
                    guard let kind = CombinedArmKind(rawValue: name) else {
                        let known = CombinedArmKind.allCases.map(\.rawValue).joined(separator: ", ")
                        throw BenchError.usage("--arms names '\(name)'; combined-bench arms: \(known)")
                    }
                    return kind
                }
            default:
                return false
            }
            return true
        }
        guard options.rustArms == nil else {
            throw BenchError.usage(
                "combined-bench selects Rust arms with --rust-mel-arm, --rust-tail-arm and --c-tail-arm, not --rust-arms"
            )
        }
        guard let melLibrary else { throw BenchError.usage("missing --rust-mel-lib") }
        guard let tailLibrary else { throw BenchError.usage("missing --rust-tail-lib") }
        if let requestedArms, !requestedArms.contains(.native) {
            throw BenchError.usage("--arms must include native: it is every other arm's same-row reference")
        }
        return CombinedBenchCommand(
            options: options,
            melLibrary: melLibrary,
            tailLibrary: tailLibrary,
            melArm: melArm,
            tailArm: tailArm,
            controlArm: controlArm,
            requestedArms: requestedArms
        )
    }

    func run() throws {
        let dump = try RustBenchDump.load(options.dumps, limit: options.limit)
        try dump.requirePublicText()
        let cache = try RustBench.pinnedModelCache()
        let kinds = requestedArms ?? CombinedArmKind.allCases
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let host = BenchHost.snapshot()

        // Everything that hashes or reads an input happens before the first timed call: the
        // running binary, the pinned model file, the worktree, every row's audio and its digest.
        let model = try CombinedModelProvenance.capture(cache: cache)
        let inputs = try CombinedInputs.verify(dump)

        let needsMel = kinds.contains { $0 == .rustMel || $0 == .rustMelTail || $0 == .cControl }
        let needsTail = kinds.contains { $0 == .rustTail || $0 == .rustMelTail }
        let needsControl = kinds.contains(.cControl)
        let melLoaded = try RustArmLibrary(url: melLibrary, abi: .mel)
        let tailLoaded = try RustArmLibrary(url: tailLibrary, abi: .tail)
        var selectedTailArms: [String] = []
        if needsTail { selectedTailArms.append(tailArm) }
        if needsControl, !selectedTailArms.contains(controlArm) { selectedTailArms.append(controlArm) }
        _ = try melLoaded.select(needsMel ? [melArm] : [])
        _ = try tailLoaded.select(selectedTailArms)

        // The sidecar's own construction: pinned artifact, its weight arena, Metal tail, 6 threads.
        let context = try ParakeetContext(modelPath: cache.modelURL.path, weightArenaPath: cache.weightArenaURL.path)
        var melInitUs: [String: Double] = [:]
        var tailInitUs: [String: Double] = [:]
        var melEngine: RustMelEngine?
        var tailEngine: RustTailEngine?
        var controlEngine: RustTailEngine?
        if needsMel {
            let start = BenchClock.mark()
            melEngine = try RustMelEngine(library: melLoaded, arm: melArm, modelPath: cache.modelURL.path)
            melInitUs[melArm] = RustBench.microseconds(from: start, to: BenchClock.mark())
        }
        if needsTail {
            let start = BenchClock.mark()
            tailEngine = try RustTailEngine(library: tailLoaded, arm: tailArm, modelPath: cache.modelURL.path)
            tailInitUs[tailArm] = RustBench.microseconds(from: start, to: BenchClock.mark())
        }
        if needsControl {
            let start = BenchClock.mark()
            controlEngine = try RustTailEngine(library: tailLoaded, arm: controlArm, modelPath: cache.modelURL.path)
            tailInitUs[controlArm] = RustBench.microseconds(from: start, to: BenchClock.mark())
        }
        let pipelines = CombinedPipelines(
            context: context,
            melEngine: melEngine,
            tailEngine: tailEngine,
            controlEngine: controlEngine,
            scratch: CombinedScratch(maxMelFrames: inputs.maxMelFrames, maxEncoderFrames: inputs.maxEncoderFrames)
        )

        let expectedRows = dump.rows.count * kinds.count * (options.passes + 1)
        let writer = try JSONLWriter(url: options.output)
        try writer.write(
            RustBenchRunMeta(
                bet: Self.bet,
                harness: "voiceour-bench combined-bench",
                startedAt: startedAt,
                host: host,
                arms: kinds.map(\.rawValue),
                passes: options.passes,
                corpus: dump.corpus,
                notes: Self.notes,
                dump: dump.provenance,
                model: cache.modelURL.path,
                weightArena: cache.weightArenaURL.path,
                threads: Int(context.decodeThreadCount),
                libraries: [
                    RustBenchLibraryInfo(
                        melLoaded,
                        selected: needsMel ? [melArm] : [],
                        engineInitUs: melInitUs
                    ),
                    RustBenchLibraryInfo(tailLoaded, selected: selectedTailArms, engineInitUs: tailInitUs),
                ],
                provenance: try RustBenchProvenance.capture(),
                config: CombinedBenchConfig(
                    melArm: needsMel ? melArm : nil,
                    tailArm: needsTail ? tailArm : nil,
                    controlArm: needsControl ? controlArm : nil,
                    expectedTimingRows: expectedRows,
                    model: model,
                    maxMelFrames: inputs.maxMelFrames,
                    maxEncoderFrames: inputs.maxEncoderFrames,
                    audioDigestsVerifiedBeforeTiming: dump.rows.count
                )
            )
        )

        var seq = 0
        var tally = CombinedTally()
        var summary = RustBenchSummary(arms: kinds.map(\.rawValue))
        do {
            for pass in 0...options.passes {
                for (rowIndex, row) in dump.rows.enumerated() {
                    let samples = try WAVFile.readSamples(at: inputs.audioURL(row))
                    guard samples.count == row.sampleCount else {
                        throw BenchError.io(
                            "\(row.id): decoded \(samples.count) samples, the dump has \(row.sampleCount)")
                    }
                    let oracleFinal = CleanupEngine.clean(LiteralComposition.apply(row.ref.text), glossary: [])

                    var measured: [CombinedMeasured] = []
                    for kind in RustBench.ordered(kinds, pass: pass, row: rowIndex) {
                        measured.append(
                            CombinedMeasured(
                                kind: kind, seq: seq, measurement: pipelines.measure(kind, samples: samples, row: row))
                        )
                        seq += 1
                    }

                    let judgements = CombinedJudge.judge(measured, row: row, oracleFinal: oracleFinal)
                    for (item, judgement) in zip(measured, judgements) {
                        try writer.write(
                            RustBenchTimingRow(
                                bet: Self.bet,
                                arm: item.kind.rawValue,
                                rowID: row.id,
                                pass: pass,
                                seq: item.seq,
                                elapsedUs: judgement.elapsedUs,
                                outputSHA256: judgement.work.finalTextSHA256,
                                equalRef: judgement.equalRef,
                                audioS: row.audioS,
                                work: judgement.work,
                                err: judgement.plogErr
                            )
                        )
                        summary.record(
                            arm: item.kind.rawValue,
                            pass: pass,
                            elapsedUs: judgement.elapsedUs,
                            equalRef: judgement.equalRef
                        )
                        tally.record(item.kind, judgement)
                        if judgement.failedCall {
                            fputs(
                                "voiceour-bench: \(row.id) pass \(pass) \(item.kind.rawValue): \(judgement.work.error ?? "failed")\n",
                                stderr
                            )
                        } else if judgement.mismatch {
                            fputs(
                                "voiceour-bench: \(row.id) pass \(pass) \(item.kind.rawValue): output differs from native/ref\n",
                                stderr)
                        }
                    }
                    tally.recordAA(judgements.compactMap(\.aa))
                }
                print("combined-bench pass \(pass) done: \(dump.rows.count) rows")
            }
        } catch {
            var counts = tally.failureCounts
            counts["failed_arm_calls"] = tally.failedCalls
            counts["aborted"] = 1
            counts = counts.filter { $0.value > 0 }
            try? writer.write(
                RustBenchRunEnd(
                    bet: Self.bet,
                    status: "aborted",
                    expectedTimingRows: expectedRows,
                    writtenTimingRows: seq,
                    failures: counts.values.reduce(0, +),
                    counts: counts,
                    informational: tally.informational,
                    error: BenchError.describe(error)
                )
            )
            throw error
        }

        print(
            "combined-bench: rows \(seq)/\(expectedRows), failed calls \(tally.failedCalls), "
                + "output mismatches \(tally.mismatches), native A/A inconsistencies \(tally.aaInconsistencies), "
                + "native A/A bitwise p/plog differences \(tally.aaBitwiseDifferences)"
        )
        for kind in kinds where tally.mismatchesByArm[kind.rawValue, default: 0] > 0 {
            print("  \(kind.rawValue): \(tally.mismatchesByArm[kind.rawValue, default: 0]) mismatching row passes")
        }
        try summary.finish(
            to: writer,
            bet: Self.bet,
            output: options.output,
            expectedTimingRows: expectedRows,
            writtenTimingRows: seq,
            extraFailures: tally.failureCounts,
            informational: tally.informational
        )
    }

    private static let notes = """
        elapsed_us: one arm's wall time from raw 16 kHz mono f32 PCM to the final cleaned text, on ONE shared \
        ParakeetContext (the sidecar's own construction: pinned model, weight arena, Metal tail, 6 threads). \
        UNTIMED: the WAV read and Int16-to-f32 conversion (WAVFile.readSamples, done once per row and pass and \
        handed to every arm as the same array), the audio digest and sample-count checks (before the first \
        pass), resetting the native stage counters, poisoning the Rust output buffers with NaN, and everything \
        after the last stage mark (hashes, token reads, the comparisons). TIMED, every arm: the stage chain below, \
        then TokenMapping.transcript, LiteralComposition.apply and CleanupEngine.clean with an empty glossary; \
        a stage mark is one monotonic clock read, taken inside the timer by every arm, so work.stages_us sums to \
        elapsed_us. native and native@aa: ParakeetContext.transcribe (parakeet_full: mel, the encoder with its \
        per-row shape preparation, the Metal tail, segment collection). rust-tail: parakeet_pcm_to_mel, \
        parakeet_encode_stored_mel (this row's graph shape prepared inside the call: no_context reset, audio \
        context, high-water-mark reservation), parakeet_copy_encoder_states into a preallocated host buffer, vt_decode \
        with the --rust-tail-arm engine, ParakeetContext.assembleSegments (token pieces from the native vocabulary \
        via parakeet_token_to_str/_text, the tail's t0/t1, punctuation collapse and word-start rule). rust-mel: vm_compute \
        with the --rust-mel-arm engine into a preallocated buffer, parakeet_set_mel (a copy into the state), \
        parakeet_full over the stored mel (native encoder and Metal tail), collectSegments. rust-mel-tail: vm_compute, \
        parakeet_set_mel, parakeet_encode_stored_mel, state copy-out, vt_decode with the Rust tail, assembleSegments. \
        c-control: rust-mel-tail with the --c-tail-arm tail, the same Rust mel and native encoder. No arm is \
        primed by an untimed decode; pass 0 is a discarded warmup of the whole grid. NOT measured: microphone \
        capture, focus, insertion, cancellation, the sidecar IPC, stage overlap or pipelining across arms. \
        Candidates never read the dump's mel or encoder states; the dump supplies audio_path, audio_sha256 and the \
        reference tokens and text. Validation per row and pass, after the last arm: tokens_equal_ref = canonical \
        token string digest equals the dump ref; text_equal_ref = the raw transcript equals the dump ref text; \
        final_equal_ref = the final text equals CleanupEngine.clean(LiteralComposition.apply(ref text)); *_equal_native \
        = the same comparisons against this row's native arm (tokens, raw text, final text, and segments_sha256 = \
        segment and word text with start/end ms); identical_native / identical_ref = every token field with p and plog \
        bitwise (informational: p and plog are floats, no identity is claimed); p_max_abs and err (plog max_abs/rel_l2 \
        against ref) quantify them. equal_ref = tokens_equal_ref and text_equal_ref and final_equal_ref. \
        output_sha256 = sha256 of the final text. work.transcript and work.final_text are real text from public \
        benchmark audio under benchmarks/data/ only. mel_equal_dump / states_equal_dump compare an arm's own mel and \
        encoder states with the dump's digests (diagnostic). A failed arm call has elapsed_us null and work.error; \
        the command exits nonzero on any failed call, any candidate output that differs from the dump ref or the \
        same-row native, any native A/A inconsistency (tokens, text, segments) or an incomplete grid, and keeps \
        the file, whose last line is run_end.
        """
}

// MARK: - Arms

enum CombinedArmKind: String, CaseIterable {
    case native
    case nativeAA = "native@aa"
    case rustTail = "rust-tail"
    case rustMel = "rust-mel"
    case rustMelTail = "rust-mel-tail"
    case cControl = "c-control"
}

private struct CombinedMeasured {
    var kind: CombinedArmKind
    var seq: Int
    var measurement: CombinedMeasurement
}

private enum CombinedFront {
    case nativeMel
    case rustMel(RustMelEngine)
}

/// What one arm's call left behind. `elapsedUs` is nil exactly when `error` is set.
private struct CombinedMeasurement {
    var elapsedUs: Double?
    var error: String?
    var stagesUs: [String: Double] = [:]
    var transcript: ASRTranscript?
    var finalText: String?
    var tokens: [RustBenchToken]?
    var melFrames: Int?
    var encoderFrames: Int?
    var melSHA256: String?
    var statesSHA256: String?
    var native: ParakeetStageTimings?

    init() {}

    init(failure: String) {
        error = failure
    }
}

/// Monotonic stage marks inside one timed region. Capacity is reserved before the first mark, and
/// names are static, so a lap allocates nothing.
private struct CombinedStageClock {
    private let start: UInt64
    private var last: UInt64
    private var laps: [(name: StaticString, us: Double)] = []

    init(reserving capacity: Int) {
        var reserved: [(name: StaticString, us: Double)] = []
        reserved.reserveCapacity(capacity)
        laps = reserved
        start = BenchClock.mark()
        last = start
    }

    mutating func lap(_ name: StaticString) {
        let now = BenchClock.mark()
        laps.append((name, RustBench.microseconds(from: last, to: now)))
        last = now
    }

    /// First mark to the last lap: the timed region.
    var elapsedUs: Double {
        RustBench.microseconds(from: start, to: last)
    }

    var stages: [String: Double] {
        Dictionary(uniqueKeysWithValues: laps.map { ("\($0.name)", $0.us) })
    }
}

/// Host buffers sized once from the verified corpus, so no arm allocates inside its timer.
private final class CombinedScratch {
    let melCapacity: Int
    let statesCapacity: Int
    let tokenCapacity: Int
    let mel: UnsafeMutablePointer<Float>
    let states: UnsafeMutablePointer<Float>
    let tokens: UnsafeMutableRawPointer

    init(maxMelFrames: Int, maxEncoderFrames: Int) {
        let melFrames = maxMelFrames + RustBench.frameSlack
        let stateFrames = maxEncoderFrames + RustBench.frameSlack
        let melValues = melFrames * ParakeetContext.NativeMel.melBins
        let stateValues = stateFrames * ParakeetContext.encoderStateWidth
        let tokenSlots = stateFrames * RustBench.maxTokensPerFrame + 1
        let melBuffer = UnsafeMutablePointer<Float>.allocate(capacity: melValues)
        melBuffer.initialize(repeating: .nan, count: melValues)
        let stateBuffer = UnsafeMutablePointer<Float>.allocate(capacity: stateValues)
        stateBuffer.initialize(repeating: .nan, count: stateValues)
        melCapacity = melFrames
        statesCapacity = stateFrames
        tokenCapacity = tokenSlots
        mel = melBuffer
        states = stateBuffer
        tokens = .allocate(
            byteCount: tokenSlots * RustTailToken.stride,
            alignment: MemoryLayout<Int32>.alignment
        )
    }

    deinit {
        mel.deallocate()
        states.deallocate()
        tokens.deallocate()
    }

    /// Poisons exactly the regions an arm is checked over, so a value it claims but never writes
    /// surfaces as a digest mismatch instead of a previous row's data.
    func poison(melFrames: Int, encoderFrames: Int) {
        mel.update(repeating: .nan, count: melFrames * ParakeetContext.NativeMel.melBins)
        states.update(repeating: .nan, count: encoderFrames * ParakeetContext.encoderStateWidth)
    }
}

// MARK: - Pipelines

private final class CombinedPipelines {
    private let context: ParakeetContext
    private let melEngine: RustMelEngine?
    private let tailEngine: RustTailEngine?
    private let controlEngine: RustTailEngine?
    private let scratch: CombinedScratch

    init(
        context: ParakeetContext,
        melEngine: RustMelEngine?,
        tailEngine: RustTailEngine?,
        controlEngine: RustTailEngine?,
        scratch: CombinedScratch
    ) {
        self.context = context
        self.melEngine = melEngine
        self.tailEngine = tailEngine
        self.controlEngine = controlEngine
        self.scratch = scratch
    }

    /// One arm over one row's samples. A thrown stage becomes a failed measurement so the declared
    /// grid still completes and the file shows every failure.
    func measure(_ kind: CombinedArmKind, samples: [Float], row: RustBenchDumpRow) -> CombinedMeasurement {
        do {
            switch kind {
            case .native, .nativeAA:
                return try measureNative(samples: samples)
            case .rustTail:
                return try measureSplit(
                    front: .nativeMel, tail: required(tailEngine, "rust-tail"), samples: samples, row: row)
            case .rustMel:
                return try measureRustMel(engine: required(melEngine, "rust-mel"), samples: samples, row: row)
            case .rustMelTail:
                return try measureSplit(
                    front: .rustMel(required(melEngine, "rust-mel-tail")),
                    tail: required(tailEngine, "rust-mel-tail"),
                    samples: samples,
                    row: row
                )
            case .cControl:
                return try measureSplit(
                    front: .rustMel(required(melEngine, "c-control")),
                    tail: required(controlEngine, "c-control"),
                    samples: samples,
                    row: row
                )
            }
        } catch {
            return CombinedMeasurement(failure: BenchError.describe(error))
        }
    }

    private func required<Engine>(_ engine: Engine?, _ arm: String) throws -> Engine {
        guard let engine else { throw BenchError.io("\(arm): its engine was not opened") }
        return engine
    }

    private func measureNative(samples: [Float]) throws -> CombinedMeasurement {
        context.resetStageTimings()
        var clock = CombinedStageClock(reserving: 4)
        let segments = try context.transcribe(samples: samples, isCancelled: { false })
        clock.lap("transcribe")
        let transcript = TokenMapping.transcript(from: segments)
        clock.lap("transcript")
        let finalText = CleanupEngine.clean(LiteralComposition.apply(transcript.text), glossary: [])
        clock.lap("text")

        var measurement = CombinedMeasurement()
        measurement.elapsedUs = clock.elapsedUs
        measurement.stagesUs = clock.stages
        measurement.transcript = transcript
        measurement.finalText = finalText
        measurement.native = context.stageTimings()
        measurement.tokens = context.decodedNativeTokens().flatMap { $0 }.map(RustBenchToken.init)
        measurement.melFrames = context.storedMelFrameCount
        measurement.encoderFrames = context.storedEncoderFrameCount
        return measurement
    }

    /// Front end, native encoder through `parakeet_encode_stored_mel`, state copy-out, a Rust tail.
    private func measureSplit(
        front: CombinedFront,
        tail: RustTailEngine,
        samples: [Float],
        row: RustBenchDumpRow
    ) throws -> CombinedMeasurement {
        let melBins = ParakeetContext.NativeMel.melBins
        let stateWidth = ParakeetContext.encoderStateWidth
        context.resetStageTimings()
        scratch.poison(melFrames: row.melFrameCount, encoderFrames: row.encoderFrameCount)
        let statesBuffer = UnsafeMutableBufferPointer(start: scratch.states, count: scratch.statesCapacity * stateWidth)

        var clock = CombinedStageClock(reserving: 8)
        let melFrames: Int
        var rustMel = false
        switch front {
        case .nativeMel:
            melFrames = try samples.withUnsafeBufferPointer { try context.computeMel(samples: $0) }
            clock.lap("mel")
        case .rustMel(let engine):
            rustMel = true
            melFrames = try computeRustMel(engine, samples: samples, row: row)
            clock.lap("rust_mel")
            try context.setStoredMel(
                UnsafeBufferPointer(start: scratch.mel, count: melFrames * melBins),
                frameCount: melFrames
            )
            clock.lap("set_mel")
        }
        guard melFrames == row.melFrameCount else {
            throw BenchError.io(
                "\(row.id): the front end made \(melFrames) mel frames, the dump has \(row.melFrameCount)")
        }
        try context.encodeStoredMelPreparingShape()
        clock.lap("encode")
        let encoderFrames = try context.copyEncoderStates(into: statesBuffer)
        clock.lap("readback")
        guard encoderFrames == row.encoderFrameCount else {
            throw BenchError.io(
                "\(row.id): the encoder made \(encoderFrames) frames, the dump has \(row.encoderFrameCount)")
        }
        let maxTokens = encoderFrames * RustBench.maxTokensPerFrame + 1
        tail.error.clear()
        let tokenCount = tail.decode(
            states: scratch.states,
            frameCount: Int32(encoderFrames),
            stateWidth: Int32(stateWidth),
            tokens: scratch.tokens,
            maxTokens: Int32(maxTokens)
        )
        guard tokenCount >= 0 else {
            throw BenchError.io("vt_decode (\(tail.arm)): \(tail.error.message(fallback: "returned \(tokenCount)"))")
        }
        guard Int(tokenCount) <= maxTokens else {
            throw BenchError.io("vt_decode (\(tail.arm)) returned \(tokenCount) tokens for a \(maxTokens)-token buffer")
        }
        clock.lap("tail")
        let emitted = RustTailEngine.tokens(in: scratch.tokens, count: Int(tokenCount))
        let segments = try context.assembleSegments(
            from: emitted.map {
                ParakeetTailToken(id: $0.id, frameIndex: $0.frameIndex, duration: $0.duration, probability: $0.p)
            }
        )
        clock.lap("segments")
        let transcript = TokenMapping.transcript(from: segments)
        clock.lap("transcript")
        let finalText = CleanupEngine.clean(LiteralComposition.apply(transcript.text), glossary: [])
        clock.lap("text")

        var measurement = CombinedMeasurement()
        measurement.elapsedUs = clock.elapsedUs
        measurement.stagesUs = clock.stages
        measurement.transcript = transcript
        measurement.finalText = finalText
        measurement.tokens = emitted.map(RustBenchToken.init)
        measurement.melFrames = melFrames
        measurement.encoderFrames = encoderFrames
        measurement.native = context.stageTimings()
        measurement.statesSHA256 = RustBench.hex(
            UnsafeBufferPointer<Float>(start: scratch.states, count: encoderFrames * stateWidth)
        )
        if rustMel {
            measurement.melSHA256 = RustBench.hex(
                UnsafeBufferPointer<Float>(start: scratch.mel, count: melFrames * melBins)
            )
        }
        return measurement
    }

    /// Rust mel, then the normal native path over a stored mel: `parakeet_full` with no samples.
    private func measureRustMel(
        engine: RustMelEngine,
        samples: [Float],
        row: RustBenchDumpRow
    ) throws -> CombinedMeasurement {
        let melBins = ParakeetContext.NativeMel.melBins
        context.resetStageTimings()
        scratch.poison(melFrames: row.melFrameCount, encoderFrames: 0)

        var clock = CombinedStageClock(reserving: 8)
        let melFrames = try computeRustMel(engine, samples: samples, row: row)
        clock.lap("rust_mel")
        try context.setStoredMel(
            UnsafeBufferPointer(start: scratch.mel, count: melFrames * melBins),
            frameCount: melFrames
        )
        clock.lap("set_mel")
        try context.decodeStoredMel()
        clock.lap("native_full")
        let segments = context.collectDecodedSegments()
        clock.lap("segments")
        let transcript = TokenMapping.transcript(from: segments)
        clock.lap("transcript")
        let finalText = CleanupEngine.clean(LiteralComposition.apply(transcript.text), glossary: [])
        clock.lap("text")

        var measurement = CombinedMeasurement()
        measurement.elapsedUs = clock.elapsedUs
        measurement.stagesUs = clock.stages
        measurement.transcript = transcript
        measurement.finalText = finalText
        measurement.native = context.stageTimings()
        measurement.tokens = context.decodedNativeTokens().flatMap { $0 }.map(RustBenchToken.init)
        measurement.melFrames = melFrames
        measurement.encoderFrames = context.storedEncoderFrameCount
        measurement.melSHA256 = RustBench.hex(
            UnsafeBufferPointer<Float>(start: scratch.mel, count: melFrames * melBins))
        return measurement
    }

    /// One `vm_compute` call into the shared mel buffer; the frame count must be the dump's.
    private func computeRustMel(_ engine: RustMelEngine, samples: [Float], row: RustBenchDumpRow) throws -> Int {
        engine.error.clear()
        let frames = samples.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return engine.compute(
                samples: base,
                sampleCount: Int32(buffer.count),
                output: scratch.mel,
                maxFrames: Int32(scratch.melCapacity),
                melBins: Int32(ParakeetContext.NativeMel.melBins)
            )
        }
        guard frames >= 0 else {
            throw BenchError.io("vm_compute (\(engine.arm)): \(engine.error.message(fallback: "returned \(frames)"))")
        }
        guard Int(frames) == row.melFrameCount else {
            throw BenchError.io("vm_compute (\(engine.arm)) made \(frames) frames, the dump has \(row.melFrameCount)")
        }
        return Int(frames)
    }
}

// MARK: - Judging

/// One arm's measurement judged against the dump ref and this row's native arm.
private struct CombinedJudgement {
    var elapsedUs: Double?
    var work: CombinedWork
    var equalRef: Bool
    var plogErr: RustBenchErr?
    /// The call itself failed (no measurement).
    var failedCall: Bool
    /// The call succeeded but its output differs from the dump ref or the same-row native arm.
    var mismatch: Bool
    /// Set for `native@aa`: its consistency with `native`.
    var aa: CombinedAAVerdict?
}

private struct CombinedAAVerdict {
    var consistent: Bool
    /// Every token field, p and plog bitwise, against `native`; nil when either call failed.
    var bitwiseIdentical: Bool?
}

private enum CombinedJudge {
    static func judge(
        _ measured: [CombinedMeasured],
        row: RustBenchDumpRow,
        oracleFinal: String
    ) -> [CombinedJudgement] {
        let native = measured.first { $0.kind == .native }?.measurement
        let nativeReference: CombinedNativeReference? = native.flatMap { measurement in
            guard measurement.error == nil, let tokens = measurement.tokens, let transcript = measurement.transcript,
                let finalText = measurement.finalText
            else { return nil }
            return CombinedNativeReference(
                tokens: tokens,
                tokensSHA256: RustBenchToken.canonicalSHA256(tokens),
                transcript: transcript.text,
                finalText: finalText,
                segmentsSHA256: segmentsDigest(transcript)
            )
        }
        return measured.map { judge($0, row: row, oracleFinal: oracleFinal, native: nativeReference) }
    }

    private static func judge(
        _ item: CombinedMeasured,
        row: RustBenchDumpRow,
        oracleFinal: String,
        native: CombinedNativeReference?
    ) -> CombinedJudgement {
        let measurement = item.measurement
        var work = CombinedWork()
        work.stagesUs = measurement.stagesUs
        work.melFrames = measurement.melFrames
        work.encoderFrames = measurement.encoderFrames
        work.native = measurement.native.map(CombinedNativeCounters.init)
        work.melSHA256 = measurement.melSHA256
        work.melEqualDump = measurement.melSHA256.map { $0 == row.melSHA256 }
        work.statesSHA256 = measurement.statesSHA256
        work.statesEqualDump = measurement.statesSHA256.map { $0 == row.encSHA256 }

        guard measurement.error == nil, let elapsedUs = measurement.elapsedUs, let tokens = measurement.tokens,
            let transcript = measurement.transcript, let finalText = measurement.finalText
        else {
            work.error = measurement.error ?? "no measurement"
            return CombinedJudgement(
                elapsedUs: nil,
                work: work,
                equalRef: false,
                plogErr: nil,
                failedCall: true,
                mismatch: false,
                aa: item.kind == .nativeAA ? CombinedAAVerdict(consistent: false, bitwiseIdentical: nil) : nil
            )
        }

        let comparison = RustBenchTokenComparison(tokens, reference: row.ref)
        let segments = segmentsDigest(transcript)
        work.tokenCount = tokens.count
        work.transcript = transcript.text
        work.finalText = finalText
        work.transcriptSHA256 = GlossaryConditioningDigest.hex(transcript.text)
        work.finalTextSHA256 = GlossaryConditioningDigest.hex(finalText)
        work.tokensSHA256 = comparison.tokensSHA256
        work.segmentsSHA256 = segments
        work.meanConfidence = transcript.confidence
        work.tokensEqualRef = comparison.equalRef
        work.textEqualRef = transcript.text.utf8.elementsEqual(row.ref.text.utf8)
        work.finalEqualRef = finalText.utf8.elementsEqual(oracleFinal.utf8)
        work.identicalRef = comparison.identicalRef
        work.firstDifference = comparison.firstDifference
        work.pMaxAbs = comparison.pMaxAbs

        var againstNative: [Bool] = []
        if item.kind != .native, let native {
            work.tokensEqualNative = comparison.tokensSHA256 == native.tokensSHA256
            work.textEqualNative = transcript.text.utf8.elementsEqual(native.transcript.utf8)
            work.finalEqualNative = finalText.utf8.elementsEqual(native.finalText.utf8)
            work.segmentsEqualNative = segments == native.segmentsSHA256
            work.identicalNative =
                tokens.count == native.tokens.count && zip(tokens, native.tokens).allSatisfy { $0.identical($1) }
            againstNative = [
                work.tokensEqualNative == true, work.textEqualNative == true, work.finalEqualNative == true,
                work.segmentsEqualNative == true,
            ]
        }

        let equalRef = comparison.equalRef && work.textEqualRef == true && work.finalEqualRef == true
        let mismatch = !equalRef || againstNative.contains(false)
        var aa: CombinedAAVerdict?
        if item.kind == .nativeAA {
            aa = CombinedAAVerdict(
                consistent: native != nil && !againstNative.contains(false) && againstNative.count == 4,
                bitwiseIdentical: work.identicalNative
            )
        }
        return CombinedJudgement(
            elapsedUs: elapsedUs,
            work: work,
            equalRef: equalRef,
            plogErr: comparison.plogErr,
            failedCall: false,
            mismatch: mismatch,
            aa: aa
        )
    }

    /// The digest of what a transcript says about its segments: each segment's bounds and text,
    /// each word's text and bounds. Word confidences are floats and are judged separately.
    private static func segmentsDigest(_ transcript: ASRTranscript) -> String {
        var canonical = ""
        for segment in transcript.segments ?? [] {
            canonical += "S\u{0}\(segment.startMs)\u{0}\(segment.endMs)\u{0}\(segment.text)\u{1}"
            for word in segment.words ?? [] {
                canonical += "W\u{0}\(word.startMs)\u{0}\(word.endMs)\u{0}\(word.text)\u{1}"
            }
        }
        return GlossaryConditioningDigest.hex(canonical)
    }
}

private struct CombinedNativeReference {
    var tokens: [RustBenchToken]
    var tokensSHA256: String
    var transcript: String
    var finalText: String
    var segmentsSHA256: String
}

private struct CombinedTally {
    var failedCalls = 0
    var mismatches = 0
    var aaInconsistencies = 0
    var aaBitwiseDifferences = 0
    var mismatchesByArm: [String: Int] = [:]

    /// Failure categories the command itself judges; failed arm calls are counted by the summary.
    var failureCounts: [String: Int] {
        ["output_mismatches": mismatches, "native_aa_inconsistencies": aaInconsistencies]
    }

    /// Reported, not failures: p and plog are floats, no bitwise identity is claimed.
    var informational: [String: Int] {
        var info = ["native_aa_bitwise_p_plog_differences": aaBitwiseDifferences]
        for (arm, count) in mismatchesByArm { info["output_mismatches.\(arm)"] = count }
        return info
    }

    mutating func record(_ kind: CombinedArmKind, _ judgement: CombinedJudgement) {
        if judgement.failedCall {
            failedCalls += 1
        } else if judgement.mismatch {
            mismatches += 1
            mismatchesByArm[kind.rawValue, default: 0] += 1
        }
    }

    mutating func recordAA(_ verdicts: [CombinedAAVerdict]) {
        for verdict in verdicts {
            if !verdict.consistent { aaInconsistencies += 1 }
            if verdict.bitwiseIdentical == false { aaBitwiseDifferences += 1 }
        }
    }
}

// MARK: - Output rows

private struct CombinedNativeCounters: Encodable {
    var melUs: Int64
    var encodeUs: Int64
    var decodeUs: Int64
    var predictUs: Int64
    var sampleUs: Int64
    var encodeCount: Int
    var decodeCount: Int
    var predictCount: Int
    var sampleCount: Int

    init(_ timings: ParakeetStageTimings) {
        melUs = timings.melMicroseconds
        encodeUs = timings.encodeMicroseconds
        decodeUs = timings.decodeMicroseconds
        predictUs = timings.predictMicroseconds
        sampleUs = timings.sampleMicroseconds
        encodeCount = timings.encodeCount
        decodeCount = timings.decodeCount
        predictCount = timings.predictCount
        sampleCount = timings.sampleCount
    }

    enum CodingKeys: String, CodingKey {
        case melUs = "t_mel_us"
        case encodeUs = "t_encode_us"
        case decodeUs = "t_decode_us"
        case predictUs = "t_predict_us"
        case sampleUs = "t_sample_us"
        case encodeCount = "n_encode"
        case decodeCount = "n_decode"
        case predictCount = "n_predict"
        case sampleCount = "n_sample"
    }
}

private struct CombinedWork: Encodable {
    var error: String?
    /// Per-stage microseconds inside the timer; they sum to `elapsed_us`.
    var stagesUs: [String: Double] = [:]
    var melFrames: Int?
    var encoderFrames: Int?
    var tokenCount: Int?
    var transcript: String?
    var finalText: String?
    var transcriptSHA256: String?
    var finalTextSHA256: String?
    var tokensSHA256: String?
    var segmentsSHA256: String?
    var tokensEqualRef: Bool?
    var textEqualRef: Bool?
    var finalEqualRef: Bool?
    var tokensEqualNative: Bool?
    var textEqualNative: Bool?
    var finalEqualNative: Bool?
    var segmentsEqualNative: Bool?
    var identicalRef: Bool?
    var identicalNative: Bool?
    var firstDifference: Int?
    var pMaxAbs: Double?
    var meanConfidence: Double?
    var melSHA256: String?
    var melEqualDump: Bool?
    var statesSHA256: String?
    var statesEqualDump: Bool?
    var native: CombinedNativeCounters?

    enum CodingKeys: String, CodingKey {
        case error
        case stagesUs = "stages_us"
        case melFrames = "n_mel_frames"
        case encoderFrames = "n_enc_frames"
        case tokenCount = "n_tokens"
        case transcript
        case finalText = "final_text"
        case transcriptSHA256 = "transcript_sha256"
        case finalTextSHA256 = "final_text_sha256"
        case tokensSHA256 = "tokens_sha256"
        case segmentsSHA256 = "segments_sha256"
        case tokensEqualRef = "tokens_equal_ref"
        case textEqualRef = "text_equal_ref"
        case finalEqualRef = "final_equal_ref"
        case tokensEqualNative = "tokens_equal_native"
        case textEqualNative = "text_equal_native"
        case finalEqualNative = "final_equal_native"
        case segmentsEqualNative = "segments_equal_native"
        case identicalRef = "identical_ref"
        case identicalNative = "identical_native"
        case firstDifference = "first_diff"
        case pMaxAbs = "p_max_abs"
        case meanConfidence = "mean_confidence"
        case melSHA256 = "mel_sha256"
        case melEqualDump = "mel_equal_dump"
        case statesSHA256 = "states_sha256"
        case statesEqualDump = "states_equal_dump"
        case native
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(error, forKey: .error)
        try container.encode(stagesUs, forKey: .stagesUs)
        try container.encode(melFrames, forKey: .melFrames)
        try container.encode(encoderFrames, forKey: .encoderFrames)
        try container.encode(tokenCount, forKey: .tokenCount)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(finalText, forKey: .finalText)
        try container.encode(transcriptSHA256, forKey: .transcriptSHA256)
        try container.encode(finalTextSHA256, forKey: .finalTextSHA256)
        try container.encode(tokensSHA256, forKey: .tokensSHA256)
        try container.encode(segmentsSHA256, forKey: .segmentsSHA256)
        try container.encode(tokensEqualRef, forKey: .tokensEqualRef)
        try container.encode(textEqualRef, forKey: .textEqualRef)
        try container.encode(finalEqualRef, forKey: .finalEqualRef)
        try container.encode(tokensEqualNative, forKey: .tokensEqualNative)
        try container.encode(textEqualNative, forKey: .textEqualNative)
        try container.encode(finalEqualNative, forKey: .finalEqualNative)
        try container.encode(segmentsEqualNative, forKey: .segmentsEqualNative)
        try container.encode(identicalRef, forKey: .identicalRef)
        try container.encode(identicalNative, forKey: .identicalNative)
        try container.encode(firstDifference, forKey: .firstDifference)
        try container.encode(pMaxAbs, forKey: .pMaxAbs)
        try container.encode(meanConfidence, forKey: .meanConfidence)
        try container.encode(melSHA256, forKey: .melSHA256)
        try container.encode(melEqualDump, forKey: .melEqualDump)
        try container.encode(statesSHA256, forKey: .statesSHA256)
        try container.encode(statesEqualDump, forKey: .statesEqualDump)
        try container.encode(native, forKey: .native)
    }
}

private struct CombinedBenchConfig: Encodable {
    var melArm: String?
    var tailArm: String?
    var controlArm: String?
    var expectedTimingRows: Int
    var model: CombinedModelProvenance
    var maxMelFrames: Int
    var maxEncoderFrames: Int
    var audioDigestsVerifiedBeforeTiming: Int

    enum CodingKeys: String, CodingKey {
        case melArm = "rust_mel_arm"
        case tailArm = "rust_tail_arm"
        case controlArm = "c_tail_arm"
        case expectedTimingRows = "expected_timing_rows"
        case model
        case maxMelFrames = "max_mel_frames"
        case maxEncoderFrames = "max_enc_frames"
        case audioDigestsVerifiedBeforeTiming = "audio_digests_verified_before_timing"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(melArm, forKey: .melArm)
        try container.encode(tailArm, forKey: .tailArm)
        try container.encode(controlArm, forKey: .controlArm)
        try container.encode(expectedTimingRows, forKey: .expectedTimingRows)
        try container.encode(model, forKey: .model)
        try container.encode(maxMelFrames, forKey: .maxMelFrames)
        try container.encode(maxEncoderFrames, forKey: .maxEncoderFrames)
        try container.encode(audioDigestsVerifiedBeforeTiming, forKey: .audioDigestsVerifiedBeforeTiming)
    }
}

// MARK: - Inputs and provenance

/// Every row's audio, checked against the dump before any arm runs: digest, decodability and
/// sample count, plus the buffer sizes the largest row needs.
private struct CombinedInputs {
    var maxMelFrames: Int
    var maxEncoderFrames: Int

    func audioURL(_ row: RustBenchDumpRow) -> URL {
        BenchCLI.fileURL(row.audioPath)
    }

    static func verify(_ dump: RustBenchDump) throws -> CombinedInputs {
        var maxMel = 0
        var maxEncoder = 0
        for row in dump.rows {
            let url = BenchCLI.fileURL(row.audioPath)
            let digest = try BenchRunner.sha256(of: url)
            guard digest == row.audioSHA256 else {
                throw BenchError.io("\(row.id): \(url.path) sha256 \(digest) is not the dump's \(row.audioSHA256)")
            }
            let samples = try WAVFile.readSamples(at: url)
            guard samples.count == row.sampleCount else {
                throw BenchError.io("\(row.id): decoded \(samples.count) samples, the dump has \(row.sampleCount)")
            }
            maxMel = max(maxMel, row.melFrameCount)
            maxEncoder = max(maxEncoder, row.encoderFrameCount)
        }
        return CombinedInputs(maxMelFrames: maxMel, maxEncoderFrames: maxEncoder)
    }
}

/// The pinned model file, hashed before timing and checked against the product pin.
private struct CombinedModelProvenance: Encodable {
    var path: String
    var sha256: String
    var bytes: Int64
    var pinSHA256: String
    var pinBytes: Int64
    var file: String
    var modelID: String
    var revision: String

    enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case bytes
        case pinSHA256 = "pin_sha256"
        case pinBytes = "pin_bytes"
        case file
        case modelID = "model_id"
        case revision
    }

    static func capture(cache: ParakeetModelCache) throws -> CombinedModelProvenance {
        let modelURL = cache.modelURL
        let digest = try BenchRunner.sha256(of: modelURL)
        let bytes: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
            bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw BenchError.io("cannot stat \(modelURL.path): \(BenchError.describe(error))")
        }
        guard digest == cache.artifact.sha256.lowercased(), bytes == cache.artifact.sizeBytes else {
            throw BenchError.io(
                "\(modelURL.path) is sha256 \(digest), \(bytes) bytes; the pin is "
                    + "\(cache.artifact.sha256), \(cache.artifact.sizeBytes) bytes"
            )
        }
        return CombinedModelProvenance(
            path: modelURL.path,
            sha256: digest,
            bytes: bytes,
            pinSHA256: cache.artifact.sha256,
            pinBytes: cache.artifact.sizeBytes,
            file: cache.artifact.file,
            modelID: cache.artifact.modelId,
            revision: cache.artifact.revision
        )
    }
}
