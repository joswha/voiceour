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
            selectedUID: nil,
            systemDefault: airPods,
            available: [airPods, builtIn],
            lidIsClosed: false
        )

        #expect(uid == "BuiltInMicrophoneDevice")
    }

    @Test func bluetoothLowEnergyDefaultIsRedirectedToo() {
        let headset = device("LE Headset", transport: kAudioDeviceTransportTypeBluetoothLE)

        let uid = CoreAudioInputDevice.preferredCaptureUID(
            selectedUID: nil,
            systemDefault: headset,
            available: [headset, builtIn],
            lidIsClosed: false
        )

        #expect(uid == "BuiltInMicrophoneDevice")
    }

    /// A shut lid does not slow the built-in array down, it silences it: 552 of
    /// 552 buffers were exactly zero in clamshell. Redirecting there swaps a
    /// headset that warms up in half a second for a microphone that never
    /// arrives, so the headset keeps the dictation.
    @Test func aClosedLidKeepsTheDictationOnTheBluetoothHeadset() {
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                selectedUID: nil,
                systemDefault: airPods,
                available: [airPods, builtIn],
                lidIsClosed: true
            ) == nil
        )
    }

    /// `nil` means "record from the system default", which is what every
    /// non-Bluetooth default must keep doing.
    @Test func builtInDefaultIsLeftAlone() {
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                selectedUID: nil,
                systemDefault: builtIn,
                available: [builtIn],
                lidIsClosed: false
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
                    selectedUID: nil,
                    systemDefault: chosen,
                    available: [chosen, builtIn],
                    lidIsClosed: false
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
                selectedUID: nil,
                systemDefault: airPods,
                available: [airPods],
                lidIsClosed: false
            ) == nil
        )
    }

    @Test func noDefaultInputMeansNoRedirect() {
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                selectedUID: nil,
                systemDefault: nil,
                available: [builtIn],
                lidIsClosed: false
            ) == nil
        )
    }

    /// The Settings selection outranks the automatic policy in both directions:
    /// it wins over a Bluetooth redirect that would otherwise fire, and it holds
    /// a Bluetooth device the redirect would otherwise flee — a device the user
    /// pointed at by name is a considered choice.
    @Test func aResolvableUserSelectionAlwaysWins() {
        let yeti = device("Yeti Stereo Microphone", transport: kAudioDeviceTransportTypeUSB, uid: "usb-yeti")

        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                selectedUID: "usb-yeti",
                systemDefault: airPods,
                available: [airPods, builtIn, yeti],
                lidIsClosed: false
            ) == "usb-yeti"
        )
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                selectedUID: airPods.uid,
                systemDefault: airPods,
                available: [airPods, builtIn],
                lidIsClosed: false
            ) == airPods.uid
        )
    }

    /// An unplugged selection falls back to the whole automatic policy — the
    /// Bluetooth redirect included — rather than failing the dictation or
    /// pinning to hardware that is not there.
    @Test func anUnpluggedUserSelectionFallsBackToTheAutomaticPolicy() {
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                selectedUID: "usb-yeti-unplugged",
                systemDefault: airPods,
                available: [airPods, builtIn],
                lidIsClosed: false
            ) == "BuiltInMicrophoneDevice"
        )
        #expect(
            CoreAudioInputDevice.preferredCaptureUID(
                selectedUID: "usb-yeti-unplugged",
                systemDefault: builtIn,
                available: [builtIn],
                lidIsClosed: false
            ) == nil
        )
    }

    /// The Settings picker's live HAL read: every entry carries the durable UID a
    /// selection would persist, and the order is the stated name-then-UID sort so
    /// the menu cannot reshuffle with CoreAudio's enumeration order.
    @Test func availableMicrophonesAreSortedAndDurablyIdentified() {
        let microphones = CoreAudioInputDevice.availableMicrophones()

        #expect(microphones.allSatisfy { !$0.uid.isEmpty })
        let keys = microphones.map { ($0.name, $0.uid) }
        #expect(keys.map { $0.0 + "\u{1F}" + $0.1 } == keys.sorted(by: <).map { $0.0 + "\u{1F}" + $0.1 })
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

    /// A format arriving that no converter can be built for must latch a
    /// capture failure; otherwise the recorder could accept pre-change audio
    /// as though it were the whole utterance.
    @Test func unconvertibleSourceFormatLatchesTheFailureFlag() {
        let converter = CaptureConverter(targetFormat: target, makeConverter: { _, _ in nil })

        let out = converter.convert(buffer(sampleRate: 48_000, channels: 1, milliseconds: 40))

        #expect(out.isEmpty)
        #expect(converter.didFailToFollowFormat)
    }

    /// The failure must be reported at the seam, not swallowed: audio captured
    /// before an unfollowable change is still returned, and only then is the flag
    /// raised. That ordering preserves the usable prefix while ensuring the
    /// recorder rejects the truncated capture.
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
/// Gated on `VOICEOUR_CAPTURE_INTEGRATION` and `.serialized` because it opens
/// the one physical microphone, and concurrent sessions on a single input
/// device deadlock.
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

    /// The end-to-end claim the policy makes: whatever `preferredCaptureUID()`
    /// chooses on THIS host, opening it produces real samples. A choice that
    /// streams digital zeros forever satisfies every value-level test and still
    /// hangs the session in WARMING, which is exactly what redirecting to a
    /// clamshell built-in microphone did.
    @Test func theChosenCaptureDeviceDeliversRealAudio() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_CAPTURE_INTEGRATION"] != nil else { return }

        let capture = try MicrophoneCapture(
            preferredDeviceUID: CoreAudioInputDevice.preferredCaptureUID(selectedUID: nil))
        capture.start { _ in }
        defer { capture.stop() }

        // Generous on purpose: a Continuity iPhone microphone was measured at
        // 3782 ms to its first buffer and cold AirPods Max at 1422 ms to its
        // first non-zero sample. A room's noise floor is never exactly zero, so
        // this needs no one to speak.
        for _ in 0..<250 where !capture.hasReceivedAudio() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(
            capture.hasReceivedAudio(),
            """
            \(capture.source.name) delivered no audio in 5 s \
            (redirected: \(capture.source.isRedirected), lid closed: \(LidState.isClosed()))
            """
        )
    }

    @Test func pinningOpensTheNamedDeviceAndReportsLivenessFromRealAudio() async throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_CAPTURE_INTEGRATION"] != nil else { return }
        // A shut lid silences the built-in array outright, so on this host the
        // premise of the test — a built-in microphone that can be heard — is
        // absent, not broken.
        guard !LidState.isClosed() else { return }
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

    /// The Phase-5 latch tests proved the pure decision; this proves the wiring.
    /// Runtime-error notifications must be scoped to the session this capture
    /// opened, and the first latched reason must win over later ones.
    @Test func runtimeErrorNotificationsAreScopedAndLatchFirstWriterWins() throws {
        guard ProcessInfo.processInfo.environment["VOICEOUR_CAPTURE_INTEGRATION"] != nil else { return }

        let capture = try MicrophoneCapture(preferredDeviceUID: nil)
        let center = NotificationCenter.default

        // A runtime error on someone else's session is not this capture's failure.
        center.post(
            name: AVCaptureSession.runtimeErrorNotification,
            object: AVCaptureSession(),
            userInfo: [AVCaptureSessionErrorKey: NSError(domain: "test", code: 1)]
        )
        #expect(capture.failureReason() == nil)

        center.post(
            name: AVCaptureSession.runtimeErrorNotification,
            object: capture.session,
            userInfo: [
                AVCaptureSessionErrorKey: NSError(
                    domain: "test", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "first failure"]
                )
            ]
        )
        let first = capture.failureReason()
        #expect(first != nil)

        // First-writer-wins: a second error must not overwrite the original cause.
        center.post(
            name: AVCaptureSession.runtimeErrorNotification,
            object: capture.session,
            userInfo: [
                AVCaptureSessionErrorKey: NSError(
                    domain: "test", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "second failure"]
                )
            ]
        )
        #expect(capture.failureReason() == first)
    }
}

