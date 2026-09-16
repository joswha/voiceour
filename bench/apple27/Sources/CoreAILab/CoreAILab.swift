import AVFAudio
import CoreAI
import CoreAISpeech
import Foundation
import PrototypeSupport

@main
struct CoreAILab {
    static func main() async {
        do {
            try await run()
        } catch {
            PrototypeIO.diagnostic("coreai prototype failed: \(error)")
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = try PrototypeArguments(
            values: ["--input", "--output", "--model", "--metadata", "--maximum-audio-seconds", "--capture-directory"],
            flags: ["--probe"]
        )
        if arguments.contains("--probe") {
            let object: [String: Any] = [
                "type": "capabilities",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": AIModel.deviceArchitectureName,
                "compute_units": ComputeUnitKind.availableKinds.map { String(describing: $0) }.sorted(),
            ]
            print(
                String(
                    decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            )
            return
        }
        let inputURL = URL(fileURLWithPath: try arguments.require("--input"))
        let outputURL = URL(fileURLWithPath: try arguments.require("--output"))
        let modelURL = URL(fileURLWithPath: try arguments.require("--model"))
        guard let maximumAudioS = Double(try arguments.require("--maximum-audio-seconds")),
            maximumAudioS.isFinite, maximumAudioS > 0
        else { throw PrototypeError.message("A positive finite --maximum-audio-seconds is required") }
        let metadataURL = URL(fileURLWithPath: try arguments.require("--metadata"))
        let export = try verifiedExport(at: metadataURL, modelURL: modelURL, maximumAudioS: maximumAudioS)
        let rows = try PrototypeIO.inputs(at: inputURL)
        let writer = try PrototypeWriter(at: outputURL)
        let setupStart = PrototypeClock.now()
        let model: SpeechRecognitionModel
        do {
            model = try await SpeechRecognitionModel(resourcesAt: modelURL)
        } catch {
            try writer.writeObject([
                "type": "blocked", "backend": "coreai-parakeet", "error": String(describing: error),
            ])
            try writer.close()
            throw error
        }
        let setupMs = PrototypeClock.milliseconds(since: setupStart)
        let sampleRate = await model.sampleRate
        let architecture = await model.architecture
        guard architecture == "Parakeet TDT" else {
            throw PrototypeError.message("Expected Parakeet TDT, loaded \(architecture)")
        }
        let shape = await model.melFeatures(pcm: [Float](repeating: 0, count: 160)).shape
        let expectedFrames = 1 + Int((maximumAudioS * sampleRate).rounded()) / 160
        guard shape == [1, expectedFrames, 128] else {
            throw PrototypeError.message("Expected static [1, \(expectedFrames), 128] mel shape, got \(shape)")
        }
        let captureURL = arguments["--capture-directory"].map { URL(fileURLWithPath: $0) }
        if let captureURL {
            try FileManager.default.createDirectory(at: captureURL, withIntermediateDirectories: true)
        }
        try writer.writeObject([
            "type": "bench_meta",
            "mode": "apple27-prototype",
            "backend": "coreai-parakeet",
            "model_id": export.model,
            "model_revision": export.revision,
            "export_manifest_sha256": try PrototypeIO.digest(of: metadataURL),
            "provenance": export.metadata,
            "model_path": modelURL.path,
            "architecture": architecture,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "device_architecture": AIModel.deviceArchitectureName,
            "manifest_sha256": try PrototypeIO.digest(of: inputURL),
            "setup_ms": setupMs,
            "setup_includes_encoder_warmup": true,
            "maximum_audio_seconds": maximumAudioS,
            "bounds_source": "verified export manifest and static mel shape",
            "capture_stages": captureURL != nil,
            "timing_note": captureURL == nil
                ? "Mono float PCM read before timing; ASR includes Swift mel, Core AI encoder, and TDT decode."
                : "Parity run includes duplicate mel calculation; not a performance sample.",
            "thermal_state": String(describing: ProcessInfo.processInfo.thermalState),
        ])
        for (index, row) in rows.enumerated() {
            do {
                let audioURL = try PrototypeIO.audioURL(for: row)
                let pcm = try readPCM(at: audioURL, sampleRate: sampleRate)
                guard Double(pcm.count) / sampleRate <= maximumAudioS + 1 / sampleRate else {
                    throw PrototypeError.message(
                        "Audio exceeds the \(maximumAudioS)-second export window; refusing truncation")
                }
                let start = PrototypeClock.now()
                let text: String
                let steps: Int
                let inferenceMs: Double
                if let captureURL {
                    let capture = try await model.transcribeCapturingStages(pcm: pcm)
                    text = capture.text
                    steps = capture.stats.stepCount
                    inferenceMs = PrototypeClock.milliseconds(since: start)
                    try save(capture, row: row, directory: captureURL)
                } else {
                    let result = try await model.transcribe(pcm: pcm)
                    text = result.0
                    steps = result.1.stepCount
                    inferenceMs = PrototypeClock.milliseconds(since: start)
                }
                var details = ["phase": index == 0 ? "first_request" : "warm", "decoder_steps": String(steps)]
                if captureURL != nil { details["parity_run"] = "true" }
                try writer.write(
                    PrototypeOutput(
                        id: row.id, rawTranscript: text, audioS: row.audioS, asrMs: inferenceMs, details: details
                    ))
                PrototypeIO.diagnostic("processed \(row.id)")
            } catch {
                try writer.write(
                    PrototypeOutput(
                        id: row.id, rawTranscript: "", audioS: row.audioS, error: String(describing: error)
                    ))
                PrototypeIO.diagnostic("failed \(row.id): \(error)")
            }
        }
        try writer.close()
    }

    private static func verifiedExport(
        at url: URL, modelURL: URL, maximumAudioS: Double
    ) throws -> (metadata: [String: Any], model: String, revision: String) {
        guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            metadata["schema"] as? String == "voiceour.apple27.coreai/1",
            metadata["engine"] as? String == "parakeet",
            let model = metadata["model"] as? String,
            model == "nvidia/parakeet-tdt-0.6b-v3",
            let revision = metadata["revision"] as? String,
            let details = metadata["details"] as? [String: Any],
            details["dynamic_audio"] as? Bool == false,
            details["maximum_audio_seconds"] as? Double == maximumAudioS,
            let bundlePath = details["bundle"] as? String,
            let bundleDigest = details["bundle_metadata_sha256"] as? String,
            let artifacts = metadata["artifacts"] as? [String: [String: Any]]
        else { throw PrototypeError.message("Invalid or non-static Parakeet export manifest") }
        let directory = url.deletingLastPathComponent()
        guard directory.appendingPathComponent(bundlePath).standardizedFileURL == modelURL.standardizedFileURL,
            try PrototypeIO.digest(of: modelURL.appendingPathComponent("metadata.json")) == bundleDigest
        else { throw PrototypeError.message("Parakeet bundle does not match export manifest") }
        for artifact in artifacts.values {
            guard let relativePath = artifact["path"] as? String,
                let descriptor = artifact["artifact"] as? [String: Any],
                let files = descriptor["files"] as? [[String: Any]]
            else { throw PrototypeError.message("Invalid asset digest manifest") }
            let root = directory.appendingPathComponent(relativePath)
            let isDirectory = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            for file in files {
                guard let path = file["path"] as? String, let expectedHash = file["sha256"] as? String,
                    let expectedBytes = file["size_bytes"] as? Int
                else { throw PrototypeError.message("Invalid asset file pin") }
                let fileURL = isDirectory ? root.appendingPathComponent(path) : root
                let bytes = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard bytes == expectedBytes, try PrototypeIO.digest(of: fileURL) == expectedHash else {
                    throw PrototypeError.message("Asset pin mismatch: \(fileURL.path)")
                }
            }
        }
        return (metadata, model, revision)
    }

    private static func readPCM(at url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == sampleRate, file.processingFormat.channelCount == 1,
            file.length > 0, file.length <= Int64(UInt32.max)
        else { throw PrototypeError.message("Expected nonempty mono \(sampleRate) Hz fixture: \(url.path)") }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(file.length, 16_384))
            )
        else { throw PrototypeError.message("Could not allocate fixture audio buffer") }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while samples.count < file.length {
            let requested = AVAudioFrameCount(min(Int(file.length) - samples.count, Int(buffer.frameCapacity)))
            try file.read(into: buffer, frameCount: requested)
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                throw PrototypeError.message("Short audio read: \(samples.count)/\(file.length) frames")
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }

    private static func save(
        _ capture: SpeechRecognitionModel.StageCapture, row: PrototypeInput, directory: URL
    ) throws {
        let safeID = row.id.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_"
        }.joined()
        let prefix = directory.appendingPathComponent(safeID)
        try capture.mel.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(to: prefix.appendingPathExtension("mel.f32"), options: .withoutOverwriting)
        }
        try capture.encoderHiddenStates.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(
                to: prefix.appendingPathExtension("encoder.f32"), options: .withoutOverwriting)
        }
        let metadata: [String: Any] = [
            "id": row.id,
            "mel_shape": capture.melShape,
            "encoder_shape": capture.encoderShape,
            "valid_encoder_frames": capture.validEncoderFrames,
            "tokens": capture.tokens,
            "text": capture.text,
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(
            to: prefix.appendingPathExtension("json"), options: .withoutOverwriting
        )
    }
}
