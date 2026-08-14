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
        #expect(LaunchOptions.validBackend("Apple") == "apple")
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

    @Test func refinementEligibilityMatrix() {
        let tooLong = TranscriptAssessment(needsRefinement: true, tooLong: true)
        let needsRefinement = TranscriptAssessment(needsRefinement: true, tooLong: false)

        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: false,
                refinerConfigured: true,
                targetSafety: .normalText,
                providerReadiness: .ready,
                assessment: tooLong
            ) == .skip(reason: "disabled"))

        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: false,
                targetSafety: .normalText,
                providerReadiness: .needsModel,
                assessment: tooLong
            ) == .skip(reason: "unconfigured"))

        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .terminal,
                providerReadiness: .ready,
                assessment: tooLong
            ) == .skip(reason: "unsafe_target"))

        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .normalText,
                providerReadiness: .ready,
                assessment: needsRefinement
            ) == .refine)

        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .unknownRisky,
                providerReadiness: .ready,
                assessment: needsRefinement
            ) == .refine)
    }

    @Test func cleanShortTranscriptSkipsRefinement() {
        let assessment = DictationPolicy.assessTranscript("Please send the document tomorrow.", glossary: [])

        #expect(!assessment.needsRefinement)
        #expect(!assessment.tooLong)
        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .normalText,
                providerReadiness: .ready,
                assessment: assessment
            ) == .skip(reason: "clean_transcript"))
    }

    @Test func correctionMarkerNeedsRefinement() {
        let assessment = DictationPolicy.assessTranscript("Send it Tuesday, no wait, Wednesday.", glossary: [])

        #expect(assessment.needsRefinement)
        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .normalText,
                providerReadiness: .ready,
                assessment: assessment
            ) == .refine)
    }

    @Test func fortyOneWordTranscriptNeedsRefinement() {
        let raw = (1...41).map { "word\($0)" }.joined(separator: " ")
        let assessment = DictationPolicy.assessTranscript(raw, glossary: [])

        #expect(assessment.needsRefinement)
        #expect(!assessment.tooLong)
        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .normalText,
                providerReadiness: .ready,
                assessment: assessment
            ) == .refine)
    }

    @Test func transcriptOverThreeHundredFiftyWordsSkipsRefinement() {
        let raw = (1...351).map { "word\($0)" }.joined(separator: " ")
        let assessment = DictationPolicy.assessTranscript(raw, glossary: [])

        #expect(assessment.tooLong)
        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .normalText,
                providerReadiness: .ready,
                assessment: assessment
            ) == .skip(reason: "transcript_too_long"))
    }

    @Test func bareMultiWordGlossaryComponentNeedsRefinement() {
        let glossary = [ProtectedTerm(canonical: "NVIDIA Parakeet", spokenAliases: [])]
        let assessment = DictationPolicy.assessTranscript("Use Parakeet for this recording.", glossary: glossary)

        #expect(assessment.needsRefinement)
        #expect(
            DictationPolicy.refinementDecision(
                refinerEnabled: true,
                refinerConfigured: true,
                targetSafety: .normalText,
                providerReadiness: .ready,
                assessment: assessment
            ) == .refine)
    }

    // The counterpart to the test above, and the reason it needs a threshold at
    // all. A technical canonical routinely contains ordinary English, and matching
    // any component made this the dominant refine trigger: simulated over 500 real
    // local sessions the unrestricted rule fired on 83.0% of dictations, with "the"
    // from `see the SSH config` accounting for 336 of them on its own. Each firing
    // requests a refine that costs ~1.9 s at p50, so this is a latency defect, not
    // a cosmetic one.
    @Test func ordinaryWordInsideAMultiWordGlossaryTermDoesNotForceRefinement() {
        let glossary = [ProtectedTerm(canonical: "see the SSH config", spokenAliases: [])]
        let assessment = DictationPolicy.assessTranscript(
            "The recording finished without any problems.",
            glossary: glossary
        )

        #expect(!assessment.needsRefinement)
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

    @Test func phoneticNearMissNeedsRefinement() {
        let glossary = [ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])]
        let assessment = DictationPolicy.assessTranscript(
            "Please run cube cuttle now.",
            glossary: glossary
        )

        #expect(assessment.needsRefinement)
    }

    @Test func exactGlossaryAliasDoesNotTriggerNearMissRouting() {
        let glossary = [ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])]
        let assessment = DictationPolicy.assessTranscript(
            "Please run cube cuddle now.",
            glossary: glossary
        )

        #expect(!assessment.needsRefinement)
    }

    @Test func unrelatedCleanTextStillSkipsRefinement() {
        let glossary = [ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"])]
        let assessment = DictationPolicy.assessTranscript(
            "Please open the document tomorrow.",
            glossary: glossary
        )

        #expect(!assessment.needsRefinement)
    }

    @Test func refinementStyleMapsKnownBundleIdentifiers() {
        #expect(DictationPolicy.refinementStyle(forBundleId: "com.hnc.Discord") == .casual)
        #expect(DictationPolicy.refinementStyle(forBundleId: "com.apple.mail") == .formal)
        #expect(DictationPolicy.refinementStyle(forBundleId: "com.apple.TextEdit") == .standard)
        #expect(DictationPolicy.refinementStyle(forBundleId: nil) == .standard)
        #expect(DictationPolicy.refinementStyle(forBundleId: "com.hnc.discord") == .standard)
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
