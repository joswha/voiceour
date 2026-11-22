import Foundation

/// `polish --guided`: how guided decoding feeds tokens that are their trie node's only option.
enum PolishGuidedMode: String {
    /// Forced tokens are appended without reading their logits and fed together (`batch_forced`).
    case batched
    /// One token per evaluation: every token and the EOS are chosen from their own logits.
    case stepwise

    /// The `summary.json` config name when `--config` is not given.
    var config: String { self == .batched ? "guided" : "guided-stepwise" }
}

/// The `--guided` data contract: each case's `allowed_outputs` become the token sequences decoding may produce.
///
/// An allowed output is a final output as `rows.jsonl` reports it: nonempty, without the harness's six ASCII
/// whitespace bytes at either end. The model's completion for it is one space (U+0020) followed by the output, the
/// training completion `" " + target`, encoded by the model's tokenizer as that text alone, then the EOS; trimming
/// the completion gives the output back byte for byte. The input itself, byte for byte, must be one of the outputs,
/// so decoding can always leave the text unchanged. Every check here is token-level: nothing judges whether an
/// output is a safe edit of its input. The policy that wrote the list owns that.
enum PolishGuide {
    /// The most allowed outputs one case may list.
    static let maxCandidates = 128

    /// The completion tokens of each of `allowedOutputs`, in order.
    ///
    /// - Throws: `PolishGuideError` when the list is empty, longer than `maxCandidates` or lacks the input, or when
    ///   an output is empty, has surrounding ASCII whitespace, repeats an earlier one, encodes to a token that is not
    ///   plain text, does not decode back to its own bytes (text that NFC changes), or needs more than
    ///   `maxNewTokens` tokens.
    static func completions(
        input: String, allowedOutputs: [String], tokenizer: Qwen3Tokenizer, maxNewTokens: Int32
    ) throws -> [[Int32]] {
        guard !allowedOutputs.isEmpty else { throw PolishGuideError.noCandidates }
        guard allowedOutputs.count <= maxCandidates else {
            throw PolishGuideError.tooManyCandidates(allowedOutputs.count)
        }
        var seen = Set<[UInt8]>()
        var completions: [[Int32]] = []
        completions.reserveCapacity(allowedOutputs.count)
        for (index, output) in allowedOutputs.enumerated() {
            let bytes = Array(output.utf8)
            guard !bytes.isEmpty else { throw PolishGuideError.emptyCandidate(index) }
            guard PolishCommand.trimmed(bytes).count == bytes.count else {
                throw PolishGuideError.surroundingWhitespace(index)
            }
            guard seen.insert(bytes).inserted else { throw PolishGuideError.duplicateCandidate(index) }
            let ids = tokenizer.encode(" " + output)
            if let id = ids.first(where: { !tokenizer.isNormalToken($0) }) {
                throw PolishGuideError.nonTextToken(index, id)
            }
            guard tokenizer.decodeBytes(ids) == [0x20] + bytes else {
                throw PolishGuideError.unstableEncoding(index)
            }
            guard ids.count <= Int(maxNewTokens) else {
                throw PolishGuideError.candidateTooLong(index, tokens: ids.count, limit: Int(maxNewTokens))
            }
            completions.append(ids)
        }
        guard seen.contains(Array(input.utf8)) else { throw PolishGuideError.missingIdentity }
        return completions
    }

