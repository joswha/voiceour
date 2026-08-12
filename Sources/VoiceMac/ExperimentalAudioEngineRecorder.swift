import AVFoundation
import AudioToolbox
import Foundation
import VoiceCore

public enum ExperimentalAudioEngineRecorderError: Error, LocalizedError, Sendable {
    case alreadyRecording
    case notRecording
    case unsupportedMode(CaptureProcessingMode, String)
    case invalidInputFormat(String)
    case noCapturedAudio
    case conversionFailed(String)
    case soundIsolationInstantiationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "the experimental recorder is already recording"
        case .notRecording:
            return "the experimental recorder is not recording"
        case .unsupportedMode(let mode, let reason):
            return "capture mode \(mode.rawValue) is unavailable: \(reason)"
        case .invalidInputFormat(let detail):
            return "unsupported microphone format: \(detail)"
        case .noCapturedAudio:
            return "the microphone delivered no audio buffers"
        case .conversionFailed(let detail):
            return "16 kHz mono conversion failed: \(detail)"
        case .soundIsolationInstantiationFailed(let detail):
            return "Sound Isolation could not be created: \(detail)"
        }
    }
}

public struct ExperimentalCaptureModeAvailability: Codable, Equatable, Sendable {
    public var mode: CaptureProcessingMode
    public var available: Bool
    public var unavailableReason: String?

    public init(mode: CaptureProcessingMode, available: Bool, unavailableReason: String? = nil) {
        self.mode = mode
        self.available = available
        self.unavailableReason = unavailableReason
    }
}

/// Measurement-only recorder. It is deliberately not wired into the app's default recorder.
/// Buffers remain at the engine's device-rate Float PCM format until telemetry and endpoint
/// bounds have been computed; the retained interval then goes through one converter to the
/// requested 16 kHz mono WAV.
public final class ExperimentalAudioEngineRecorder: @unchecked Sendable {
    private static let outputSampleRate = 16_000.0
    private static let maximumDurationMs = 600_000

    private let mode: CaptureProcessingMode
    private let outputURL: URL
    private let preRollMs: Int
    private let postRollMs: Int
    private let expectedDurationMs: Int
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private var captureStore: NativeCaptureStore?
    private var tappedNode: AVAudioNode?
    private var configurationObserver: NSObjectProtocol?
    private var recording = false

