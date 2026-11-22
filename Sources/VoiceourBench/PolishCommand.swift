import CGgml
import CQwen3
import Darwin
import Foundation
import IOKit.ps

/// Bench-only probe of a local polish pass: a Qwen3 GGUF decoded in-process on the vendored ggml (`CQwen3`).
///
/// It follows the polish-lab runtime harness contract: the prompt is `"text: " + input + "\nout:"` with no BOS
/// and no chat template, decoding is greedy and stops at the EOS, and the output is the decoded text with ASCII
/// whitespace trimmed. One process loads the model (`load_ms` counts from process start), runs two warm-ups,
/// then `reps` repetitions over every case, rep-major. A request's `ms` runs from the input string to the
/// trimmed output string. Nothing here ships in the app or the sidecar.
///
/// With `--guided`, every case also lists `allowed_outputs` and decoding is greedy over those candidates only, as
/// `PolishGuide` and `qwen3_generate_guided` describe: each output is one of them byte for byte, n-gram drafting
/// is off, and a request's `ms` also covers encoding and checking the candidates.
/// `--draft-text-m` instead takes optional, untrusted `draft_text` proposals and keeps full-vocabulary greedy.
struct PolishCommand {
    /// Batch measurement writes files; standard I/O returns one reply per request from a single loaded model.
    enum IO {
        case files(input: URL, output: URL)
        case standard
    }

    var io: IO
    var model: URL
    /// n-gram drafting (lookup length, draft length); nil decodes one token per evaluation.
    var ngram: (n: Int32, m: Int32)?
    /// Guided decoding over each case's `allowed_outputs`; nil decodes unguided.
    var guided: PolishGuidedMode?
    /// Maximum number of proposed draft-text tokens per verification batch; nil ignores draft text entirely.
    var draftTextBatch: Int32?
    var reps: Int
    var maxNewTokens: Int32
    var trace: Bool
    var config: String?
    var modelRepo: String?
    var modelRevision: String?

    static let warmups = ["Okay so, like, test.", "Send it to Sarah, no wait, to Morgan."]
    static let contextLength: Int32 = 2048
    static let threadCount: Int32 = 4

