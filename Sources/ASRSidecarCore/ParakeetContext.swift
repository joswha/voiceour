import CParakeet
import Foundation

enum ParakeetTailBackend: Equatable {
    case `default`
    case cpu

    static let environmentKey = "VOICEOUR_TAIL_BACKEND"

    static func resolve(environment: [String: String]) throws -> ParakeetTailBackend {
        guard let value = environment[environmentKey] else { return .default }
        switch value {
        case "default": return .default
        case "cpu": return .cpu
        default: throw ParakeetTailBackendError.invalidValue(value)
        }
    }

    var usesCPU: Bool { self == .cpu }
}

enum ParakeetTailBackendError: Error, CustomStringConvertible {
    case invalidValue(String)

    var description: String {
        switch self {
        case .invalidValue(let value):
            return "invalid \(ParakeetTailBackend.environmentKey) value '\(value)'; expected 'default' or 'cpu'"
        }
    }
}

/// Opt-in load-time q8_0 repack of the CPU tail's matmul weights. `default` keeps the f16
/// tail; `q8_0` quantizes prediction/joint weight streams at load, halving the memory
/// traffic the batch-1 tail matvecs pay per token. Requires the CPU tail; any other value
/// refuses startup, mirroring `VOICEOUR_TAIL_BACKEND`.
enum ParakeetTailQuant: Equatable {
    case `default`
    case q8

    static let environmentKey = "VOICEOUR_TAIL_QUANT"

    static func resolve(environment: [String: String]) throws -> ParakeetTailQuant {
        guard let value = environment[environmentKey] else { return .default }
        switch value {
        case "default": return .default
        case "q8_0": return .q8
        default: throw ParakeetTailQuantError.invalidValue(value)
        }
    }

    var isQ8: Bool { self == .q8 }
}

enum ParakeetTailQuantError: Error, CustomStringConvertible {
    case invalidValue(String)
    case requiresCPUTail

    var description: String {
        switch self {
        case .invalidValue(let value):
            return "invalid \(ParakeetTailQuant.environmentKey) value '\(value)'; expected 'default' or 'q8_0'"
        case .requiresCPUTail:
            return "\(ParakeetTailQuant.environmentKey)=q8_0 requires \(ParakeetTailBackend.environmentKey)=cpu"
        }
    }
}

/// Opt-in CoreML tier warm during backend warm-up. `default` keeps tiers lazy — each loads on
/// the first utterance routed to it. `tiers` loads every configured tier on the preload thread,
/// under the decode lock, so a cold ANE specialization (~20 s per tier, and disk-pressure
/// volatile) is paid before the first dictation instead of inside it. Any other value refuses
/// startup, mirroring the other experimental dials.
enum CoreMLWarmMode: Equatable {
    case `default`
    case tiers

    static let environmentKey = "VOICEOUR_COREML_WARM"

    static func resolve(environment: [String: String]) throws -> CoreMLWarmMode {
        guard let value = environment[environmentKey] else { return .default }
        switch value {
        case "default": return .default
        case "tiers": return .tiers
        default: throw CoreMLWarmModeError.invalidValue(value)
        }
    }

    var warmsAllTiers: Bool { self == .tiers }
}

enum CoreMLWarmModeError: Error, CustomStringConvertible {
    case invalidValue(String)

    var description: String {
        switch self {
        case .invalidValue(let value):
            return "invalid \(CoreMLWarmMode.environmentKey) value '\(value)'; expected 'default' or 'tiers'"
        }
    }
}

/// Opt-in persistent ggml CPU threadpool. `default` keeps the disposable per-compute pool;
/// `persistent` attaches one pool sized to the decode thread count, removing the thread
/// create/join churn the TDT tail pays on every one of its per-step graph computes. Any
/// other value refuses startup, mirroring `VOICEOUR_TAIL_BACKEND`.
enum ParakeetCPUPool: Equatable {
    case `default`
    case persistent

    static let environmentKey = "VOICEOUR_CPU_POOL"

    static func resolve(environment: [String: String]) throws -> ParakeetCPUPool {
        guard let value = environment[environmentKey] else { return .default }
        switch value {
        case "default": return .default
        case "persistent": return .persistent
        default: throw ParakeetCPUPoolError.invalidValue(value)
        }
    }

