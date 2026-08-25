import Darwin
import Foundation
import VoiceCore

public final class FakeAudioRecorder: AudioRecording, @unchecked Sendable {
    private var startedAt: Date?
    private var outputURL: URL?

    public init() {}

    public func start() throws {
        outputURL = try CaptureTemporaryFile.makeWAVURL()
        startedAt = Date()
    }

    public func stop() async throws -> RecordedAudio {
        let url = outputURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("voiceour-fake.wav")
        let wav = Self.silenceWav(sampleRate: 16_000, milliseconds: 100)
        try wav.write(to: url, options: [.atomic])
        let durationMs = max(100, Int(Date().timeIntervalSince(startedAt ?? Date()) * 1000))
        outputURL = nil
        startedAt = nil
        let telemetry = try CaptureTelemetryAnalyzer.analyzeWAV(
            data: wav,
            processingMode: .standard
        )
        return RecordedAudio(
            url: url,
            meta: ASRAudioMeta(
                path: url.path,
                format: "wav",
                sampleRateHz: 16_000,
                channels: 1,
                durationMs: durationMs,
                byteCount: wav.count
            ),
            telemetry: telemetry,
            isSynthetic: true
        )
    }

    public func discardRecording() async {
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        startedAt = nil
    }

    public func currentInputLevel() -> Float? {
        guard let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let pulse = (sin(elapsed * 6.2) + 1) / 2
        let flutter = (sin(elapsed * 18.0 + 0.7) + 1) / 2
        let level = 0.12 + pulse * 0.55 + flutter * 0.12
        return Float(Swift.min(Swift.max(level, 0), 1))
    }

    private static func silenceWav(sampleRate: Int, milliseconds: Int) -> Data {
        let samples = max(1, sampleRate * milliseconds / 1000)
        let dataBytes = samples * 2
        var data = Data()
        func appendString(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendUInt16(_ value: UInt16) {
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: 2))
        }
        func appendUInt32(_ value: UInt32) {
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: 4))
        }
        appendString("RIFF")
        appendUInt32(UInt32(36 + dataBytes))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(dataBytes))
        data.append(Data(repeating: 0, count: dataBytes))
        return data
    }
}
