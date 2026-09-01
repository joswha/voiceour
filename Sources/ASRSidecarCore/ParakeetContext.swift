import CParakeet
import Foundation

public enum ParakeetContextError: Error, CustomStringConvertible {
    case loadFailed(String)
    case decodeFailed(Int32)

    public var description: String {
        switch self {
        case .loadFailed(let path): return "parakeet_init_from_file_with_params failed for \(path)"
        case .decodeFailed(let code): return "parakeet_full returned \(code)"
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

    private let context: OpaquePointer
    private let threadCount: Int32
    private var coreMLEncoder: CoreMLEncoder?
    private var coreMLConfiguration: CoreMLEncoderConfiguration?

    /// Loads the model and uses `weightArenaPath` for the versioned file-backed weight cache.
    /// Cache creation or validation failures fall back to ordinary ggml buffers in C++.
    public init(
        modelPath: String,
        weightArenaPath: String? = nil,
        useGPU: Bool = true,
        threadCount: Int32 = 6
    ) throws {
        var params = parakeet_context_default_params()
        params.use_gpu = useGPU
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
        threadCount: Int32 = 6,
        coreMLEncoder: CoreMLEncoder,
        coreMLConfiguration: CoreMLEncoderConfiguration
    ) throws {
        try self.init(
            modelPath: modelPath,
            weightArenaPath: weightArenaPath,
            useGPU: useGPU,
            threadCount: threadCount
        )
        self.coreMLEncoder = coreMLEncoder
        self.coreMLConfiguration = coreMLConfiguration
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

    private func decode(
        samples: [Float],
        isCancelled: @escaping () -> Bool,
        latticeBridge: LatticeBridge?
    ) throws {
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
        let status = try withUnsafeMutablePointer(to: &cancellation) { bridge in
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
                if let coreMLEncoder, coreMLConfiguration?.routesThroughCoreML(sampleCount: samples.count) == true {
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
        }
        guard status == 0 else { throw ParakeetContextError.decodeFailed(status) }
    }

    private func decodeWithCoreMLEncoder(
        _ encoder: CoreMLEncoder,
        samples: [Float],
        params: parakeet_full_params,
        isCancelled: () -> Bool
    ) throws -> Int32 {
        var hybridParams = params
        hybridParams.n_threads = 4
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
        return String(cString: buffer)
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
