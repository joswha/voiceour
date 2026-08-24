import Foundation
import Testing

@testable import VoiceCore

/// The bundle-id-to-label fallback is pure so the offscreen harness, tests and
/// the running app all name an app identically.
@Suite("AppDisplayName")
struct AppDisplayNameTests {
    @Test func aPersistedNameWinsOverTheBundleId() {
        #expect(
            AppDisplayName.label(bundleId: "com.microsoft.VSCode", name: "Visual Studio Code")
                == "Visual Studio Code")
    }

    @Test func aWhitespaceOnlyNameFallsThroughToTheBundleId() {
        #expect(AppDisplayName.label(bundleId: "com.mitchellh.ghostty", name: "   ") == "Ghostty")
        #expect(AppDisplayName.label(bundleId: "com.mitchellh.ghostty", name: "") == "Ghostty")
    }

    @Test func aNameIsTrimmedRatherThanRejected() {
        #expect(AppDisplayName.label(bundleId: "com.apple.Terminal", name: "  Terminal\n") == "Terminal")
    }

    @Test func theBundleIdTailIsHumanizedWithoutLoweringTheRest() {
        #expect(AppDisplayName.label(bundleId: "com.mitchellh.ghostty", name: nil) == "Ghostty")
        #expect(AppDisplayName.label(bundleId: "com.microsoft.VSCode", name: nil) == "VSCode")
        #expect(AppDisplayName.label(bundleId: "com.apple.dt.Xcode", name: nil) == "Xcode")
        #expect(AppDisplayName.label(bundleId: "Slack", name: nil) == "Slack")
    }

    @Test func aTrailingEmptyComponentUsesTheLastNonEmptyOne() {
        #expect(AppDisplayName.label(bundleId: "com.example.", name: nil) == "Example")
        #expect(AppDisplayName.label(bundleId: "com.example..", name: nil) == "Example")
    }

    /// Measured on a real history: 59 of 104 rows targeted `com.cmuxterm.app`,
    /// which a plain last-component rule labels "App".
    @Test func aTrailingAppComponentIsASuffixRatherThanAName() {
        #expect(AppDisplayName.label(bundleId: "com.cmuxterm.app", name: nil) == "Cmuxterm")
        #expect(AppDisplayName.label(bundleId: "com.cmuxterm.App", name: nil) == "Cmuxterm")
        // A persisted name still wins over any derivation.
        #expect(AppDisplayName.label(bundleId: "com.cmuxterm.app", name: "cmux") == "cmux")
        // Nothing precedes it: the suffix is all there is.
        #expect(AppDisplayName.label(bundleId: "app", name: nil) == "App")
    }

    @Test func anAbsentOrEmptyBundleIdIsUnknown() {
        #expect(AppDisplayName.label(bundleId: nil, name: nil) == "Unknown app")
        #expect(AppDisplayName.label(bundleId: "", name: nil) == "Unknown app")
        #expect(AppDisplayName.label(bundleId: ".", name: nil) == "Unknown app")
        #expect(AppDisplayName.label(bundleId: nil, name: " ") == "Unknown app")
    }
}
