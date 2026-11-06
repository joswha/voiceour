import ASRSidecarCore
import Foundation
import VoiceCore

/// Research probe for `research/prereg/granite-ctc-word-spotting.md`.
///
/// Decodes each manifest row once with a production `GraniteContext`, runs the app's text stage on
/// the greedy transcript (M0), spots every target term over the run's CTC logits, and for every
/// preregistered operating point renders the accepted spots and runs the same text stage (M1).
/// Rows record M1 texts only where they differ from M0, grouped by the grid points producing them.
struct GraniteSpotCommand {
    var input: URL
    var output: URL
    var glossary: URL
    var model: URL?

    /// The preregistered grid, `total` outermost, then `perToken`, then `ordinaryScale`.
    static let totals: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4, 6, 8]
    static let perTokens: [Double] = [0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5]
    static let ordinaryScales: [Double] = [0, 0.25, 0.5, 1]
    static let grid: [TermSpottingPolicy] = totals.flatMap { total in
        perTokens.flatMap { perToken in
            ordinaryScales.map { TermSpottingPolicy(total: total, perToken: perToken, ordinaryScale: $0) }
        }
    }

    static func parse(_ arguments: [String]) throws -> GraniteSpotCommand {
        var input: URL?
        var output: URL?
        var glossary = BenchCLI.fileURL("bench/autoresearch/repair.vocabulary.json")
        var model: URL?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--input": input = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--output": output = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--glossary":
                glossary = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--model": model = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            default: throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }
        guard let input else { throw BenchError.usage("granite-spot requires --input") }
        guard let output else { throw BenchError.usage("granite-spot requires --output") }
        return GraniteSpotCommand(input: input, output: output, glossary: glossary, model: model)
    }

    func run() throws {
        let modelURL = model ?? ModelCache.granite().modelURL
        let context = try GraniteContext(modelPath: modelURL.path)
        let setup = SpotSetup(glossary: try BenchGlossary.load(glossary), encoder: try context.makeEncoder())
        let writer = try JSONLWriter(url: output)
        try writer.write(
            SpotMeta(
                model: modelURL.lastPathComponent,
                modelSHA256: try BenchRunner.sha256(of: modelURL),
                manifestSHA256: try BenchRunner.sha256(of: input),
                glossarySHA256: setup.glossary.sha256,
                targets: setup.targets.canonicals,
                protectedSurfaces: setup.targets.protectedSurfaces,
                patterns: setup.patterns.map {
                    SpotPatternRecord(
                        term: $0.term,
                        variant: $0.variant,
                        text: setup.variantTexts[$0.term][$0.variant],
                        tokens: $0.tokens
                    )
                },
                grid: Self.grid.map { [$0.total, $0.perToken, $0.ordinaryScale] },
                startedAt: ISO8601DateFormatter().string(from: Date())
            )
        )

        let reader = try JSONLLineReader(url: input)
        var count = 0
        while let line = try reader.nextLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let row = try JSONDecoder().decode(PipelineInputRow.self, from: Data(line.utf8))
            try writer.write(spotRow(row, context: context, setup: setup))
            count += 1
        }
        print("wrote \(count) granite-spot rows to \(output.path)")
    }

    private func spotRow(_ row: PipelineInputRow, context: GraniteContext, setup: SpotSetup) throws -> SpotRow {
        let samples = try WAVFile.readSamples(at: try BenchRunner.validatedAudioURL(for: row))
        let decodeStart = BenchClock.mark()
        let raw = try context.transcribe(samples: samples, isCancelled: { false })
        let decodeMs = BenchClock.elapsedMilliseconds(since: decodeStart)
        let transcript = GraniteTranscriptMapping.transcript(from: raw)
        let words = transcript.segments?.first?.words?.map(\.text) ?? []
        let wordsMatch = words.joined(separator: " ") == transcript.text

        let spotStart = DispatchTime.now().uptimeNanoseconds
        let candidates =
            context.withLastLogits { logits, frames in
                CTCWordSpotter.candidates(
                    logits: logits,
                    frames: frames,
                    vocabulary: context.vocabularySize,
                    blank: context.blankId,
                    patterns: setup.patterns
                )
            } ?? []
        let spots = GraniteTermSpotting.spots(from: candidates, raw: raw)
        let spotMicroseconds = (DispatchTime.now().uptimeNanoseconds - spotStart) / 1_000

        let baseline = setup.glossary.textStage(transcript.text)
        var special: [String: Int] = [:]
        for token in raw.tokens where token.isSpecial {
            special[String(decoding: token.bytes, as: UTF8.self), default: 0] += 1
        }
        return SpotRow(
            id: row.id,
            rawText: transcript.text,
            m0Final: baseline,
            wordsMatchText: wordsMatch,
            frames: context.withLastLogits { _, frames in frames } ?? 0,
            decodeMs: decodeMs,
            spotMicroseconds: Int(spotMicroseconds),
            specialTokens: special,
            spots: zip(spots, candidates).map {
                SpotRecord(spot: $0, candidate: $1, msPerFrame: raw.msPerFrame, words: words, setup: setup)
            },
            finals: wordsMatch ? Self.finals(words: words, spots: spots, baseline: baseline, setup: setup) : []
        )
    }

    /// M1 texts that differ from the baseline, each with the grid points that produce it. Points are
    /// grouped by the spots their thresholds admit, so each distinct admitted set renders once.
    private static func finals(words: [String], spots: [TermSpot], baseline: String, setup: SpotSetup) -> [SpotFinal] {
        guard !spots.isEmpty else { return [] }
        let targets = setup.targets
        var bySignature: [[Int]: [Int]] = [:]
        for (index, policy) in grid.enumerated() {
            let passing = spots.indices.filter {
                TermSpotting.accepts(spots[$0], words: words, ordinaryWords: targets.ordinaryWords, policy: policy)
            }
            if !passing.isEmpty { bySignature[passing, default: []].append(index) }
        }
        var rendered: [String: String] = [:]
        var finals: [String: [Int]] = [:]
        for (passing, points) in bySignature {
            guard
                let changed = TermSpotting.apply(
                    words: words,
                    spots: passing.map { spots[$0] },
                    canonicals: targets.canonicals,
                    protectedSurfaces: targets.protectedSurfaces,
                    ordinaryWords: targets.ordinaryWords,
                    policy: grid[points[0]]
                )
            else { continue }
            let spottedRaw = changed.joined(separator: " ")
            let final = rendered[spottedRaw] ?? setup.glossary.textStage(spottedRaw)
            rendered[spottedRaw] = final
            if final != baseline { finals[final, default: []].append(contentsOf: points) }
        }
        return finals.map { SpotFinal(points: $0.value.sorted(), text: $0.key) }.sorted { $0.points[0] < $1.points[0] }
    }
}

