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

    /// A live state still names itself, and a stale failure from the previous
    /// session must not be spoken over one that is going fine.
    @Test func aLiveSessionSpeaksItsOwnState() {
        let spoken = RecordingOverlayController.announcement(
            for: .recording,
            failure: .microphoneDenied
        )

        #expect(spoken == "Recording")
    }

    /// The associated value is an insertion mechanism token. The island's
    /// stable value and the announcement use one presentation, so neither can
    /// leak it.
    @Test func copyOnlyAnnouncementsNameTheClipboardRatherThanTheirReason() {
        #expect(
            RecordingOverlayController.announcement(
                for: .copiedOnly(reason: "target_terminal"),
                failure: nil
            ) == "The transcript is on the clipboard."
        )
        #expect(
            RecordingOverlayController.announcement(
                for: .insertFailed(reason: "kAXErrorNoValue"),
                failure: nil
            ) == "Paste failed. The transcript is on the clipboard."
        )
    }

    /// A normal paste is already confirmed by the arriving text, and a
    /// cancellation was just requested by the user. Neither earns a second
    /// spoken interruption.
    @Test func cleanPasteAndCancelAreSilent() {
        #expect(
            RecordingOverlayController.announcement(for: .pasteAttempted, failure: nil)
                == nil
        )
        #expect(
            RecordingOverlayController.announcement(for: .cancelled, failure: nil)
                == nil
        )
        #expect(
            RecordingOverlayController.announcement(for: .idle, failure: nil)
                == nil
        )
    }

    /// The code is only the failure family. The coordinator's published cause
    /// preserves the actual remedy — here, microphone permission rather than a
    /// generic engine outage.
    @Test func aPermissionFailureKeepsItsPublishedCause() {
        #expect(
            RecordingOverlayController.announcement(
                for: .error(.backendUnavailable),
                failure: .microphoneDenied
            ) == UserFacingDictationFailure.microphoneDenied.cause
        )
    }
}