    var isPersistent: Bool { self == .persistent }
}

enum ParakeetCPUPoolError: Error, CustomStringConvertible {
    case invalidValue(String)

    var description: String {
        switch self {
        case .invalidValue(let value):
            return "invalid \(ParakeetCPUPool.environmentKey) value '\(value)'; expected 'default' or 'persistent'"
        }
    }
}

public enum ParakeetContextError: Error, CustomStringConvertible {
    case loadFailed(String)
    case decodeFailed(Int32)
    case coreMLEncodersUnconfigured
    case coreMLTierUnavailable(sampleCount: Int)
    case externalStateContract(String)

    public var description: String {
        switch self {
        case .loadFailed(let path): return "parakeet_init_from_file_with_params failed for \(path)"
        case .decodeFailed(let code): return "parakeet_full returned \(code)"
        case .coreMLEncodersUnconfigured:
            return
                "no CoreML encoder tier is configured: set VOICEOUR_COREML_ENCODER_TINY, VOICEOUR_COREML_ENCODER_SHORT, or VOICEOUR_COREML_ENCODER"
        case .coreMLTierUnavailable(let sampleCount):
            return "no configured CoreML encoder tier accepts \(sampleCount) samples"
        case .externalStateContract(let detail):
            return "external encoder states rejected: \(detail)"
        }
    }
}

/// One decoded token, flattened out of `parakeet_token_data` plus its text pieces.
public struct ParakeetToken: Equatable, Sendable {
    /// The raw vocabulary piece, still carrying the SentencePiece meta-space marker.
    public var piece: String
    /// The piece rendered as user-visible text.
    public var text: String
    /// Per-token posterior from the greedy TDT decode.
    public var probability: Float
    public var startMs: Int
    public var endMs: Int
    public var isWordStart: Bool

    public init(piece: String, text: String, probability: Float, startMs: Int, endMs: Int, isWordStart: Bool) {
        self.piece = piece
        self.text = text
        self.probability = probability
        self.startMs = startMs
        self.endMs = endMs
        self.isWordStart = isWordStart
    }
}

/// A decoded segment: its bounds, its own text, and its tokens.
public struct ParakeetSegmentRaw: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var tokens: [ParakeetToken]

    public init(startMs: Int, endMs: Int, text: String, tokens: [ParakeetToken]) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.tokens = tokens
    }
}

/// One ranked token logit from a greedy TDT decode step.
public struct ParakeetLatticeTokenLogit: Equatable, Sendable {
    public var id: Int32
    public var logit: Float
}

/// The bounded information needed to study one greedy TDT decision.
public struct ParakeetLatticeStep: Equatable, Sendable {
    public var frameIndex: Int32
    public var isBlank: Bool
    public var chosenTokenID: Int32
    public var chosenTokenPiece: String
    public var chosenTokenLogit: Float
    public var chosenDurationSlot: Int32
    public var chosenDurationLogit: Float
    public var topTokens: [ParakeetLatticeTokenLogit]
    public var durationLogits: [Float]
    public var tokenMargin: Float
    public var durationMargin: Float
}

/// A normal transcription plus the greedy decisions that produced it.
public struct ParakeetLatticeResult: Equatable, Sendable {
    public var segments: [ParakeetSegmentRaw]
    public var steps: [ParakeetLatticeStep]
}

/// Owns one `parakeet_context` and its default state.
///
/// `parakeet_full` is documented as not thread safe for the same context, so exactly one
/// instance exists per process and every call arrives on the sidecar's single decode queue.
/// The class is deliberately not `Sendable`: the serialization is the queue's job, and making
/// this type look concurrency-safe would invite a second caller.
public final class ParakeetContext {
    /// Timestamps are in mel frames; hop 160 at 16 kHz makes each frame 10 ms
    /// (`include/parakeet.h:33-34`, `src/parakeet.cpp` `create_token_data`).
    public static let msPerFrame = 10

    /// Frame-major encoder state width — the model's `n_audio_state`, and the trailing
    /// dimension of every state buffer the external-encoder seams lend or accept.
    public static let encoderStateWidth = CoreMLEncoder.encoderChannels