/// The glossary of one run with its targets' spotting patterns, encoded by the run's model.
private struct SpotSetup {
    let glossary: BenchGlossary
    let variantTexts: [[String]]
    let patterns: [CTCSpotPattern]

    var targets: TermSpotTargets { glossary.targets }

    init(glossary: BenchGlossary, encoder: GraniteBPEEncoder) {
        self.glossary = glossary
        variantTexts = glossary.targets.variants
        patterns = GraniteTermSpotting.patterns(for: variantTexts, encoder: encoder)
    }
}

private struct SpotMeta: Encodable {
    var type = "granite_spot_meta"
    var model: String
    var modelSHA256: String
    var manifestSHA256: String
    var glossarySHA256: String
    var targets: [String]
    var protectedSurfaces: [String]
    var patterns: [SpotPatternRecord]
    var grid: [[Double]]
    var startedAt: String

    enum CodingKeys: String, CodingKey {
        case type, model, targets, patterns, grid
        case modelSHA256 = "model_sha256"
        case manifestSHA256 = "manifest_sha256"
        case glossarySHA256 = "glossary_sha256"
        case protectedSurfaces = "protected_surfaces"
        case startedAt = "started_at"
    }
}

private struct SpotPatternRecord: Encodable {
    var term: Int
    var variant: Int
    var text: String
    var tokens: [Int32]
}

private struct SpotRecord: Encodable {
    var term: Int
    var canonical: String
    var variant: Int
    var variantText: String
    var firstWord: Int?
    var lastWord: Int?
    var coveredText: String?
    var startMs: Int
    var endMs: Int
    var score: Double
    var tokenCount: Int

