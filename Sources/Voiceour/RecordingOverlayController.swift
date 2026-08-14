import AppKit
import Combine
import VoiceCore

@MainActor
final class RecordingOverlayController: NSObject, NSWindowDelegate {
    private weak var coordinator: DictationCoordinator?
    private var stateCancellable: AnyCancellable?
    private var inputLevelCancellable: AnyCancellable?
    private var captureLiveCancellable: AnyCancellable?
    private let model = RecordingOverlayModel()
    private var panel: RecordingOverlayPanel?
    private var isApplyingPosition = false
    private var visibilityToken = 0
    private lazy var focusTracker = RecordingOverlayFocusTracker { [weak self] destinationScreen in
        self?.follow(destinationScreen)
    }

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func bind(to statePublisher: AnyPublisher<SessionState, Never>) {
        stateCancellable =
            statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    let wasActive = self.model.state.isActive
                    self.model.update(state)
                    if !state.isActive {
                        self.model.reset()
                    }
                    self.setVisible(state.isOverlayVisible)
                    if state.isActive || wasActive {
                        self.announce(state)
                    }
                }
            }

        if let coordinator {
            inputLevelCancellable = coordinator.inputMeter.$level
                .receive(on: RunLoop.main)
                .sink { [weak self] level in
                    Task { @MainActor in
                        self?.model.record(level)
                    }
                }

            captureLiveCancellable = coordinator.inputMeter.$live
                .receive(on: RunLoop.main)
                .sink { [weak self] live in
                    Task { @MainActor in
                        self?.model.updateCaptureLive(live)
                    }
                }
        } else {
            inputLevelCancellable = nil
            captureLiveCancellable = nil
        }
    }

    private func setVisible(_ isVisible: Bool) {
        visibilityToken &+= 1
        let token = visibilityToken
        if isVisible {
            show()
        } else {
            hide(token: token)
        }
    }

    /// The pill is a `.screenSaver`-level surface that sits above every window and
    /// every fullscreen Space, so it fades in and out instead of popping on at full
    /// opacity the moment `checkingPermissions` fires. Reduce Motion keeps the
    /// instant behaviour; `visibilityToken` makes a hide that lands mid-show (or the
    /// reverse) a no-op rather than a panel stuck at alpha 0.
    private func show() {
        let panel = panel ?? makePanel()
        position(panel, on: focusTracker.currentScreen())
        if !panel.isVisible {
            focusTracker.start()
            panel.alphaValue = prefersReducedMotion ? 1 : 0
        }
        panel.orderFrontRegardless()
        guard !prefersReducedMotion else {
            panel.alphaValue = 1
            return
        }
        // Already lit: a state change inside one session is not a new entrance. A
        // show that lands mid-hide sees the pending target of 0 here and reverses
        // the fade from wherever it currently is.
        guard panel.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = VoiceourMotion.standardDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide(token: Int) {
        focusTracker.stop()
        guard let panel, panel.isVisible else { return }
        guard !prefersReducedMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = VoiceourMotion.standardDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.visibilityToken == token, let panel = self.panel else {
                    return
                }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    private var prefersReducedMotion: Bool {
        RenderOverrides.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makePanel() -> RecordingOverlayPanel {
        let panel = RecordingOverlayPanel(
            contentRect: NSRect(origin: .zero, size: RecordingOverlayMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Behind-window liquid glass (FrostedGlassBackground / NSVisualEffectView)
        // only samples the desktop while the panel stays transparent and shadowless:
        // keep backgroundColor = .clear, isOpaque = false, and hasShadow = false below.
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        // .floating sits below fullscreen apps; .screenSaver keeps the island
        // topmost over fullscreen Spaces, games, and every regular window.
        panel.level = .screenSaver
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.delegate = self

        let overlayModel = model
        let hostingView = RecordingOverlayHostingView(
            rootView: RecordingOverlayView(
                model: overlayModel,
                onCancel: { [weak self] in
                    Task { @MainActor in
                        self?.cancel()
                    }
                },
                onFinish: { [weak self] in
                    Task { @MainActor in
                        self?.finish()
                    }
                }
            ),
            showsFinishButton: { [weak overlayModel] in
                overlayModel?.showsFinishButton ?? false
            }
        )
        hostingView.frame = NSRect(origin: .zero, size: RecordingOverlayMetrics.windowSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, on destinationScreen: NSScreen) {
        let frame = preferredFrame(on: destinationScreen)
        guard panel.frame != frame else { return }
        isApplyingPosition = true
        defer { isApplyingPosition = false }
        panel.setFrame(frame, display: true)
    }

    /// Placement is computed on the ISLAND, never on the window. `screenPadding` and
    /// `topOffset` used to be applied to the 260x80 transparent box, so one 14pt
    /// constant produced four different observable clearances (54 left, 54 right,
    /// 28 top, 46 bottom) and the pill could never be parked near a screen edge.
    private func preferredFrame(on destinationScreen: NSScreen) -> NSRect {
        let size = RecordingOverlayMetrics.islandSize
        if let origin = storedOrigin() {
            let savedWindow = NSRect(origin: origin, size: RecordingOverlayMetrics.windowSize)
            if let sourceScreen = screen(containing: savedWindow) {
                return RecordingOverlayMetrics.windowFrame(
                    forIsland: RecordingOverlayFramePlacement.translatedFrame(
                        RecordingOverlayMetrics.islandFrame(forWindow: savedWindow),
                        from: sourceScreen.visibleFrame,
                        to: destinationScreen.visibleFrame,
                        size: size,
                        padding: RecordingOverlayMetrics.screenPadding
                    )
                )
            }
        }

        return RecordingOverlayMetrics.windowFrame(
            forIsland: RecordingOverlayFramePlacement.defaultFrame(
                on: destinationScreen.visibleFrame,
                size: size,
                padding: RecordingOverlayMetrics.screenPadding,
                topOffset: RecordingOverlayMetrics.topOffset
            )
        )
    }

    /// The panel is deliberately never key, so the status element inside it is only
    /// ever spoken if VoiceOver happens to be parked on it. The surface whose entire
    /// job is to report session state has to say so out loud; an app-level
    /// announcement is the one path that does not require focus. A no-op when
    /// VoiceOver is not running.
    private func announce(_ state: SessionState) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: state.displayName,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return screen
        }
        return NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })
    }

    private func follow(_ destinationScreen: NSScreen) {
        guard let panel, panel.isVisible else { return }
        position(panel, on: destinationScreen)
        coordinator?.refreshTarget()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingPosition,
            let movedPanel = notification.object as? NSPanel,
            let currentPanel = panel,
            movedPanel === currentPanel,
            movedPanel.isVisible
        else {
            return
        }
        savePosition(of: movedPanel)
    }

    private func savePosition(of panel: NSPanel) {
        let screen = screen(containing: panel.frame) ?? focusTracker.currentScreen()
        let frame = RecordingOverlayMetrics.windowFrame(
            forIsland: RecordingOverlayFramePlacement.clamped(
                RecordingOverlayMetrics.islandFrame(forWindow: panel.frame),
                to: screen.visibleFrame,
                padding: RecordingOverlayMetrics.screenPadding
            )
        )
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.minX), forKey: RecordingOverlayDefaults.originXKey)
        defaults.set(Double(frame.minY), forKey: RecordingOverlayDefaults.originYKey)
    }

    private func storedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: RecordingOverlayDefaults.originXKey) != nil,
            defaults.object(forKey: RecordingOverlayDefaults.originYKey) != nil
        else {
            return nil
        }
        return NSPoint(
            x: defaults.double(forKey: RecordingOverlayDefaults.originXKey),
            y: defaults.double(forKey: RecordingOverlayDefaults.originYKey)
        )
    }

    private func cancel() {
        coordinator?.cancel()
    }

    private func finish() {
        coordinator?.stopAndProcess()
    }
}
private enum RecordingOverlayDefaults {
    static let originXKey = "Voiceour.RecordingOverlay.origin.x"
    static let originYKey = "Voiceour.RecordingOverlay.origin.y"
}
