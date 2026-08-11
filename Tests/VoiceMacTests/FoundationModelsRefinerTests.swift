import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Covers FoundationModels refiner gating, availability, lifecycle, and integration.
@Suite("FoundationModels Refiner")
struct FoundationModelsRefinerTests {
    @Test func unsupportedRefinerAlwaysSkipsWithItsReason() async {
        let refiner = UnsupportedRefiner(reason: "requires_macos_26")
        #expect(
            await refiner.refine("hello", glossary: [], safety: .normalText, style: .standard)
                == .skipped(reason: "requires_macos_26"))
    }

    @Test func foundationModelsRefinerSkipsDisabledAndUnsafeBeforeTouchingTheModel() async {
        guard #available(macOS 26.0, *) else { return }
        let disabled = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: false),
            deterministicFallback: { "CLEAN:\($0)" }
        )
        #expect(
            await disabled.refine("hello", glossary: [], safety: .normalText, style: .standard)
                == .skipped(reason: "disabled"))

        let unsafe = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: true),
            deterministicFallback: { "CLEAN:\($0)" }
        )
        #expect(
            await unsafe.refine("hello", glossary: [], safety: .terminal, style: .standard)
                == .skipped(reason: "unsafe_target"))
    }

    @Test func foundationModelsAvailabilitySummaryIsAlwaysSafeToCall() {
        let status = FoundationModelsAvailability.summary()
        #expect(!status.detail.isEmpty)
    }

    @Test func foundationModelsRefinerRealIntegration() async {
        guard ProcessInfo.processInfo.environment["VOICEOOUR_FM_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }
        guard FoundationModelsAvailability.summary().available else {
            Issue.record("Apple Intelligence unavailable; enable it before running the FM integration test")
            return
        }

        let refiner = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: true, timeoutMs: 15_000),
            deterministicFallback: { $0 }
        )
        await refiner.warmUp()
        let warmSnapshot = refiner.sessionLifecycleSnapshot()
        #expect(warmSnapshot.state == .ready)
        #expect(warmSnapshot.rejectedPrewarms == 0)
        #expect(warmSnapshot.activeCheckouts == 0)

        let started = Date()
        let outcome = await refiner.refine(
            "um please send the meeting notes to Morgan",
            glossary: [],
            safety: .normalText,
            style: .standard
        )
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("fm integration refine: \(ms)ms -> \(outcome)")

        switch outcome {
        case .refined(let text):
            let lowered = text.lowercased()
            #expect(lowered.contains("send the meeting notes"))
            #expect(lowered.contains("morgan"))
            #expect(!lowered.hasPrefix("um "))
        case .fellBack(_, let reason):
            Issue.record("FM happy-path integration must refine, but fell back: \(reason)")
        case .skipped(let reason):
            Issue.record("FM integration must not skip: \(reason)")
        }
        #expect(ms < 10_000)

        // The recorded identity is what makes a post-OS-update refinement
        // regression attributable: the configured model is the constant
        // `on-device`, so only this distinguishes one system model from its
        // successor. Asserted structurally, never against a literal id — the id
        // is expected to change, and pinning it would fail on the very update
        // this field exists to detect.
        let identity = refiner.lastModelIdentity()
        print("fm integration model identity: \(identity ?? "nil")")
        #expect(identity != nil)
        #expect(identity?.contains("com.apple.fm.") == true)
    }

    @Test func assetIdentityIsSortedJoinedAndAbsentWhenEmpty() {
        #expect(foundationModelsAssetIdentity([]) == nil)
        #expect(foundationModelsAssetIdentity(["", ""]) == nil)
        #expect(foundationModelsAssetIdentity(["only"]) == "only")
        // Sorted so two runs of the same model produce byte-identical strings
        // whatever order the framework hands the assets back in.
        #expect(foundationModelsAssetIdentity(["b", "a", "c"]) == "a b c")
        #expect(foundationModelsAssetIdentity(["b", "", "a"]) == "a b")
    }

    /// A refine call that never reaches the model must not report an identity.
    /// Both gates run before any generation, so this holds with or without
    /// Apple Intelligence on the host.
    @Test func modelIdentityStaysAbsentWhenNoModelRuns() async {
        guard #available(macOS 26.0, *) else { return }
        let disabled = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: false),
            deterministicFallback: { $0 }
        )
        _ = await disabled.refine("anything", glossary: [], safety: .normalText, style: .standard)
        #expect(disabled.lastModelIdentity() == nil)

        let unsafe = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: true),
            deterministicFallback: { $0 }
        )
        _ = await unsafe.refine("anything", glossary: [], safety: .secure, style: .standard)
        #expect(unsafe.lastModelIdentity() == nil)
    }

    @Test func foundationModelsAdaptiveTimeoutAllowsLongTranscript() async {
        guard ProcessInfo.processInfo.environment["VOICEOOUR_FM_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }
        guard FoundationModelsAvailability.summary().available else {
            Issue.record("Apple Intelligence unavailable; enable it before running the FM integration test")
            return
        }

        let raw = """
            The project review covered the release schedule and confirmed that the design team will finish the dashboard on Monday. \
            Engineering will validate the new onboarding flow on Tuesday and share the measured results with the product group. \
            The support team summarized the most common customer questions and prepared updated answers for the internal knowledge base. \
            Marketing drafted the launch announcement, checked every product name, and scheduled a final legal review before publication. \
            Finance confirmed the quarterly budget, documented the remaining vendor costs, and asked each team to submit receipts by Friday. \
            Operations reviewed the deployment checklist, verified the rollback steps, and assigned an owner to every production dependency. \
            The security review found no blocking issues, but it requested clearer notes about access controls and credential rotation. \
            Research compared the latest usability sessions, identified two recurring navigation problems, and proposed a simpler information hierarchy. \
            The team agreed to keep the current scope, avoid adding speculative features, and resolve the documented defects before release. \
            I will send the final summary tomorrow after the remaining test results arrive and the responsible owners confirm their dates.
            """
        #expect(raw.split(whereSeparator: \.isWhitespace).count > 100)
        let refiner = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: true, timeoutMs: 3_000),
            deterministicFallback: { $0 }
        )
        await refiner.warmUp()
        let started = Date()
        let outcome = await refiner.refine(
            raw,
            glossary: [],
            safety: .normalText,
            style: .standard
        )
        let latencyMs = Int(Date().timeIntervalSince(started) * 1_000)
        print("fm long adaptive integration: \(latencyMs)ms -> \(outcome)")

        switch outcome {
        case .refined(let text):
            #expect(!text.isEmpty)
        case .fellBack(_, let reason):
            #expect(reason != "timed_out")
        case .skipped(let reason):
            Issue.record("FM long integration must not skip: \(reason)")
        }
    }

    @Test func foundationModelsRefinerRealCancellationIntegration() async {
        guard ProcessInfo.processInfo.environment["VOICEOOUR_FM_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }
        guard FoundationModelsAvailability.summary().available else {
            Issue.record("Apple Intelligence unavailable; enable it before running the FM integration test")
            return
        }

        let refiner = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: true, timeoutMs: 15_000),
            deterministicFallback: { $0 }
        )
        await refiner.warmUp()
        let generation = Task {
            await refiner.refine(
                "Rewrite this dictated project update as concise prose while preserving every stated fact and number. "
                    + String(
                        repeating: "The measured batch contained 17 records and completed in 43 seconds. ", count: 12),
                glossary: [],
                safety: .normalText,
                style: .standard
            )
        }

        let responseStartDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < responseStartDeadline {
            if refiner.sessionLifecycleSnapshot().respondingCheckouts == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let respondingSnapshot = refiner.sessionLifecycleSnapshot()
        guard respondingSnapshot.respondingCheckouts == 1 else {
            generation.cancel()
            _ = await generation.value
            Issue.record("Real generation completed before LanguageModelSession.isResponding became true")
            return
        }
        #expect(respondingSnapshot.activeCheckouts == 1)
        #expect(respondingSnapshot.state == .empty)

        let cancellationStarted = ContinuousClock.now
        generation.cancel()
        let outcome = await generation.value
        let cancellationDuration = ContinuousClock.now - cancellationStarted

        switch outcome {
        case .fellBack(_, let reason):
            #expect(reason == "cancelled")
        case .refined:
            Issue.record("In-flight FoundationModels generation ignored cancellation")
        case .skipped(let reason):
            Issue.record("FM cancellation integration must not skip: \(reason)")
        }
        #expect(cancellationDuration < .seconds(5))

        let settlementDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < settlementDeadline {
            let snapshot = refiner.sessionLifecycleSnapshot()
            if snapshot.unsettledDiscardedSessions == 0 { break }
            #expect(snapshot.state == .empty)
            try? await Task.sleep(for: .milliseconds(5))
        }

        var snapshot = refiner.sessionLifecycleSnapshot()
        #expect(snapshot.activeCheckouts == 0)
        #expect(snapshot.respondingCheckouts == 0)
        #expect(snapshot.unsettledDiscardedSessions == 0)
        if snapshot.unsettledDiscards > 0 {
            #expect(snapshot.state == .empty)
            await refiner.warmUp()
            snapshot = refiner.sessionLifecycleSnapshot()
        }
        #expect(snapshot.state == .ready)
    }

    /// Pins the two semantic behaviours the shared-rules exemplars buy, against
    /// the real model.
    ///
    /// `SystemLanguageModel` is a moving target: Apple swaps it on OS updates
    /// (26.0-26.3, 26.4, 27.0 so far) and publishes no API to pin or even
    /// report a model version — `variant` only distinguishes AFM 3 Core from
    /// Core Advanced. So a macOS 27 upgrade silently replaces the model this
    /// prompt was tuned against, and Apple's own guidance is to diff prompt
    /// output across versions. This test is that diff.
    ///
    /// Both cases were measured wrong before the exemplars landed, and the
    /// faithfulness guards passed both: a short rewrite that inverts intent is
    /// lexically almost identical to the transcript, so nothing downstream can
    /// catch it. A failure here means the refined text is confidently wrong,
    /// not merely unpolished.
    @Test func foundationModelsPreservesDictatedIntentIntegration() async {
        guard ProcessInfo.processInfo.environment["VOICEOOUR_FM_INTEGRATION"] != nil else { return }
        guard #available(macOS 26.0, *) else { return }
        guard FoundationModelsAvailability.summary().available else {
            Issue.record("Apple Intelligence unavailable; enable it before running the FM integration test")
            return
        }

        let refiner = FoundationModelsRefiner(
            configuration: FoundationModelsRefinerConfiguration(enabled: true, timeoutMs: 15_000),
            deterministicFallback: { $0 }
        )

        // A self-correction must resolve to the LAST alternative. Measured
        // failure: "Use terminal." — the alternative the speaker rejected.
        let corrected = await refiner.refine(
            "use terminal no use text edit", glossary: [], safety: .normalText, style: .standard)
        if case .refined(let text) = corrected {
            let lowered = text.lowercased()
            #expect(lowered.contains("textedit") || lowered.contains("text edit"))
            #expect(!lowered.contains("terminal"))
        } else {
            Issue.record("self-correction case must refine, got: \(corrected)")
        }

        // Framing words that mark the transcript as dictated text must survive.
        // Measured failure: "git status into the note" — "type the words" gone.
        let framed = await refiner.refine(
            "type the words git status into the note", glossary: [], safety: .normalText, style: .standard)
        if case .refined(let text) = framed {
            #expect(text.lowercased().contains("type the words"))
        } else {
            Issue.record("instruction-framing case must refine, got: \(framed)")
        }
    }

}