    static func parse(_ arguments: [String]) throws -> PolishCommand {
        var input: URL?
        var output: URL?
        var standardIO = false
        var model: URL?
        var ngramN: Int32?
        var ngramM: Int32?
        var noNgram = false
        var guided = false
        var draftTextBatch: Int32?
        var stepwise = false
        var reps: Int?
        var maxNewTokens: Int32 = 512
        var trace = false
        var config: String?
        var modelRepo: String?
        var modelRevision: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--input": input = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--output": output = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--model": model = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--stdio": standardIO = true
            case "--ngram-n": ngramN = try positive(parsed, arguments, &index)
            case "--ngram-m": ngramM = try positive(parsed, arguments, &index)
            case "--no-ngram": noNgram = true
            case "--guided": guided = true
            case "--guided-stepwise": stepwise = true
            case "--draft-text-m": draftTextBatch = try positive(parsed, arguments, &index)
            case "--reps": reps = Int(try positive(parsed, arguments, &index))
            case "--max-new-tokens": maxNewTokens = try positive(parsed, arguments, &index)
            case "--trace": trace = true
            case "--config": config = try BenchCLI.value(for: parsed, in: arguments, index: &index)
            case "--model-repo": modelRepo = try BenchCLI.value(for: parsed, in: arguments, index: &index)
            case "--model-revision": modelRevision = try BenchCLI.value(for: parsed, in: arguments, index: &index)
            default: throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }
        guard let model else { throw BenchError.usage("polish requires --model") }
        let io: IO
        if standardIO {
            guard input == nil, output == nil, reps == nil, !trace, !guided, config == nil,
                modelRepo == nil, modelRevision == nil
            else {
                throw BenchError.usage("--stdio excludes file, repetition, trace, guided and report options")
            }
            io = .standard
        } else {
            guard let input, let output else {
                throw BenchError.usage("polish requires --input and --output or --stdio")
            }
            io = .files(input: input, output: output)
        }
        if noNgram, ngramN != nil || ngramM != nil {
            throw BenchError.usage("--no-ngram excludes --ngram-n and --ngram-m")
        }
        if stepwise, !guided {
            throw BenchError.usage("--guided-stepwise requires --guided")
        }
        if guided, ngramN != nil || ngramM != nil {
            throw BenchError.usage("--guided decodes without n-gram drafts; it excludes --ngram-n and --ngram-m")
        }
        if let draftTextBatch {
            guard !guided else { throw BenchError.usage("--draft-text-m excludes --guided") }
            guard draftTextBatch <= QWEN3_MAX_HINT_BATCH else {
                throw BenchError.usage("--draft-text-m must be at most \(QWEN3_MAX_HINT_BATCH)")
            }
        }
        let defaults = qwen3_generate_default_params()
        return PolishCommand(
            io: io,
            model: model,
            ngram: noNgram || guided ? nil : (ngramN ?? defaults.ngram_n, ngramM ?? defaults.ngram_m),
            guided: guided ? (stepwise ? .stepwise : .batched) : nil,
            draftTextBatch: draftTextBatch,
            reps: reps ?? 3,
            maxNewTokens: maxNewTokens,
            trace: trace,
            config: config,
            modelRepo: modelRepo,
            modelRevision: modelRevision
        )
    }

    private static func positive(
        _ parsed: (name: String, inlineValue: String?), _ arguments: [String], _ index: inout Int
    ) throws -> Int32 {
        let value = try BenchCLI.value(for: parsed, in: arguments, index: &index)
        guard let number = Int32(value), number > 0 else {
            throw BenchError.usage("\(parsed.name) must be a positive integer")
        }
        return number
    }

    func run() throws {
        switch io {
        case .files(let input, let output):
            try runBenchmark(input: input, output: output)
        case .standard:
            let runner = try makeRunner()
            try PolishPipe.serve(readsDraft: draftTextBatch != nil, process: runner.polish)
        }
    }

    private func makeRunner() throws -> Runner {
        let context = try Qwen3Context(
            modelPath: model.path, threadCount: Self.threadCount, contextLength: Self.contextLength)
        return try Runner(
            context: context, tokenizer: context.makeTokenizer(), ngram: ngram, maxNewTokens: maxNewTokens,
            guided: guided, draftTextBatch: draftTextBatch)
    }

    private func runBenchmark(input: URL, output: URL) throws {
        let processStart = Self.processStartTime()
        let cases = try readCases(from: input)
        let powerBefore = PowerSnapshot.current()

        let runner = try makeRunner()
        let context = runner.context
        let loadMs = Self.milliseconds(since: processStart)
        if guided != nil {
            // Every case's candidates are checked before the first timed request.
            for polishCase in cases {
                do {
                    _ = try PolishGuide.completions(
                        input: polishCase.input, allowedOutputs: polishCase.allowedOutputs ?? [],
                        tokenizer: runner.tokenizer, maxNewTokens: maxNewTokens)
                } catch {
                    throw BenchError.io("guided case \(polishCase.id): \(error)")
                }
            }
        }

        var warmups: [PolishWarmup] = []
        for text in Self.warmups {
            // A guided warm-up allows only the text itself and runs stepwise, so the single-token graphs a guided
            // run needs have run once too, not only the prompt-sized ones.
            let result: PolishResult
            if guided == nil {
                result = try runner.polish(text)
            } else {
                result = try runner.polishGuided(text, allowedOutputs: [text], mode: .stepwise)
            }
            warmups.append(PolishWarmup(input: text, output: result.output, ms: result.ms))
        }

        var results = Array(repeating: [PolishResult](), count: cases.count)
        for _ in 0..<reps {
            for (index, polishCase) in cases.enumerated() {
                results[index].append(try runner.polish(polishCase))
            }
        }
        let peakFootprintMb = Self.peakFootprintMb()
        let powerAfter = PowerSnapshot.current()

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rows = zip(cases, results).map { polishCase, runs in PolishRow(id: polishCase.id, runs: runs) }
        try Self.writeLines(rows, to: output.appendingPathComponent("rows.jsonl"))
        if trace {
            let traces = zip(cases, results).map { polishCase, runs in PolishTrace(id: polishCase.id, run: runs[0]) }
            try Self.writeLines(traces, to: output.appendingPathComponent("trace.jsonl"))
        }

        let summary = PolishSummary(
            config: config ?? guided?.config ?? draftTextBatch.map { "draft-text-m\($0)" }
                ?? ngram.map { "ngram-n\($0.n)-m\($0.m)" } ?? "no-ngram",
            modelRepo: modelRepo,
            modelRevision: modelRevision,
            weightsFile: model.path,
            weightsSHA256: try BenchRunner.sha256(of: model),
            quantization: context.weightType.uppercased(),
            computeDevice: Self.computeDevice(backend: context.backendName),
            loadMs: Self.round1(loadMs),
            firstRequestMs: Self.round1(warmups[0].ms),
            rows: rows,
            peakFootprintMb: peakFootprintMb,
            deterministic: results.allSatisfy { runs in
                runs.allSatisfy {
                    $0.output.utf8.elementsEqual(runs[0].output.utf8)
                        && $0.generation.tokens == runs[0].generation.tokens
                        && $0.generation.decisions.elementsEqual(runs[0].generation.decisions) { $0.token == $1.token }
                }
            },
            power: PolishPower(before: powerBefore, after: powerAfter),
            versions: PolishVersions(
                ggml: String(cString: ggml_version()),
                ggmlCommit: String(cString: ggml_commit()),
                macOS: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            notes: PolishNotes(
                cases: input.path,
                reps: reps,
                maxNewTokens: Int(maxNewTokens),
                ngramN: ngram.map { Int($0.n) },
                ngramM: ngram.map { Int($0.m) },
                contextLength: context.contextLength,
                threadCount: Int(Self.threadCount),
                specStats: PolishSpecStats(firstRuns: results.map { $0[0] }),
                warmup: warmups,
                guided: guided.map { mode in
                    PolishGuidedNotes(mode: mode, firstRuns: results.compactMap { $0[0].guided })
                },
                draftTextBatch: draftTextBatch
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(summary)
        data.append(0x0A)
        try data.write(to: output.appendingPathComponent("summary.json"))
        print(
            "polish \(summary.config): \(rows.count) cases x \(reps) reps, load \(summary.loadMs) ms, "
                + "p50 \(summary.p50Ms) ms, p95 \(summary.p95Ms) ms, max \(summary.maxMs) ms, "
                + "peak footprint \(peakFootprintMb.map { "\($0) MB" } ?? "unknown"), "
                + "deterministic \(summary.deterministic) -> \(output.path)"
        )
    }

    private func readCases(from input: URL) throws -> [PolishCase] {
        let reader = try JSONLLineReader(url: input)
        let decoder = JSONDecoder()
        decoder.userInfo[PolishCase.readDraftText] = draftTextBatch != nil
        var cases: [PolishCase] = []
        var lineNumber = 0
        while let line = try reader.nextLine() {
            lineNumber += 1
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let polishCase: PolishCase
            do {
                polishCase = try decoder.decode(PolishCase.self, from: Data(line.utf8))
            } catch {
                throw BenchError.malformedInput(line: lineNumber, detail: BenchError.describe(error))
            }
            if guided != nil, polishCase.allowedOutputs == nil {
                throw BenchError.malformedInput(line: lineNumber, detail: "--guided needs allowed_outputs")
            }
            cases.append(polishCase)
        }
        guard !cases.isEmpty else { throw BenchError.io("no cases in \(input.path)") }
        return cases
    }

    /// One request: prompt, greedy generation, decode, trim, timed end to end.
    struct Runner {
        let context: Qwen3Context
        let tokenizer: Qwen3Tokenizer
        let ngram: (n: Int32, m: Int32)?
        let maxNewTokens: Int32
        let guided: PolishGuidedMode?
        let draftTextBatch: Int32?

        /// One request for `polishCase`: guided over its `allowed_outputs` when the runner is guided.
        func polish(_ polishCase: PolishCase) throws -> PolishResult {
            guard let guided else { return try polish(polishCase.input, draftText: polishCase.draftText) }
            return try polishGuided(polishCase.input, allowedOutputs: polishCase.allowedOutputs ?? [], mode: guided)
        }

        func polish(_ input: String, draftText: String? = nil) throws -> PolishResult {
            let start = DispatchTime.now().uptimeNanoseconds
            let prompt = tokenizer.encode("text: " + input + "\nout:")
            var hint: (tokens: [Int32], batch: Int32)?
            var encodingMs: Double?
            if let draftTextBatch {
                let encodeStart = DispatchTime.now().uptimeNanoseconds
                let ids = draftText.map { tokenizer.encode(" " + $0) } ?? []
                hint = (ids.count <= QWEN3_MAX_HINT_TOKENS ? ids : [], draftTextBatch)
                encodingMs = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1_000_000
            }
            let generation = try context.generate(
                prompt: prompt, maxNewTokens: maxNewTokens, ngram: ngram, hint: hint, isCancelled: { false })
            let output = String(
                decoding: PolishCommand.trimmed(tokenizer.decodeBytes(generation.tokens)), as: UTF8.self)
            let end = DispatchTime.now().uptimeNanoseconds
            return PolishResult(
                output: output,
                ms: Double(end - start) / 1_000_000,
                prompt: prompt,
                generation: generation,
                hintEncodingMs: encodingMs
            )
        }

        /// One guided request: prompt and candidate encoding and checks, constrained greedy generation, and the
        /// output checked against the chosen candidate byte for byte, timed end to end.
        func polishGuided(_ input: String, allowedOutputs: [String], mode: PolishGuidedMode) throws -> PolishResult {
            let start = DispatchTime.now().uptimeNanoseconds
            let prompt = tokenizer.encode("text: " + input + "\nout:")
            let completions = try PolishGuide.completions(
                input: input, allowedOutputs: allowedOutputs, tokenizer: tokenizer, maxNewTokens: maxNewTokens)
            let generation = try context.generateGuided(
                prompt: prompt, candidates: completions, maxNewTokens: maxNewTokens,
                batchesForcedTokens: mode == .batched, isCancelled: { false })
            let output = try PolishGuide.output(
                tokens: generation.tokens, candidate: generation.candidate, completions: completions,
                allowedOutputs: allowedOutputs, tokenizer: tokenizer)
            let end = DispatchTime.now().uptimeNanoseconds
            return PolishResult(
                output: output,
                ms: Double(end - start) / 1_000_000,
                prompt: prompt,
                generation: Qwen3Generation(
                    tokens: generation.tokens,
                    decisions: [],
                    prefillMs: generation.prefillMs,
                    decodeMs: generation.decodeMs,
                    evaluations: generation.evaluations,
                    drafted: 0,
                    accepted: 0
                ),
                guided: PolishGuidedRun(
                    candidate: generation.candidate, completions: completions, steps: generation.steps)
            )
        }
    }

    /// The harness's trim: the six ASCII whitespace bytes `" \t\n\r\f\v"`, at both ends.
    static func trimmed(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B]
        guard let first = bytes.firstIndex(where: { !whitespace.contains($0) }),
            let last = bytes.lastIndex(where: { !whitespace.contains($0) })
        else { return [] }
        return bytes[first...last]
    }

    // MARK: Process measurements

    /// Wall-clock creation time of this process, from the kernel.
    private static func processStartTime() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private static func milliseconds(since date: Date) -> Double {
        Date().timeIntervalSince(date) * 1000
    }

    /// The task's lifetime peak physical footprint (`task_info` `TASK_VM_INFO`), in MiB to 0.1.
    private static func peakFootprintMb() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return round1(Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    private static func computeDevice(backend: String) -> String {
        let description = ggml_backend_dev_by_name(backend).map { String(cString: ggml_backend_dev_description($0)) }
        let device = description.map { "\(backend) (\($0))" } ?? backend
        return "\(device): weights, F16 KV cache (\(contextLength) cells) and every supported graph op"
    }

    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func writeLines<T: Encodable>(_ values: [T], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        do {
            try data.write(to: url)
        } catch {
            throw BenchError.io("cannot write \(url.path): \(BenchError.describe(error))")
        }
    }
}

struct PolishCase: Decodable {
    var id: String
    var input: String
    /// `--guided` only, and ignored without it: the outputs decoding may produce, the input itself among them.
    var allowedOutputs: [String]?
    /// `--draft-text-m` only: an optional untrusted proposal, not a candidate constraint.
    var draftText: String?

    static let readDraftText = CodingUserInfoKey(rawValue: "polishReadDraftText")!
    static let maxDraftBytes = 4096

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        input = try container.decode(String.self, forKey: .input)
        allowedOutputs = try container.decodeIfPresent([String].self, forKey: .allowedOutputs)
        if decoder.userInfo[Self.readDraftText] as? Bool == true,
            let text = try? container.decode(String.self, forKey: .draftText), !text.isEmpty,
            text.utf8.prefix(Self.maxDraftBytes + 1).count <= Self.maxDraftBytes,
            !text.utf8.contains(0)
        {
            draftText = text
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, input
        case allowedOutputs = "allowed_outputs"
        case draftText = "draft_text"
    }
}

struct PolishResult {
    var output: String
    var ms: Double
    var prompt: [Int32]
    var generation: Qwen3Generation
    var guided: PolishGuidedRun? = nil
    var hintEncodingMs: Double? = nil
}

/// One `rows.jsonl` line, the lab harness's schema: the first repetition's output and token counts, and the
/// median of each timing over the repetitions. Guided rows add the first repetition's chosen candidate (its index
/// in `allowed_outputs`), the candidate count, the choices read from logits, how many of those the constraint
/// overrode, and the smallest logit margin of a real choice (absent when no step had one).
struct PolishRow: Encodable {
    var id: String
    var output: String
    var ms: Double
    var msAll: [Double]
    var promptTokens: Int
    var outputTokens: Int
    var prefillMs: Double
    var decodeMs: Double
    var candidate: Int?
    var candidates: Int?
    var guidedSteps: Int?
    var overriddenSteps: Int?
    var minMargin: Double?
    var hint: PolishHintRow?

    init(id: String, runs: [PolishResult]) {
        self.id = id
        output = runs[0].output
        ms = PolishStatistics.median(runs.map(\.ms))
        msAll = runs.map(\.ms)
        promptTokens = runs[0].prompt.count
        outputTokens = runs[0].generation.tokens.count
        prefillMs = PolishStatistics.median(runs.map(\.generation.prefillMs))
        decodeMs = PolishStatistics.median(runs.map(\.generation.decodeMs))
        if let stats = runs[0].generation.hintStats {
            hint = PolishHintRow(
                fed: Int(stats.fed), verified: Int(stats.verified), accepted: Int(stats.accepted),
                encodingMsAll: runs.compactMap(\.hintEncodingMs))
        }
        if let guided = runs[0].guided {
            candidate = guided.candidate
            candidates = guided.completions.count
            guidedSteps = guided.steps.count
            overriddenSteps = guided.overriddenSteps
            minMargin = guided.minimumMargin
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, output, ms, candidate, candidates, hint
        case msAll = "ms_all"
        case promptTokens = "prompt_tokens"
        case outputTokens = "output_tokens"
        case prefillMs = "prefill_ms"
        case decodeMs = "decode_ms"
        case guidedSteps = "guided_steps"
        case overriddenSteps = "overridden_steps"
        case minMargin = "min_margin"
    }
}

/// External-only counts (the general speculation counters also include n-gram fallback).
struct PolishHintRow: Encodable {
    var fed: Int
    var verified: Int
    var accepted: Int
    var encodingMsAll: [Double]

    enum CodingKeys: String, CodingKey {
        case fed, verified, accepted
        case encodingMsAll = "encoding_ms_all"
    }
}

/// One `trace.jsonl` line (`--trace`): the first repetition's prompt and output ids and every greedy choice as
/// `[token, runner_up, logit, runner_up_logit]`. Guided lines have no greedy choices; they add every candidate's
/// completion ids and the guided steps.
struct PolishTrace: Encodable {
    var id: String
    var promptIds: [Int32]
    var outputIds: [Int32]
    var decisions: [[Double]]
    var candidateIds: [[Int32]]?
    var guidedSteps: [PolishTraceStep]?

    init(id: String, run: PolishResult) {
        self.id = id
        promptIds = run.prompt
        outputIds = run.generation.tokens
        decisions = run.generation.decisions.map {
            [Double($0.token), Double($0.runnerUp), Double($0.logit), Double($0.runnerUpLogit)]
        }
        if let guided = run.guided {
            candidateIds = guided.completions
            guidedSteps = guided.steps.map(PolishTraceStep.init)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, decisions
        case promptIds = "prompt_ids"
        case outputIds = "output_ids"
        case candidateIds = "candidate_ids"
        case guidedSteps = "guided_steps"
    }
}

enum PolishStatistics {
    /// Python's `statistics.median`: the mean of the middle pair for an even count.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// polish-lab's `_percentile`: the sorted value at `round(p * (n - 1))`, rounding half to even.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count - 1)).rounded(.toNearestOrEven))
        return sorted[min(sorted.count - 1, rank)]
    }
}

struct PolishWarmup: Encodable {
    var input: String
    var output: String
    var ms: Double
}

struct PolishSpecStats: Encodable {
    var decodeCalls: Int
    var drafted: Int
    var accepted: Int
    var outputTokens: Int

    init(firstRuns: [PolishResult]) {
        decodeCalls = firstRuns.reduce(0) { $0 + $1.generation.evaluations }
        drafted = firstRuns.reduce(0) { $0 + $1.generation.drafted }
        accepted = firstRuns.reduce(0) { $0 + $1.generation.accepted }
        outputTokens = firstRuns.reduce(0) { $0 + $1.generation.tokens.count }
    }

    enum CodingKeys: String, CodingKey {
        case drafted, accepted
        case decodeCalls = "decode_calls"
        case outputTokens = "output_tokens"
    }
}

struct PowerSnapshot: Encodable {
    var source: String?
    var lowPowerMode: Bool
    var thermalState: String
    var at: String

    static func current() -> PowerSnapshot {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return PowerSnapshot(
            source: source,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermal,
            at: ISO8601DateFormatter().string(from: Date())
        )
    }

    enum CodingKeys: String, CodingKey {
        case source, at
        case lowPowerMode = "low_power_mode"
        case thermalState = "thermal_state"
    }
}

struct PolishPower: Encodable {
    var before: PowerSnapshot
    var after: PowerSnapshot
}

struct PolishVersions: Encodable {
    var runtime = "Vendor/qwen3 (llama.cpp b12606 e412c6f4 qwen3 port) on Vendor/ggml"
    var ggml: String
    var ggmlCommit: String
    var macOS: String
    #if DEBUG
        var build = "debug"
    #else
        var build = "release"
    #endif

    enum CodingKeys: String, CodingKey {
        case runtime, ggml, build
        case ggmlCommit = "ggml_commit"
        case macOS = "macOS"
    }
}

struct PolishNotes: Encodable {
    var prompt = "\"text: \" + input + \"\\nout:\", no BOS, no chat template; greedy; stop at the EOS"
    var cases: String
    var reps: Int
    var maxNewTokens: Int
    var ngramN: Int?
    var ngramM: Int?
    var contextLength: Int
    var ubatch = 512
    var kvType = "f16"
    var flashAttention = true
    var threadCount: Int
    var specStats: PolishSpecStats
    var warmup: [PolishWarmup]
    /// `--guided` only; absent from unguided summaries.
    var guided: PolishGuidedNotes? = nil
    var draftTextBatch: Int32? = nil

    enum CodingKeys: String, CodingKey {
        case prompt, cases, reps, ubatch, warmup, guided
        case draftTextBatch = "draft_text_m"
        case maxNewTokens = "max_new_tokens"
        case ngramN = "ngram_n"
        case ngramM = "ngram_m"
        case contextLength = "n_ctx"
        case kvType = "kv_type"
        case flashAttention = "flash_attn"
        case threadCount = "n_threads"
        case specStats = "spec_stats"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(cases, forKey: .cases)
        try container.encode(reps, forKey: .reps)
        try container.encode(maxNewTokens, forKey: .maxNewTokens)
        try container.encode(ngramN, forKey: .ngramN)
        try container.encode(ngramM, forKey: .ngramM)
        try container.encode(contextLength, forKey: .contextLength)
        try container.encode(ubatch, forKey: .ubatch)
        try container.encode(kvType, forKey: .kvType)
        try container.encode(flashAttention, forKey: .flashAttention)
        try container.encode(threadCount, forKey: .threadCount)
        try container.encode(specStats, forKey: .specStats)
        try container.encode(warmup, forKey: .warmup)
        try container.encodeIfPresent(guided, forKey: .guided)
        try container.encodeIfPresent(draftTextBatch, forKey: .draftTextBatch)
    }
}

/// `summary.json`, the polish-lab summary schema.
struct PolishSummary: Encodable {
    var runtime = "voiceour-ggml"
    var config: String
    var modelRepo: String?
    var modelRevision: String?
    var weightsFile: String
    var weightsSHA256: String
    var quantization: String
    var computeDevice: String
    var loadMs: Double
    var firstRequestMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var maxMs: Double
    var g01Ms: Double?
    var g02Ms: Double?
    var peakFootprintMb: Double?
    var deterministic: Bool
    var power: PolishPower
    var versions: PolishVersions
    var notes: PolishNotes

    init(
        config: String, modelRepo: String?, modelRevision: String?, weightsFile: String, weightsSHA256: String,
        quantization: String, computeDevice: String, loadMs: Double, firstRequestMs: Double, rows: [PolishRow],
        peakFootprintMb: Double?, deterministic: Bool, power: PolishPower, versions: PolishVersions, notes: PolishNotes
    ) {
        self.config = config
        self.modelRepo = modelRepo
        self.modelRevision = modelRevision
        self.weightsFile = weightsFile
        self.weightsSHA256 = weightsSHA256
        self.quantization = quantization
        self.computeDevice = computeDevice
        self.loadMs = loadMs
        self.firstRequestMs = firstRequestMs
        let ms = rows.map(\.ms)
        p50Ms = PolishCommand.round1(PolishStatistics.median(ms))
        p95Ms = PolishCommand.round1(PolishStatistics.percentile(ms, 0.95))
        maxMs = PolishCommand.round1(ms.max() ?? 0)
        g01Ms = rows.first { $0.id == "G01" }.map { PolishCommand.round1($0.ms) }
        g02Ms = rows.first { $0.id == "G02" }.map { PolishCommand.round1($0.ms) }
        self.peakFootprintMb = peakFootprintMb
        self.deterministic = deterministic
        self.power = power
        self.versions = versions
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case runtime, config, quantization, deterministic, power, versions, notes
        case modelRepo = "model_repo"
        case modelRevision = "model_revision"
        case weightsFile = "weights_file"
        case weightsSHA256 = "weights_sha256"
        case computeDevice = "compute_device"
        case loadMs = "load_ms"
        case firstRequestMs = "first_request_ms"
        case p50Ms = "p50_ms"
        case p95Ms = "p95_ms"
        case maxMs = "max_ms"
        case g01Ms = "G01_ms"
        case g02Ms = "G02_ms"
        case peakFootprintMb = "peak_footprint_mb"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(config, forKey: .config)
        try container.encode(modelRepo, forKey: .modelRepo)
        try container.encode(modelRevision, forKey: .modelRevision)
        try container.encode(weightsFile, forKey: .weightsFile)
        try container.encode(weightsSHA256, forKey: .weightsSHA256)
        try container.encode(quantization, forKey: .quantization)
        try container.encode(computeDevice, forKey: .computeDevice)
        try container.encode(loadMs, forKey: .loadMs)
        try container.encode(firstRequestMs, forKey: .firstRequestMs)
        try container.encode(p50Ms, forKey: .p50Ms)
        try container.encode(p95Ms, forKey: .p95Ms)
        try container.encode(maxMs, forKey: .maxMs)
        try container.encode(g01Ms, forKey: .g01Ms)
        try container.encode(g02Ms, forKey: .g02Ms)
        try container.encode(peakFootprintMb, forKey: .peakFootprintMb)
        try container.encode(deterministic, forKey: .deterministic)
        try container.encode(power, forKey: .power)
        try container.encode(versions, forKey: .versions)
        try container.encode(notes, forKey: .notes)
    }
}
