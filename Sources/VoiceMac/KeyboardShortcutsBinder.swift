import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
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

    private static let globeAssignedActionKeyCode: Int64 = 179

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
        // Tap-only: a passive monitor cannot suppress the popup, so that path leaves the
        // key to the Fn detector exactly as it always has.
        if event.getIntegerValueField(.keyboardEventKeycode) == Self.globeAssignedActionKeyCode {
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
    private var router = HotkeyEventRouter()
    private var handler: (@Sendable () -> Void)?
    private var cancelHandler: (@Sendable () -> Void)?

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
        router.isCancelArmed = isArmed
    }

    // MARK: - Installation

    private func installIfNeeded() {
        guard eventTap == nil, monitorTokens.isEmpty else { return }
        // Primary path: an active session event tap that can *consume* the standalone
        // Fn/Globe tap so macOS does not also open the emoji/dictation popup.
        if installEventTap() { return }
        // Fallback (no Accessibility): passive monitors still toggle, but cannot suppress
        // the popup because a passive NSEvent monitor cannot consume events.
        installPassiveMonitors()
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
    private func handleTap(_ event: CGEvent) -> Bool {
        switch router.routeTapped(event) {
        case .pass:
            return false
        case .consume:
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
                self.handler?()
            case .cancel:
                self.cancelHandler?()
            }
        }
    }

    // MARK: - Teardown

    private func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        for token in monitorTokens {
            NSEvent.removeMonitor(token)
        }
        monitorTokens.removeAll()
    }
}
