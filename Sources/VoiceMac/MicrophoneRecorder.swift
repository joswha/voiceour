import AVFoundation
import Darwin
import Foundation
import VoiceCore

enum RecorderError: Error {
    case alreadyRecording
    case notRecording
    case fileMissing
}

/// The sidecar backends' recorder: capture through ``MicrophoneCapture``, convert
/// to 16 kHz mono Int16, write a WAV incrementally.
///
/// It replaced an `AVAudioRecorder` for two reasons, both measured on AirPods Max.
/// `AVAudioRecorder` cannot choose an input device, so a dictation was forced onto
/// the Bluetooth headset microphone and lost its first 1.3 seconds to HFP/SCO
/// negotiation — as digital zeros in the WAV, not as quiet audio. And it exposes
/// only metering, so the recorder could not tell warm-up from silence and reported
/// `captureIsLive() == true` from the first tick; the `-120 dB` floor that
/// `averagePower` returns during the gap is a workable signal but a weaker one than
/// simply looking at the samples.
public final class MicrophoneRecorder: NSObject, AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var capture: MicrophoneCapture?
    private var converter: CaptureConverter?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var startedAt: Date?
    private var writtenFrames: AVAudioFramePosition = 0
    private var lastStartLatency: Int?
    private var lastSource: MicrophoneCapture.Source?

    private static let sampleRate = 16_000

    public override init() {}

    public func start() throws {
        try lock.withLock {
            guard capture == nil else { throw RecorderError.alreadyRecording }

            guard
                let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(Self.sampleRate),
                    channels: 1,
                    interleaved: true
                )
            else {
                throw RecorderError.fileMissing
            }

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "voiceoour", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

            // commonFormat/interleaved set the file's PROCESSING format to match the
            // converter output; the default Float32 processing format makes
            // write(from:) abort on Int16 buffers (CoreAudio CAVerboseAbort).
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )

            let capture = try MicrophoneCapture(
                preferredDeviceUID: CoreAudioInputDevice.preferredCaptureUID())
            let converter = CaptureConverter(targetFormat: targetFormat)

            self.file = file
            self.converter = converter
            self.capture = capture
            outputURL = url
            startedAt = Date()
            writtenFrames = 0
            lastStartLatency = nil
            lastSource = capture.source

            capture.start { [weak self] buffer in
                self?.consume(buffer)
            }

            // The sidecar path had no way to say which microphone it opened, which is
            // exactly why a Bluetooth warm-up gap went unnoticed for so long. One line
            // on stderr, matching the Apple path's init breakdown.
            let line =
                "VoiceOour: capture device=\(capture.source.name)"
                + "\(capture.source.isRedirected ? " (redirected from system default)" : "")\n"
            try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        }
    }

    public func stop() async throws -> RecordedAudio {
        // `stop()` on the capture is deliberately OUTSIDE this lock.
        // `AVCaptureSession.stopRunning()` blocks until the delegate queue quiesces,
        // and that delegate is `consume`, which takes this same lock — holding it
        // across the stop is a deadlock waiting for a buffer to be in flight.
        let claimed: MicrophoneCapture = try lock.withLock {
            guard let capture, outputURL != nil else { throw RecorderError.notRecording }
            return capture
        }
        claimed.stop()

        let finished: (url: URL, frames: AVAudioFramePosition, latency: Int?) = try lock.withLock {
            guard let outputURL else { throw RecorderError.notRecording }
            let latency = claimed.startLatencyMs()
            // Whatever the resampler still holds belongs to this utterance. Safe to
            // drain now: no more buffers can arrive once the capture has stopped.
            if let converter, let file {
                for chunk in converter.drain() {
                    try? file.write(from: chunk)
                    writtenFrames += AVAudioFramePosition(chunk.frameLength)
                }
            }
            let frames = writtenFrames
            capture = nil
            self.converter = nil
            // Releasing the file is what flushes the WAV header's final sizes.
            file = nil
            self.outputURL = nil
            startedAt = nil
            lastStartLatency = latency
            return (outputURL, frames, latency)
        }

        guard FileManager.default.fileExists(atPath: finished.url.path) else {
            throw RecorderError.fileMissing
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: finished.url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        // Frames written, not wall clock: a warm-up gap is real recorded silence
        // and belongs in the duration, but a slow stop path does not.
        let durationMs = Int(finished.frames * 1000 / AVAudioFramePosition(Self.sampleRate))

        let meta = ASRAudioMeta(
            path: finished.url.path,
            format: "wav",
            sampleRateHz: Self.sampleRate,
            channels: 1,
            durationMs: durationMs,
            byteCount: byteCount
        )
        let telemetry = try? CaptureTelemetryAnalyzer.analyzeWAV(
            at: finished.url,
            inputFormat: CaptureAudioFormat(
                sampleRateHz: Self.sampleRate,
                channels: 1,
                encoding: "pcm_s16le"
            ),
            processingMode: .standard
        )
        return RecordedAudio(url: finished.url, meta: meta, telemetry: telemetry)
    }

    public func discardRecording() async {
        let claimed: MicrophoneCapture? = lock.withLock { capture }
        claimed?.stop()

        let url = lock.withLock { () -> URL? in
            capture = nil
            converter = nil
            file = nil
            startedAt = nil
            let url = outputURL
            outputURL = nil
            return url
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func currentInputLevel() -> Float? {
        lock.withLock { capture?.currentLevel() }
    }

    public func lastStartLatencyMs() -> Int? {
        lock.withLock { capture?.startLatencyMs() ?? lastStartLatency }
    }

    public func captureIsLive() -> Bool {
        lock.withLock { capture?.hasReceivedAudio() ?? false }
    }

    /// Which microphone the last capture actually used, and whether that was a
    /// redirect away from the system default.
    func lastCaptureSource() -> MicrophoneCapture.Source? {
        lock.withLock { lastSource }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let converter, let file else { return }
            for chunk in converter.convert(buffer) where chunk.frameLength > 0 {
                do {
                    try file.write(from: chunk)
                    writtenFrames += AVAudioFramePosition(chunk.frameLength)
                } catch {
                    // A failed write must not kill the capture: the utterance so far
                    // is still worth transcribing, and stop() validates the file.
                }
            }
        }
    }
}
