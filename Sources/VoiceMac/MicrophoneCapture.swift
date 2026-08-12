import AVFoundation
import CoreMedia
import Foundation

/// The one microphone front-end both real backends record through: an
/// `AVCaptureSession` pinned to a chosen input device, handing raw PCM buffers to
/// a consumer.
///
/// **Why not `AVAudioEngine`.** An engine's input and output share a single AUHAL
/// on macOS, so pinning the input to the built-in microphone while the output
/// stays on a Bluetooth headset fails graph initialisation with `-10868`
/// (`kAudioUnitErr_FormatNotSupported`). Measured twice, once setting the device
/// after the node materialised and once before any format was read: in both
/// orderings `setDeviceID` reports success, the node keeps the *old* device's
/// format, and `engine.start()` throws. `AVCaptureSession` selects its device
/// explicitly and has no output side to conflict with.
///
/// **What "live" means here.** `firstAudioAt` is the first buffer containing a
/// non-zero sample, never merely the first buffer to arrive. On a cold Bluetooth
/// link those are 1.3 seconds apart: macOS opens the capture immediately and pads
/// it with digital silence until HFP/SCO negotiation completes. Keying liveness
/// on buffer arrival is what let the recording overlay claim LIVE while the
/// microphone did not yet exist, so the distinction is the entire point of this
/// type. Exact zero is a sound proxy rather than a threshold guess: across 375
/// consecutive built-in-microphone buffers, none were all-zero, while 64 of 197
/// were on a cold AirPods Max.
final class MicrophoneCapture: NSObject, @unchecked Sendable {
    enum CaptureError: Error, LocalizedError {
        case noInputDevice
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .cannotAddInput: "The selected microphone could not be opened."
            case .cannotAddOutput: "The audio capture output could not be attached."
            }
        }
    }

    /// Where the samples are coming from, for diagnostics and session metadata.
    struct Source: Equatable, Sendable {
        var uid: String
        var name: String
        /// True when the *system default* input was overridden to reach this
        /// device, i.e. this dictation is deliberately not using the headset mic.
        var isRedirected: Bool
    }

    let source: Source

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.voiceoour.microphone-capture")

    private let lock = NSLock()
    private var startedAt: Date?
    private var firstAudioAt: Date?
    private var meterLevel: Float = 0
    private var isCapturing = false
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// - Parameter preferredDeviceUID: a CoreAudio device UID to pin to, or `nil`
    ///   to record from the system default input.
    init(preferredDeviceUID: String?) throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        // A pinned UID that no longer resolves means the device was unplugged
        // between the policy decision and now; the system default is the right
        // answer then, not a failed dictation.
        let pinned = preferredDeviceUID.flatMap { uid in
            discovery.devices.first { $0.uniqueID == uid }
        }
        guard let device = pinned ?? AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noInputDevice
        }
        source = Source(
            uid: device.uniqueID,
            name: device.localizedName,
            isRedirected: pinned != nil
        )

        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Begins delivering buffers. `onBuffer` runs on a private serial queue, so it
    /// must not block; it is released on `stop()`.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.withLock {
            handler = onBuffer
            startedAt = Date()
            isCapturing = true
        }
        session.startRunning()
    }

    /// Idempotent: cancel, error and normal-stop paths all reach it.
    func stop() {
        let wasCapturing = lock.withLock { () -> Bool in
            let was = isCapturing
            isCapturing = false
            handler = nil
            return was
        }
        guard wasCapturing else { return }
        session.stopRunning()
    }

    func hasReceivedAudio() -> Bool {
        lock.withLock { firstAudioAt != nil }
    }

    /// Milliseconds from `start()` to the first non-silent buffer. `nil` until
    /// real audio arrives, which is itself the signal that the mic is still warming.
    func startLatencyMs() -> Int? {
        lock.withLock {
            guard let startedAt, let firstAudioAt else { return nil }
            return max(0, Int(firstAudioAt.timeIntervalSince(startedAt) * 1000))
        }
    }

    func currentLevel() -> Float? {
        lock.withLock { isCapturing ? meterLevel : nil }
    }

    /// Normalised meter level for one buffer.
    ///
    /// The single copy of a curve that used to exist identically in
    /// `AVAudioEngineRecorder.currentInputLevel()` and
    /// `AppleSpeechDictationEngine.StreamingSession.rmsLevel(of:)`.
    static func normalizedLevel(rms: Double) -> Float {
        let decibels = Float(20 * log10(max(rms, 1e-7)))
        let floor: Float = -55
        let ceiling: Float = -8
        let clamped = Swift.min(Swift.max(decibels, floor), ceiling)
        let normalized = (clamped - floor) / (ceiling - floor)
        return Swift.min(Swift.max(sqrtf(normalized), 0), 1)
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = Self.makeBuffer(from: sampleBuffer) else { return }
        let scan = Self.scan(buffer)

        // The handler is invoked with the lock released: its consumers take locks
        // of their own, and holding this one across an opaque callback is how a
        // capture thread deadlocks against a stop path.
        let deliver = lock.withLock { () -> (@Sendable (AVAudioPCMBuffer) -> Void)? in
            guard isCapturing else { return nil }
            if scan.hasSignal, firstAudioAt == nil {
                firstAudioAt = Date()
            }
            meterLevel = Self.normalizedLevel(rms: scan.rms)
            return handler
        }
        deliver?(buffer)
    }

    private static func makeBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else {
            return nil
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        // The buffer-list pointer is passed straight through rather than a copy of
        // its `pointee`: an AudioBufferList is variable length, and copying the
        // head struct drops every buffer past the first on a non-interleaved device.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    /// One pass for both questions: is any sample non-zero, and what is the RMS.
    private static func scan(_ buffer: AVAudioPCMBuffer) -> (hasSignal: Bool, rms: Double) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return (false, 0) }

        var hasSignal = false
        var sum: Double = 0
        if let floatData = buffer.floatChannelData {
            let samples = floatData[0]
            for index in 0..<frames {
                let sample = samples[index]
                if sample != 0 { hasSignal = true }
                sum += Double(sample) * Double(sample)
            }
        } else if let intData = buffer.int16ChannelData {
            let samples = intData[0]
            for index in 0..<frames {
                let sample = samples[index]
                if sample != 0 { hasSignal = true }
                let scaled = Double(sample) / 32768
                sum += scaled * scaled
            }
        } else {
            return (false, 0)
        }
        return (hasSignal, (sum / Double(frames)).squareRoot())
    }
}
