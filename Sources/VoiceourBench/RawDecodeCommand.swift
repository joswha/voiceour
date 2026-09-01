import ASRSidecarCore
import Foundation
import VoiceCore

/// Research probe: decode a frozen manifest with an explicit model file, bypassing the
/// pinned-artifact cache on purpose.
///
/// The pipeline command speaks to the sidecar, whose cache refuses any artifact that is
/// not the compiled pin — exactly right for the shipping path, and exactly wrong for
/// asking "what would a different checkpoint of the same architecture do on this
/// corpus". This command constructs `ParakeetContext` directly on `--model`, runs the
/// same deterministic text stage as the pipeline (cleanup with an empty glossary, then
/// the optional repair vocabulary), validates every row's audio SHA, and emits
/// pipeline-shaped rows. Native execution only: no CoreML tiers, no weight arena, no
/// tail dials — a probe measures the checkpoint, not the acceleration stack.
struct RawDecodeCommand {
    var options: BenchOptions

    func run() throws {
        guard let modelURL = options.model else {
            throw BenchError.usage("raw-decode requires --model")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw BenchError.io("model file missing: \(modelURL.path)")
        }
        let repair = try options.vocabulary.map(LoadedRepairEngine.load)
        let context = try ParakeetContext(modelPath: modelURL.path)
        let reader = try JSONLLineReader(url: options.input)
        let writer = try JSONLWriter(url: options.output)
        let decoder = JSONDecoder()
        var lineNumber = 0
        var rowCount = 0

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
            try writer.write(decodeRow(input, context: context, repair: repair?.engine))
            rowCount += 1
        }

        print("wrote \(rowCount) raw-decode rows to \(options.output.path)")
    }

    private func decodeRow(
        _ input: PipelineInputRow,
        context: ParakeetContext,
        repair: VocabularyRepairEngine?
    ) throws -> BenchOutputRow {
        let audioURL = try validatedAudioURL(for: input)
        let samples = try WAVFile.readSamples(at: audioURL)
        let inferenceStart = BenchClock.mark()
        let segments = try context.transcribe(samples: samples, isCancelled: { false })
        let inferenceMs = BenchClock.elapsedMilliseconds(since: inferenceStart)
        let rawTranscript = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedText = CleanupEngine.clean(rawTranscript, glossary: [])
        let finalText = repair?.repair(cleanedText).text ?? cleanedText
        print("processed \(input.id) inference_ms=\(inferenceMs)")
        return BenchOutputRow(
            id: input.id,
            rawTranscript: rawTranscript,
            cleanedText: cleanedText,
            finalText: finalText,
            timingsMs: BenchOutputTimings(
                asr: inferenceMs,
                asrLoad: nil,
                asrInference: inferenceMs,
                cleanup: 0,
                total: inferenceMs
            ),
            audioS: input.audioS
        )
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
