import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog
import VoiceCore

struct FnKeyToggleDetector {
    enum EventKind {
        case flagsChanged
        case keyDown
        case keyUp

        init?(_ eventType: NSEvent.EventType) {
            switch eventType {
            case .flagsChanged:
                self = .flagsChanged
            case .keyDown:
                self = .keyDown
            case .keyUp:
                self = .keyUp
            default:
                return nil
            }
        }
    }

    private static let functionKeyCode = UInt16(kVK_Function)
    private static let disarmingModifierMask: NSEvent.ModifierFlags = [
        .capsLock,
        .shift,
        .control,
        .option,
        .command,
    ]

    private var fnIsHeld = false
    private var isArmed = false

    mutating func handle(_ eventKind: EventKind, keyCode: UInt16? = nil, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch eventKind {
        case .flagsChanged:
            if flags.contains(.function) {
                beginOrUpdateFnHold(modifierFlags: flags)
                return false
            }

            guard fnIsHeld else { return false }
            return releaseFn()

        case .keyDown:
            if isFunctionKey(keyCode) {
                beginOrUpdateFnHold(modifierFlags: flags)
            } else if fnIsHeld {
                isArmed = false
            } else if flags.contains(.function) {
                fnIsHeld = true
                isArmed = false
            }
            return false

        case .keyUp:
            if isFunctionKey(keyCode) {
                guard fnIsHeld else { return false }
                return releaseFn()
            }

            if fnIsHeld {
                isArmed = false
            }
            return false
        }
    }

    private mutating func beginOrUpdateFnHold(modifierFlags: NSEvent.ModifierFlags) {
        if !fnIsHeld {
            fnIsHeld = true
            isArmed = !hasDisarmingModifier(in: modifierFlags)
        } else if hasDisarmingModifier(in: modifierFlags) {
            isArmed = false
        }
    }

    private mutating func releaseFn() -> Bool {
        let shouldFire = isArmed
        fnIsHeld = false
        isArmed = false
        return shouldFire
    }

    private func hasDisarmingModifier(in modifierFlags: NSEvent.ModifierFlags) -> Bool {
        !modifierFlags.intersection(Self.disarmingModifierMask).isEmpty
    }

    private func isFunctionKey(_ keyCode: UInt16?) -> Bool {
        keyCode == Self.functionKeyCode
    }
}

/// Escape dismisses a live dictation session, the same action as the overlay's
/// CANCEL control. The decision is pure so the event-tap callback stays a thin
/// shim and the keyUp pairing is testable without an event tap.
///
/// Escape is the single most overloaded key on the system, so the claim is
/// deliberately narrow: only an unmodified, non-repeating press, and only while
/// a session is armed. Everything else passes through to the focused app.
struct EscapeCancelDetector {
    enum Decision: Equatable {
        /// Leave the event alone.
        case ignore
        /// Swallow the event without firing: repeats of a claimed press, and the
        /// keyUp that pairs with one. An orphan Escape keyUp is harmless in Cocoa
        /// but not in apps that track key state themselves.
        case consume
        /// Swallow the event and cancel the session.
        case cancel
    }

    private static let escapeKeyCode = UInt16(kVK_Escape)
    /// CapsLock is a lock state, not a chord, so it is not disqualifying. `.function`
    /// is: Fn+Escape belongs to the Fn detector, which must still see it to disarm.
    private static let disqualifyingModifierMask: NSEvent.ModifierFlags = [
        .shift,
        .control,
        .option,
        .command,
        .function,
    ]

    private var claimedKeyDown = false

    mutating func handle(
        _ eventKind: FnKeyToggleDetector.EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isAutorepeat: Bool,
        isArmed: Bool
    ) -> Decision {
        guard keyCode == Self.escapeKeyCode else { return .ignore }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch eventKind {
        case .keyDown:
            // Checked before arming: cancelling disarms immediately, so the repeats
            // and keyUp of a press already claimed still have to be swallowed.
            if claimedKeyDown { return .consume }
            guard isArmed, !isAutorepeat, flags.isDisjoint(with: Self.disqualifyingModifierMask) else {
                return .ignore
            }
            claimedKeyDown = true
            return .cancel

        case .keyUp:
            guard claimedKeyDown else { return .ignore }
            claimedKeyDown = false
            return .consume

        case .flagsChanged:
            return .ignore
        }
    }
}

