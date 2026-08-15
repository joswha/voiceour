import AVFoundation
import Darwin
import Foundation
import VoiceCore

public enum RecorderError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case outputUnavailable
    /// The capture stopped being able to record: a session runtime error, a
    /// disconnected device, or a recording that ended with zero frames written.
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "No recording is in progress."
        case .outputUnavailable: "The recording file could not be read back."
        case .captureFailed(let reason): "Recording failed: \(reason)."
        }
    }
}

/// The one 16 kHz mono interleaved Int16 WAV the capture path writes. The format is
/// also `parakeet`'s input contract, so the construction lives in exactly one place:
/// a drift surfaces only as audio the backend cannot read.
struct CaptureWAVTarget {
    let url: URL
    let format: AVAudioFormat
    let file: AVAudioFile

    init(sampleRate: Int) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: true
            )
        else {
            throw RecorderError.outputUnavailable
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voiceour", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

        // commonFormat/interleaved set the file's PROCESSING format to match the
        // converter output; the default Float32 processing format makes
        // write(from:) abort on Int16 buffers (CoreAudio CAVerboseAbort).
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.url = url
        self.format = format
        self.file = file
    }
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
    private var writtenFrames: AVAudioFramePosition = 0
    private var lastStartLatency: Int?

    private static let sampleRate = 16_000

    public override init() {}

    public func start() throws {
        try lock.withLock {
            guard capture == nil else { throw RecorderError.alreadyRecording }

            let wav = try CaptureWAVTarget(sampleRate: Self.sampleRate)

            let capture: MicrophoneCapture
            let converter: CaptureConverter
            do {
                capture = try MicrophoneCapture(
                    preferredDeviceUID: CoreAudioInputDevice.preferredCaptureUID())
                converter = CaptureConverter(targetFormat: wav.format)
            } catch {
                // The WAV exists the moment `CaptureWAVTarget` is constructed, so a
                // capture this recorder never owned would otherwise leave a 0-sample
                // file in the temp directory for the scavenger to find on some later
                // launch. Nothing points at it yet, so this is the only chance to
                // remove it.
                try? FileManager.default.removeItem(at: wav.url)
                throw error
            }

            self.file = wav.file
            self.converter = converter
            self.capture = capture
            outputURL = wav.url
            writtenFrames = 0
            lastStartLatency = nil

            capture.start { [weak self] buffer in
                self?.consume(buffer)
            }

            // The sidecar path had no way to say which microphone it opened, which is
            // exactly why a Bluetooth warm-up gap went unnoticed for so long. One line
            // on stderr, matching the session init breakdown.
            let line =
                "Voiceour: capture device=\(capture.source.name)"
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
            // Identity check, not just presence: a cancel that ran between the
            // claim above and here has already started a *new* session, and
            // clearing its capture/file/URL here would strand a live recording
            // with nothing owning it.
            guard capture === claimed, let outputURL else { throw RecorderError.notRecording }
            let latency = claimed.startLatencyMs()
            // Whatever the resampler still holds belongs to this utterance. Safe to
            // drain now: no more buffers can arrive once the capture has stopped.
            if let converter, let file {
                for chunk in converter.drain() {
                    // Counted only when the WAV accepted it. `try?` plus an
                    // unconditional increment made `writtenFrames` a count of frames
                    // *offered*, which is what the emptiness check below reads.
                    do {
                        try file.write(from: chunk)
                        writtenFrames += AVAudioFramePosition(chunk.frameLength)
                    } catch {
                        // A failed tail write costs the tail, not the utterance.
                    }
                }
            }
            let frames = writtenFrames
            capture = nil
            self.converter = nil
            // Releasing the file is what flushes the WAV header's final sizes.
            file = nil
            self.outputURL = nil
            lastStartLatency = latency
            return (outputURL, frames, latency)
        }

        // A capture that failed mid-recording, or one that wrote nothing at all, is
        // reported rather than transcribed. Both used to reach ASR as a valid-looking
        // WAV: the model then invents words from silence and the app pastes them.
        if let error = Self.recordingFailure(latched: claimed.failureReason(), frames: finished.frames) {
            try? FileManager.default.removeItem(at: finished.url)
            throw error
        }
        guard FileManager.default.fileExists(atPath: finished.url.path) else {
            throw RecorderError.outputUnavailable
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

    /// Whether a finished recording may be transcribed, as a value so the rule is
    /// provable without a microphone.
    ///
    /// `frames` counts frames the WAV *accepted*. Zero means one of: a capture that
    /// never delivered a buffer (a denied or seized device), a session that failed
    /// before its first buffer, or a file that rejected every write. All three
    /// produced a header-only WAV that passed the old existence check, and a
    /// header-only WAV transcribes as invented words rather than as nothing.
    static func recordingFailure(latched: String?, frames: AVAudioFramePosition) -> RecorderError? {
        if let latched { return .captureFailed(latched) }
        if frames <= 0 { return .captureFailed("no audio was recorded") }
        return nil
    }

    public func discardRecording() async {
        let claimed: MicrophoneCapture? = lock.withLock { capture }
        claimed?.stop()

        let claimedURL = lock.withLock { () -> URL? in
            // Same identity rule as `stop()`: only the session this call claimed may
            // be torn down, so a discard racing a newer start cannot orphan it.
            guard capture === claimed else { return nil }
            capture = nil
            converter = nil
            file = nil
            let url = outputURL
            outputURL = nil
            return url
        }
        if let url = claimedURL {
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
