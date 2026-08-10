import Testing
import VoiceCore

@testable import VoiceOour

/// The Refinement pane's Status row does not simply mirror
/// `DictationCoordinator.refinerReachability`, and the rule that decides what it
/// shows is asymmetric enough to be worth pinning.
///
/// Two sources write that slot. `checkRefinerReachability()` runs when the user
/// presses CHECK, and the pane stamps the configuration it measured so a green
/// verdict cannot outlive the provider, endpoint, model or key behind it. But a
/// real refine also writes it — `applyRefinerReachabilityFailureIfCurrent` turns
/// an HTTP 401/403/400/404 into `.unauthorized` or `.failed` — and that path
/// never touches the stamp. Gating those behind a probe the user never ran hid
/// the reason their last paste fell back to deterministic cleanup.
@MainActor
struct RefinementStatusVerdictTests {
    private static let current = "openAI|https://api.openai.com/v1|gpt-4.1-nano|keychain"
    private static let other = "openRouter|https://openrouter.ai/api/v1|llama|environment"

    private func verdict(
        _ measured: RefinerReachability,
        stamp: String?
    ) -> RefinerReachability {
        RefinementPane.statusVerdict(
            measured: measured,
            checkedFingerprint: stamp,
            configurationFingerprint: Self.current
        )
    }

    @Test func reachableNeedsAStampForThisConfiguration() {
        #expect(verdict(.ok(models: 62), stamp: Self.current) == .ok(models: 62))
    }

    @Test func reachableIsWithheldWithoutAMatchingStamp() {
        #expect(verdict(.ok(models: 62), stamp: nil) == .unknown)
        #expect(verdict(.ok(models: 62), stamp: Self.other) == .unknown)
    }

    /// The refine-driven case: no CHECK was ever pressed, so there is no stamp,
    /// and the row still has to say the key was rejected.
    @Test func unauthorizedShowsWithoutAStamp() {
        #expect(verdict(.unauthorized, stamp: nil) == .unauthorized)
        #expect(verdict(.unauthorized, stamp: Self.other) == .unauthorized)
        #expect(verdict(.unauthorized, stamp: Self.current) == .unauthorized)
    }

    @Test(arguments: ["HTTP 400", "HTTP 404", "The request timed out after 3000 ms."])
    func failureShowsWithoutAStamp(reason: String) {
        #expect(verdict(.failed(reason), stamp: nil) == .failed(reason))
        #expect(verdict(.failed(reason), stamp: Self.other) == .failed(reason))
    }

    /// The in-flight state is the coordinator's own, published synchronously
    /// before it suspends, so a stamp it has not earned yet must not hide it.
    @Test func checkingIsAlwaysLive() {
        #expect(verdict(.checking, stamp: nil) == .checking)
        #expect(verdict(.checking, stamp: Self.other) == .checking)
    }

    @Test func unknownStaysUnknown() {
        #expect(verdict(.unknown, stamp: Self.current) == .unknown)
        #expect(verdict(.unknown, stamp: nil) == .unknown)
    }
}
