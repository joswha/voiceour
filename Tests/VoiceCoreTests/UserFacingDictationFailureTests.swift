import Testing

@testable import VoiceCore

/// The one translation from wire code to what the user reads.
@Suite struct UserFacingDictationFailureTests {
    /// The mapping is a table, so this is what makes it exhaustive: a code added to
    /// the wire without a sentence fails here instead of rendering
    /// `Error: some_new_code` in the menu-bar popover.
    @Test func everyErrorCodeHasAUserFacingRow() {
        for code in ASRErrorCode.allCases {
            #expect(UserFacingDictationFailure.rows[code] != nil, "no user-facing row for \(code.rawValue)")
        }
    }

    /// No row may leave the user with a mechanism name or an empty sentence.
    @Test func everyRowReadsAsASentenceAndAStatusWord() {
        for (code, row) in UserFacingDictationFailure.rows {
            #expect(!row.title.isEmpty, "\(code.rawValue) has no title")
            #expect(row.title == row.title.uppercased(), "\(code.rawValue) title is not in the status voice")
            #expect(row.cause.hasSuffix("."), "\(code.rawValue) cause is not a sentence")
            #expect(!row.cause.contains("_"), "\(code.rawValue) cause leaks a wire identifier")
        }
    }

    /// A missing model during a download is a wait, not a fault: the user cannot
    /// act on it, so it must not be presented as something to fix.
    @Test func aMissingModelDuringDownloadReportsProgressInsteadOfAFault() {
        let downloading = UserFacingDictationFailure(
            code: .modelNotInstalled,
            detail: "still fetching",
            acquisitionFraction: 0.42
        )

        #expect(downloading.title == "DOWNLOADING MODEL")
        #expect(downloading.cause.contains("42%"))
        #expect(downloading.destination == .none)
        #expect(downloading.isRetryable)
    }

    /// The same code with no download running IS actionable, and points at the app's
    /// own settings rather than at System Settings.
    @Test func aMissingModelWithNoDownloadPointsAtVoiceSettings() {
        let missing = UserFacingDictationFailure(code: .modelNotInstalled, detail: nil)

        #expect(missing.title == "MODEL NEEDED")
        #expect(missing.destination == .voiceSettings)
    }

    /// Progress is floored, so 99.6% never reads as a finished download.
    @Test func progressIsFlooredRatherThanRounded() {
        #expect(UserFacingDictationFailure.percent(0.996) == "99%")
        #expect(UserFacingDictationFailure.percent(0) == "0%")
        #expect(UserFacingDictationFailure.percent(1) == "100%")
        // Out-of-range answers stay inside the range a percentage can have.
        #expect(UserFacingDictationFailure.percent(1.7) == "100%")
        #expect(UserFacingDictationFailure.percent(-0.3) == "0%")
    }

    /// The sidecar's own message is a diagnostic, never the sentence: a decoder
    /// dump or a file path is not something to show a user as the cause.
    @Test func theBackendDetailIsCarriedButNeverBecomesTheCause() {
        let failure = UserFacingDictationFailure(
            code: .inferenceFailed,
            detail: "ggml_metal_graph_compute: command buffer 0 failed"
        )

        #expect(failure.detail == "ggml_metal_graph_compute: command buffer 0 failed")
        #expect(failure.cause == "The engine could not transcribe that recording.")
    }

    /// A protocol mismatch cannot be retried away: a second identical request gets
    /// a second identical refusal, so the menu must not offer one.
    @Test func anIncompatibleEngineIsNotOfferedARetry() {
        #expect(UserFacingDictationFailure(code: .incompatibleProtocol, detail: nil).isRetryable == false)
        #expect(UserFacingDictationFailure.microphoneDenied.isRetryable == false)
    }
}
