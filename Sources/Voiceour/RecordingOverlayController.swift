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

    /// The display the panel is laid out on, as it was read when the body went there. Nil until
    /// the first session.
    private var display: OverlayDisplay?
    /// One for the controller's lifetime: a display left at the end of one session is still a
    /// return at the start of the next, and a storm of moves does not stop for a dictation.
    private var movePolicy = RecordingOverlayMovePolicy()
    /// The hand-off in flight, counted on the clock of the surface presenting the body.
    private var conductor = RecordingOverlayConductor(display: kCGNullDirectDisplay)
    /// The display the conductor's drain is heading for, as it was read when the move was decided.
    /// A re-frame only ever targets the display of the retarget that started or re-aimed its drain.
    private var handOffDestination: OverlayDisplay?
    /// The last substep a live frame presented; nil until the session's surface presents one, whose
    /// clock starts again from zero.
    private var presentedStep: Int?
    /// Arrival tokens issued. Each is newer than every one before it, which is how the body knows
    /// a hand-off from the same arrival handed over on the next frame.
    private var arrivalCount = 0
    /// A move the policy deferred: a click waiting for the activation it may cause, a return
    /// holding, or a reconfiguration settling.
    private var reevaluation: Task<Void, Never>?
    /// The user dragged the panel this session. It stays where it was put until the session ends.
    private var userDragged = false
    private var pointerGate = RecordingOverlayPointerGate()
    /// −1…1 toward the frontmost window, from the body's anchor. See ``lean(towardWindow:anchorX:displayFrame:)``.
    private var windowLean = 0.0
    /// The frontmost window fills the panel's display.
    private var frontmostIsFullScreen = false
    /// The pointer is in the menu-bar band beside the collar's housing.
    private var pointerInBand = false

    private lazy var focusTracker = RecordingOverlayFocusTracker { [weak self] screen, cause in
        self?.consider(screen, cause: cause)
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
                    // idle that follows delivery. The idle after a paste or a
                    // cancel finds the panel already fading out on its own.
                    if state == .idle, self.outcomeDismissal != nil || self.model.isDismissing {
                        return
                    }
                    let wasActive = self.model.state.isActive
                    if state.isActive {
                        // A session arriving while the panel fades out reverses the fade, and
                        // focus went unwatched while it ran.
                        let reversesHide = self.model.isDismissing
                        let preemptingDwell = self.outcomeDismissal != nil
                        self.cancelOutcomeDismissal()
                        if preemptingDwell {
                            self.model.reset()
                        }
                        self.model.update(state)
                        self.setVisible(true)
                        if reversesHide {
                            // Where the body belongs is the move policy's to say, through a
                            // hand-off rather than a jump: the panel is still showing it.
                            self.consider(self.focusTracker.currentScreen(), cause: .focus)
                        }
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
                        self.setVisible(false)
                    }
                    self.updatePointerGate()
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

    private func setVisible(_ isVisible: Bool) {
        visibilityToken &+= 1
        let token = visibilityToken
        if isVisible {
            show()
        } else {
            hide(token: token)
        }
    }

    /// The body floats above the menu bar and every app window, full-screen ones included, so it
    /// fades in and out instead of popping on when permission checking starts. Reduce Motion
    /// keeps the instant behaviour; `visibilityToken` makes a hide that lands mid-show (or the
    /// reverse) a no-op.
    ///
    /// A session starts on the focused display, laid out there while the panel is hidden, and the
    /// body grows out of that display's notch or top edge from its first frame. A show that lands
    /// mid-hide reverses the fade and the swallow with it: the body grows back where it is.
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
        model.endDismissal()
        if beginsSession {
            beginSession(in: panel)
        }
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

    /// Paste, cancel and the end of a dwell all leave the same way: the body is asked for the idle
    /// pose while the panel fades, so it swallows itself into the notch or the top edge, and the
    /// session is forgotten only once the panel is gone. Reduce Motion orders it out at once.
    private func hide(token: Int) {
        focusTracker.stop()
        cancelReevaluation()
        guard let panel, panel.isVisible else {
            finishHide()
            return
        }
        guard !prefersReducedMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            finishHide()
            return
        }
        model.beginDismissal()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = VoiceourMotion.standardDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [self] in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityToken == token, let panel = self.panel else {
                    return
                }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.finishHide()
            }
        }
    }

    /// After `orderOut`, so the fade's last frame is still the swallowing body or the dwell's
    /// outcome. The session's hand-off goes with it, and the hidden panel ignores the mouse.
    private func finishHide() {
        model.reset()
        outcomeDismissal = nil
        conductor = RecordingOverlayConductor(display: display?.id ?? kCGNullDirectDisplay)
        handOffDestination = nil
        presentedStep = nil
        applyPoseContext()
        updatePointerGate()
    }

    private func cancelOutcomeDismissal() {
        outcomeDismissal?.cancel()
        outcomeDismissal = nil
    }

    /// Unclean deliveries hold the island for `outcomeDwell` so the moment can be read. The
    /// pointer gate holds the panel click-through for that window so it cannot swallow a click
    /// meant for the app underneath, and the move policy holds it where it is. `visibilityToken`
    /// is captured now and re-checked after the sleep: a newer session bumps it, and a stale
    /// dwell must not `orderOut` a live dictation.
    private func beginOutcomeDwell() {
        cancelOutcomeDismissal()
        setVisible(true)
        let token = visibilityToken
        outcomeDismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RecordingOverlayMetrics.outcomeDwell))
            guard let self else { return }
            guard !Task.isCancelled, self.visibilityToken == token else { return }
            self.setVisible(false)
        }
    }

    private var prefersReducedMotion: Bool {
        RenderOverrides.reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makePanel() -> RecordingOverlayPanel {
        let size = model.layout.panelSize
        let panel = RecordingOverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // The rasterized body carries its own alpha and no app shadow. Keep the panel
        // transparent, non-opaque and shadowless so only those pixels exist onscreen.
        panel.backgroundColor = .clear
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications,
        ]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        // Above the menu bar, which macOS 27 draws as a window at level 24, so the collar can hang
        // from the screen's top edge around the housing; below open menus at 101, so a menu pulled
        // down across it is never covered. `.fullScreenAuxiliary` lets the panel join a full-screen
        // app's Space, where it floats over that app's window like any other.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
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
                seed: { [weak self] in self?.mercurySeed ?? MercuryMetrics.defaultSeed },
                onFrame: { [weak self] report in self?.didPresent(report) }
            ),
            hitRegion: hitRegion,
            model: model,
            onPointerEvent: { [weak self] in self?.updatePointerGate() }
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    // MARK: - Layout

    /// The panel is hidden, so the session is laid out on the focused display at once, and it
    /// starts with no hand-off, no drag and a surface whose clock has not presented yet.
    private func beginSession(in panel: NSPanel) {
        let display = OverlayDisplayGeometry.display(for: focusTracker.currentScreen())
        place(panel, on: display)
        conductor = RecordingOverlayConductor(display: display.id)
        handOffDestination = nil
        presentedStep = nil
        userDragged = false
        refreshWindowContext()
        refreshPointerContext()
    }

    /// Lays the panel out on `display`: the layout its housing allows, at the frame that layout
    /// takes there. The model's layout changes first, so the tracking area AppKit rebuilds as the
    /// panel resizes already covers the new canvas.
    private func place(_ panel: NSPanel, on display: OverlayDisplay) {
        let layout = RecordingOverlayLayout.forDisplay(display)
        model.update(layout: layout)
        self.display = display
        let frame: NSRect
        if layout.kind == .collar, let housing = display.housing {
            frame = Self.collarFrame(panelSize: layout.panelSize, housing: housing, displayFrame: display.frame)
        } else {
            frame = islandFrame(on: display.visibleFrame)
        }
        guard panel.frame != frame else { return }
        isApplyingPosition = true
        defer { isApplyingPosition = false }
        panel.setFrame(frame, display: true)
    }

    /// The collar's panel is its canvas, which centres the housing's outline: centred on the
    /// housing and flush with the display's top edge, the outline lies on the housing itself.
    nonisolated static func collarFrame(panelSize: NSSize, housing: CGRect, displayFrame: CGRect) -> NSRect {
        NSRect(
            x: housing.midX - panelSize.width / 2,
            y: displayFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Placement is computed on the ISLAND, never on the window. `screenPadding` and
    /// `topOffset` used to be applied to the 260x80 transparent box, so one 14pt
    /// constant produced four different observable clearances (54 left, 54 right,
    /// 28 top, 46 bottom) and the pill could never be parked near a screen edge.
    private func islandFrame(on visibleFrame: NSRect) -> NSRect {
        let size = RecordingOverlayMetrics.islandSize
        if let origin = storedOrigin() {
            let savedWindow = NSRect(origin: origin, size: RecordingOverlayMetrics.windowSize)
            if let sourceScreen = screen(containing: savedWindow) {
                return RecordingOverlayMetrics.windowFrame(
                    forIsland: RecordingOverlayFramePlacement.translatedFrame(
                        RecordingOverlayMetrics.islandFrame(forWindow: savedWindow),
                        from: sourceScreen.visibleFrame,
                        to: visibleFrame,
                        size: size,
                        padding: RecordingOverlayMetrics.screenPadding
                    )
                )
            }
        }

        return RecordingOverlayMetrics.windowFrame(
            forIsland: RecordingOverlayFramePlacement.defaultFrame(
                on: visibleFrame,
                size: size,
                padding: RecordingOverlayMetrics.screenPadding,
                topOffset: RecordingOverlayMetrics.topOffset
            )
        )
    }

    // MARK: - Hand-off

    /// A screen the focus tracker or a deferred re-evaluation proposes, put to the move policy.
    ///
    /// The policy measures it against the conductor's destination rather than the panel's display,
    /// so a drain already heading there is not started twice and focus going back to the display
    /// a drain is leaving reads as the return it is. A fading panel takes no proposal: one queued
    /// before `hide()` stopped the tracker would otherwise start a hand-off for a session that is
    /// over.
    private func consider(_ screen: NSScreen, cause: RecordingOverlayMovePolicy.Cause) {
        guard let panel, panel.isVisible, !model.isDismissing, let current = display else { return }
        cancelReevaluation()
        let candidate = OverlayDisplayGeometry.display(for: screen)
        let decision = movePolicy.evaluate(
            now: CACurrentMediaTime(),
            current: conductor.destination,
            candidate: candidate.id,
            cause: cause,
            frozen: isFrozen
        )
        switch decision {
        case .stay:
            if candidate.id == current.id, candidate != current, conductor.isResting, !userDragged {
                // The display itself changed — a resolution, a mirror set, an auto-hidden menu
                // bar — so the body is laid out on it afresh, where it is. A body the user
                // dragged stays where they put it.
                place(panel, on: candidate)
            }
            if conductor.drainSign == nil {
                scheduleTargetRefresh()
            }
        case .move(_, let instant):
            hand(to: candidate, instant: instant)
        case .reevaluate(let time):
            scheduleReevaluation(at: time)
        }
        refreshWindowContext()
        updatePointerGate()
    }

    /// An outcome dwell shows its result where it is, and a session the user dragged has been put
    /// where they want it.
    private var isFrozen: Bool {
        outcomeDismissal != nil || userDragged
    }

    private func hand(to destination: OverlayDisplay, instant: Bool) {
        guard let current = display else { return }
        handOffDestination = destination
        let action = conductor.retarget(
            to: destination.id,
            exitSign: RecordingOverlayConductor.exitSign(from: current.frame, to: destination.frame),
            step: presentedStep ?? 0,
            instant: instant || prefersReducedMotion
        )
        if let action {
            perform(action)
        } else if conductor.drainSign == nil {
            // The body grows again on the display it never left. The target was last read when
            // the drain began, and focus has moved since.
            scheduleTargetRefresh()
        }
    }

    private func perform(_ action: RecordingOverlayConductor.Action) {
        switch action {
        case .reframe(let destination, let arrivalSign):
            reframe(to: destination, arrivalSign: arrivalSign)
        case .settled:
            // The hand-off's click-through ends; the frame that reported it re-asks the gate.
            break
        }
    }

    /// Moves the empty panel to the conductor's destination and kicks the body that emerges there.
    /// The policy hears of the move now, as the body leaves.
    private func reframe(to id: UInt32, arrivalSign: Double?) {
        guard let panel, let source = display, let destination = handOffDestination, destination.id == id else {
            return
        }
        handOffDestination = nil
        place(panel, on: destination)
        movePolicy.didMove(now: CACurrentMediaTime(), from: source.id, to: destination.id)
        if let arrivalSign {
            arrivalCount += 1
            model.present(arrival: RecordingOverlayConductor.arrival(id: arrivalCount, sign: arrivalSign))
        }
        scheduleTargetRefresh()
    }

    /// The target label reads the focused element through accessibility, which a slow app can make
    /// slow. It runs on the next main-actor turn, so neither a re-frame nor the frame that asked
    /// for it waits on that read.
    private func scheduleTargetRefresh() {
        Task { @MainActor [weak self] in
            self?.coordinator?.refreshTarget()
        }
    }

    private func scheduleReevaluation(at time: Double) {
        reevaluation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Swift.max(0, time - CACurrentMediaTime())))
            guard !Task.isCancelled, let self else { return }
            self.reevaluation = nil
            self.consider(self.focusTracker.currentScreen(), cause: .focus)
        }
    }

    private func cancelReevaluation() {
        reevaluation?.cancel()
        reevaluation = nil
    }

    // MARK: - Presented frames

    /// One live frame: the conductor's clock, the pointer's place in the band, and the gate.
    private func didPresent(_ report: MercuryFrameReport) {
        guard let panel, panel.isVisible else { return }
        presentedStep = report.step
        if let action = conductor.frame(volume: report.volume, step: report.step) {
            perform(action)
            if case .reframe = action {
                refreshWindowContext()
            }
        }
        refreshPointerContext()
        updatePointerGate()
    }

    /// Re-asks the pointer gate where the pointer is now. The panel is forced click-through while
    /// it is hidden or fading, through an outcome dwell, and through a hand-off. A collar is always
    /// click-through: it hangs from the housing, and a drag would carry the housing's outline away
    /// from it.
    private func updatePointerGate() {
        guard let panel else { return }
        let forced =
            !panel.isVisible || model.isDismissing || outcomeDismissal != nil || !conductor.isResting
            || model.layout.kind == .collar
        let pointer = RecordingOverlayPointerGate.pointInPanel(NSEvent.mouseLocation, panelFrame: panel.frame)
        pointerGate.set(
            ignoresMouse: RecordingOverlayPointerGate.ignoresMouse(
                pointerInPanel: pointer,
                hitRegion: hitRegion,
                forcedClickThrough: forced
            ),
            on: panel
        )
    }

    // MARK: - Pose context

    /// The lean toward the frontmost window and whether it fills the display. A window-list walk,
    /// so it runs when a session starts and on focus events, never per frame.
    private func refreshWindowContext() {
        guard let display else { return }
        let window = focusTracker.frontmostWindowFrame()
        let anchor: CGFloat
        if model.layout.kind == .collar, let housing = display.housing {
            anchor = housing.midX
        } else {
            anchor = panel?.frame.midX ?? display.frame.midX
        }
        windowLean = Self.lean(towardWindow: window, anchorX: anchor, displayFrame: display.frame)
        frontmostIsFullScreen = Self.isFullScreen(window: window, displayFrame: display.frame)
        applyPoseContext()
    }

    /// Whether the pointer is in the collar's band, per frame: the speaking collar gives the walls
    /// back as the pointer reaches for a menu, and takes them again as it leaves.
    private func refreshPointerContext() {
        guard let display else { return }
        pointerInBand = model.layout.kind == .collar && Self.isPointerInBand(NSEvent.mouseLocation, display: display)
        applyPoseContext()
    }

    /// The model hears each only when it changes. A draining body leans toward the display it is
    /// leaving for rather than the window.
    private func applyPoseContext() {
        let drainSign = conductor.drainSign
        model.update(
            poseContext: MercuryPoseContext(
                pointerInBand: pointerInBand,
                fullScreen: frontmostIsFullScreen,
                draining: drainSign != nil
            )
        )
        model.update(lean: drainSign ?? windowLean)
    }

    /// −1…1: how far the window's centre lies from the body's anchor, in half display widths, so a
    /// window centred on either edge of a display the body is centred on leans it fully. Zero with
    /// no window or no display width.
    nonisolated static func lean(towardWindow window: CGRect?, anchorX: CGFloat, displayFrame: CGRect) -> Double {
        guard let window, displayFrame.width > 0 else { return 0 }
        let lean = Double((window.midX - anchorX) / (displayFrame.width / 2))
        guard lean.isFinite else { return 0 }
        return Swift.min(Swift.max(lean, -1), 1)
    }

    /// The window fills the display to within a point on every edge: a full-screen app, whose
    /// menu bar is hidden, so the band beside the notch is empty black.
    nonisolated static func isFullScreen(window: CGRect?, displayFrame: CGRect) -> Bool {
        guard let window else { return false }
        return abs(window.minX - displayFrame.minX) <= 1 && abs(window.maxX - displayFrame.maxX) <= 1
            && abs(window.minY - displayFrame.minY) <= 1 && abs(window.maxY - displayFrame.maxY) <= 1
    }

    /// How far beside the housing the band counts as the pointer's reach for a menu, in points.
    nonisolated static let bandReach: CGFloat = 40

    /// `pointer`, in AppKit global coordinates, lies in `display`'s menu-bar band within
    /// `bandReach` of its housing. False on a display without one.
    nonisolated static func isPointerInBand(_ pointer: CGPoint, display: OverlayDisplay) -> Bool {
        guard let housing = display.housing else { return false }
        return pointer.x >= housing.minX - bandReach && pointer.x <= housing.maxX + bandReach
            && pointer.y >= display.frame.maxY - display.bandHeight && pointer.y <= display.frame.maxY
    }

    // MARK: - Accessibility

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

    // MARK: - Drag

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return screen
        }
        return NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })
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
        // A move the controller did not make, with the primary button held, is the user's drag,
        // and the session stays where it was put. AppKit relocating the panel off a display that
        // went away is not a placement.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            userDragged = true
        }
        // Stored placement is the island's. A collar's frame is its housing's, and its panel is
        // not the island's 260×80 that the stored origin measures.
        if model.layout.kind == .island {
            savePosition(of: movedPanel)
        }
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
