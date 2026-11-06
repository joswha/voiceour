import CGranite
import Foundation

public enum GraniteContextError: Error, Equatable, CustomStringConvertible {
    case loadFailed(String)
    /// `GRANITE_ERR_INVALID_ARGUMENT`, or audio the native call cannot be handed at all.
    case invalidArgument(String)
    /// `GRANITE_ERR_CANCELLED`: the abort callback answered true at a stage boundary.
    case cancelled
    /// `GRANITE_ERR_BACKEND`: graph construction, allocation or compute failed.
    case backendFailed
    /// A status this build does not know. Treated like a backend failure by callers.
    case unexpectedStatus(UInt32)

    public var description: String {
        switch self {
        case .loadFailed(let path): return "granite_init_from_file failed for \(path)"
        case .invalidArgument(let detail): return "granite_transcribe rejected its input: \(detail)"
        case .cancelled: return "granite_transcribe was cancelled"
        case .backendFailed: return "granite_transcribe failed in the ggml backend"
        case .unexpectedStatus(let status): return "granite_transcribe returned unknown status \(status)"
        }
    }
}

/// Owns one `granite_context`: the Granite Speech 5 TurboCTC model on the vendored ggml.
///
/// `granite_transcribe` replaces the context's previous results, so a context serves one decode
/// at a time; the backend serializes every call through its decode lock. The class is
/// deliberately not `Sendable`: serialization is the caller's
/// job, and a type that looked concurrency-safe would invite a second caller.
public final class GraniteContext {
    private let context: OpaquePointer
    /// Model constants, read once: none changes for the lifetime of a context.
    public let msPerFrame: Int
    public let nospeechTokenId: Int32
    /// CTC output dimension, the blank included.
    public let vocabularySize: Int
    /// Vocabulary id of the CTC blank.
    public let blankId: Int32

    public init(modelPath: String, useGPU: Bool = true, threadCount: Int32 = 6, mapWeights: Bool = true) throws {
        var params = granite_context_default_params()
        params.use_gpu = useGPU
        params.n_threads = threadCount
        params.map_weights = mapWeights
        guard let context = granite_init_from_file(modelPath, params) else {
            throw GraniteContextError.loadFailed(modelPath)
        }
        self.context = context
        msPerFrame = Int(granite_ms_per_frame(context))
        nospeechTokenId = granite_nospeech_token_id(context)
        vocabularySize = Int(granite_n_vocab(context))
        blankId = granite_blank_id(context)
    }

    deinit {
        granite_free(context)
    }

    /// Recognizes one whole utterance of mono 16 kHz PCM and copies the native results out.
    ///
    /// Cancellation is cooperative and coarse: the native side polls `isCancelled` only at its
    /// stage boundaries (before the frontend, around the graph compute, before CTC decoding),
    /// never inside a Metal command buffer, so the client's hard timeout still relies on
    /// terminating the process.
    public func transcribe(samples: [Float], isCancelled: @escaping () -> Bool) throws -> GraniteRawResult {
        guard let sampleCount = Int32(exactly: samples.count) else {
            throw GraniteContextError.invalidArgument("\(samples.count) samples exceed one native call")
        }
        var cancellation = GraniteCancellationBridge(isCancelled: isCancelled)
        let status = withUnsafeMutablePointer(to: &cancellation) { bridge in
            samples.withUnsafeBufferPointer { buffer in
                granite_transcribe(
                    context,
                    buffer.baseAddress,
                    sampleCount,
                    { userData in
                        guard let userData else { return false }
                        return userData.assumingMemoryBound(to: GraniteCancellationBridge.self).pointee.isCancelled()
                    },
                    UnsafeMutableRawPointer(bridge)
                )
            }
        }
        switch status {
        case GRANITE_OK: return collectResult()
        case GRANITE_ERR_INVALID_ARGUMENT: throw GraniteContextError.invalidArgument("\(samples.count) samples")
        case GRANITE_ERR_CANCELLED: throw GraniteContextError.cancelled
        case GRANITE_ERR_BACKEND: throw GraniteContextError.backendFailed
        default: throw GraniteContextError.unexpectedStatus(status.rawValue)
        }
    }

    /// Runs `body` over the last successful run's CTC logits, frame-major: `frames` rows of
    /// `vocabularySize` floats, before softmax. Nil when that run produced no frame. No copy: the
    /// buffer is the native one and is valid only inside `body`, since the next run overwrites it.
    public func withLastLogits<Result>(
        _ body: (_ logits: UnsafeBufferPointer<Float>, _ frames: Int) throws -> Result
    ) rethrows -> Result? {
        let frames = Int(granite_n_frames(context))
        guard frames > 0, let pointer = granite_logits(context) else { return nil }
        return try body(UnsafeBufferPointer(start: pointer, count: frames * vocabularySize), frames)
    }

    /// The model's own tokenizer tables, as an encoder: raw vocabulary pieces and BPE merges.
    public func makeEncoder() throws -> GraniteBPEEncoder {
        var pieces: [String] = []
        pieces.reserveCapacity(vocabularySize)
        for id in 0..<vocabularySize {
            var length = 0
            let pointer = granite_vocab_piece(context, Int32(id), &length)
            pieces.append(Self.string(pointer, length))
        }
        let mergeCount = Int(granite_n_merges(context))
        var merges: [String] = []
        merges.reserveCapacity(mergeCount)
        for index in 0..<mergeCount {
            var length = 0
            let pointer = granite_merge(context, Int32(index), &length)
            merges.append(Self.string(pointer, length))
        }
        return try GraniteBPEEncoder(pieces: pieces, merges: merges)
    }

    private static func string(_ pointer: UnsafePointer<CChar>?, _ length: Int) -> String {
        guard let pointer, length > 0 else { return "" }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    private func collectResult() -> GraniteRawResult {
        let count = granite_n_tokens(context)
        var tokens: [GraniteRawToken] = []
        tokens.reserveCapacity(Int(max(0, count)))
        for index in 0..<max(0, count) {
            let token = granite_get_token(context, index)
            var length = 0
            let bytes: [UInt8]
            if let pointer = granite_token_bytes(context, index, &length), length > 0 {
                bytes = Array(UnsafeRawBufferPointer(start: pointer, count: length))
            } else {
                bytes = []
            }
            tokens.append(
                GraniteRawToken(
                    id: token.id,
                    frameBegin: token.frame_begin,
                    frameEnd: token.frame_end,
                    probability: token.p,
                    isSpecial: token.is_special,
                    bytes: bytes
                )
            )
        }
        return GraniteRawResult(tokens: tokens, msPerFrame: msPerFrame, nospeechTokenId: nospeechTokenId)
    }
}

/// Holds the cancellation closure at a stable address for the C callback, which
/// `granite_transcribe` invokes synchronously on the calling thread only.
private struct GraniteCancellationBridge {
    let isCancelled: () -> Bool
}
