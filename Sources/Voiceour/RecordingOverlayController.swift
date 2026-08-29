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
    private var outcomeDismissal: Task<Void, Never>?
    private let hitRegion = MercuryHitRegion()
    /// The world this session's body reflects. A fresh one is installed on every
    /// transition from hidden to visible — a state change inside one session must not
    /// re-seed, or the room would change under the reader mid-utterance.
    private var mercurySeed = RenderOverrides.mercurySeed ?? MercuryMetrics.defaultSeed
    private var mercuryWorld = MercuryWorld.default

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
                    // The coordinator publishes a terminal state and `.idle` on
                    // adjacent main-actor turns (`resetToIdleWhenInactive`). A
                    // latched unclean outcome outranks that idle: dismissing
                    // here would hide the moment before it could be read. The
                    // dwell is presentation only and must not sit in the
                    // delivery path — but it also must not be discarded by the
                    // idle that follows delivery.
                    if state == .idle, self.outcomeDismissal != nil {
                        return
                    }
                    let wasActive = self.model.state.isActive
                    if state.isActive {
                        let preemptingDwell = self.outcomeDismissal != nil
                        self.cancelOutcomeDismissal()
                        if preemptingDwell {
                            self.model.reset()
                        }
                        self.model.update(state)
                        self.setVisible(true)
                    } else if let outcome = RecordingOverlayOutcome(
                        state: state,
                        failure: self.coordinator?.lastFailure
                            ?? self.coordinator?.acquisitionFailure
                    ) {
                        self.model.update(state)
                        self.model.present(outcome)
                        self.beginOutcomeDwell()
                    } else {
                        self.cancelOutcomeDismissal()
                        self.model.update(state)
                        self.model.reset()
                        self.setVisible(false)
                    }
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
                        guard let self else { return }
                        self.model.updateCaptureLive(live)
                        if live, self.model.isRecording {
                            self.postAnnouncement(self.model.accessibilityStatus)
                        }
                    }
                }
        } else {
            inputLevelCancellable = nil
            captureLiveCancellable = nil
        }
    }

    private func setVisible(_ isVisible: Bool, resetAfterOrderOut: Bool = false) {
        visibilityToken &+= 1
        let token = visibilityToken
        if isVisible {
            show()
        } else {
            hide(token: token, resetAfterOrderOut: resetAfterOrderOut)
        }
    }

    /// The body is a `.screenSaver`-level surface above every window and fullscreen
    /// Space, so it fades in and out instead of popping on when permission checking
    /// starts. Reduce Motion keeps the instant behaviour; `visibilityToken` makes a hide
    /// that lands mid-show (or the reverse) a no-op.
    private func show() {
        let beginsSession = panel?.isVisible != true
        if beginsSession {
            // Install both world inputs before `makePanel()` constructs the StateObject.
            // A Settings change applies to the next dictation, never mid-utterance.
            mercurySeed = RenderOverrides.mercurySeed ?? UInt64.random(in: .min ... .max)
            mercuryWorld =
                RenderOverrides.mercuryWorld
                ?? coordinator?.settings.mercuryWorld
                ?? .default
        }
        let panel = panel ?? makePanel()
        // A dwell makes the panel click-through; the next show must restore
        // hit-testing or a later session is inert.
        panel.ignoresMouseEvents = false
        position(panel, on: focusTracker.currentScreen())
        // `hide()` stops tracking before its fade. A new session can reverse that fade
        // while the panel is still visible, so starting only inside `!isVisible` strands
        // the live island on the old display. `start()` is idempotent and must run for
        // every show, including a hide reversal.
        focusTracker.start()
        if !panel.isVisible {
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

    private func hide(token: Int, resetAfterOrderOut: Bool = false) {
        focusTracker.stop()
        guard let panel, panel.isVisible else {
            finishHide(resetAfterOrderOut: resetAfterOrderOut)
            return
        }
        guard !prefersReducedMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            finishHide(resetAfterOrderOut: resetAfterOrderOut)
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
                self.finishHide(resetAfterOrderOut: resetAfterOrderOut)
            }
        }
    }

    /// `reset()` before `orderOut` blanks the dwell's last frame; click-through
    /// must not survive a cancelled or completed dismissal either.
    private func finishHide(resetAfterOrderOut: Bool) {
        panel?.ignoresMouseEvents = false
        guard resetAfterOrderOut else { return }
        model.reset()
        outcomeDismissal = nil
    }

    /// Drop a pending outcome dwell. Restores hit-testing so cancellation
    /// cannot leave the panel inert for the next session.
    private func cancelOutcomeDismissal() {
        outcomeDismissal?.cancel()
        outcomeDismissal = nil
        panel?.ignoresMouseEvents = false
    }

    /// Unclean deliveries hold the island for `outcomeDwell` so the moment can
    /// be read. The panel is click-through for that window so it cannot swallow
    /// a click meant for the app underneath. `visibilityToken` is captured now
    /// and re-checked after the sleep: a newer session bumps it, and a stale
    /// dwell must not `orderOut` a live dictation.
    private func beginOutcomeDwell() {
        cancelOutcomeDismissal()
        setVisible(true)
        panel?.ignoresMouseEvents = true
        let token = visibilityToken
        outcomeDismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RecordingOverlayMetrics.outcomeDwell))
            guard let self else { return }
            guard !Task.isCancelled, self.visibilityToken == token else { return }
            self.setVisible(false, resetAfterOrderOut: true)
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
        // The rasterized body carries its own alpha and no app shadow. Keep the panel
        // transparent, non-opaque and shadowless so only those pixels exist onscreen.
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

        let hostingView = RecordingOverlayHostingView(
            rootView: RecordingOverlayView(
                model: model,
                onCancel: { [weak self] in
                    Task { @MainActor in
                        self?.cancel()
                    }
                },
                onFinish: { [weak self] in
                    Task { @MainActor in
                        self?.finish()
                    }
                },
                hitRegion: hitRegion,
                // Session-latched closures: Settings remains the persisted authority, but
                // changing the debug picker cannot replace lighting mid-utterance.
                world: { [weak self] in self?.mercuryWorld ?? .default },
                seed: { [weak self] in self?.mercurySeed ?? MercuryMetrics.defaultSeed }
            ),
            hitRegion: hitRegion
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
        guard
            let announcement = Self.announcement(
                for: state,
                failure: coordinator?.lastFailure ?? coordinator?.acquisitionFailure
            )
        else { return }
        postAnnouncement(announcement)
    }

    private func postAnnouncement(_ announcement: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    /// What VoiceOver hears, which has to be what the stable island readout and menu
    /// show. Pure so the rule is testable without a panel, the same way the
    /// coordinator's acquisition rules are.
    ///
    /// `SessionState.displayName` interpolates both ASR wire codes and insertion-reason
    /// tokens. Every unclean terminal routes through the one outcome presentation
    /// instead, so its announcement and its latched AX value cannot disagree. A clean
    /// paste stays silent because the text arriving in the target is confirmation, and
    /// a cancellation stays silent because the user just asked for it. Active states
    /// still name themselves as they progress.
    nonisolated static func announcement(
        for state: SessionState,
        failure: UserFacingDictationFailure?
    ) -> String? {
        if let outcome = RecordingOverlayOutcome(state: state, failure: failure) {
            return outcome.accessibilityStatus
        }
        return state.isActive ? state.displayName : nil
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
