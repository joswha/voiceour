import AppKit

@MainActor
final class RecordingOverlayFocusTracker {
    private let onScreenChange: (NSScreen) -> Void
    private var isRunning = false
    private var globalMouseMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    init(onScreenChange: @escaping (NSScreen) -> Void) {
        self.onScreenChange = onScreenChange
    }

    func currentScreen() -> NSScreen {
        if let focused = frontmostWindowScreen() {
            return focused
        }
        if let pointed = screen(containing: NSEvent.mouseLocation) {
            return pointed
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followPointerScreen()
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followFocusedScreen()
            }
        }

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followFocusedScreen()
            }
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followFocusedScreen()
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

    private func followPointerScreen() {
        guard let destinationScreen = screen(containing: NSEvent.mouseLocation) else { return }
        onScreenChange(destinationScreen)
    }

    private func followFocusedScreen() {
        onScreenChange(currentScreen())
    }

    private func frontmostWindowScreen() -> NSScreen? {
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
                return screen
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
