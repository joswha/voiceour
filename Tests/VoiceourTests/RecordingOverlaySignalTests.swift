import Testing

@testable import VoiceCore
@testable import Voiceour

/// The island's one job is to say "I am hearing you", and it now says it with a resting
/// row that holds steady rather than a meter that follows every sample. That makes the
/// listening/speaking boundary a contract: it has to be quick enough to catch the first
/// syllable and slow enough that a breath does not read as silence.
@MainActor
struct RecordingOverlaySpeechActivityTests {
    private func listening() -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        return model
    }

    private func startSpeaking(_ model: RecordingOverlayModel) {
        model.record(0.9)
        model.record(0.9)
    }

    /// A door closing is one loud sample. If that flipped the row the meter would jump at
    /// every desk noise, which is the jitter the resting row exists to remove.
    @Test func oneLoudSampleIsNotSpeech() {
        let model = listening()

        model.record(0.9)

        #expect(model.isSpeaking == false)
    }

    @Test func twoConsecutiveLoudSamplesAreSpeech() {
        let model = listening()

        startSpeaking(model)

        #expect(model.isSpeaking)
    }

    /// 280ms of release. Six quiet samples is 240ms — a gap between words, not the end of
    /// an utterance — and the row must not collapse inside it.
    @Test func aBreathDoesNotConcedeSilence() {
        let model = listening()
        startSpeaking(model)

        for _ in 0..<(RecordingOverlayMetrics.Speech.releaseSamples - 1) {
            model.record(0)
        }

        #expect(model.isSpeaking)
    }

    @Test func sustainedSilenceEndsSpeech() {
        let model = listening()
        startSpeaking(model)

        for _ in 0..<RecordingOverlayMetrics.Speech.releaseSamples {
            model.record(0)
        }

        #expect(model.isSpeaking == false)
    }

    /// The band between the two thresholds is the whole point of a hysteresis: it holds
    /// whichever state it finds AND leaves the run it interrupted intact, so a level
    /// hovering at the noise floor can neither start nor stop speech on its own.
    @Test func theDeadBandHoldsTheCurrentStateWithoutResettingTheRun() {
        let quiet = listening()
        let between =
            (RecordingOverlayMetrics.Speech.attackLevel
                + RecordingOverlayMetrics.Speech.releaseLevel) / 2

        quiet.record(between)
        quiet.record(between)
        quiet.record(between)
        #expect(quiet.isSpeaking == false)

        let interrupted = listening()
        interrupted.record(0.9)
        interrupted.record(between)
        interrupted.record(0.9)
        #expect(interrupted.isSpeaking)
    }

    /// Warm-up draws a word, not a meter, so speech cannot be true there — and a session
    /// that stops recording must not leave the next one starting mid-utterance.
    @Test func goingOffAirClearsSpeech() {
        let model = listening()
        startSpeaking(model)

        model.updateCaptureLive(false)

        #expect(model.isSpeaking == false)
        #expect(model.isWarmingUp)
    }

    @Test func leavingTheRecordingStateClearsSpeech() {
        let model = listening()
        startSpeaking(model)

        model.update(.transcribing)

        #expect(model.isSpeaking == false)
    }
}

/// Only a delivery that did not go as asked earns a moment on screen. A clean paste is
/// already evidenced by the transcript arriving in the target app, and it is the common
/// path, so an island that lingered after every utterance would be in the way.
@MainActor
struct RecordingOverlayOutcomeTests {
    @Test(arguments: [
        SessionState.idle,
        .checkingPermissions,
        .recording,
        .finalizingAudio,
        .transcribing,
        .cleaning,
        .readyToInsert,
        .pasteAttempted,
        .cancelled,
    ])
    func aStateThatNeedsNoReportGetsNoMoment(state: SessionState) {
        #expect(RecordingOverlayOutcome(state: state) == nil)
    }

    @Test(arguments: [
        SessionState.copiedOnly(reason: "terminal"),
        .insertFailed(reason: "no focused element"),
        .error(.backendUnavailable),
    ])
    func anUncleanDeliveryGetsAMoment(state: SessionState) {
        let outcome = RecordingOverlayOutcome(state: state)

        #expect(outcome != nil)
        #expect(outcome?.word.isEmpty == false)
        #expect(outcome?.symbol.isEmpty == false)
    }

