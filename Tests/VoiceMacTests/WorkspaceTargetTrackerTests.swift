import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Characterizes `WorkspaceTargetTracker` through its injected workspace and
/// AX-inspection seams: no NSWorkspace, no Accessibility grant, no live app.
@Suite("WorkspaceTargetTracker")
struct WorkspaceTargetTrackerTests {
    private func tracker(
        app: WorkspaceTargetApplication?,
        focus: TargetFocusInspection,
        secureInputActive: Bool = false
    ) -> WorkspaceTargetTracker {
        WorkspaceTargetTracker(
            frontmostApplication: { app },
            focusInspector: { _ in focus },
            secureInputActive: { secureInputActive }
        )
    }

    @Test func ordinaryFieldInAKnownAppIsNormalText() {
        let snapshot = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.apple.TextEdit", name: "TextEdit", pid: 42),
            focus: .inspected(role: "AXTextArea", subrole: nil)
        ).snapshot()

        #expect(snapshot.bundleId == "com.apple.TextEdit")
        #expect(snapshot.appName == "TextEdit")
        #expect(snapshot.pid == 42)
        #expect(snapshot.safety == .normalText)
    }

    @Test func secureFocusRoleOverridesAnOtherwiseOrdinaryApp() {
        let snapshot = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.apple.Safari", name: "Safari", pid: 7),
            focus: .inspected(role: "AXTextField", subrole: "AXSecureTextField")
        ).snapshot()

        #expect(snapshot.safety == .secure)
    }

    /// The flip C2 exists for: `.unavailable` used to classify as `.normalText`,
    /// which is the one class that permits synthetic paste.
    @Test func unavailableInspectionIsUnknownRiskyRatherThanOrdinaryText() {
        let snapshot = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.apple.TextEdit", name: "TextEdit", pid: 42),
            focus: .unavailable
        ).snapshot()

        #expect(snapshot.safety == .unknownRisky)
    }

    /// Measured on Discord: `kAXFocusedUIElement` answers `kAXErrorNoValue` whenever
    /// its composer does not hold focus, which used to make every Electron target
    /// copy-only. An answer is not absent information.
    @Test func noFocusedElementIsOrdinaryTextRatherThanUnknownRisk() {
        let snapshot = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.hnc.Discord", name: "Discord", pid: 42),
            focus: .noFocusedElement
        ).snapshot()

        #expect(snapshot.safety == .normalText)
    }

    @Test func noFocusedElementStillYieldsToActiveSecureInput() {
        let snapshot = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.hnc.Discord", name: "Discord", pid: 42),
            focus: .noFocusedElement,
            secureInputActive: true
        ).snapshot()

        #expect(snapshot.safety == .secure)
    }

    @Test func noFrontmostApplicationIsUnknownRisky() {
        let snapshot = tracker(app: nil, focus: .unavailable).snapshot()

        #expect(snapshot.bundleId == nil)
        #expect(snapshot.appName == nil)
        #expect(snapshot.pid == 0)
        #expect(snapshot.safety == .unknownRisky)
    }

    @Test func sameProcessAndBundleStillMatches() {
        let subject = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.apple.TextEdit", name: "TextEdit", pid: 42),
            focus: .inspected(role: "AXTextArea", subrole: nil)
        )
        let snapshot = subject.snapshot()

        #expect(subject.stillMatches(snapshot))
    }

    @Test func changedProcessDoesNotStillMatch() {
        let subject = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.apple.TextEdit", name: "TextEdit", pid: 42),
            focus: .inspected(role: "AXTextArea", subrole: nil)
        )
        let snapshot = subject.snapshot()
        let moved = tracker(
            app: WorkspaceTargetApplication(bundleId: "com.apple.TextEdit", name: "TextEdit", pid: 99),
            focus: .inspected(role: "AXTextArea", subrole: nil)
        )

        #expect(!moved.stillMatches(snapshot))
    }

    /// The C3 defect: a focus change from an ordinary field to a password field
    /// inside one process keeps both the pid and the bundle id, so comparing
    /// only those two let a secure field receive synthetic Cmd-V.
    @Test func sameProcessFocusChangeToASecureFieldDoesNotStillMatch() {
        let app = WorkspaceTargetApplication(bundleId: "com.apple.Safari", name: "Safari", pid: 42)
        let before = tracker(app: app, focus: .inspected(role: "AXTextField", subrole: nil)).snapshot()
        let after = tracker(app: app, focus: .inspected(role: "AXTextField", subrole: "AXSecureTextField"))

        #expect(before.safety == .normalText)
        #expect(!after.stillMatches(before))
    }

    @Test func sameProcessLosingAXInspectionDoesNotStillMatch() {
        let app = WorkspaceTargetApplication(bundleId: "com.apple.TextEdit", name: "TextEdit", pid: 42)
        let before = tracker(app: app, focus: .inspected(role: "AXTextArea", subrole: nil)).snapshot()
        let after = tracker(app: app, focus: .unavailable)

        #expect(!after.stillMatches(before))
    }
}