    /// Mel frames per encoder frame, the factor the tail's external-state guard applies
    /// to the stored mel length (`parakeet.cpp:6236-6237`).
    private static let melSubsamplingFactor = 8

    /// Thread count the hybrid CoreML path hands the TDT tail. Both external-encoder
    /// routes use it, so replayed states decode under exactly the dumping run's tail.
    private static let hybridTailThreadCount: Int32 = 4

    private let context: OpaquePointer
    private let threadCount: Int32
    private var coreMLEncoders: CoreMLEncoderSet?

    /// Primes every configured CoreML tier's specialization cache. Lock-free; see
    /// `CoreMLEncoderSet.primeAll`. A context without CoreML tiers does nothing.
    func primeCoreMLTiers(log: (String) -> Void) {
        coreMLEncoders?.primeAll(log: log)
    }

    /// Loads the model and uses `weightArenaPath` for the versioned file-backed weight cache.
    /// Cache creation or validation failures fall back to ordinary ggml buffers in C++.
    public init(
        modelPath: String,
        weightArenaPath: String? = nil,
        useGPU: Bool = true,
        tailBackendCPU: Bool = false,
        tailQuantQ8: Bool = false,
        persistentCPUPool: Bool = false,
        threadCount: Int32 = 6
    ) throws {
        var params = parakeet_context_default_params()
        params.use_gpu = useGPU
        params.tail_backend_cpu = tailBackendCPU
        params.tail_quant_q8 = tailQuantQ8
        params.persistent_cpu_pool_threads = persistentCPUPool ? threadCount : 0
        let loaded: OpaquePointer?
        if let weightArenaPath {
            loaded = parakeet_init_from_file_with_params_and_weight_arena(
                modelPath,
                weightArenaPath,
                params
            )
        } else {
            loaded = parakeet_init_from_file_with_params(modelPath, params)
        }
        guard let context = loaded else {
            throw ParakeetContextError.loadFailed(modelPath)
        }
        self.context = context
        self.threadCount = threadCount
    }

    convenience init(
        modelPath: String,
        weightArenaPath: String?,
        useGPU: Bool = true,
        tailBackendCPU: Bool = false,
        tailQuantQ8: Bool = false,
        persistentCPUPool: Bool = false,
        threadCount: Int32 = 6,
        coreMLEncoders: CoreMLEncoderSet
    ) throws {
        try self.init(
            modelPath: modelPath,
            weightArenaPath: weightArenaPath,
            useGPU: useGPU,
            tailBackendCPU: tailBackendCPU,
            tailQuantQ8: tailQuantQ8,
            persistentCPUPool: persistentCPUPool,
            threadCount: threadCount
        )
        self.coreMLEncoders = coreMLEncoders
    }

    /// Research entry point: one context whose encode routes through the same fixed-shape
    /// CoreML tiers the sidecar resolves from `environment`, with no sidecar process,
    /// pinned-artifact cache, or weight arena in the way.
    ///
    /// Refuses a configuration with no tier at all instead of silently handing back the
    /// native encoder: a caller that asked for the CoreML states must not get other ones.
    public convenience init(
        modelPath: String,
        coreMLEnvironment: [String: String],
        useGPU: Bool = true,
        tailBackendCPU: Bool = false,
        threadCount: Int32 = 6,
        log: @escaping (String) -> Void = { _ in }
    ) throws {
        let configurations = try CoreMLEncoderConfigurationSet.resolve(environment: coreMLEnvironment)
        let encoders = try CoreMLEncoderSet(configurations: configurations, log: log)
        guard !encoders.isEmpty else { throw ParakeetContextError.coreMLEncodersUnconfigured }
        try self.init(
            modelPath: modelPath,
            weightArenaPath: nil,
            useGPU: useGPU,
            tailBackendCPU: tailBackendCPU,
            threadCount: threadCount,
            coreMLEncoders: encoders
        )
    }

    deinit {
        parakeet_free(context)
    }

