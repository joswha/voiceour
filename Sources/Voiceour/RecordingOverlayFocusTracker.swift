import AppKit

/// Proposes the screen the recording island belongs on, and reads the window it leans toward.
///
/// Every proposal carries its cause, because the move policy weighs them differently: a click is
/// a hint that waits for the activation it may cause, focus is an answer, and a reconfiguration
/// describes displays that are still changing.
@MainActor
final class RecordingOverlayFocusTracker {
    private let onCandidate: (NSScreen, RecordingOverlayMovePolicy.Cause) -> Void
    private var isRunning = false
    private var globalMouseMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    init(onCandidate: @escaping (NSScreen, RecordingOverlayMovePolicy.Cause) -> Void) {
        self.onCandidate = onCandidate
    }

    func currentScreen() -> NSScreen {
        if let focused = frontmostWindow()?.screen {
            return focused
        }
        if let pointed = screen(containing: NSEvent.mouseLocation) {
            return pointed
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// The frontmost app's frontmost on-screen window, in AppKit global coordinates: the window the
    /// body leans toward, and the one whose filling its display makes that display full screen.
    func frontmostWindowFrame() -> CGRect? {
        guard let bounds = frontmostWindow()?.bounds else { return nil }
        return Self.appKitFrame(quartz: bounds, primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.proposePointerScreen()
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.proposeFocusedScreen(cause: .focus)
            }
        }

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.proposeFocusedScreen(cause: .focus)
            }
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.proposeFocusedScreen(cause: .reconfiguration)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    /// A Quartz window rectangle — global, origin at the primary display's top-left, +y down, as
    /// `CGWindowListCopyWindowInfo` reports it — in AppKit global coordinates, whose origin is the
    /// same display's bottom-left, +y up.
    nonisolated static func appKitFrame(quartz: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: primaryDisplayHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    private func proposePointerScreen() {
        guard let destinationScreen = screen(containing: NSEvent.mouseLocation) else { return }
        onCandidate(destinationScreen, .pointerClick)
    }

    private func proposeFocusedScreen(cause: RecordingOverlayMovePolicy.Cause) {
        onCandidate(currentScreen(), cause)
    }

    /// The frontmost app's frontmost layer-0 window that lies on a screen: its Quartz bounds, and
    /// the screen holding most of it.
    private func frontmostWindow() -> (bounds: CGRect, screen: NSScreen)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            pid > 0,
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                CGWindowID(kCGNullWindowID)
            ) as? [[String: Any]]
        else {
            return nil
        }

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                frame.width > 1,
                frame.height > 1
            else {
                continue
            }
            if let screen = screen(containingQuartzFrame: frame) {
                return (frame, screen)
            }
        }
        return nil
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
    }

    private func screen(containingQuartzFrame windowFrame: CGRect) -> NSScreen? {
        var bestMatch: (screen: NSScreen, area: CGFloat)?
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else { continue }
            let displayFrame = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let intersection = displayFrame.intersection(windowFrame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > (bestMatch?.area ?? 0) {
                bestMatch = (screen, area)
            }
        }
        return bestMatch?.screen
    }
}
