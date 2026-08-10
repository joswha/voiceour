import CoreGraphics
import Foundation
import VoiceCore

public final class PasteboardInserter: TextInserting, @unchecked Sendable {
    private let permissions: PermissionsChecking
    private let tracker: TargetTracking
    private let postPaste: @Sendable () -> Bool
    private let scheduleTransientClear: @Sendable (Int) -> Void
    private let permissionRequestGate = OneShotPermissionRequestGate()

    public init(
        permissions: PermissionsChecking,
        tracker: TargetTracking,
        postPaste: @escaping @Sendable () -> Bool = { PasteboardInserter.postCommandV() },
        scheduleTransientClear: @escaping @Sendable (Int) -> Void = PasteboardInserter.defaultTransientClear
    ) {
        self.permissions = permissions
        self.tracker = tracker
        self.postPaste = postPaste
        self.scheduleTransientClear = scheduleTransientClear
    }

    public func insert(_ text: String, into target: TargetSnapshot) async -> InsertionOutcome {
        // Policy decisions -- may this class be pasted into, and what does each
        // refusal report -- belong to `InsertionSafetyPolicy`. What is left here
        // is mechanism: pasteboard writes, the permission request, the identity
        // re-checks, and posting the key event.
        if Task.isCancelled { return .failed(reason: "cancelled") }
        let safeText =
            InsertionSafetyPolicy.stripsTrailingNewline(for: target.safety)
            ? stripSingleTrailingNewline(text)
            : text
        if case .copyOnly(let reason) = InsertionSafetyPolicy.disposition(for: target.safety) {
            GeneralPasteboard.copy(safeText, concealed: target.safety == .secure)
            return .copiedOnly(reason: reason)
        }
        if permissions.synthPaste() != .granted {
            let permissionGranted: Bool
            if permissionRequestGate.claim() {
                permissionGranted = await permissions.requestSynthPaste()
            } else {
                permissionGranted = false
            }
            if Task.isCancelled { return .failed(reason: "cancelled") }
            guard permissionGranted else {
                GeneralPasteboard.copy(safeText)
                return .copiedOnly(reason: InsertionSafetyPolicy.missingSynthPastePermission)
            }
        }
        guard tracker.stillMatches(target) else {
            GeneralPasteboard.copy(safeText)
            return .copiedOnly(reason: InsertionSafetyPolicy.targetChangedBeforeCopy)
        }
        if Task.isCancelled { return .failed(reason: "cancelled") }
        let changeCount = GeneralPasteboard.copy(safeText, transient: true)
        guard tracker.stillMatches(target) else {
            return .copiedOnly(reason: InsertionSafetyPolicy.targetChangedAfterCopy)
        }
        // Past the write the clipboard IS the delivery, so both remaining exits
        // are copy-only rather than failures — and neither schedules the
        // transient clear, which would take the text back.
        if Task.isCancelled { return .copiedOnly(reason: InsertionSafetyPolicy.cancelledAfterCopy) }
        guard postPaste() else { return .copiedOnly(reason: InsertionSafetyPolicy.postEventFailed) }
        scheduleTransientClear(changeCount)
        return .pasteAttempted
    }

    /// After a successful synthetic paste, wait 1.5 seconds for the target to
    /// service Cmd-V, then drop the dictated text from the clipboard. The
    /// change-count guard leaves anything copied in the meantime untouched.
    public static let defaultTransientClear: @Sendable (Int) -> Void = { changeCount in
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            GeneralPasteboard.clearIfUnchanged(since: changeCount)
        }
    }

    private func stripSingleTrailingNewline(_ text: String) -> String {
        if text.hasSuffix("\r\n") { return String(text.dropLast(2)) }
        if text.hasSuffix("\n") || text.hasSuffix("\r") { return String(text.dropLast()) }
        return text
    }

    public static func postCommandV() -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

private final class OneShotPermissionRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var wasClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !wasClaimed else { return false }
        wasClaimed = true
        return true
    }
}
