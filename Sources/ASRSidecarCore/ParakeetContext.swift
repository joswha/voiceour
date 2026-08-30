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

    /// Loads the model and uses `weightArenaPath` for the versioned file-backed weight cache.
    /// Cache creation or validation failures fall back to ordinary ggml buffers in C++.
    public init(
        modelPath: String,
        weightArenaPath: String? = nil,
        useGPU: Bool = true,
        threadCount: Int32 = 4
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
        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = threadCount

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

            let status = samples.withUnsafeBufferPointer { buffer in
                parakeet_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
            guard status == 0 else { throw ParakeetContextError.decodeFailed(status) }
            return collectSegments()
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
