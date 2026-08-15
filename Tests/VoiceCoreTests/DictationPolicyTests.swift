import Testing

@testable import VoiceCore

@Suite("DictationPolicy")
struct DictationPolicyTests {
    @Test func launchOptionsParsesSeparateArguments() {
        let options = LaunchOptions(arguments: [
            "--repo-root", "/tmp/repo",
            "--asr-backend", "PARAKEET",
        ])

        #expect(options.repoRoot == "/tmp/repo")
        #expect(options.asrBackend == "parakeet")
    }

    @Test func launchOptionsParsesInlineArguments() {
        let options = LaunchOptions(arguments: [
            "--repo-root=/tmp/inline-repo",
            "--asr-backend=fake",
        ])

        #expect(options.repoRoot == "/tmp/inline-repo")
        #expect(options.asrBackend == "fake")
    }

    @Test func launchOptionsRejectsInvalidBackend() {
        let options = LaunchOptions(arguments: ["--asr-backend", "sherpa"])

        #expect(options.asrBackend == nil)
        #expect(LaunchOptions.validBackend(" fake ") == "fake")
        #expect(LaunchOptions.validBackend("PARAKEET") == "parakeet")
        #expect(LaunchOptions.validBackend("sherpa") == nil)
    }

    /// An install that persisted one of the retired Python-sidecar backend ids keeps its real
    /// backend. Without the mapping every one of these would fail validation and silently fall
    /// through to the fake backend on the next launch.
    @Test func retiredBackendIdsNormalizeToParakeet() {
        #expect(LaunchOptions.validBackend("mlx") == "parakeet")
        #expect(LaunchOptions.validBackend("MLX") == "parakeet")
        #expect(LaunchOptions.validBackend("ark-0.6b") == "parakeet")
        #expect(LaunchOptions.validBackend("ark-3b") == "parakeet")
        #expect(LaunchOptions(arguments: ["--asr-backend=mlx"]).asrBackend == "parakeet")
    }

    @Test func launchOptionsIgnoresMissingValues() {
        let options = LaunchOptions(arguments: [
            "--repo-root",
            "--asr-backend",
        ])

        #expect(options.repoRoot == nil)
        #expect(options.asrBackend == nil)
    }

    // The no-speech gate. ASR models invent text from noise rather than returning
    // nothing: measured on this machine, 8 s of quiet dither produced
    // "Esta mañana está en su mayor mayor mayor." from the default backend and
    // "嗯。" from ark-0.6b, neither of which shouldSkipTranscript can catch. snrDB is
    // the discriminator because it is the p90-minus-p10 gap of 10 ms buffer RMS, so
    // flat noise collapses to ~0 while speech keeps a wide gap: measured 0.0/0.8/0.8
    // for zeros/dither/hiss against 20.4-52.8 for nine real clips.
    private static func telemetry(snrDB: Double) -> CaptureTelemetry {
        let format = CaptureAudioFormat(sampleRateHz: 16_000, channels: 1, encoding: "pcm_s16le")
        return CaptureTelemetry(
            inputFormat: format,
            outputFormat: format,
            clipRatio: 0,
            activeSpeechRatio: 0,
            peakDBFS: -30,
            noiseFloorDBFS: -60,
            snrDB: snrDB,
            leadingSilenceMs: 0,
            trailingSilenceMs: 0,
            routeChangeCount: 0,
            droppedBufferCount: 0,
            zeroBufferCount: 0,
            processingMode: .standard
        )
    }

    @Test func noiseLevelCaptureIsTreatedAsSpeechless() {
        // 0.8 dB is the measured value for both quiet dither and hiss.
        #expect(
            DictationPolicy.capturedSpeechIsAbsent(
                telemetry: Self.telemetry(snrDB: 0.8),
                isSynthetic: false
            ))
    }

    @Test func quietRealSpeechIsNotTreatedAsSpeechless() {
        // 20.4 dB is the quietest of nine measured real speech clips.
        #expect(
            !DictationPolicy.capturedSpeechIsAbsent(
                telemetry: Self.telemetry(snrDB: 20.4),
                isSynthetic: false
            ))
    }

    // Both fail-open directions. The fake recorder writes literal silence and
    // synthesises a transcript, which is its contract; and suppressing a real
    // dictation on absent evidence is worse than passing noise through.
    @Test func syntheticCaptureIsNeverGated() {
        #expect(
            !DictationPolicy.capturedSpeechIsAbsent(
                telemetry: Self.telemetry(snrDB: 0),
                isSynthetic: true
            ))
    }

    @Test func absentTelemetryIsNeverGated() {
        #expect(!DictationPolicy.capturedSpeechIsAbsent(telemetry: nil, isSynthetic: false))
    }

    @Test func blankTranscriptDecision() {
        #expect(DictationPolicy.shouldSkipTranscript(""))
        #expect(DictationPolicy.shouldSkipTranscript("  \n\t  "))
        #expect(!DictationPolicy.shouldSkipTranscript("hello"))
        #expect(!DictationPolicy.shouldSkipTranscript("  hello  "))
    }

    @Test func insertionOutcomeMappingKeepsFailureCriticalAndCopyOnlyNonCritical() {
        let pasted = DictationPolicy.sessionState(for: .pasteAttempted)
        let copied = DictationPolicy.sessionState(for: .copiedOnly(reason: "target_terminal"))
        let failed = DictationPolicy.sessionState(for: .failed(reason: "post_event_failed"))

        #expect(pasted == .pasteAttempted)
        #expect(!pasted.isCritical)

        #expect(copied == .copiedOnly(reason: "target_terminal"))
        #expect(!copied.isCritical)
        #expect(!copied.isActive)

        #expect(failed == .insertFailed(reason: "post_event_failed"))
        #expect(failed.isCritical)
        #expect(!failed.isActive)
        #expect(failed.displayName.contains("Copied"))
    }
}