    /// Runs mel → encoder → TDT decode over the whole utterance in one call.
    ///
    /// There is no length cap and no chunking: inputs longer than the 5000-mel context take
    /// the dynamic-encoder path inside `parakeet_full`. Cancellation is cooperative, checked
    /// between graph computations, so the client's hard timeout still depends on killing the
    /// process — unchanged from the Python sidecar.
    public func transcribe(samples: [Float], isCancelled: @escaping () -> Bool) throws -> [ParakeetSegmentRaw] {
        try decode(samples: samples, isCancelled: isCancelled, latticeBridge: nil)
        return collectSegments()
    }

    /// Preload warms the native Parakeet/Metal path without claiming a lazy CoreML tier before
    /// the first real request routed to it.
    func transcribeForWarmUp(
        samples: [Float],
        isCancelled: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw] {
        try decode(
            samples: samples,
            isCancelled: isCancelled,
            latticeBridge: nil,
            routesThroughCoreML: false
        )
        return collectSegments()
    }

    /// Runs the production greedy decode while retaining only top-8 token logits and all five
    /// duration logits per step. This is a research seam; the ordinary transcription path does
    /// not install the callback and therefore performs no lattice work.
    public func transcribeWithLattice(
        samples: [Float],
        isCancelled: @escaping () -> Bool
    ) throws -> ParakeetLatticeResult {
        let bridge = LatticeBridge(reserveCapacity: max(16, samples.count / 2_000))
        try decode(samples: samples, isCancelled: isCancelled, latticeBridge: bridge)
        return ParakeetLatticeResult(segments: collectSegments(), steps: bridge.steps)
    }

    /// Research seam: run the configured CoreML tier's encode, lend the frame-major
    /// `[frames, encoderStateWidth]` F32 states to `observeStates` before the tail can see
    /// them, then run the unchanged external-encoder tail over those same bytes.
    ///
    /// The lent buffer is the encoder's reusable storage and is valid only for the duration
    /// of the observer call; a caller that needs it afterwards copies it. An observer that
    /// throws stops before the tail runs and its error is rethrown unchanged.
    ///
    /// This refuses a row no configured tier accepts rather than falling back to the native
    /// encoder, because such a row has no CoreML state to hand out.
    public func transcribeCapturingCoreMLStates(
        samples: [Float],
        isCancelled: @escaping () -> Bool,
        observeStates: (UnsafeBufferPointer<Float>, Int) throws -> Void
    ) throws -> [ParakeetSegmentRaw] {
        guard let encoder = try coreMLEncoders?.encoder(sampleCount: samples.count) else {
            throw ParakeetContextError.coreMLTierUnavailable(sampleCount: samples.count)
        }
        var observationError: Error?
        let status = try withDecodeParams(
            threadCount: threadCount,
            isCancelled: isCancelled,
            latticeBridge: nil
        ) { params in
            try decodeWithCoreMLEncoder(
                encoder,
                samples: samples,
                params: params,
                isCancelled: isCancelled
            ) { states, encoderFrameCount in
                do {
                    try observeStates(states, encoderFrameCount)
                    return true
                } catch {
                    observationError = error
                    return false
                }
            }
        }
        if let observationError { throw observationError }
        guard status == 0 else { throw ParakeetContextError.decodeFailed(status) }
        return collectSegments()
    }

