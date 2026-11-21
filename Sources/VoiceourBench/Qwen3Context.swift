import CQwen3
import Foundation

enum Qwen3ContextError: Error, CustomStringConvertible {
    case loadFailed(String)
    /// `QWEN3_ERR_INVALID_ARGUMENT`, or a prompt the native call cannot be handed at all.
    case invalidArgument(String)
    /// `QWEN3_ERR_CANCELLED`: the abort callback answered true before a graph evaluation.
    case cancelled
    /// `QWEN3_ERR_BACKEND`: graph construction, allocation or compute failed.
    case backendFailed
    /// A status this build does not know.
    case unexpectedStatus(UInt32)

    var description: String {
        switch self {
        case .loadFailed(let path): return "qwen3_init_from_file failed for \(path)"
        case .invalidArgument(let detail): return "qwen3_generate rejected its input: \(detail)"
        case .cancelled: return "qwen3_generate was cancelled"
        case .backendFailed: return "qwen3_generate failed in the ggml backend"
        case .unexpectedStatus(let status): return "qwen3_generate returned unknown status \(status)"
        }
    }
}

/// One greedy choice of a generation, with the best other token it beat.
struct Qwen3Decision: Equatable {
    var token: Int32
    var runnerUp: Int32
    var logit: Float
    var runnerUpLogit: Float
}

/// One `qwen3_generate` call's results, copied out of the context.
struct Qwen3Generation {
    /// Output tokens, the EOS excluded.
    var tokens: [Int32]
    /// One per output token, plus the EOS choice when generation stopped there.
    var decisions: [Qwen3Decision]
    var prefillMs: Double
    var decodeMs: Double
    /// Decode-loop graph evaluations, drafted tokens fed, drafted tokens kept.
    var evaluations: Int
    var drafted: Int
    var accepted: Int
}

/// Owns one `qwen3_context`: a Qwen3 decoder on the vendored ggml, for the bench-only polish runner.
///
/// `qwen3_generate` replaces the context's previous results, so a context serves one generation at a time; the
/// class is deliberately not `Sendable`.
final class Qwen3Context {
    private let context: OpaquePointer
    let vocabularySize: Int
    let eosTokenId: Int32
    let contextLength: Int
    /// ggml type name of the layer matrices, e.g. `q8_0`.
    let weightType: String
    /// The backend holding the weights and running the graph, e.g. `MTL0`.
    let backendName: String

    init(modelPath: String, useGPU: Bool = true, threadCount: Int32 = 4, contextLength: Int32 = 2048) throws {
        var params = qwen3_context_default_params()
        params.use_gpu = useGPU
        params.n_threads = threadCount
        params.n_ctx = contextLength
        guard let context = qwen3_init_from_file(modelPath, params) else {
            throw Qwen3ContextError.loadFailed(modelPath)
        }
        self.context = context
        vocabularySize = Int(qwen3_n_vocab(context))
        eosTokenId = qwen3_eos_token_id(context)
        self.contextLength = Int(qwen3_n_ctx(context))
        weightType = String(cString: qwen3_weight_type(context))
        backendName = String(cString: qwen3_backend_name(context))
    }

    deinit {
        qwen3_free(context)
    }

    /// The model's own tokenizer tables: every vocabulary piece with its type, and the merges in rank order.
    func makeTokenizer() throws -> Qwen3Tokenizer {
        var tokens: [Qwen3Tokenizer.Token] = []
        tokens.reserveCapacity(vocabularySize)
        for id in 0..<Int32(vocabularySize) {
            var length = 0
            let pointer = qwen3_vocab_piece(context, id, &length)
            let kind = Qwen3Tokenizer.Kind(rawValue: qwen3_vocab_type(context, id)) ?? .unknown
            tokens.append(Qwen3Tokenizer.Token(id: id, piece: Self.string(pointer, length), kind: kind))
        }
        let mergeCount = Int(qwen3_n_merges(context))
        var merges: [Qwen3Tokenizer.Merge] = []
        merges.reserveCapacity(mergeCount)
        for rank in 0..<mergeCount {
            var length = 0
            let pointer = qwen3_merge(context, Int32(rank), &length)
            merges.append(Qwen3Tokenizer.Merge(rank: rank, text: Self.string(pointer, length)))
        }
        return try Qwen3Tokenizer(tokens: tokens, merges: merges)
    }

    /// Greedy generation for `prompt`, with n-gram drafting when `ngram` is given. Cancellation is polled before
    /// every graph evaluation, never inside one.
    func generate(
        prompt: [Int32], maxNewTokens: Int32, ngram: (n: Int32, m: Int32)?, isCancelled: @escaping () -> Bool
    ) throws -> Qwen3Generation {
        guard let promptCount = Int32(exactly: prompt.count) else {
            throw Qwen3ContextError.invalidArgument("\(prompt.count) prompt tokens exceed one native call")
        }
        var params = qwen3_generate_default_params()
        params.max_new_tokens = maxNewTokens
        params.ngram_n = ngram?.n ?? 0
        params.ngram_m = ngram?.m ?? 0
        var cancellation = Qwen3CancellationBridge(isCancelled: isCancelled)
        let status = withUnsafeMutablePointer(to: &cancellation) { bridge in
            prompt.withUnsafeBufferPointer { buffer in
                qwen3_generate(
                    context,
                    buffer.baseAddress,
                    promptCount,
                    params,
                    { userData in
                        guard let userData else { return false }
                        return userData.assumingMemoryBound(to: Qwen3CancellationBridge.self).pointee.isCancelled()
                    },
                    UnsafeMutableRawPointer(bridge)
                )
            }
        }
        switch status {
        case QWEN3_OK: return collectGeneration()
        case QWEN3_ERR_INVALID_ARGUMENT:
            throw Qwen3ContextError.invalidArgument("\(prompt.count) prompt tokens, max \(maxNewTokens) new")
        case QWEN3_ERR_CANCELLED: throw Qwen3ContextError.cancelled
        case QWEN3_ERR_BACKEND: throw Qwen3ContextError.backendFailed
        default: throw Qwen3ContextError.unexpectedStatus(status.rawValue)
        }
    }

    private func collectGeneration() -> Qwen3Generation {
        let count = Int(qwen3_n_output(context))
        var tokens: [Int32] = []
        if count > 0, let pointer = qwen3_output(context) {
            tokens = Array(UnsafeBufferPointer(start: pointer, count: count))
        }
        let decisions = (0..<qwen3_n_decisions(context)).map { index in
            let decision = qwen3_get_decision(context, index)
            return Qwen3Decision(
                token: decision.token,
                runnerUp: decision.runner_up,
                logit: decision.logit,
                runnerUpLogit: decision.runner_up_logit
            )
        }
        let timings = qwen3_get_timings(context)
        return Qwen3Generation(
            tokens: tokens,
            decisions: decisions,
            prefillMs: timings.prefill_ms,
            decodeMs: timings.decode_ms,
            evaluations: Int(timings.n_evals),
            drafted: Int(timings.n_drafted),
            accepted: Int(timings.n_accepted)
        )
    }

    private static func string(_ pointer: UnsafePointer<CChar>?, _ length: Int) -> String {
        guard let pointer, length > 0 else { return "" }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }
}

/// Holds the cancellation closure at a stable address for the C callback, which `qwen3_generate` invokes
/// synchronously on the calling thread only.
private struct Qwen3CancellationBridge {
    let isCancelled: () -> Bool
}
