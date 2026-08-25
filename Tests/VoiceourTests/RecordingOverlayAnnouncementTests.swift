import Testing

@testable import VoiceCore
@testable import Voiceour

/// The overlay is the surface a VoiceOver reader hears during a session, and it is
/// deliberately never key — the announcement is the whole readout. So the sentence it
/// posts is a contract: it says what the menu says, and it never says a wire code.
struct RecordingOverlayAnnouncementTests {
    @Test func anErrorSpeaksThePublishedSentenceRatherThanTheWireCode() {
        let spoken = RecordingOverlayController.announcement(
            for: .error(.modelNotInstalled),
            failure: UserFacingDictationFailure(
                code: .modelNotInstalled,
                detail: "still acquiring",
                acquisitionFraction: 0.43
            )
        )

        #expect(spoken == "The speech model is still downloading — 43% done.")
    }

    /// Nothing published is still no excuse for a mechanism name: the code resolves
    /// through the same table the menu reads. `backend_unavailable` is named because
    /// it is the one a fresh install hits first.
    @Test func anErrorWithNoPublishedFailureFallsBackToTheCodesOwnSentence() {
        #expect(
            RecordingOverlayController.announcement(for: .error(.backendUnavailable), failure: nil)
                == "The transcription engine is not running."
        )

        for code in ASRErrorCode.allCases {
            #expect(
                RecordingOverlayController.announcement(for: .error(code), failure: nil)
                    == UserFacingDictationFailure(code: code, detail: nil).cause
            )
        }
    }

    /// Every other state already names itself in plain words, and a stale failure from
    /// the previous session must not be spoken over one that is going fine.
    @Test func aLiveSessionSpeaksItsOwnState() {
        let spoken = RecordingOverlayController.announcement(
            for: .recording,
            failure: .microphoneDenied
        )

        #expect(spoken == "Recording")
    }
}