/// What `MicrophoneRecorder.stop()` refuses to hand to ASR.
///
/// The rule used to be "the file exists", which a header-only WAV satisfies. The
/// decoder does not answer silence with silence: 8 s of quiet dither through the
/// shipped backend produced `"Esta mañana está en su mayor mayor mayor."`, and a
/// dictation app pastes that into the user's document.
@Suite struct RecordingValidationTests {
    @Test func aLatchedCaptureFailureIsReportedInsteadOfTranscribed() throws {
        let failure = MicrophoneRecorder.recordingFailure(
            latched: "the microphone was disconnected during recording",
            converterLostRoute: false,
            frames: 48_000,
            silentCapture: nil
        )
        guard case .captureFailed(let reason) = try #require(failure) else {
            Issue.record("expected a captureFailed error, got \(String(describing: failure))")
            return
        }
        #expect(reason == "the microphone was disconnected during recording")
    }

    /// Zero accepted frames covers a device that never delivered a buffer and a
    /// file that rejected every write. Both used to reach the model.
    @Test func aRecordingThatWroteNoFramesIsReportedInsteadOfTranscribed() throws {
        let failure = MicrophoneRecorder.recordingFailure(
            latched: nil, converterLostRoute: false, frames: 0, silentCapture: nil)
        guard case .captureFailed(let reason) = try #require(failure) else {
            Issue.record("expected a captureFailed error, got \(String(describing: failure))")
            return
        }
        #expect(reason == "no audio was recorded")
    }

    /// The shape a dead microphone actually produces: a full-length WAV, every
    /// frame accepted, every sample zero. The frame count alone calls that
    /// healthy, which is how a clamshell built-in microphone reached the decoder.
    @Test func aCaptureThatHeardOnlySilenceIsReportedInsteadOfTranscribed() throws {
        let failure = MicrophoneRecorder.recordingFailure(
            latched: nil,
            converterLostRoute: false,
            frames: 96_000,
            silentCapture: "MacBook Pro Microphone hears nothing while the lid is closed"
        )
        guard case .captureFailed(let reason) = try #require(failure) else {
            Issue.record("expected a captureFailed error, got \(String(describing: failure))")
            return
        }
        #expect(reason == "MacBook Pro Microphone hears nothing while the lid is closed")
    }

    /// Silence outranks the frame count, which would otherwise reduce the one
    /// diagnostic the user can act on to "no audio was recorded".
    @Test func aSilentCaptureOutranksTheFrameCount() throws {
        let failure = try #require(
            MicrophoneRecorder.recordingFailure(
                latched: nil, converterLostRoute: false, frames: 0,
                silentCapture: "AirPods Max delivered no audio"
            )
        )
        guard case .captureFailed(let reason) = failure else {
            Issue.record("expected a captureFailed error")
            return
        }
        #expect(reason == "AirPods Max delivered no audio")
    }

    /// A latched runtime error or disconnect still names the cause first: it
    /// explains why the samples stopped, where the silence only reports them.
    @Test func aLatchedFailureOutranksSilence() throws {
        let failure = try #require(
            MicrophoneRecorder.recordingFailure(
                latched: "the microphone was disconnected during recording",
                converterLostRoute: false,
                frames: 48_000,
                silentCapture: "AirPods Max delivered no audio"
            )
        )
        guard case .captureFailed(let reason) = failure else {
            Issue.record("expected a captureFailed error")
            return
        }
        #expect(reason == "the microphone was disconnected during recording")
    }

    /// The lid clause is the difference between a user who knows to open the lid
    /// and one who reads that an unnamed microphone failed. It applies only to a
    /// built-in array: nothing about a closed lid silences a USB or Bluetooth mic.
    @Test func onlyAClosedLidOnABuiltInMicrophoneIsNamedAsTheCause() {
        #expect(
            MicrophoneRecorder.silentCaptureReason(
                device: "MacBook Pro Microphone", isBuiltIn: true, lidIsClosed: true
            ) == "MacBook Pro Microphone hears nothing while the lid is closed"
        )
        #expect(
            MicrophoneRecorder.silentCaptureReason(
                device: "MacBook Pro Microphone", isBuiltIn: true, lidIsClosed: false
            ) == "MacBook Pro Microphone delivered no audio"
        )
        #expect(
            MicrophoneRecorder.silentCaptureReason(
                device: "Vlad’s AirPods Max", isBuiltIn: false, lidIsClosed: true
            ) == "Vlad’s AirPods Max delivered no audio"
        )
    }

    /// The latch wins over the frame count: it names the cause, and a failed
    /// capture can still have written frames before it failed.
    @Test func aLatchedFailureOutranksAHealthyFrameCount() throws {
        let failure = try #require(
            MicrophoneRecorder.recordingFailure(
                latched: "session runtime error", converterLostRoute: false, frames: 1,
                silentCapture: nil
            )
        )
        guard case .captureFailed(let reason) = failure else {
            Issue.record("expected a captureFailed error")
            return
        }
        #expect(reason == "session runtime error")
    }

    /// A converter that could not follow a mid-recording format change stopped
    /// contributing audio — a silently short recording, refused even though the
    /// frames written before the change look healthy.
    @Test func aLostRouteIsReportedInsteadOfTranscribed() throws {
        let failure = MicrophoneRecorder.recordingFailure(
            latched: nil, converterLostRoute: true, frames: 48_000, silentCapture: nil)
        guard case .captureFailed(let reason) = try #require(failure) else {
            Issue.record("expected a captureFailed error, got \(String(describing: failure))")
            return
        }
        #expect(reason == MicrophoneRecorder.routeFollowFailureReason)
    }

    /// Precedence is latch > route > silence > frames: the latch names the
    /// specific cause, and the route loss explains an otherwise healthy-looking
    /// frame count.
    @Test func aLatchedFailureOutranksALostRoute() throws {
        let failure = try #require(
            MicrophoneRecorder.recordingFailure(
                latched: "session runtime error", converterLostRoute: true, frames: 0,
                silentCapture: nil
            )
        )
        guard case .captureFailed(let reason) = failure else {
            Issue.record("expected a captureFailed error")
            return
        }
        #expect(reason == "session runtime error")
    }

    @Test func aCleanRecordingWithAudioIsAccepted() {
        #expect(
            MicrophoneRecorder.recordingFailure(
                latched: nil, converterLostRoute: false, frames: 1, silentCapture: nil
            ) == nil
        )
    }
}
