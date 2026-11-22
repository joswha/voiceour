import Foundation
import Testing

@testable import VoiceourBench

/// `polish --guided`: the candidate contract, the output check and the CLI run on the tokenizer fixture; the decoding
/// itself needs a qwen3 GGUF in `VOICEOUR_QWEN3_MODEL`.
@Suite("Polish guided decoding")
struct PolishGuidedTests {
    // MARK: Candidate contract

    @Test func completionsAreOneSpaceAndTheOutputAndDecodeBackToIt() throws {
        let tokenizer = try Qwen3TokenizerTests.fixtureTokenizer()
        let input = "Okay, test the export."
        let allowed = [input, "Test the export.", "Okay, test the export"]
        let completions = try PolishGuide.completions(
            input: input, allowedOutputs: allowed, tokenizer: tokenizer, maxNewTokens: 512)
        #expect(completions.count == allowed.count)
        for (completion, output) in zip(completions, allowed) {
            #expect(tokenizer.decodeBytes(completion) == Array((" " + output).utf8))
            #expect(completion.allSatisfy(tokenizer.isNormalToken))
        }
    }

    @Test(arguments: [
        ([String](), PolishGuideError.noCandidates),
        (["Test the export."], .missingIdentity),
        (["Okay, test the export.", ""], .emptyCandidate(1)),
        (["Okay, test the export.", " Test the export."], .surroundingWhitespace(1)),
        (["Okay, test the export.", "Test the export.\n"], .surroundingWhitespace(1)),
        (["Okay, test the export.", "Test the export.", "Okay, test the export."], .duplicateCandidate(2)),
        (["Okay, test the export.", "Test <think> the export."], .nonTextToken(1, 151667)),
        (["Okay, test the export.", "Test the cafe\u{301}."], .unstableEncoding(1)),
    ])
    func refusesCandidateListsOutsideTheContract(allowed: [String], error: PolishGuideError) throws {
        let tokenizer = try Qwen3TokenizerTests.fixtureTokenizer()
        #expect(throws: error) {
            try PolishGuide.completions(
                input: "Okay, test the export.", allowedOutputs: allowed, tokenizer: tokenizer, maxNewTokens: 512)
        }
    }

    @Test func boundsTheCandidateCountAndLength() throws {
        let tokenizer = try Qwen3TokenizerTests.fixtureTokenizer()
        let input = "Okay, test the export."
        let many = [input] + (0..<PolishGuide.maxCandidates).map { "Test \($0)." }
        #expect(throws: PolishGuideError.tooManyCandidates(PolishGuide.maxCandidates + 1)) {
            try PolishGuide.completions(input: input, allowedOutputs: many, tokenizer: tokenizer, maxNewTokens: 512)
        }
        let length = tokenizer.encode(" " + input).count
        #expect(throws: PolishGuideError.candidateTooLong(0, tokens: length, limit: length - 1)) {
            try PolishGuide.completions(
                input: input, allowedOutputs: [input], tokenizer: tokenizer, maxNewTokens: Int32(length - 1))
        }
    }

    @Test func requiresTheInputItselfByteForByte() throws {
        let tokenizer = try Qwen3TokenizerTests.fixtureTokenizer()
        // Canonically equal to the decomposed input, so Swift's `==` matches them; the bytes differ.
        let precomposed = "Caf\u{E9} time"
        #expect(throws: PolishGuideError.missingIdentity) {
            try PolishGuide.completions(
                input: "Cafe\u{301} time", allowedOutputs: [precomposed], tokenizer: tokenizer, maxNewTokens: 512)
        }
    }

    // MARK: Output check

    @Test func outputIsTheChosenCandidateByteForByte() throws {
        let tokenizer = try Qwen3TokenizerTests.fixtureTokenizer()
        let input = "Okay, test the export."
        let allowed = [input, "Test the export.", "Okay, test the export"]
        let completions = try PolishGuide.completions(
            input: input, allowedOutputs: allowed, tokenizer: tokenizer, maxNewTokens: 512)
        let output = try PolishGuide.output(
            tokens: completions[1], candidate: 1, completions: completions, allowedOutputs: allowed,
            tokenizer: tokenizer)
        #expect(Array(output.utf8) == Array(allowed[1].utf8))
        #expect(throws: PolishGuideError.outputMismatch(1)) {
            try PolishGuide.output(
                tokens: completions[2], candidate: 1, completions: completions, allowedOutputs: allowed,
                tokenizer: tokenizer)
        }
        #expect(throws: PolishGuideError.outputMismatch(1)) {
            try PolishGuide.output(
                tokens: Array(completions[1].dropLast()), candidate: 1, completions: completions,
                allowedOutputs: allowed, tokenizer: tokenizer)
        }
        #expect(throws: PolishGuideError.outputMismatch(3)) {
            try PolishGuide.output(
                tokens: completions[1], candidate: 3, completions: completions, allowedOutputs: allowed,
                tokenizer: tokenizer)
        }
    }

    // MARK: Command line

    private static let required = ["--input", "/tmp/c.jsonl", "--output", "/tmp/o", "--model", "/tmp/m.gguf"]

    @Test func guidedDecodesWithoutDrafts() throws {
        let unguided = try PolishCommand.parse(Self.required)
        #expect(unguided.guided == nil)
        let batched = try PolishCommand.parse(Self.required + ["--guided"])
        #expect(batched.guided == .batched)
        #expect(batched.ngram == nil)
        let stepwise = try PolishCommand.parse(Self.required + ["--guided", "--guided-stepwise"])
        #expect(stepwise.guided == .stepwise)
        #expect(stepwise.ngram == nil)
        let explicit = try PolishCommand.parse(Self.required + ["--guided", "--no-ngram"])
        #expect(explicit.guided == .batched)
    }

    @Test(arguments: [["--guided-stepwise"], ["--guided", "--ngram-n", "3"], ["--guided", "--ngram-m", "4"]])
    func refusesFlagsGuidedDecodingCannotHonour(flags: [String]) {
        #expect(throws: BenchError.self) {
            try PolishCommand.parse(Self.required + flags)
        }
    }

    // MARK: Reports

    private static var generation: Qwen3Generation {
        Qwen3Generation(
            tokens: [7, 10, 11], decisions: [], prefillMs: 1, decodeMs: 2, evaluations: 1, drafted: 0, accepted: 0)
    }

    private static func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func unguidedRowsAndNotesKeepTheirSchema() throws {
        let plain = PolishResult(output: "Done.", ms: 3, prompt: [1, 2], generation: Self.generation)
        let row = try Self.object(PolishRow(id: "A01", runs: [plain]))
        let unguidedKeys: Set = [
            "id", "output", "ms", "ms_all", "prompt_tokens", "output_tokens", "prefill_ms", "decode_ms",
        ]
        #expect(Set(row.keys) == unguidedKeys)
        let notes = PolishNotes(
            cases: "cases.jsonl", reps: 1, maxNewTokens: 512, ngramN: 2, ngramM: 8, contextLength: 2048,
            threadCount: 4, specStats: PolishSpecStats(firstRuns: [plain]), warmup: [])
        #expect(try Self.object(notes)["guided"] == nil)
    }

    @Test func guidedRowsAndTracesReportTheChoice() throws {
        let steps = [
            Qwen3GuidedStep(
                position: 0, optionCount: 2, token: 7, runnerUp: 8, unconstrainedToken: 9, logit: 3, runnerUpLogit: 1,
                unconstrainedLogit: 4),
            Qwen3GuidedStep(
                position: 3, optionCount: 1, token: 151643, runnerUp: -1, unconstrainedToken: 151643, logit: 5,
                runnerUpLogit: -.infinity, unconstrainedLogit: 5),
        ]
        let run = PolishResult(
            output: "Done.", ms: 3, prompt: [1, 2], generation: Self.generation,
            guided: PolishGuidedRun(candidate: 1, completions: [[7, 7, 7], [7, 10, 11]], steps: steps))
        let row = try Self.object(PolishRow(id: "A01", runs: [run]))
        #expect(row["candidate"] as? Int == 1)
        #expect(row["candidates"] as? Int == 2)
        #expect(row["guided_steps"] as? Int == 2)
        #expect(row["overridden_steps"] as? Int == 1)
        #expect(row["min_margin"] as? Double == 2)
        let trace = try Self.object(PolishTrace(id: "A01", run: run))
        #expect(trace["candidate_ids"] as? [[Int]] == [[7, 7, 7], [7, 10, 11]])
        let traced = try #require(trace["guided_steps"] as? [[String: Any]])
        #expect(traced.count == 2)
        #expect(traced[0]["runner_up"] as? Int == 8)
        #expect(traced[1]["runner_up"] == nil)
        #expect(traced[1]["runner_up_logit"] == nil)
    }

    // MARK: Model

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["VOICEOUR_QWEN3_MODEL"] != nil,
            "set VOICEOUR_QWEN3_MODEL to a qwen3 polish GGUF"))
    func decodesOnlyCandidatesOnTheModel() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOICEOUR_QWEN3_MODEL"])
        let context = try Qwen3Context(modelPath: path)
        let tokenizer = try context.makeTokenizer()
        let eos = context.eosTokenId
        // Token-level fixtures only: these candidates are not claimed to be safe edits.
        let input = "Okay so, like, test the export, you know, before the release."
        let allowed = [
            input, "So, like, test the export before the release.", "Test the export before the release.",
            "Okay so, like, test the export, you know, before the release",
        ]
        let completions = try PolishGuide.completions(
            input: input, allowedOutputs: allowed, tokenizer: tokenizer, maxNewTokens: 512)
        let prompt = tokenizer.encode("text: " + input + "\nout:")

        for batched in [true, false] {
            let generation = try context.generateGuided(
                prompt: prompt, candidates: completions, maxNewTokens: 512, batchesForcedTokens: batched,
                isCancelled: { false })
            let output = try PolishGuide.output(
                tokens: generation.tokens, candidate: generation.candidate, completions: completions,
                allowedOutputs: allowed, tokenizer: tokenizer)
            #expect(Array(output.utf8) == Array(allowed[generation.candidate].utf8))
            #expect(generation.evaluations == generation.steps.count - 1)
            #expect(zip(generation.steps, generation.steps.dropFirst()).allSatisfy { $0.position < $1.position })
            for step in generation.steps {
                let expected = step.position < generation.tokens.count ? generation.tokens[step.position] : eos
                #expect(step.token == expected)
                #expect(step.optionCount >= 1)
            }
            if !batched {
                #expect(generation.steps.map(\.position) == Array(0...generation.tokens.count))
            }
        }

        // One candidate leaves nothing to choose: the root step is forced and no decode evaluation runs.
        let single = try context.generateGuided(
            prompt: prompt, candidates: [completions[0]], maxNewTokens: 512, batchesForcedTokens: true,
            isCancelled: { false })
        #expect(single.candidate == 0)
        #expect(single.tokens == completions[0])
        #expect(single.steps.map(\.optionCount) == [1])
        #expect(single.evaluations == 0)

        // Stepwise guided decoding is unguided greedy decoding whenever greedy's own output is a candidate.
        let greedy = try context.generate(prompt: prompt, maxNewTokens: 512, ngram: nil, isCancelled: { false })
        let greedyBytes = tokenizer.decodeBytes(greedy.tokens)
        let greedyText = String(decoding: PolishCommand.trimmed(greedyBytes), as: UTF8.self)
        let pairOutputs = greedyText == input ? [input] : [input, greedyText]
        if greedy.decisions.count == greedy.tokens.count + 1, greedyBytes == Array((" " + greedyText).utf8),
            let pair = try? PolishGuide.completions(
                input: input, allowedOutputs: pairOutputs, tokenizer: tokenizer, maxNewTokens: 512),
            pair.last == greedy.tokens
        {
            let guided = try context.generateGuided(
                prompt: prompt, candidates: pair, maxNewTokens: 512, batchesForcedTokens: false,
                isCancelled: { false })
            #expect(guided.tokens == greedy.tokens)
            #expect(guided.steps.allSatisfy { $0.token == $0.unconstrainedToken })
        }

        // The native call refuses what it cannot decode, then serves the next valid request.
        let special = try #require(
            (0..<Int32(context.vocabularySize)).last { !tokenizer.isNormalToken($0) && $0 != eos })
        let refused: [(candidates: [[Int32]], maxNewTokens: Int32)] = [
            ([], 512),
            ([[]], 512),
            ([[eos]], 512),
            ([[special]], 512),
            ([[-1]], 512),
            ([[Int32(context.vocabularySize)]], 512),
            ([completions[0], completions[0]], 512),
            ([completions[0]], Int32(completions[0].count - 1)),
        ]
        for request in refused {
            #expect(throws: Qwen3ContextError.self) {
                try context.generateGuided(
                    prompt: prompt, candidates: request.candidates, maxNewTokens: request.maxNewTokens,
                    batchesForcedTokens: true, isCancelled: { false })
            }
        }
        let recovered = try context.generateGuided(
            prompt: prompt, candidates: completions, maxNewTokens: 512, batchesForcedTokens: true,
            isCancelled: { false })
        #expect(completions.indices.contains(recovered.candidate))
    }
}
