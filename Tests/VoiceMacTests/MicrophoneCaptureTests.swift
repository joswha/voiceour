import AVFoundation
import CoreAudio
import Testing

@testable import VoiceMac

/// The microphone-selection policy. Values in, UID out, so the decision is
/// provable without a Bluetooth headset attached to the machine running the suite.
@Suite struct CaptureDevicePolicyTests {
    private func device(
        _ name: String,
        transport: UInt32,
        uid: String? = nil
    ) -> CoreAudioInputDevice.Device {
        CoreAudioInputDevice.Device(
            id: 0,
            uid: uid ?? "uid:\(name)",
            name: name,
            transportType: transport
        )
    }

    private var builtIn: CoreAudioInputDevice.Device {
        device("MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn, uid: "BuiltInMicrophoneDevice")
    }

    private var airPods: CoreAudioInputDevice.Device {
        device("AirPods Max", transport: kAudioDeviceTransportTypeBluetooth)
    }

    /// The whole point: a Bluetooth default hands over ~1.4 s of digital zeros
    /// while HFP/SCO negotiates, so capture goes to the built-in mic instead.
    @Test func bluetoothDefaultRedirectsToTheBuiltInMicrophone() {
        let uid = CoreAudioInputDevice.preferredCaptureUID(
            systemDefault: airPods,
            available: [airPods, builtIn]
        )

        #expect(uid == "BuiltInMicrophoneDevice")
    }

    @Test func bluetoothLowEnergyDefaultIsRedirectedToo() {
        let headset = device("LE Headset", transport: kAudioDeviceTransportTypeBluetoothLE)

        let uid = CoreAudioInputDevice.preferredCaptureUID(
            systemDefault: headset,
            available: [headset, builtIn]
        )

        #expect(uid == "BuiltInMicrophoneDevice")
    }

    /// `nil` means "record from the system default", which is what every
    /// non-Bluetooth default must keep doing.
    @Test func builtInDefaultIsLeftAlone() {
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                systemDefault: builtIn,
                available: [builtIn]
            ) == nil
        )
    }

    /// A USB interface, an aggregate device or a virtual microphone is a
    /// considered choice. Redirecting one would override the user, not help them.
    @Test func deliberatelyChosenNonBluetoothInputsAreNeverRedirected() {
        for transport in [
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeThunderbolt,
        ] {
            let chosen = device("Interface", transport: transport)

            #expect(
                CoreAudioInputDevice.preferredCaptureUID(
                    systemDefault: chosen,
                    available: [chosen, builtIn]
                ) == nil,
                "transport \(transport) must not be redirected"
            )
        }
    }

    /// A headset on a machine with no built-in microphone has nowhere better to
    /// go, so it records from the headset and warms up rather than failing.
    @Test func bluetoothDefaultWithNoBuiltInStaysOnTheHeadset() {
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                systemDefault: airPods,
                available: [airPods]
            ) == nil
        )
    }

    @Test func noDefaultInputMeansNoRedirect() {
        #expect(CoreAudioInputDevice.preferredCaptureUID(systemDefault: nil, available: [builtIn]) == nil)
    }
}

