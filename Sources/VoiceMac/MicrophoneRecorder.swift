import AVFoundation
import Darwin
import Foundation
import VoiceCore

enum RecorderError: Error {
    case alreadyRecording
    case notRecording
    case outputUnavailable
}

/// The one 16 kHz mono interleaved Int16 WAV every capture path writes. The
/// sidecar recorder and the Apple Speech streaming session must produce a
/// byte-identical file — a drift between the two surfaces only as audio the
/// backend cannot read, so the construction lives in exactly one place.
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
    /// Append-only raw s16le sibling of the WAV, written for partial previews.
    ///
    /// A second file rather than a re-read of the WAV: `AVAudioFile` owns the WAV's header and
    /// only finalises its sizes on release, so a live WAV declares a data chunk length that has
    /// not been written yet. The tee has no header to be wrong about.
    private var pcmURL: URL?
    private var pcmHandle: FileHandle?
    private var writtenFrames: AVAudioFramePosition = 0
    private var lastStartLatency: Int?

    private static let sampleRate = 16_000

    public override init() {}

    public func start() throws {
        try lock.withLock {
            guard capture == nil else { throw RecorderError.alreadyRecording }

            let wav = try CaptureWAVTarget(sampleRate: Self.sampleRate)

            let capture = try MicrophoneCapture(
                preferredDeviceUID: CoreAudioInputDevice.preferredCaptureUID())
            let converter = CaptureConverter(targetFormat: wav.format)

            let pcm = wav.url.deletingPathExtension().appendingPathExtension("pcm")
            FileManager.default.createFile(atPath: pcm.path, contents: nil)

            self.file = wav.file
            self.converter = converter
            self.capture = capture
            outputURL = wav.url
            pcmURL = pcm
            // A tee that cannot be opened is not a reason to refuse a dictation: partials
            // simply do not appear, and the recording itself is unaffected.
            pcmHandle = try? FileHandle(forWritingTo: pcm)
            writtenFrames = 0
            lastStartLatency = nil

            capture.start { [weak self] buffer in
                self?.consume(buffer)
            }

            // The sidecar path had no way to say which microphone it opened, which is
            // exactly why a Bluetooth warm-up gap went unnoticed for so long. One line
            // on stderr, matching the Apple path's init breakdown.
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
            // The tee exists only for the live preview. Dropping it here is what keeps the
            // "no audio history" promise: only the WAV survives, and only until insertion.
            try? pcmHandle?.close()
            pcmHandle = nil
            if let pcmURL { try? FileManager.default.removeItem(at: pcmURL) }
            pcmURL = nil
            lastStartLatency = latency
            return (outputURL, frames, latency)
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

    public func discardRecording() async {
        let claimed: MicrophoneCapture? = lock.withLock { capture }
        claimed?.stop()

        let urls = lock.withLock { () -> (wav: URL?, pcm: URL?) in
            capture = nil
            converter = nil
            file = nil
            let url = outputURL
            outputURL = nil
            try? pcmHandle?.close()
            pcmHandle = nil
            let pcm = pcmURL
            pcmURL = nil
            return (url, pcm)
        }
        if let url = urls.wav {
            try? FileManager.default.removeItem(at: url)
        }
        if let pcm = urls.pcm {
            try? FileManager.default.removeItem(at: pcm)
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
                // The tee first, and never fatal: the WAV is the deliverable, the tee is a
                // preview convenience, and `writtenFrames` only advances once the WAV took it.
                if let pcmHandle, let channel = chunk.int16ChannelData?[0] {
                    let byteCount = Int(chunk.frameLength) * 2
                    let bytes = Data(
                        bytesNoCopy: UnsafeMutableRawPointer(channel),
                        count: byteCount,
                        deallocator: .none
                    )
                    try? pcmHandle.write(contentsOf: bytes)
                }
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

extension MicrophoneRecorder: PartialAudioProviding {
    public func partialAudio() -> PartialAudioSnapshot? {
        lock.withLock {
            guard let pcmURL, writtenFrames > 0 else { return nil }
            // `writtenFrames` counts frames the WAV accepted, and the tee is always written
            // first, so the file holds at least this many samples. A reader that stops at this
            // count can never see a torn write.
            return PartialAudioSnapshot(pcmURL: pcmURL, sampleCount: Int(writtenFrames))
        }
    }
}