    init(spot: TermSpot, candidate: CTCSpotCandidate, msPerFrame: Int, words: [String], setup: SpotSetup) {
        term = spot.term
        canonical = setup.targets.canonicals[spot.term]
        variant = spot.variant
        variantText = setup.variantTexts[spot.term][spot.variant]
        firstWord = spot.firstWord
        lastWord = spot.lastWord
        if let first = spot.firstWord, let last = spot.lastWord, last < words.count {
            coveredText = words[first...last].joined(separator: " ")
        }
        startMs = candidate.startFrame * msPerFrame
        endMs = (candidate.endFrame + 1) * msPerFrame
        score = spot.score
        tokenCount = spot.tokenCount
    }

    enum CodingKeys: String, CodingKey {
        case term, canonical, variant, score
        case variantText = "variant_text"
        case firstWord = "first_word"
        case lastWord = "last_word"
        case coveredText = "covered_text"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case tokenCount = "token_count"
    }
}

private struct SpotFinal: Encodable {
    var points: [Int]
    var text: String
}

private struct SpotRow: Encodable {
    var type = "row"
    var id: String
    var rawText: String
    var m0Final: String
    var wordsMatchText: Bool
    var frames: Int
    var decodeMs: Int
    var spotMicroseconds: Int
    var specialTokens: [String: Int]
    var spots: [SpotRecord]
    var finals: [SpotFinal]

    enum CodingKeys: String, CodingKey {
        case type, id, frames, spots, finals
        case rawText = "raw_text"
        case m0Final = "m0_final"
        case wordsMatchText = "words_match_text"
        case decodeMs = "decode_ms"
        case spotMicroseconds = "spot_us"
        case specialTokens = "special_tokens"
    }
}

/// Encodes text with the pinned model's own tokenizer tables, for checking the encoder against the
/// reference tokenizer. Input rows are `{"id": …, "text": …}`; output rows add `"ids"`.
struct GraniteTokenizeCommand {
    var input: URL
    var output: URL
    var model: URL?

    static func parse(_ arguments: [String]) throws -> GraniteTokenizeCommand {
        var input: URL?
        var output: URL?
        var model: URL?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--input": input = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--output": output = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--model": model = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            default: throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }
        guard let input, let output else { throw BenchError.usage("granite-tokenize requires --input and --output") }
        return GraniteTokenizeCommand(input: input, output: output, model: model)
    }

    func run() throws {
        let modelURL = model ?? ModelCache.granite().modelURL
        let encoder = try GraniteContext(modelPath: modelURL.path, useGPU: false).makeEncoder()
        let reader = try JSONLLineReader(url: input)
        let writer = try JSONLWriter(url: output)
        var count = 0
        while let line = try reader.nextLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let row = try JSONDecoder().decode(TokenizeRow.self, from: Data(line.utf8))
            try writer.write(TokenizeRow(id: row.id, text: row.text, ids: encoder.encode(row.text)))
            count += 1
        }
        print("wrote \(count) granite-tokenize rows to \(output.path)")
    }

    private struct TokenizeRow: Codable {
        var id: String
        var text: String
        var ids: [Int32]?
    }
}

/// Labels each text with `DictationLanguage.detect`. Input rows are `{"id": …, "text": …}`; output rows
/// add `"language"` (an ISO 639-1 code, or null when undetermined).
struct DetectLanguageCommand {
    var input: URL
    var output: URL

    static func parse(_ arguments: [String]) throws -> DetectLanguageCommand {
        var input: URL?
        var output: URL?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let parsed = BenchCLI.splitOption(arguments[index])
            switch parsed.name {
            case "--input": input = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            case "--output": output = BenchCLI.fileURL(try BenchCLI.value(for: parsed, in: arguments, index: &index))
            default: throw BenchError.usage("unknown option: \(arguments[index])")
            }
            index = arguments.index(after: index)
        }
        guard let input, let output else { throw BenchError.usage("detect-language requires --input and --output") }
        return DetectLanguageCommand(input: input, output: output)
    }

    func run() throws {
        let reader = try JSONLLineReader(url: input)
        let writer = try JSONLWriter(url: output)
        var count = 0
        while let line = try reader.nextLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let row = try JSONDecoder().decode(LanguageRow.self, from: Data(line.utf8))
            try writer.write(
                LanguageRow(id: row.id, text: row.text, language: DictationLanguage.detect(row.text)?.rawValue))
            count += 1
        }
        print("wrote \(count) detect-language rows to \(output.path)")
    }

    private struct LanguageRow: Codable {
        var id: String
        var text: String
        var language: String?
    }
}
