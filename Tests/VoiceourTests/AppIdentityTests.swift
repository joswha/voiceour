import AppKit
import Testing
import VoiceMac

@testable import Voiceour

/// The display precedence, exercised through the pure overload only: the
/// seam-aware entry reads a process-wide static, and these run in parallel with
/// every other suite.
@Suite("App identity")
struct AppIdentityTests {
    @Test("Installed app's own name outranks the name the row persisted")
    func installedNameWins() {
        let identity = AppIdentity.resolve(
            bundleId: "com.microsoft.VSCode",
            persistedName: "Visual Studio Code",
            installed: InstalledApp(name: "Code", icon: NSImage())
        )

        #expect(identity.label == "Code")
        #expect(identity.icon != nil)
    }

    @Test("An app this Mac no longer has falls back to the persisted name")
    func persistedNameWhenNotInstalled() {
        let identity = AppIdentity.resolve(
            bundleId: "com.anthropic.claudefordesktop",
            persistedName: "Claude",
            installed: nil
        )

        #expect(identity.label == "Claude")
        #expect(identity.icon == nil)
    }

    @Test("With neither installed app nor persisted name, the bundle id is humanized")
    func humanizedBundleIdIsTheLastResort() {
        let identity = AppIdentity.resolve(
            bundleId: "com.anthropic.claudefordesktop",
            persistedName: nil,
            installed: nil
        )

        #expect(identity.label == "Claudefordesktop")
        #expect(identity.icon == nil)
    }

    @Test("No bundle id and no name is still a readable label")
    func unknownApp() {
        let identity = AppIdentity.resolve(bundleId: nil, persistedName: nil, installed: nil)

        #expect(identity.label == "Unknown app")
        #expect(identity.icon == nil)
    }
}