    /// Research seam: decode caller-supplied frame-major `[frames, encoderStateWidth]` F32
    /// states through the same unchanged external-encoder tail, over `samples`' own mel.
    ///
    /// The mel is recomputed from the audio because the tail checks the external frame count
    /// against the stored mel length (`parakeet.cpp:6236-6254`); the supplied states are
    /// never re-encoded, and no CoreML model is loaded or required. The frame count and
    /// width are refused here, with the mismatch named, before the C guard sees them.
    public func transcribeWithExternalStates(
        samples: [Float],
        states: UnsafeBufferPointer<Float>,
        frameCount: Int,
        isCancelled: @escaping () -> Bool
    ) throws -> [ParakeetSegmentRaw] {
        let status = try withDecodeParams(
            threadCount: Self.hybridTailThreadCount,
            isCancelled: isCancelled,
            latticeBridge: nil
        ) { params in
            let melStatus = samples.withUnsafeBufferPointer { buffer in
                parakeet_pcm_to_mel(context, buffer.baseAddress, Int32(buffer.count), params.n_threads)
            }
            guard melStatus == 0 else { return melStatus }

            let melFrameCount = Int(parakeet_n_len(context))
            let expectedMelFrameCount = samples.count / 160 + 1
            guard melFrameCount == expectedMelFrameCount else {
                throw ParakeetContextError.externalStateContract(
                    "mel is \(melFrameCount) frames, expected \(expectedMelFrameCount)"
                )
            }
            let expectedFrameCount =
                (melFrameCount + Self.melSubsamplingFactor - 1) / Self.melSubsamplingFactor
            guard frameCount == expectedFrameCount else {
                throw ParakeetContextError.externalStateContract(
                    "\(frameCount) encoder frames supplied, mel of \(melFrameCount) expects \(expectedFrameCount)"
                )
            }
            guard states.count == frameCount * Self.encoderStateWidth else {
                throw ParakeetContextError.externalStateContract(
                    "\(states.count) floats supplied, expected \(frameCount) x \(Self.encoderStateWidth)"
                )
            }
            if isCancelled() { return -6 }

            return parakeet_full_with_external_encoder(
                context,
                params,
                nil,
                0,
                states.baseAddress,
                Int32(frameCount),
                Int32(Self.encoderStateWidth)
            )
        }
        guard status == 0 else { throw ParakeetContextError.decodeFailed(status) }
        return collectSegments()
    }

    /// Builds the greedy parameters every decode route shares — thread count, the optional
    /// lattice callback, and the cancellation callbacks bound to a bridge that outlives
    /// `body` — then runs `body` with them.
    private func withDecodeParams<Result>(
        threadCount: Int32,
        isCancelled: @escaping () -> Bool,
        latticeBridge: LatticeBridge?,
        body: (parakeet_full_params) throws -> Result
    ) throws -> Result {
        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = threadCount

        if let latticeBridge {
            params.decode_step_callback_user_data = Unmanaged.passUnretained(latticeBridge).toOpaque()
            params.decode_step_callback = {
                context,
                _,
                frameIndex,
                chosenToken,
                isBlank,
                chosenDurationSlot,
                tokenLogits,
                tokenLogitCount,
                durationLogits,
                durationLogitCount,
                userData in
                guard let context, let userData else { return }
                Unmanaged<LatticeBridge>.fromOpaque(userData).takeUnretainedValue().append(
                    context: context,
                    frameIndex: frameIndex,
                    chosenToken: chosenToken,
                    isBlank: isBlank,
                    chosenDurationSlot: chosenDurationSlot,
                    tokenLogits: tokenLogits,
                    tokenLogitCount: tokenLogitCount,
                    durationLogits: durationLogits,
                    durationLogitCount: durationLogitCount
                )
            }
        }

        var cancellation = CancellationBridge(isCancelled: isCancelled)
        return try withUnsafeMutablePointer(to: &cancellation) { bridge in
            params.encoder_begin_callback_user_data = UnsafeMutableRawPointer(bridge)
            params.encoder_begin_callback = { _, _, userData in
                guard let userData else { return true }
                return !userData.assumingMemoryBound(to: CancellationBridge.self).pointee.isCancelled()
            }
            params.abort_callback_user_data = UnsafeMutableRawPointer(bridge)
            params.abort_callback = { userData in
                guard let userData else { return false }
                return userData.assumingMemoryBound(to: CancellationBridge.self).pointee.isCancelled()
            }

            return try withExtendedLifetime(latticeBridge) {
                try body(params)
            }
        }
    }