/// Classifies one keyboard event for `KeyboardShortcutsBinder`: Globe suppression,
/// the Fn toggle, and the Escape claim in one place, so both the event-tap and the
/// passive-monitor paths reach the same verdict and the whole decision is testable
/// without installing a tap or holding Accessibility.
struct HotkeyEventRouter {
    enum Outcome: Equatable {
        /// Leave the event alone.
        case pass
        /// Claim the event; no action attached.
        case consume
        /// Claim the event and toggle dictation.
        case toggle
        /// Claim the event and discard the live session.
        case cancel
    }

    private static let globeAssignedActionKeyCode = UInt16(179)

    private var fnDetector = FnKeyToggleDetector()
    private var escapeDetector = EscapeCancelDetector()

    /// Mirrors `SessionState.isActive`; see `HotkeyBinding.setCancelArmed(_:)`.
    var isCancelArmed = false

    /// The event-tap path, which sees every event and can suppress one.
    mutating func routeTapped(_ event: CGEvent) -> Outcome {
        // keyCode 179 (0xB3) is the Globe/Fn "assigned action" key macOS emits on a
        // standalone Globe tap to open the Emoji & Symbols picker. It is a separate
        // keyDown/keyUp — not the flagsChanged modifier — so consume it here to suppress
        // the popup. It is never emitted for Fn+key combos, so combos are unaffected. The
        // toggle itself fires on the Fn (keyCode 63) release, so do not re-fire here.
        // A passive monitor cannot suppress the popup, but it must ignore this event so
        // the Fn detector does not disarm a hold that is still in progress.
        if event.getIntegerValueField(.keyboardEventKeycode) == Int64(Self.globeAssignedActionKeyCode) {
            return .consume
        }
        guard let nsEvent = NSEvent(cgEvent: event),
            let eventKind = FnKeyToggleDetector.EventKind(nsEvent.type)
        else { return .pass }
        return route(
            eventKind,
            keyCode: nsEvent.keyCode,
            modifierFlags: nsEvent.modifierFlags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }

    /// The passive-monitor fallback shares this entry point. It cannot suppress, so
    /// every outcome but `.pass` still lets the focused app see the key. Values rather
    /// than an `NSEvent` because that path hops queues before deciding.
    mutating func route(
        _ eventKind: FnKeyToggleDetector.EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isAutorepeat: Bool
    ) -> Outcome {
        // Passive monitors cannot suppress Globe's assigned action. Forwarding it would
        // disarm an in-progress Fn hold, so leave both detectors unchanged.
        if keyCode == Self.globeAssignedActionKeyCode {
            return .pass
        }

        switch escapeDetector.handle(
            eventKind,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isAutorepeat: isAutorepeat,
            isArmed: isCancelArmed
        ) {
        case .cancel:
            return .cancel
        case .consume:
            return .consume
        case .ignore:
            break
        }

        let shouldToggle = fnDetector.handle(eventKind, keyCode: keyCode, modifierFlags: modifierFlags)
        return shouldToggle ? .toggle : .pass
    }
}

public final class KeyboardShortcutsBinder: HotkeyBinding, @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorTokens: [Any] = []
    private var watchdog: DispatchSourceTimer?
    private var router = HotkeyEventRouter()
    private var handler: (@Sendable () -> Void)?
    private var cancelHandler: (@Sendable () -> Void)?
    private var didPromptForAccessibility = false
    /// True once the passive path has routed a real dictation gesture. The prompt
    /// waits on this; see `promptForAccessibilityIfEarned()`.
    private var didUseGestureWithoutTap = false
    /// The app's own view of whether a session is on screen, kept beside the router's
    /// copy so recreating the router cannot drop a fact only the app knows.
    private var isSessionActive = false

