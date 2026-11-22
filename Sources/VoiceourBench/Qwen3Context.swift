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
    var hintStats: qwen3_hint_stats? = nil
}

/// One choice of a guided generation read from logits (`qwen3_guided_step`).
struct Qwen3GuidedStep: Equatable {
    /// Output index the step chose; the output length for the EOS.
    var position: Int
    /// Allowed options at the step's trie node, the EOS included where a candidate ends.
    var optionCount: Int
    var token: Int32
    /// The best other allowed option; -1 when `optionCount == 1`.
    var runnerUp: Int32
    /// The argmax over the whole vocabulary: what unconstrained greedy decoding picks from the same logits.
    var unconstrainedToken: Int32
    var logit: Float
    /// `-infinity` when `runnerUp == -1`.
    var runnerUpLogit: Float
    var unconstrainedLogit: Float
}

/// One `qwen3_generate_guided` call's results, copied out of the context.
struct Qwen3GuidedGeneration {
    /// The chosen candidate's tokens, the EOS excluded.
    var tokens: [Int32]
    /// Index of the chosen candidate.
    var candidate: Int
    /// Every choice read from logits; tokens without a step were their node's only option.
    var steps: [Qwen3GuidedStep]
    var prefillMs: Double
    var decodeMs: Double
    /// Decode-loop graph evaluations.
    var evaluations: Int
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

    /// Greedy generation for `prompt`. An optional untrusted hint proposes tokens before n-gram fallback.
    /// Cancellation is polled before every graph evaluation, never inside one.
    func generate(
        prompt: [Int32], maxNewTokens: Int32, ngram: (n: Int32, m: Int32)?,
        hint: (tokens: [Int32], batch: Int32)? = nil, isCancelled: @escaping () -> Bool
    ) throws -> Qwen3Generation {
        guard let promptCount = Int32(exactly: prompt.count) else {
            throw Qwen3ContextError.invalidArgument("\(prompt.count) prompt tokens exceed one native call")
        }
        var params = qwen3_generate_default_params()
        params.max_new_tokens = maxNewTokens
        params.ngram_n = ngram?.n ?? 0
        params.ngram_m = ngram?.m ?? 0
        var cancellation = Qwen3CancellationBridge(isCancelled: isCancelled)
        var hintStats = qwen3_hint_stats()
        let callback: qwen3_abort_callback = { userData in
            guard let userData else { return false }
            return userData.assumingMemoryBound(to: Qwen3CancellationBridge.self).pointee.isCancelled()
        }
        let status = withUnsafeMutablePointer(to: &cancellation) { bridge in
            prompt.withUnsafeBufferPointer { buffer in
                if let hint {
                    return hint.tokens.withUnsafeBufferPointer { draft in
                        qwen3_generate_with_hint(
                            context, buffer.baseAddress, promptCount, params, draft.baseAddress,
                            Int32(draft.count), hint.batch, &hintStats, callback, UnsafeMutableRawPointer(bridge))
                    }
                }
                return qwen3_generate(context, buffer.baseAddress, promptCount, params, callback, bridge)
            }
        }
        try check(status) { "\(prompt.count) prompt tokens, max \(maxNewTokens) new" }
        var generation = collectGeneration()
        generation.hintStats = hint == nil ? nil : hintStats
        return generation
    }

    /// Greedy generation for `prompt` restricted to `candidates`, each a nonempty token sequence, as
    /// `qwen3_generate_guided` describes. With `batchesForcedTokens`, tokens that are their trie node's only option
    /// are fed together without reading their logits; without it every token is chosen from its own evaluation.
    /// Cancellation is polled before every graph evaluation, never inside one.
    func generateGuided(
        prompt: [Int32], candidates: [[Int32]], maxNewTokens: Int32, batchesForcedTokens: Bool,
        isCancelled: @escaping () -> Bool
    ) throws -> Qwen3GuidedGeneration {
        guard let promptCount = Int32(exactly: prompt.count) else {
            throw Qwen3ContextError.invalidArgument("\(prompt.count) prompt tokens exceed one native call")
        }
        guard let candidateCount = Int32(exactly: candidates.count) else {
            throw Qwen3ContextError.invalidArgument("\(candidates.count) guided candidates exceed one native call")
        }
        var lengths: [Int32] = []
        lengths.reserveCapacity(candidates.count)
        var tokens: [Int32] = []
        tokens.reserveCapacity(candidates.reduce(0) { $0 + $1.count })
        for candidate in candidates {
            guard let length = Int32(exactly: candidate.count) else {
                throw Qwen3ContextError.invalidArgument("a \(candidate.count)-token candidate exceeds one native call")
            }
            lengths.append(length)
            tokens.append(contentsOf: candidate)
        }
        var params = qwen3_guided_default_params()
        params.max_new_tokens = maxNewTokens
        params.batch_forced = batchesForcedTokens
        var cancellation = Qwen3CancellationBridge(isCancelled: isCancelled)
        let status = withUnsafeMutablePointer(to: &cancellation) { bridge in
            prompt.withUnsafeBufferPointer { promptBuffer in
                tokens.withUnsafeBufferPointer { tokenBuffer in
                    lengths.withUnsafeBufferPointer { lengthBuffer in
                        qwen3_generate_guided(
                            context,
                            promptBuffer.baseAddress,
                            promptCount,
                            tokenBuffer.baseAddress,
                            lengthBuffer.baseAddress,
                            candidateCount,
                            params,
                            { userData in
                                guard let userData else { return false }
                                let holder = userData.assumingMemoryBound(to: Qwen3CancellationBridge.self)
                                return holder.pointee.isCancelled()
                            },
                            UnsafeMutableRawPointer(bridge)
                        )
                    }
                }
            }
        }
        try check(status) {
            "\(prompt.count) prompt tokens, \(candidates.count) guided candidates, max \(maxNewTokens) new"
        }
        let steps = (0..<qwen3_n_guided_steps(context)).map { index in
            let step = qwen3_get_guided_step(context, index)
            return Qwen3GuidedStep(
                position: Int(step.position),
                optionCount: Int(step.n_options),
                token: step.token,
                runnerUp: step.runner_up,
                unconstrainedToken: step.unconstrained_token,
                logit: step.logit,
                runnerUpLogit: step.runner_up_logit,
                unconstrainedLogit: step.unconstrained_logit
            )
        }
        let timings = qwen3_get_timings(context)
        return Qwen3GuidedGeneration(
            tokens: outputTokens(),
            candidate: Int(qwen3_guided_candidate(context)),
            steps: steps,
            prefillMs: timings.prefill_ms,
            decodeMs: timings.decode_ms,
            evaluations: Int(timings.n_evals)
        )
    }

    /// Maps a native status to success or the matching error; `detail` describes an invalid-argument request.
    private func check(_ status: qwen3_status, invalidArgument detail: () -> String) throws {
        switch status {
        case QWEN3_OK: return
        case QWEN3_ERR_INVALID_ARGUMENT: throw Qwen3ContextError.invalidArgument(detail())
        case QWEN3_ERR_CANCELLED: throw Qwen3ContextError.cancelled
        case QWEN3_ERR_BACKEND: throw Qwen3ContextError.backendFailed
        default: throw Qwen3ContextError.unexpectedStatus(status.rawValue)
        }
    }

    /// The last call's output tokens, the EOS excluded.
    private func outputTokens() -> [Int32] {
        let count = Int(qwen3_n_output(context))
        guard count > 0, let pointer = qwen3_output(context) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func collectGeneration() -> Qwen3Generation {
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
            tokens: outputTokens(),
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
