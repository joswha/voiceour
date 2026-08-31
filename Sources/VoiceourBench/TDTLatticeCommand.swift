import ASRSidecarCore
import Foundation

struct TDTLatticeCommand {
    var options: BenchOptions

    func run() throws {
        let cache = ParakeetModelCache.standard()
        guard cache.cacheOK() else {
            throw BenchError.io("pinned model cache is not ready: \(cache.modelURL.path)")
        }

        let context = try ParakeetContext(
            modelPath: cache.modelURL.path,
            weightArenaPath: cache.weightArenaURL.path
        )
        let reader = try JSONLLineReader(url: options.input)
        let writer = try JSONLWriter(url: options.output)
        let decoder = JSONDecoder()
        var lineNumber = 0
        var rowCount = 0
        var stepCount = 0

        while let line = try reader.nextLine() {
            lineNumber += 1
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchError.malformedInput(line: lineNumber, detail: "empty line")
            }

            let input: PipelineInputRow
            do {
                input = try decoder.decode(PipelineInputRow.self, from: Data(line.utf8))
            } catch {
                throw BenchError.malformedInput(line: lineNumber, detail: BenchError.describe(error))
            }

            let audioURL = try validatedAudioURL(for: input)
            let samples = try WAVFile.readSamples(at: audioURL)
            let lattice = try context.transcribeWithLattice(samples: samples, isCancelled: { false })
            let output = TDTLatticeOutputRow(input: input, lattice: lattice)
            try writer.write(output)
            rowCount += 1
            stepCount += lattice.steps.count
            print("processed \(input.id) steps=\(lattice.steps.count)")
        }

        print("wrote \(rowCount) lattice rows, \(stepCount) steps to \(options.output.path)")
    }

    private func validatedAudioURL(for input: PipelineInputRow) throws -> URL {
        let audioURL = BenchCLI.fileURL(input.audioPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount == input.audioBytes else {
            throw BenchError.io(
                "audio size mismatch for \(input.id): got \(byteCount), expected \(input.audioBytes)"
            )
        }
        let digest = try BenchRunner.sha256(of: audioURL)
        guard digest == input.audioSHA256.lowercased() else {
            throw BenchError.io(
                "audio SHA-256 mismatch for \(input.id): got \(digest), expected \(input.audioSHA256)"
            )
        }
        return audioURL
    }
}

private struct TDTLatticeOutputRow: Encodable {
    var id: String
    var audioPath: String
    var audioS: Double?
    var reference: String
    var transcript: String
    var steps: [TDTLatticeOutputStep]
    var summary: TDTLatticeSummary

    init(input: PipelineInputRow, lattice: ParakeetLatticeResult) {
        id = input.id
        audioPath = input.audioPath
        audioS = input.audioS
        reference = input.reference
        transcript = lattice.segments.map(\.text).joined(separator: " ")
        steps = lattice.steps.map(TDTLatticeOutputStep.init)
        summary = TDTLatticeSummary(steps: lattice.steps)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case audioPath = "audio_path"
        case audioS = "audio_s"
        case reference
        case transcript
        case steps
        case summary
    }
}

private struct TDTLatticeOutputStep: Encodable {
    var frameIndex: Int32
    var isBlank: Bool
    var chosenToken: TDTLatticeChosenToken
    var chosenDuration: TDTLatticeChosenDuration
    var topTokens: [TDTLatticeTokenLogit]
    var durationLogits: [Float]
    var tokenMargin: Float
    var durationMargin: Float

    init(_ step: ParakeetLatticeStep) {
        frameIndex = step.frameIndex
        isBlank = step.isBlank
        chosenToken = TDTLatticeChosenToken(
            id: step.chosenTokenID,
            piece: step.chosenTokenPiece,
            logit: step.chosenTokenLogit
        )
        chosenDuration = TDTLatticeChosenDuration(
            slot: step.chosenDurationSlot,
            logit: step.chosenDurationLogit
        )
        topTokens = step.topTokens.map { TDTLatticeTokenLogit(id: $0.id, logit: $0.logit) }
        durationLogits = step.durationLogits
        tokenMargin = step.tokenMargin
        durationMargin = step.durationMargin
    }

    enum CodingKeys: String, CodingKey {
        case frameIndex = "frame_index"
        case isBlank = "is_blank"
        case chosenToken = "chosen_token"
        case chosenDuration = "chosen_duration"
        case topTokens = "top_tokens"
        case durationLogits = "duration_logits"
        case tokenMargin = "token_margin"
        case durationMargin = "duration_margin"
    }
}

private struct TDTLatticeChosenToken: Encodable {
    var id: Int32
    var piece: String
    var logit: Float
}

private struct TDTLatticeChosenDuration: Encodable {
    var slot: Int32
    var logit: Float
}

private struct TDTLatticeTokenLogit: Encodable {
    var id: Int32
    var logit: Float
}

private struct TDTLatticeSummary: Encodable {
    var stepCount: Int
    var tokenMargin: TDTLatticeMarginSummary
    var durationMargin: TDTLatticeMarginSummary

    init(steps: [ParakeetLatticeStep]) {
        stepCount = steps.count
        tokenMargin = TDTLatticeMarginSummary(values: steps.map(\.tokenMargin))
        durationMargin = TDTLatticeMarginSummary(values: steps.map(\.durationMargin))
    }

    enum CodingKeys: String, CodingKey {
        case stepCount = "step_count"
        case tokenMargin = "token_margin"
        case durationMargin = "duration_margin"
    }
}

private struct TDTLatticeMarginSummary: Encodable {
    var min: Float?
    var p5: Float?
    var p50: Float?

    init(values: [Float]) {
        let sorted = values.sorted()
        min = sorted.first
        p5 = Self.quantile(sorted, fraction: 0.05)
        p50 = Self.quantile(sorted, fraction: 0.50)
    }

    private static func quantile(_ sorted: [Float], fraction: Double) -> Float? {
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = Float(position - Double(lower))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }
}