    /// Diagnostic channel for the tap-vs-passive decision. The two paths are
    /// visually identical until a standalone Globe tap opens the system emoji
    /// picker, so the active path must be observable without a reproduction:
    ///     log stream --predicate 'subsystem == "com.voiceour.app" AND category == "hotkey"'
    private static let log = Logger(subsystem: "com.voiceour.app", category: "hotkey")

    public init() {}

    deinit {
        teardown()
    }

    public func onToggle(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        installIfNeeded()
    }

    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        cancelHandler = handler
        installIfNeeded()
    }

    /// Written by the app on session-state changes and read by the tap callback. Both
    /// run on the main thread — the tap's run-loop source is attached to
    /// `CFRunLoopGetMain()` — so this needs no more synchronisation than `handler`.
    public func setCancelArmed(_ isArmed: Bool) {
        isSessionActive = isArmed
        router.isCancelArmed = isArmed
    }

    // MARK: - Installation

    private func installIfNeeded() {
        guard eventTap == nil, monitorTokens.isEmpty else { return }
        // Primary path: an active session event tap that can *consume* the standalone
        // Fn/Globe tap so macOS does not also open the emoji/dictation popup.
        if installEventTap() {
            Self.log.log("hotkey path: session event tap (suppressing)")
        } else {
            // Fallback (no Accessibility): passive monitors still toggle, but cannot
            // suppress the popup because a passive NSEvent monitor cannot consume events.
            Self.log.error("tapCreate failed at install; falling back to passive monitors (emoji popup NOT suppressed)")
            installPassiveMonitors()
        }
        // Either way, keep watching: the tap must win back the key the moment it can.
        startWatchdog()
    }

    /// Asks for Accessibility trust once the reader has shown they want what it buys.
    ///
    /// Nothing in the hotkey path needs the grant to exist for the app to work: the
    /// passive monitors are installed either way and already toggle recording on a
    /// solitary Fn/Globe release, insertion degrades to copy-only rather than pasting
    /// silently, and this watchdog promotes to the tap within one tick of the grant
    /// arriving, with no relaunch. Asking at install time therefore bought nothing but
    /// the earliest possible refusal: an unexplained system dialog about controlling
    /// the computer, for an app the reader had not used yet.
    ///
    /// So it waits for the gesture itself, which is the thing trust actually buys. By
    /// then the reader has met the emoji picker the tap exists to swallow, and the
    /// dialog answers a question they now have. Still one prompt per process: the
    /// watchdog's silent retries must never spawn dialogs on a timer.
    ///
    /// Never during a live session. `AXIsProcessTrustedWithOptions` puts a system alert
    /// on screen, and a transcript's delivery target is snapshotted from whatever is
    /// focused when insertion begins — prompting mid-utterance would move the
    /// destination out from under the reader.
    private func promptForAccessibilityIfEarned() {
        guard !didPromptForAccessibility else { return }
        guard eventTap == nil, didUseGestureWithoutTap, !isSessionActive else { return }
        didPromptForAccessibility = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// The tap is not install-once. Accessibility can be granted after launch, and an
    /// ad-hoc re-sign invalidates the TCC grant so `tapCreate` fails on the next run —
    /// both previously stranded the binder on the passive path forever, where the Fn
    /// toggle still fired but the Globe assigned-action key could not be consumed and
    /// the macOS emoji picker opened alongside dictation. macOS can also invalidate a
    /// live tap's mach port when the grant is revoked mid-run. This timer heals all
    /// three: promote passive monitors to a tap as soon as one can be created, and
    /// rebuild a tap whose port has died. A tick against a healthy tap is one
    /// `CFMachPortIsValid` plus one `tapIsEnabled` check.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        timer.resume()
        watchdog = timer
    }

    private func watchdogTick() {
        if let tap = eventTap {
            if CFMachPortIsValid(tap) {
                // The callback re-enables on tapDisabled events; this covers a disable
                // observed between callback invocations.
                if !CGEvent.tapIsEnabled(tap: tap) {
                    Self.log.error("event tap found disabled; re-enabling")
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return
            }
            Self.log.error("event tap mach port invalidated; rebuilding")
            teardownTap()
        }
        if installEventTap() {
            // The tap now owns the key; drop the passive path so a toggle cannot fire
            // twice, and start the new tap on a clean router so it cannot pair a release
            // with a press only the passive monitor saw.
            resetRouter()
            Self.log.log("hotkey path upgraded: passive monitors -> session event tap")
            removePassiveMonitors()
        } else if monitorTokens.isEmpty {
            Self.log.error("tapCreate still failing; staying on passive monitors")
            installPassiveMonitors()
        }
        promptForAccessibilityIfEarned()
    }

    /// Clears both detectors so no half-seen press survives a tap that came or went,
    /// while restoring the arming the app owns: `isCancelArmed` mirrors session state,
    /// which a rebuild does not change, and dropping it would disarm Escape for a
    /// session already on screen.
    ///
    /// Called only where the tap itself changed. A tick that merely fails to create one
    /// leaves the passive path's router alone: recreating it every two seconds threw
    /// away an Fn hold in progress, so a tap that straddled a tick toggled nothing.
    private func resetRouter() {
        router = HotkeyEventRouter()
        router.isCancelArmed = isSessionActive
    }

    private func installEventTap() -> Bool {
        let mask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let binder = Unmanaged<KeyboardShortcutsBinder>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = binder.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let consume = binder.handleTap(event)
            return consume ? nil : Unmanaged.passUnretained(event)
        }

        // `.cgSessionEventTap` (not `.cghidEventTap`) because a non-root process can only
        // *actively* filter — i.e. return nil to consume — at the session tap; the HID tap
        // silently downgrades to listen-only without root, which cannot suppress the popup.
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func installPassiveMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        if let globalToken = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                self?.enqueuePassive(event)
            })
        {
            monitorTokens.append(globalToken)
        }

        if let localToken = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                self?.enqueuePassive(event)
                return event
            })
        {
            monitorTokens.append(localToken)
        }
    }

    // MARK: - Event handling

    // Runs on the main run loop (the tap source is attached to it). Returns true when the
    // event should be consumed.
    func handleTap(_ event: CGEvent) -> Bool {
        switch router.routeTapped(event) {
        case .pass:
            return false
        case .consume:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            Self.log.log("consumed event type=\(event.type.rawValue) keycode=\(keycode)")
            return true
        case .toggle:
            let handler = self.handler
            DispatchQueue.main.async { handler?() }
            return true
        case .cancel:
            let cancelHandler = self.cancelHandler
            DispatchQueue.main.async { cancelHandler?() }
            return true
        }
    }

    /// No Accessibility grant means no tap: this path still fires the toggle and the
    /// cancel, but cannot swallow anything, so the focused app sees the key too.
    private func enqueuePassive(_ event: NSEvent) {
        guard let eventKind = FnKeyToggleDetector.EventKind(event.type) else { return }
        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        // `isARepeat` raises on anything that is not a key event.
        let isAutorepeat = eventKind != .flagsChanged && event.isARepeat

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.router.route(
                eventKind,
                keyCode: keyCode,
                modifierFlags: modifierFlags,
                isAutorepeat: isAutorepeat
            ) {
            case .pass, .consume:
                return
            case .toggle:
                // The reader wants the gesture and is not getting the suppression the
                // tap would give it, so the grant is now worth asking for. The watchdog
                // does the asking, off the session path.
                self.didUseGestureWithoutTap = true
                self.handler?()
            case .cancel:
                self.cancelHandler?()
            }
        }
    }

    // MARK: - Teardown

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        teardownTap()
        removePassiveMonitors()
    }

    func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        // Once the tap is gone, no held-key belief can be paired with future events.
        resetRouter()
    }

    private func removePassiveMonitors() {
        for token in monitorTokens {
            NSEvent.removeMonitor(token)
        }
        monitorTokens.removeAll()
    }
}
