import Testing

@testable import VoiceCore

@Suite("DictationPolicy")
struct DictationPolicyTests {
    @Test func launchOptionsParsesSeparateArguments() {
        let options = LaunchOptions(arguments: [
            "--repo-root", "/tmp/repo",
            "--asr-dir", "/tmp/repo/asr",
            "--asr-backend", "MLX",
        ])

        #expect(options.repoRoot == "/tmp/repo")
        #expect(options.asrDirectory == "/tmp/repo/asr")
        #expect(options.asrBackend == "mlx")
    }

    @Test func launchOptionsParsesInlineArguments() {
        let options = LaunchOptions(arguments: [
            "--repo-root=/tmp/inline-repo",
            "--asr-dir=/tmp/inline-repo/asr",
            "--asr-backend=fake",
        ])

        #expect(options.repoRoot == "/tmp/inline-repo")
        #expect(options.asrDirectory == "/tmp/inline-repo/asr")
        #expect(options.asrBackend == "fake")
    }

    @Test func launchOptionsRejectsInvalidBackend() {
        let options = LaunchOptions(arguments: ["--asr-backend", "sherpa"])

        #expect(options.asrBackend == nil)
        #expect(LaunchOptions.validBackend(" fake ") == "fake")
        #expect(LaunchOptions.validBackend("MLX") == "mlx")
        #expect(LaunchOptions.validBackend("Apple") == "apple")
        #expect(LaunchOptions.validBackend("sherpa") == nil)
    }

    @Test func launchOptionsIgnoresMissingValues() {
        let options = LaunchOptions(arguments: [
            "--repo-root",
            "--asr-dir",
            "--asr-backend",
        ])

        #expect(options.repoRoot == nil)
        #expect(options.asrDirectory == nil)
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
                providerReadiness: .needsKey,
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
