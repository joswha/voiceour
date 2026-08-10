import AVFoundation
import Darwin
import Foundation
import VoiceCore

enum RecorderError: Error {
    case alreadyRecording
    case notRecording
    case fileMissing
}

public final class AVAudioEngineRecorder: NSObject, AudioRecording, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var startedAt: Date?

    public override init() {}

    public func start() throws {
        guard recorder == nil else { throw RecorderError.alreadyRecording }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceoour", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.fileMissing }
        self.recorder = recorder
        self.outputURL = url
        self.startedAt = Date()
    }

    public func stop() async throws -> RecordedAudio {
        guard let recorder, let outputURL else { throw RecorderError.notRecording }
        recorder.stop()
        self.recorder = nil
        self.outputURL = nil
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt ?? Date()) * 1000))
        self.startedAt = nil
        guard FileManager.default.fileExists(atPath: outputURL.path) else { throw RecorderError.fileMissing }
        let meta = ASRAudioMeta(
            path: outputURL.path,
            format: "wav",
            sampleRateHz: 16_000,
            channels: 1,
            durationMs: durationMs,
            byteCount: byteCount
        )
        let telemetry = try? CaptureTelemetryAnalyzer.analyzeWAV(
            at: outputURL,
            inputFormat: CaptureAudioFormat(
                sampleRateHz: 16_000,
                channels: 1,
                encoding: "pcm_s16le"
            ),
            processingMode: .standard
        )
        return RecordedAudio(url: outputURL, meta: meta, telemetry: telemetry)
    }

    public func discardRecording() async {
        recorder?.stop()
        let url = outputURL
        recorder = nil
        outputURL = nil
        startedAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func currentInputLevel() -> Float? {
        guard let recorder, recorder.isRecording else { return nil }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        guard decibels.isFinite else { return 0 }

        let floor: Float = -55
        let ceiling: Float = -8
        let clamped = Swift.min(Swift.max(decibels, floor), ceiling)
        let normalized = (clamped - floor) / (ceiling - floor)
        return Swift.min(Swift.max(sqrtf(normalized), 0), 1)
    }
}
