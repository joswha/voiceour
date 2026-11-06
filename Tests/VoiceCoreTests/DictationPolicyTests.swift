import Foundation
import Testing

@testable import VoiceCore

@Suite("DictationPolicy")
struct DictationPolicyTests {
    @Test func launchOptionsParsesSeparateArguments() {
        let options = LaunchOptions(arguments: [
            "--repo-root", "/tmp/repo",
            "--asr-backend", "GRANITE",
        ])

        #expect(options.repoRoot == "/tmp/repo")
        #expect(options.asrBackend == "granite")
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
        #expect(LaunchOptions.validBackend("GRANITE") == "granite")
        #expect(LaunchOptions.validBackend("sherpa") == nil)
    }

    /// A retired backend id from an argument, the environment or a debug-persisted choice still
    /// names a real backend: it normalizes to Granite, the one recognizer, instead of failing
    /// validation and dropping the install to the fake backend.
    @Test func retiredBackendIdsNormalizeToGranite() {
        for retired in ["parakeet", "PARAKEET", " Parakeet ", "mlx", "MLX", "ark-0.6b", "ark-3b", "apple"] {
            #expect(LaunchOptions.validBackend(retired) == "granite")
        }
        #expect(LaunchOptions(arguments: ["--asr-backend=mlx"]).asrBackend == "granite")
        #expect(LaunchOptions(arguments: ["--asr-backend", "parakeet"]).asrBackend == "granite")
    }

    /// A persisted backend is the debug picker's saved choice, honored only in a `--debug`
    /// launch. A release launch never restores one, whatever it names: every launch writes its
    /// resolved id into settings and a release build has no picker, so honoring the file would
    /// pin a user to whatever an earlier launch ran — `fake`, or a former default — for good.
    @Test func aPersistedBackendIsHonoredOnlyInDebugLaunches() {
        let ids = LaunchOptions.defaultBackendIDs

        for persisted in ["fake", "parakeet", "granite", "apple"] {
            #expect(LaunchOptions.persistedBackend(persisted, validBackendIDs: ids, allowsDevBackend: false) == nil)
        }
        #expect(LaunchOptions.persistedBackend("fake", validBackendIDs: ids, allowsDevBackend: true) == "fake")
        #expect(LaunchOptions.persistedBackend("parakeet", validBackendIDs: ids, allowsDevBackend: true) == "granite")
        #expect(LaunchOptions.persistedBackend("granite", validBackendIDs: ids, allowsDevBackend: true) == "granite")
        #expect(LaunchOptions.persistedBackend("apple", validBackendIDs: ids, allowsDevBackend: true) == "granite")
        #expect(LaunchOptions.persistedBackend("sherpa", validBackendIDs: ids, allowsDevBackend: true) == nil)
    }

    /// Both registered backends are selectable per launch, case-insensitively, split or inline.
    /// The sidecars' wire ids are not selectors.
    @Test func eachRegisteredBackendIsSelectablePerLaunch() {
        #expect(LaunchOptions(arguments: ["--asr-backend", "fake"]).asrBackend == "fake")
        #expect(LaunchOptions(arguments: ["--asr-backend=GRANITE"]).asrBackend == "granite")
        #expect(LaunchOptions.validBackend(" Granite ") == "granite")
        #expect(LaunchOptions.validBackend("granite-ctc") == nil)
    }

    /// Argument beats environment beats the debug-persisted choice beats the default; an
    /// invalid value at any level falls through, and a release launch skips the persisted level.
    @Test func backendPrecedence() {
        func resolve(
            argument: String? = nil,
            environment: String? = nil,
            persisted: String? = nil,
            allowsDevBackend: Bool = false
        ) -> String {
            LaunchOptions.resolvedBackend(
                launchArgument: argument.flatMap { LaunchOptions(arguments: ["--asr-backend", $0]).asrBackend },
                environment: environment,
                persisted: persisted,
                validBackendIDs: LaunchOptions.defaultBackendIDs,
                allowsDevBackend: allowsDevBackend,
                defaultBackend: "granite"
            )
        }

        #expect(resolve() == "granite")
        // A release launch never restores a saved backend.
        #expect(resolve(persisted: "fake") == "granite")
        #expect(resolve(persisted: "fake", allowsDevBackend: true) == "fake")
        #expect(resolve(environment: "fake", persisted: "granite", allowsDevBackend: true) == "fake")
        #expect(resolve(argument: "fake", environment: "granite") == "fake")
        #expect(
            resolve(argument: "granite", environment: "fake", persisted: "fake", allowsDevBackend: true)
                == "granite"
        )
        // Invalid values fall through to the next source.
        #expect(resolve(argument: "sherpa", environment: "FAKE") == "fake")
        #expect(resolve(environment: "granite-ctc", persisted: "fake", allowsDevBackend: true) == "fake")
        #expect(resolve(environment: "sherpa", persisted: "nonsense", allowsDevBackend: true) == "granite")
        // A retired id normalizes at its own level, so it still outranks a lower source.
        #expect(resolve(environment: "parakeet", persisted: "fake", allowsDevBackend: true) == "granite")
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
    }

    // MARK: First-run guidance

    /// The rule Home's card and the launch-open both read. Table-driven because
    /// the interesting property is which combinations are owed guidance and which
    /// are not: only a genuinely fresh install is.
    @Test func onlyAnInstallWithNoRecordOfDictatingIsOwedFirstRunGuidance() {
        #expect(
            DictationPolicy.owesFirstRunGuidance(
                hasCompletedFirstRun: false, journaledSessions: 0, ledgerSessions: 0))
        // The flag is the authority once it is set, even on a Mac whose durable
        // records were later erased.
        #expect(
            !DictationPolicy.owesFirstRunGuidance(
                hasCompletedFirstRun: true, journaledSessions: 0, ledgerSessions: 0))
        // Either surviving record is proof of prior use on its own, which is what
        // spares an install upgrading into this build from being shown onboarding
        // it does not need.
        #expect(
            !DictationPolicy.owesFirstRunGuidance(
                hasCompletedFirstRun: false, journaledSessions: 1, ledgerSessions: 0))
        #expect(
            !DictationPolicy.owesFirstRunGuidance(
                hasCompletedFirstRun: false, journaledSessions: 0, ledgerSessions: 1))
    }

    /// The flag decodes to false when the key is absent, so a settings file
    /// written by an earlier build stays readable and is never quarantined over a
    /// field it could not have known about.
    @Test func settingsWithoutTheFirstRunKeyDecodeToNotCompleted() throws {
        let legacy = Data(#"{"cleanup_enabled": true, "auto_stop_silence_ms": 1500}"#.utf8)
        let decoded = try JSONDecoder().decode(Settings.self, from: legacy)

        #expect(!decoded.hasCompletedFirstRun)
        #expect(decoded.autoStopSilenceMs == 1500)
    }

    /// And a round trip preserves it, so the one write the stop pipeline makes is
    /// the one a later launch reads.
    @Test func theFirstRunFlagSurvivesARoundTrip() throws {
        var settings = Settings()
        settings.hasCompletedFirstRun = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.hasCompletedFirstRun)
    }
}