    public init(
        mode: CaptureProcessingMode,
        outputURL: URL,
        preRollMs: Int,
        postRollMs: Int,
        expectedDurationMs: Int
    ) throws {
        guard mode != .standard else {
            throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                mode,
                "standard is the production MicrophoneRecorder baseline, not an AVAudioEngine challenger"
            )
        }
        guard (1...Self.maximumDurationMs).contains(expectedDurationMs) else {
            throw ExperimentalAudioEngineRecorderError.invalidInputFormat(
                "duration must be between 1 and \(Self.maximumDurationMs) ms"
            )
        }
        guard preRollMs >= 0, postRollMs >= 0 else {
            throw ExperimentalAudioEngineRecorderError.invalidInputFormat("pre-roll and post-roll must not be negative")
        }
        self.mode = mode
        self.outputURL = outputURL
        self.preRollMs = preRollMs
        self.postRollMs = postRollMs
        self.expectedDurationMs = expectedDurationMs
    }

    deinit {
        if let tappedNode {
            tappedNode.removeTap(onBus: 0)
        }
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// This probe only inspects APIs/components. It never opens the input node or requests
    /// microphone permission, so it is safe for `--list-modes`.
    public static func availability(for mode: CaptureProcessingMode) -> ExperimentalCaptureModeAvailability {
        switch mode {
        case .standard:
            return ExperimentalCaptureModeAvailability(mode: mode, available: true)
        case .native, .voiceProcessing, .voiceProcessingNoAGC:
            return ExperimentalCaptureModeAvailability(mode: mode, available: true)
        case .soundIsolation:
            guard soundIsolationComponentIsInstalled() else {
                return ExperimentalCaptureModeAvailability(
                    mode: mode,
                    available: false,
                    unavailableReason: "AUSoundIsolation is not installed"
                )
            }
            return ExperimentalCaptureModeAvailability(mode: mode, available: true)
        case .soundIsolationHighQuality:
            guard #available(macOS 15.0, *) else {
                return ExperimentalCaptureModeAvailability(
                    mode: mode,
                    available: false,
                    unavailableReason: "High Quality Voice Sound Isolation requires macOS 15 or later"
                )
            }
            guard soundIsolationComponentIsInstalled() else {
                return ExperimentalCaptureModeAvailability(
                    mode: mode,
                    available: false,
                    unavailableReason: "AUSoundIsolation is not installed"
                )
            }
            return ExperimentalCaptureModeAvailability(mode: mode, available: true)
        }
    }

    public func start() throws {
        let wasRecording = withStateLock { () -> Bool in
            let was = recording
            if !was { recording = true }
            return was
        }
        guard !wasRecording else { throw ExperimentalAudioEngineRecorderError.alreadyRecording }

        do {
            let advertised = Self.availability(for: mode)
            guard advertised.available else {
                throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                    mode,
                    advertised.unavailableReason ?? "not supported on this system"
                )
            }

            let inputNode = engine.inputNode
            try configureVoiceProcessing(on: inputNode)
            let inputFormat = inputNode.outputFormat(forBus: 0)
            try Self.validateNativeFormat(inputFormat)

            let expectedFrames = Int((Double(expectedDurationMs) / 1_000.0) * inputFormat.sampleRate)
            let store = NativeCaptureStore(
                sampleRate: inputFormat.sampleRate,
                channels: Int(inputFormat.channelCount),
                expectedFrames: expectedFrames
            )
            captureStore = store

            engine.mainMixerNode.outputVolume = 0
            let nodeToTap: AVAudioNode
            let tapFormat: AVAudioFormat
            if mode == .soundIsolation || mode == .soundIsolationHighQuality {
                let isolationUnit = try Self.instantiateSoundIsolationUnit()
                try configureSoundIsolation(isolationUnit)
                engine.attach(isolationUnit)
                engine.connect(inputNode, to: isolationUnit, format: inputFormat)
                engine.connect(isolationUnit, to: engine.mainMixerNode, format: inputFormat)
                nodeToTap = isolationUnit
                tapFormat = isolationUnit.outputFormat(forBus: 0)
                try Self.validateNativeFormat(tapFormat)
            } else {
                engine.connect(inputNode, to: engine.mainMixerNode, format: inputFormat)
                nodeToTap = inputNode
                tapFormat = inputFormat
            }

            guard tapFormat.sampleRate == inputFormat.sampleRate,
                tapFormat.channelCount == inputFormat.channelCount
            else {
                throw ExperimentalAudioEngineRecorderError.invalidInputFormat(
                    "processing changed the native \(Int(inputFormat.sampleRate)) Hz/\(inputFormat.channelCount)-channel format before telemetry"
                )
            }

            nodeToTap.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { buffer, time in
                store.append(buffer: buffer, at: time)
            }
            tappedNode = nodeToTap
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { _ in
                store.noteRouteChange()
            }

            engine.prepare()
            try engine.start()
        } catch {
            cleanupAfterCapture(deleteOutput: true)
            throw error
        }
    }

    public func stop() async throws -> RecordedAudio {
        let wasRecording = withStateLock { () -> Bool in
            let was = recording
            recording = false
            return was
        }
        guard wasRecording, let store = captureStore else {
            throw ExperimentalAudioEngineRecorderError.notRecording
        }

        if let tappedNode {
            tappedNode.removeTap(onBus: 0)
        }
        tappedNode = nil
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        let capture = store.snapshot()
        captureStore = nil
        guard capture.frameCount > 0 else {
            cleanupAfterCapture(deleteOutput: true)
            throw ExperimentalAudioEngineRecorderError.noCapturedAudio
        }

        do {
            let analysis = SpeechEnergyAnalysis(
                interleavedSamples: capture.samples,
                frameCount: capture.frameCount,
                channels: capture.channels,
                sampleRate: capture.sampleRate
            )
            let bounds = analysis.retainedFrameBounds(preRollMs: preRollMs, postRollMs: postRollMs)
            let writtenFrames = try Self.writeWAV(
                capture: capture,
                frameRange: bounds,
                outputURL: outputURL
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let durationMs = Int((Double(writtenFrames) / Self.outputSampleRate * 1_000.0).rounded())
            let telemetry = CaptureTelemetryAnalyzer.analyze(
                samples: capture.samples,
                sampleRateHz: Int(capture.sampleRate.rounded()),
                channels: capture.channels,
                outputFormat: CaptureAudioFormat(
                    sampleRateHz: Int(Self.outputSampleRate),
                    channels: 1,
                    encoding: "pcm_s16le"
                ),
                processingMode: mode,
                routeChangeCount: capture.routeChangeCount,
                droppedBufferCount: capture.droppedBufferCount,
                zeroBufferCount: capture.zeroBufferCount
            )
            cleanupAfterCapture(deleteOutput: false)
            return RecordedAudio(
                url: outputURL,
                meta: ASRAudioMeta(
                    path: outputURL.path,
                    format: "wav",
                    sampleRateHz: Int(Self.outputSampleRate),
                    channels: 1,
                    durationMs: durationMs,
                    byteCount: byteCount
                ),
                telemetry: telemetry
            )
        } catch {
            cleanupAfterCapture(deleteOutput: true)
            throw error
        }
    }

    public func discardRecording() {
        cleanupAfterCapture(deleteOutput: true)
    }

    private func configureVoiceProcessing(on inputNode: AVAudioInputNode) throws {
        switch mode {
        case .voiceProcessing, .voiceProcessingNoAGC:
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                    mode,
                    "the active input/output route rejected AVAudioEngine Voice Processing: \(error.localizedDescription)"
                )
            }
            inputNode.isVoiceProcessingBypassed = false
            inputNode.isVoiceProcessingAGCEnabled = mode == .voiceProcessing
            guard inputNode.isVoiceProcessingEnabled,
                inputNode.isVoiceProcessingAGCEnabled == (mode == .voiceProcessing)
            else {
                throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                    mode,
                    "the active route did not apply the requested Voice Processing/AGC state"
                )
            }
        case .native, .soundIsolation, .soundIsolationHighQuality:
            if inputNode.isVoiceProcessingEnabled {
                do {
                    try inputNode.setVoiceProcessingEnabled(false)
                } catch {
                    throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                        mode,
                        "the active route could not disable AVAudioEngine Voice Processing: \(error.localizedDescription)"
                    )
                }
            }
            guard !inputNode.isVoiceProcessingEnabled else {
                throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                    mode,
                    "AVAudioEngine Voice Processing remained enabled"
                )
            }
        case .standard:
            break
        }
    }

    private func configureSoundIsolation(_ unit: AVAudioUnit) throws {
        let audioUnit = unit.audioUnit
        var status = AudioUnitSetParameter(
            audioUnit,
            kAUSoundIsolationParam_WetDryMixPercent,
            kAudioUnitScope_Global,
            0,
            100,
            0
        )
        guard status == noErr else {
            throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                mode, "wet/dry parameter failed with OSStatus \(status)")
        }

        let soundType: AudioUnitParameterValue
        if mode == .soundIsolationHighQuality {
            guard #available(macOS 15.0, *) else {
                throw ExperimentalAudioEngineRecorderError.unsupportedMode(mode, "requires macOS 15 or later")
            }
            soundType = AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice)
        } else {
            soundType = AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice)
        }
        status = AudioUnitSetParameter(
            audioUnit,
            kAUSoundIsolationParam_SoundToIsolate,
            kAudioUnitScope_Global,
            0,
            soundType,
            0
        )
        guard status == noErr else {
            throw ExperimentalAudioEngineRecorderError.unsupportedMode(
                mode,
                "requested Sound Isolation model failed with OSStatus \(status)"
            )
        }
    }

    private func cleanupAfterCapture(deleteOutput: Bool) {
        if let tappedNode {
            tappedNode.removeTap(onBus: 0)
        }
        tappedNode = nil
        engine.stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        captureStore = nil
        withStateLock { recording = false }
        if deleteOutput {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private static func validateNativeFormat(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ExperimentalAudioEngineRecorderError.invalidInputFormat(
                "device reported \(format.sampleRate) Hz and \(format.channelCount) channels"
            )
        }
        guard format.commonFormat == .pcmFormatFloat32,
            !format.isInterleaved
        else {
            throw ExperimentalAudioEngineRecorderError.invalidInputFormat(
                "expected non-interleaved Float32 PCM, got \(format)"
            )
        }
    }

    private static func soundIsolationDescription() -> AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    private static func soundIsolationComponentIsInstalled() -> Bool {
        var description = soundIsolationDescription()
        return AudioComponentFindNext(nil, &description) != nil
    }

    private static func instantiateSoundIsolationUnit() throws -> AVAudioUnit {
        guard soundIsolationComponentIsInstalled() else {
            throw ExperimentalAudioEngineRecorderError.soundIsolationInstantiationFailed("component is not installed")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var instantiatedUnit: AVAudioUnit?
        var instantiatedError: Error?
        AVAudioUnit.instantiate(with: soundIsolationDescription(), options: []) { unit, error in
            resultLock.lock()
            instantiatedUnit = unit
            instantiatedError = error
            resultLock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw ExperimentalAudioEngineRecorderError.soundIsolationInstantiationFailed("instantiation timed out")
        }
        resultLock.lock()
        let unit = instantiatedUnit
        let error = instantiatedError
        resultLock.unlock()
        guard let unit else {
            throw ExperimentalAudioEngineRecorderError.soundIsolationInstantiationFailed(
                error?.localizedDescription ?? "component returned no Audio Unit"
            )
        }
        return unit
    }

    private static func writeWAV(
        capture: NativeCaptureSnapshot,
        frameRange: Range<Int>,
        outputURL: URL
    ) throws -> AVAudioFramePosition {
        guard !frameRange.isEmpty else {
            throw ExperimentalAudioEngineRecorderError.noCapturedAudio
        }
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: capture.sampleRate,
                channels: AVAudioChannelCount(capture.channels),
                interleaved: false
            ),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: outputSampleRate,
                channels: 1,
                interleaved: true
            )
        else {
            throw ExperimentalAudioEngineRecorderError.conversionFailed("could not create PCM formats")
        }
        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameRange.count)
            ), let sourceChannels = sourceBuffer.floatChannelData
        else {
            throw ExperimentalAudioEngineRecorderError.conversionFailed("could not allocate source buffer")
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frameRange.count)
        for channel in 0..<capture.channels {
            let destination = sourceChannels[channel]
            for (destinationFrame, sourceFrame) in frameRange.enumerated() {
                destination[destinationFrame] = capture.samples[sourceFrame * capture.channels + channel]
            }
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ExperimentalAudioEngineRecorderError.conversionFailed("AVAudioConverter rejected the format pair")
        }
        let estimatedOutputFrames = Int(ceil(Double(frameRange.count) * outputSampleRate / capture.sampleRate)) + 256
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(estimatedOutputFrames)
            )
        else {
            throw ExperimentalAudioEngineRecorderError.conversionFailed("could not allocate output buffer")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            throw ExperimentalAudioEngineRecorderError.conversionFailed(
                conversionError?.localizedDescription ?? "converter returned status \(status.rawValue)"
            )
        }

        let fileManager = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".\(UUID().uuidString).capture.tmp.wav")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        let file = try AVAudioFile(
            forWriting: temporaryURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: outputBuffer)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: outputURL)
        return AVAudioFramePosition(outputBuffer.frameLength)
    }
}