    private func decode(
        samples: [Float],
        isCancelled: @escaping () -> Bool,
        latticeBridge: LatticeBridge?,
        routesThroughCoreML: Bool = true
    ) throws {
        let status = try withDecodeParams(
            threadCount: threadCount,
            isCancelled: isCancelled,
            latticeBridge: latticeBridge
        ) { params in
            if routesThroughCoreML,
                let coreMLEncoder = try coreMLEncoders?.encoder(sampleCount: samples.count)
            {
                return try decodeWithCoreMLEncoder(
                    coreMLEncoder,
                    samples: samples,
                    params: params,
                    isCancelled: isCancelled
                )
            }
            return samples.withUnsafeBufferPointer { buffer in
                parakeet_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard status == 0 else { throw ParakeetContextError.decodeFailed(status) }
    }

    /// Nonzero status stood in for an observer that threw. The captured error is rethrown
    /// before this value can be inspected, so it only has to be distinct from success.
    private static let observerFailedStatus: Int32 = -9

    private func decodeWithCoreMLEncoder(
        _ encoder: CoreMLEncoder,
        samples: [Float],
        params: parakeet_full_params,
        isCancelled: () -> Bool,
        observeStates: (UnsafeBufferPointer<Float>, Int) -> Bool = { _, _ in true }
    ) throws -> Int32 {
        var hybridParams = params
        hybridParams.n_threads = Self.hybridTailThreadCount
        let melStatus = samples.withUnsafeBufferPointer { buffer in
            parakeet_pcm_to_mel(context, buffer.baseAddress, Int32(buffer.count), hybridParams.n_threads)
        }
        guard melStatus == 0 else { return melStatus }

        let frameCount = Int(parakeet_n_len(context))
        let expectedFrameCount = samples.count / 160 + 1
        guard frameCount == expectedFrameCount,
            parakeet_model_n_mels(context) == CoreMLEncoder.melBins,
            let melData = parakeet_get_mel_data(context)
        else {
            throw CoreMLEncoderError.nativeMelContract(
                "expected \(expectedFrameCount) frames x \(CoreMLEncoder.melBins) bins; got \(frameCount) frames"
            )
        }
        if isCancelled() { return -6 }

        return try encoder.encode(
            nativeMel: UnsafeBufferPointer(
                start: melData,
                count: frameCount * CoreMLEncoder.melBins
            ),
            frameCount: frameCount
        ) { states, encoderFrameCount in
            if isCancelled() { return -6 }
            guard observeStates(states, encoderFrameCount) else {
                return Self.observerFailedStatus
            }
            return parakeet_full_with_external_encoder(
                context,
                hybridParams,
                nil,
                0,
                states.baseAddress,
                Int32(encoderFrameCount),
                Int32(CoreMLEncoder.encoderChannels)
            )
        }
    }

    private func collectSegments() -> [ParakeetSegmentRaw] {
        let segmentCount = Int(parakeet_full_n_segments(context))
        guard segmentCount > 0 else { return [] }

        var segments: [ParakeetSegmentRaw] = []
        segments.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let segmentIndex = Int32(index)
            let tokenCount = Int(parakeet_full_n_tokens(context, segmentIndex))
            var tokens: [ParakeetToken] = []
            tokens.reserveCapacity(tokenCount)
            for tokenIndex in 0..<tokenCount {
                tokens.append(token(segment: segmentIndex, index: Int32(tokenIndex), isFirst: tokenIndex == 0))
            }
            // Bounds come from the tokens, not from `parakeet_full_get_segment_t0/t1`.
            // Those two report `0` and `state->n_frames`, and `n_frames` counts *encoder*
            // frames (post-subsampling), while `parakeet_token_data.t0/t1` are already
            // multiplied by `subsampling_factor` and so are mel frames. Scaling the segment
            // value by 10 ms would report an eighth of the real duration.
            segments.append(
                ParakeetSegmentRaw(
                    startMs: tokens.first?.startMs ?? 0,
                    endMs: tokens.last?.endMs ?? 0,
                    text: string(parakeet_full_get_segment_text(context, segmentIndex)),
                    tokens: tokens
                )
            )
        }
        return segments
    }

    private func token(segment: Int32, index: Int32, isFirst: Bool) -> ParakeetToken {
        let data = parakeet_full_get_token_data(context, segment, index)
        let piece = string(parakeet_token_to_str(context, data.id))
        return ParakeetToken(
            piece: piece,
            text: Self.renderText(piece: piece, isFirst: isFirst),
            probability: data.p,
            startMs: Int(data.t0) * Self.msPerFrame,
            endMs: Int(data.t1) * Self.msPerFrame,
            isWordStart: data.is_word_start
        )
    }

    /// `parakeet_token_to_text` strips the SentencePiece meta-space and, for a non-first
    /// piece, restores the leading space that the marker stood for.
    static func renderText(piece: String, isFirst: Bool) -> String {
        var buffer = [CChar](repeating: 0, count: piece.utf8.count + 2)
        let written = parakeet_token_to_text(piece, isFirst, &buffer, Int32(buffer.count))
        guard written > 0 else { return "" }
        return buffer.withUnsafeBytes { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private func string(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }
}

/// Holds the cancellation closure at a stable address for the C callbacks.
private struct CancellationBridge {
    let isCancelled: () -> Bool
}

/// Mutable callback state. `parakeet_full` invokes it synchronously on the decode thread.
private final class LatticeBridge {
    private static let tokenLimit = 8

    var steps: [ParakeetLatticeStep] = []

    init(reserveCapacity: Int) {
        steps.reserveCapacity(reserveCapacity)
    }

    func append(
        context: OpaquePointer,
        frameIndex: Int32,
        chosenToken: Int32,
        isBlank: Bool,
        chosenDurationSlot: Int32,
        tokenLogits: UnsafePointer<Float>?,
        tokenLogitCount: Int32,
        durationLogits: UnsafePointer<Float>?,
        durationLogitCount: Int32
    ) {
        guard
            let tokenLogits,
            let durationLogits,
            tokenLogitCount >= 2,
            durationLogitCount >= 2,
            chosenToken >= 0,
            chosenToken < tokenLogitCount,
            chosenDurationSlot >= 0,
            chosenDurationSlot < durationLogitCount
        else {
            return
        }

        let tokenBuffer = UnsafeBufferPointer(start: tokenLogits, count: Int(tokenLogitCount))
        let durationBuffer = UnsafeBufferPointer(start: durationLogits, count: Int(durationLogitCount))
        let topTokens = Self.topTokens(in: tokenBuffer)
        guard topTokens.count >= 2 else { return }

        let piecePointer = parakeet_token_to_str(context, chosenToken)
        let piece = piecePointer.map(String.init(cString:)) ?? ""
        let copiedDurationLogits = Array(durationBuffer)
        steps.append(
            ParakeetLatticeStep(
                frameIndex: frameIndex,
                isBlank: isBlank,
                chosenTokenID: chosenToken,
                chosenTokenPiece: piece,
                chosenTokenLogit: tokenBuffer[Int(chosenToken)],
                chosenDurationSlot: chosenDurationSlot,
                chosenDurationLogit: durationBuffer[Int(chosenDurationSlot)],
                topTokens: topTokens,
                durationLogits: copiedDurationLogits,
                tokenMargin: topTokens[0].logit - topTokens[1].logit,
                durationMargin: Self.topTwoMargin(in: durationBuffer)
            )
        )
    }

    private static func topTokens(
        in logits: UnsafeBufferPointer<Float>
    ) -> [ParakeetLatticeTokenLogit] {
        var top: [ParakeetLatticeTokenLogit] = []
        top.reserveCapacity(tokenLimit)
        for (index, logit) in logits.enumerated() {
            let candidate = ParakeetLatticeTokenLogit(id: Int32(index), logit: logit)
            var position = 0
            while position < top.count {
                let ranked = top[position]
                if logit > ranked.logit || (logit == ranked.logit && candidate.id < ranked.id) {
                    break
                }
                position += 1
            }
            guard position < tokenLimit else { continue }
            top.insert(candidate, at: position)
            if top.count > tokenLimit {
                top.removeLast()
            }
        }
        return top
    }

    private static func topTwoMargin(in logits: UnsafeBufferPointer<Float>) -> Float {
        var bestIndex = -1
        var secondIndex = -1
        var best = -Float.infinity
        var second = -Float.infinity
        for (index, logit) in logits.enumerated() {
            if logit > best || (logit == best && index < bestIndex) {
                second = best
                secondIndex = bestIndex
                best = logit
                bestIndex = index
            } else if logit > second || (logit == second && index < secondIndex) {
                second = logit
                secondIndex = index
            }
        }
        return best - second
    }
}