    /// The island is the surface a VoiceOver reader hears, and `displayName` interpolates
    /// the raw code on `.error` and the insertion reason token on the copy-only paths.
    /// Neither may reach the user through this readout.
    ///
    /// The test is on the snake_case codes specifically, because those are the ones that
    /// could only have arrived by interpolation. Two `ASRErrorCode` raw values —
    /// `cancelled` and `timeout` — are ordinary English words, and the published sentence
    /// for `.cancelled` is "That dictation was cancelled.", which contains its own raw
    /// value by coincidence rather than by leaking anything.
    @Test func anOutcomeNeverShowsAMechanismName() {
        for code in ASRErrorCode.allCases {
            let outcome = RecordingOverlayOutcome(state: .error(code))

            #expect(outcome?.word == "FAILED")
            #expect(outcome?.isFailure == true)
            if code.rawValue.contains("_") {
                #expect(outcome?.accessibilityStatus.contains(code.rawValue) == false)
            }
        }

        let refused = RecordingOverlayOutcome(state: .insertFailed(reason: "kAXErrorNoValue"))
        #expect(refused?.accessibilityStatus.contains("kAXErrorNoValue") == false)

        let copied = RecordingOverlayOutcome(state: .copiedOnly(reason: "secure_input"))
        #expect(copied?.accessibilityStatus.contains("secure_input") == false)
    }

    /// A failed paste is not a dead end: the transcript is on the clipboard, and that is
    /// the actionable half of the sentence.
    @Test func aFailedPasteNamesTheClipboard() {
        let spoken = RecordingOverlayOutcome(
            state: .insertFailed(reason: "no focused element")
        )?.accessibilityStatus.lowercased()

        #expect(spoken?.contains("clipboard") == true)
    }

    /// An ASR code names the failure family, not always the actual cause. The
    /// stable readout keeps the coordinator's published sentence so a denied
    /// microphone cannot masquerade as a transcription-engine outage.
    @Test func anErrorOutcomeKeepsItsPublishedCause() {
        let outcome = RecordingOverlayOutcome(
            state: .error(.backendUnavailable),
            failure: .microphoneDenied
        )

        #expect(
            outcome?.accessibilityStatus
                == UserFacingDictationFailure.microphoneDenied.cause
        )
    }

    /// Both copy-only paths cost the user nothing, so neither is dressed as a failure;
    /// only a dictation that produced no text is.
    @Test func onlyARealFailureReadsAsOne() {
        #expect(RecordingOverlayOutcome(state: .copiedOnly(reason: "terminal"))?.isFailure == false)
        #expect(RecordingOverlayOutcome(state: .insertFailed(reason: "x"))?.isFailure == false)
        #expect(RecordingOverlayOutcome(state: .error(.inferenceFailed))?.isFailure == true)
    }

    /// The island's row crossfades on `centerPhaseToken`, so latching an outcome has to
    /// move it or the report swaps in without a transition.
    @Test func latchingAnOutcomeMovesTheAnimationToken() {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        let listening = model.centerPhaseToken

        guard let outcome = RecordingOverlayOutcome(state: .error(.backendUnavailable)) else {
            Issue.record("an error state must produce an outcome")
            return
        }
        model.present(outcome)

        #expect(model.centerPhaseToken != listening)
        #expect(model.accessibilityStatus == outcome.accessibilityStatus)

        model.reset()
        #expect(model.outcome == nil)
        #expect(model.centerPhaseToken != 4)
    }

    /// The meter is gone while a report is showing, so a late buffer from the session that
    /// just ended cannot animate bars underneath it.
    @Test func aLatchedOutcomeStopsTheMeter() {
        let model = RecordingOverlayModel()
        model.update(.recording)
        model.updateCaptureLive(true)
        model.record(0.9)
        model.record(0.9)

        guard let outcome = RecordingOverlayOutcome(state: .copiedOnly(reason: "terminal")) else {
            Issue.record("a copy-only state must produce an outcome")
            return
        }
        model.present(outcome)
        model.record(0.9)

        #expect(model.samples.allSatisfy { $0 == 0 })
        #expect(model.isSpeaking == false)
    }
}