private struct NativeCaptureSnapshot: Sendable {
    var samples: [Float]
    var frameCount: Int
    var sampleRate: Double
    var channels: Int
    var routeChangeCount: Int
    var droppedBufferCount: Int
    var zeroBufferCount: Int
}

private final class NativeCaptureStore: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Double
    private let channels: Int
    private var samples: [Float]
    private var routeChangeCount = 0
    private var droppedBufferCount = 0
    private var zeroBufferCount = 0
    private var expectedNextSampleTime: AVAudioFramePosition?

    init(sampleRate: Double, channels: Int, expectedFrames: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = []
        self.samples.reserveCapacity(max(0, expectedFrames * channels))
    }

    func append(buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else {
            lock.lock()
            zeroBufferCount += 1
            lock.unlock()
            return
        }

        lock.lock()
        defer { lock.unlock() }
        if time.isSampleTimeValid, let expectedNextSampleTime, time.sampleTime != expectedNextSampleTime {
            droppedBufferCount += 1
        }
        if time.isSampleTimeValid {
            expectedNextSampleTime = time.sampleTime + AVAudioFramePosition(frames)
        }

        let originalCount = samples.count
        samples.append(contentsOf: repeatElement(0, count: frames * channels))
        var hasNonzeroSample = false
        for frame in 0..<frames {
            for channel in 0..<channels {
                let sample = channelData[channel][frame]
                samples[originalCount + frame * channels + channel] = sample
                hasNonzeroSample = hasNonzeroSample || sample != 0
            }
        }
        if !hasNonzeroSample {
            zeroBufferCount += 1
        }
    }

    func noteRouteChange() {
        lock.lock()
        routeChangeCount += 1
        expectedNextSampleTime = nil
        lock.unlock()
    }

    func snapshot() -> NativeCaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return NativeCaptureSnapshot(
            samples: samples,
            frameCount: samples.count / channels,
            sampleRate: sampleRate,
            channels: channels,
            routeChangeCount: routeChangeCount,
            droppedBufferCount: droppedBufferCount,
            zeroBufferCount: zeroBufferCount
        )
    }
}