    /// The text a guided generation emitted: `tokens`, which must be candidate `candidate`'s completion, decoded and
    /// trimmed, after checking that it equals `allowedOutputs[candidate]` byte for byte.
    static func output(
        tokens: [Int32], candidate: Int, completions: [[Int32]], allowedOutputs: [String], tokenizer: Qwen3Tokenizer
    ) throws -> String {
        guard completions.count == allowedOutputs.count, completions.indices.contains(candidate),
            tokens == completions[candidate]
        else {
            throw PolishGuideError.outputMismatch(candidate)
        }
        let expected = Array(allowedOutputs[candidate].utf8)
        let raw = tokenizer.decodeBytes(tokens)
        let output = PolishCommand.trimmed(raw)
        guard raw == [0x20] + expected, output.elementsEqual(expected) else {
            throw PolishGuideError.outputMismatch(candidate)
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Why a guided case cannot be decoded; indices are 0-based positions in its `allowed_outputs`.
enum PolishGuideError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case noCandidates
    case tooManyCandidates(Int)
    case missingIdentity
    case emptyCandidate(Int)
    case surroundingWhitespace(Int)
    case duplicateCandidate(Int)
    case nonTextToken(Int, Int32)
    case unstableEncoding(Int)
    case candidateTooLong(Int, tokens: Int, limit: Int)
    /// Decoding emitted something other than the candidate it reported; never expected.
    case outputMismatch(Int)

    var description: String {
        switch self {
        case .noCandidates:
            return "allowed_outputs is empty"
        case .tooManyCandidates(let count):
            return "allowed_outputs lists \(count) outputs, more than \(PolishGuide.maxCandidates)"
        case .missingIdentity:
            return "allowed_outputs lacks the input itself, byte for byte"
        case .emptyCandidate(let index):
            return "allowed_outputs[\(index)] is empty"
        case .surroundingWhitespace(let index):
            return "allowed_outputs[\(index)] starts or ends with ASCII whitespace"
        case .duplicateCandidate(let index):
            return "allowed_outputs[\(index)] repeats an earlier output"
        case .nonTextToken(let index, let id):
            return "allowed_outputs[\(index)] encodes to token \(id), which is not plain text"
        case .unstableEncoding(let index):
            return "allowed_outputs[\(index)] does not decode back to its own bytes; is it NFC?"
        case .candidateTooLong(let index, let tokens, let limit):
            return "allowed_outputs[\(index)] needs \(tokens) tokens, more than --max-new-tokens \(limit)"
        case .outputMismatch(let index):
            return "guided decoding emitted something other than allowed_outputs[\(index)]"
        }
    }

    var errorDescription: String? { description }
}

/// One guided request's evidence beside its output.
struct PolishGuidedRun {
    /// Index of the chosen output in the case's `allowed_outputs`.
    var candidate: Int
    /// Every allowed output's completion tokens, in order.
    var completions: [[Int32]]
    var steps: [Qwen3GuidedStep]

    /// Steps whose unconstrained argmax was not an allowed option: the constraint changed the model's choice there.
    var overriddenSteps: Int { steps.count(where: { $0.token != $0.unconstrainedToken }) }

    /// The smallest gap between the chosen option's logit and the best other allowed option's, over steps with more
    /// than one option; nil when no step had a choice.
    var minimumMargin: Double? {
        steps.lazy.filter { $0.optionCount > 1 }.map { Double($0.logit) - Double($0.runnerUpLogit) }.min()
    }
}

/// `summary.json` `notes.guided`: how guided decoding ran, with totals over every case's first repetition.
struct PolishGuidedNotes: Encodable {
    var mode: String
    var completion = "\" \" + allowed output, encoded alone by the model's tokenizer, then the EOS"
    var choice =
        "highest logit among the trie node's allowed tokens, the EOS only where an allowed output ends; "
        + "lowest id on ties"
    var maxCandidates = PolishGuide.maxCandidates
    var warmup = "each warm-up text decoded stepwise with allowed_outputs [text]"
    var timing = "ms covers prompt and candidate encoding and checks, the trie, decoding and the output check"
    var steps: Int
    var overriddenSteps: Int

    init(mode: PolishGuidedMode, firstRuns: [PolishGuidedRun]) {
        self.mode = mode.rawValue
        steps = firstRuns.reduce(0) { $0 + $1.steps.count }
        overriddenSteps = firstRuns.reduce(0) { $0 + $1.overriddenSteps }
    }

    enum CodingKeys: String, CodingKey {
        case mode, completion, choice, warmup, timing, steps
        case maxCandidates = "max_candidates"
        case overriddenSteps = "overridden_steps"
    }
}

/// One `trace.jsonl` guided step; `runner_up` and `runner_up_logit` are absent when the step had one option.
struct PolishTraceStep: Encodable {
    var position: Int
    var options: Int
    var token: Int32
    var runnerUp: Int32?
    var unconstrainedToken: Int32
    var logit: Double
    var runnerUpLogit: Double?
    var unconstrainedLogit: Double

    init(_ step: Qwen3GuidedStep) {
        position = step.position
        options = step.optionCount
        token = step.token
        runnerUp = step.runnerUp >= 0 ? step.runnerUp : nil
        unconstrainedToken = step.unconstrainedToken
        logit = Double(step.logit)
        runnerUpLogit = step.runnerUp >= 0 ? Double(step.runnerUpLogit) : nil
        unconstrainedLogit = Double(step.unconstrainedLogit)
    }

    enum CodingKeys: String, CodingKey {
        case position, options, token, logit
        case runnerUp = "runner_up"
        case unconstrainedToken = "unconstrained_token"
        case runnerUpLogit = "runner_up_logit"
        case unconstrainedLogit = "unconstrained_logit"
    }
}
