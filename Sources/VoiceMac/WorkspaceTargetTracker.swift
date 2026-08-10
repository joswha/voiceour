import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import VoiceCore

/// The frontmost application as far as target tracking is concerned.
public struct WorkspaceTargetApplication: Equatable, Sendable {
    public var bundleId: String?
    public var pid: pid_t

    public init(bundleId: String?, pid: pid_t) {
        self.bundleId = bundleId
        self.pid = pid
    }
}

public final class WorkspaceTargetTracker: TargetTracking, @unchecked Sendable {
    private let frontmostApplication: @Sendable () -> WorkspaceTargetApplication?
    private let focusInspector: @Sendable (pid_t) -> TargetFocusInspection
    private let secureInputActive: @Sendable () -> Bool

    /// Injectable seam for tests. Production uses ``init()``.
    public init(
        frontmostApplication: @escaping @Sendable () -> WorkspaceTargetApplication?,
        focusInspector: @escaping @Sendable (pid_t) -> TargetFocusInspection,
        secureInputActive: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.frontmostApplication = frontmostApplication
        self.focusInspector = focusInspector
        self.secureInputActive = secureInputActive
    }

    public convenience init() {
        self.init(
            frontmostApplication: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return WorkspaceTargetApplication(bundleId: app.bundleIdentifier, pid: app.processIdentifier)
            },
            focusInspector: { Self.focusedAXRole(pid: $0) },
            secureInputActive: { IsSecureEventInputEnabled() }
        )
    }

    public func snapshot() -> TargetSnapshot {
        let app = frontmostApplication()
        let bundleId = app?.bundleId
        let pid = app?.pid ?? 0
        let isSecureInputActive = secureInputActive()
        let safety = SafetyClassifier.classify(
            bundleId: bundleId,
            focus: focusInspector(pid),
            secureInputActive: isSecureInputActive
        )
        return TargetSnapshot(
            bundleId: bundleId,
            pid: pid,
            safety: safety,
            secureInputActive: isSecureInputActive
        )
    }

    /// Re-snapshots and compares bundle id, pid, safety class and secure-input state.
    ///
    /// Safety is part of the identity because a focus change inside one process
    /// — a web page auto-focusing a password field while `insert` awaits the
    /// permission request — keeps the pid and bundle id and would otherwise
    /// receive synthetic Cmd-V.
    public func stillMatches(_ snap: TargetSnapshot) -> Bool {
        snapshot() == snap
    }

    /// `kAXErrorNoValue` is the one failure that is an answer: the app supports the
    /// attribute and reports nothing focused. Every other status — including a
    /// success that somehow carries no element — means the lookup did not resolve,
    /// and an unresolved lookup is copy-only.
    private static func focusedAXRole(pid: pid_t) -> TargetFocusInspection {
        guard pid > 0, AXIsProcessTrusted() else { return .unavailable }
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        if status == .noValue { return .noFocusedElement }
        guard status == .success, let focusedElement = focused else { return .unavailable }
        let element = focusedElement as! AXUIElement
        var roleValue: CFTypeRef?
        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        return .inspected(role: roleValue as? String, subrole: subroleValue as? String)
    }
}