private struct SpeechEnergyAnalysis {
    private static let windowMs = 20
    private static let absoluteActivityFloorDBFS = -42.0
    private static let activityMarginDB = 9.0

    let frameCount: Int
    let windowRanges: [Range<Int>]
    let sampleRate: Double
    let activeWindows: [Bool]

    init(interleavedSamples: [Float], frameCount: Int, channels: Int, sampleRate: Double) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate

        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                let sample = interleavedSamples[frame * channels + channel]
                sum += sample
            }
            mono[frame] = sum / Float(channels)
        }

        let windowFrames = max(1, Int((sampleRate * Double(Self.windowMs) / 1_000.0).rounded()))
        var ranges: [Range<Int>] = []
        var powersDB: [Double] = []
        ranges.reserveCapacity((frameCount + windowFrames - 1) / windowFrames)
        powersDB.reserveCapacity(ranges.capacity)
        var start = 0
        while start < frameCount {
            let end = min(frameCount, start + windowFrames)
            let range = start..<end
            ranges.append(range)
            var sumSquares = 0.0
            for frame in range {
                let sample = Double(mono[frame])
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Double(range.count))
            powersDB.append(Self.decibels(amplitude: rms))
            start = end
        }
        windowRanges = ranges

        let finitePowers = powersDB.filter(\.isFinite).sorted()
        let noiseIndex = finitePowers.isEmpty ? 0 : min(finitePowers.count - 1, finitePowers.count / 5)
        let noise = finitePowers.isEmpty ? -120 : finitePowers[noiseIndex]
        let activityThreshold = max(Self.absoluteActivityFloorDBFS, noise + Self.activityMarginDB)
        activeWindows = powersDB.map { $0 >= activityThreshold }
    }

    func retainedFrameBounds(preRollMs: Int, postRollMs: Int) -> Range<Int> {
        guard let firstActive = activeWindows.firstIndex(of: true),
            let lastActive = activeWindows.lastIndex(of: true)
        else {
            return 0..<frameCount
        }
        let preRollFrames = Int((Double(preRollMs) * sampleRate / 1_000.0).rounded())
        let postRollFrames = Int((Double(postRollMs) * sampleRate / 1_000.0).rounded())
        let start = max(0, windowRanges[firstActive].lowerBound - preRollFrames)
        let end = min(frameCount, windowRanges[lastActive].upperBound + postRollFrames)
        return start..<end
    }

    private static func decibels(amplitude: Double) -> Double {
        guard amplitude > 0 else { return -120 }
        return max(-120, 20 * log10(amplitude))
    }
}
