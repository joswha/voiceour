// Walks the status element with the harness's accessibility reader, which is compiled out unless
// `UI_HARNESS` is defined. `make test` and CI pass `-Xswiftc -DUI_HARNESS`.
#if UI_HARNESS

    import AppKit
    import SwiftUI
    import Testing
    import VoiceCore

    @testable import Voiceour

    /// The status element publishes "Dock island" after the session's own actions, only while the
    /// island is free and the session is live, and performing it docks.
    @MainActor
    struct RecordingOverlayDockActionTests {
        @Test func dockIslandIsOfferedOnlyWhileTheIslandIsFree() {
            #expect(Self.actions(state: .recording, free: false).names == ["Finish recording", "Cancel recording"])
            #expect(
                Self.actions(state: .recording, free: true).names
                    == ["Finish recording", "Cancel recording", "Dock island"]
            )
            #expect(Self.actions(state: .transcribing, free: true).names == ["Cancel dictation", "Dock island"])
            #expect(Self.actions(state: .transcribing, free: false).names == ["Cancel dictation"])
        }

        @Test func performingDockIslandDocks() {
            #expect(Self.actions(state: .recording, free: true, perform: "Dock island").docked == 1)
        }

        /// Hosts the overlay for one session state, reads the status element's published action
        /// names, and performs `perform` if it is one of them. A fresh host per state, so nothing has
        /// to pump the run loop for SwiftUI to publish a change.
        private static func actions(
            state: SessionState,
            free: Bool,
            perform: String? = nil
        ) -> (names: [String], docked: Int) {
            _ = NSApplication.shared
            #expect(AXDump.enableEnhancedUserInterface())
            let model = RecordingOverlayModel()
            model.update(state)
            model.update(isFree: free)
            var docked = 0
            let host = NSHostingView(
                rootView: RecordingOverlayView(
                    model: model, onCancel: {}, onFinish: {}, onDock: { docked += 1 }, islandOnly: true)
            )
            let size = RecordingOverlayLayout.island.canvasRect.size
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            let names = AXDump.find("Dictation status", in: AXDump.tree(of: host))?.actions ?? []
            if let perform, let status = element(labelled: "Dictation status", in: host),
                let actions = status.perform(NSSelectorFromString("accessibilityCustomActions"))?
                    .takeUnretainedValue() as? [NSAccessibilityCustomAction]
            {
                _ = actions.first { $0.name == perform }?.handler?()
            }
            return (names, docked)
        }

        /// The live accessibility node labelled `label`, found by the same in-process walk `AXDump`
        /// makes, through the selectors every node answers.
        private static func element(labelled label: String, in root: NSObject) -> NSObject? {
            let children = NSSelectorFromString("accessibilityChildren")
            guard root.responds(to: children),
                let nodes = root.perform(children)?.takeUnretainedValue() as? [Any]
            else { return nil }
            for case let node as NSObject in nodes {
                let labelSelector = NSSelectorFromString("accessibilityLabel")
                if node.responds(to: labelSelector),
                    node.perform(labelSelector)?.takeUnretainedValue() as? String == label
                {
                    return node
                }
                if let found = element(labelled: label, in: node) {
                    return found
                }
            }
            return nil
        }
    }

#endif