/// Conversion to the app's WAV format, including the route-change seam that used
/// to be an `AVAudioEngineConfigurationChange` observer.
@Suite struct CaptureConverterTests {
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// A tone rather than silence: a resampler that dropped everything would still
    /// satisfy a frame count, but it cannot fake energy at the far end.
    private func buffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        milliseconds: Int,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(sampleRate * Double(milliseconds) / 1000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                samples[index] = amplitude * sinf(2 * .pi * 440 * Float(index) / Float(sampleRate))
            }
        }
        return buffer
    }

    private func peak(_ buffers: [AVAudioPCMBuffer]) -> Int16 {
        var peak: Int16 = 0
        for buffer in buffers {
            guard let samples = buffer.int16ChannelData?[0] else { continue }
            for index in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[index]))
            }
        }
        return peak
    }

    private func frames(_ buffers: [AVAudioPCMBuffer]) -> Int {
        buffers.reduce(0) { $0 + Int($1.frameLength) }
    }

    @Test func resamplesDeviceAudioToTheAppsWavFormat() {
        let converter = CaptureConverter(targetFormat: target)

        let out = converter.convert(buffer(sampleRate: 48_000, channels: 1, milliseconds: 100))

        #expect(out.allSatisfy { $0.format.sampleRate == 16_000 })
        #expect(out.allSatisfy { $0.format.channelCount == 1 })
        #expect(out.allSatisfy { $0.format.commonFormat == .pcmFormatInt16 })
        // 100 ms in at 48 kHz is 100 ms out at 16 kHz, minus the resampler's
        // priming latency, which the drain then returns.
        #expect(frames(out) > 1_200)
        #expect(peak(out) > 8_000)
    }

    @Test func downmixesMultichannelInput() {
        let converter = CaptureConverter(targetFormat: target)

        let out = converter.convert(buffer(sampleRate: 44_100, channels: 2, milliseconds: 100))

        #expect(out.allSatisfy { $0.format.channelCount == 1 })
        #expect(peak(out) > 8_000)
    }

    /// The seam a route change actually arrives on. The converter must follow the
    /// new format AND keep the previous one's resampling tail, because dropping
    /// it truncates the utterance exactly where the device switched.
    @Test func followsASourceFormatChangeWithoutLosingTheTail() {
        let converter = CaptureConverter(targetFormat: target)

        let before = converter.convert(buffer(sampleRate: 48_000, channels: 1, milliseconds: 100))
        let across = converter.convert(buffer(sampleRate: 24_000, channels: 1, milliseconds: 100))
        let tail = converter.drain()

        #expect(!converter.didFailToFollowFormat)
        #expect(across.allSatisfy { $0.format.sampleRate == 16_000 })
        #expect(peak(across) > 8_000)
        // Both 100 ms segments survive: ~1600 frames each at 16 kHz, and the
        // seam contributes the first converter's drained remainder rather than a gap.
        #expect(frames(before) + frames(across) + frames(tail) > 3_100)
    }

    @Test func drainIsIdempotentAndSafeBeforeAnyAudio() {
        let converter = CaptureConverter(targetFormat: target)

        #expect(converter.drain().isEmpty)

        _ = converter.convert(buffer(sampleRate: 48_000, channels: 1, milliseconds: 40))
        _ = converter.drain()

        #expect(converter.drain().isEmpty)
        #expect(!converter.didFailToFollowFormat)
    }

    /// A format arriving that no converter can be built for is the one case the
    /// Apple path must hear about: its analyzer would otherwise finalize
    /// pre-change audio as though it were the whole utterance.
    @Test func unconvertibleSourceFormatLatchesTheFailureFlag() {
        let converter = CaptureConverter(targetFormat: target, makeConverter: { _, _ in nil })

        let out = converter.convert(buffer(sampleRate: 48_000, channels: 1, milliseconds: 40))

        #expect(out.isEmpty)
        #expect(converter.didFailToFollowFormat)
    }

    /// The failure must be reported at the seam, not swallowed: audio captured
    /// before an unfollowable change is still returned, and only then is the flag
    /// raised. That ordering is what lets the Apple path keep a usable WAV while
    /// refusing to serve the truncated streamed transcript.
    @Test func audioBeforeAnUnfollowableChangeIsStillReturned() {
        var calls = 0
        let converter = CaptureConverter(
            targetFormat: target,
            makeConverter: { source, destination in
                calls += 1
                return calls == 1 ? AVAudioConverter(from: source, to: destination) : nil
            }
        )

        let before = converter.convert(buffer(sampleRate: 48_000, channels: 1, milliseconds: 100))
        #expect(!converter.didFailToFollowFormat)
        #expect(peak(before) > 8_000)

        let across = converter.convert(buffer(sampleRate: 24_000, channels: 1, milliseconds: 100))

        #expect(converter.didFailToFollowFormat)
        // The dead converter's tail still comes back rather than being dropped.
        #expect(frames(before) + frames(across) > 1_500)
    }
}

/// Real-hardware coverage for the pinning mechanism itself, which no amount of
/// value-level testing can reach: that naming a device UID actually opens THAT
/// device and that liveness flips only once real samples arrive.
///
/// Gated on `VOICEOUR_CAPTURE_INTEGRATION` and `.serialized` for the same reason
/// `AppleSpeechASRTests` is: it opens the one physical microphone, and concurrent
/// sessions on a single input device deadlock.
@Suite("Microphone capture integration", .serialized)
struct MicrophoneCaptureIntegrationTests {
    private final class BufferCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    @Test func pinningOpensTheNamedDeviceAndReportsLivenessFromRealAudio() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_CAPTURE_INTEGRATION"] != nil else { return }
        guard let builtIn = CoreAudioInputDevice.all().first(where: \.isBuiltIn) else {
            Issue.record("no built-in input device on this host")
            return
        }

        let capture = try MicrophoneCapture(preferredDeviceUID: builtIn.uid)

        // Pinning is only meaningful if it is observable: a silent fall back to the
        // system default would look identical from the audio alone.
        #expect(capture.source.uid == builtIn.uid)
        #expect(capture.source.isRedirected)

        #expect(!capture.hasReceivedAudio())
        #expect(capture.startLatencyMs() == nil)
        #expect(capture.currentLevel() == nil)

        let counter = BufferCounter()
        capture.start { _ in counter.record() }

        // Bounded wait rather than a fixed sleep: the built-in microphone was
        // measured live on its first buffer, so this normally settles immediately.
        for _ in 0..<100 where !capture.hasReceivedAudio() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(capture.hasReceivedAudio())
        #expect(counter.value > 0)
        #expect(capture.currentLevel() != nil)
        let latency = capture.startLatencyMs()
        #expect(latency != nil)
        // A built-in microphone has no HFP link to negotiate. Anything approaching
        // the measured Bluetooth gap here means the pin did not take.
        #expect((latency ?? .max) < 1_000)

        capture.stop()
        #expect(capture.currentLevel() == nil)
        // The latency survives the stop: the coordinator reads it after the WAV
        // has already been handed over.
        #expect(capture.startLatencyMs() == latency)
        // Idempotent, as every cancel and error path relies on.
        capture.stop()
    }
}
