import AppKit
import Testing

@testable import VoiceMac

/// Covers Fn/Globe standalone-tap detection and modifier-key disarming.
@Suite("Keyboard Shortcuts")
struct KeyboardShortcutsTests {
    @Test func fnKeyStandaloneTapTogglesExactlyOnce() {
        var detector = FnKeyToggleDetector()
        var toggleCount = 0

        if detector.handle(.flagsChanged, modifierFlags: [.function]) {
            toggleCount += 1
        }
        if detector.handle(.flagsChanged, keyCode: 0, modifierFlags: []) {
            toggleCount += 1
        }

        #expect(toggleCount == 1)
    }

    @Test func fnKeyRepeatedDownWhileHeldDoesNotToggle() {
        var detector = FnKeyToggleDetector()
        var toggleCount = 0

        if detector.handle(.flagsChanged, modifierFlags: [.function]) {
            toggleCount += 1
        }
        if detector.handle(.flagsChanged, modifierFlags: [.function]) {
            toggleCount += 1
        }
        if detector.handle(.keyDown, modifierFlags: [.function]) {
            toggleCount += 1
        }

        #expect(toggleCount == 0)
    }

    @Test func fnKeyPlusAnotherKeyDisarmsAndDoesNotToggle() {
        var detector = FnKeyToggleDetector()
        var toggleCount = 0

        if detector.handle(.flagsChanged, modifierFlags: [.function]) {
            toggleCount += 1
        }
        if detector.handle(.keyDown, keyCode: 0, modifierFlags: [.function]) {
            toggleCount += 1
        }
        if detector.handle(.flagsChanged, keyCode: 0, modifierFlags: []) {
            toggleCount += 1
        }

        #expect(toggleCount == 0)
    }

    @Test func fnModifiedKeySeenFirstDoesNotToggle() {
        var detector = FnKeyToggleDetector()
        var toggleCount = 0

        if detector.handle(.keyDown, keyCode: 0, modifierFlags: [.function]) {
            toggleCount += 1
        }
        if detector.handle(.flagsChanged, keyCode: 0, modifierFlags: []) {
            toggleCount += 1
        }

        #expect(toggleCount == 0)
    }

    @Test func nonFnModifiersDoNotToggle() {
        var detector = FnKeyToggleDetector()
        var toggleCount = 0

        if detector.handle(.flagsChanged, modifierFlags: [.shift]) {
            toggleCount += 1
        }
        if detector.handle(.flagsChanged, modifierFlags: []) {
            toggleCount += 1
        }
        if detector.handle(.keyDown, keyCode: 0, modifierFlags: [.control]) {
            toggleCount += 1
        }
        if detector.handle(.keyUp, keyCode: 0, modifierFlags: []) {
            toggleCount += 1
        }

        #expect(toggleCount == 0)
    }
}

/// Covers the Escape-to-cancel claim: it must fire exactly once per armed press,
/// leave Escape alone whenever no session is running, and never orphan a keyUp.
@Suite("Escape Cancel")
struct EscapeCancelTests {
    private static let escape = UInt16(53)
    private static let letterA = UInt16(0)

    private func press(
        _ detector: inout EscapeCancelDetector,
        keyCode: UInt16 = escape,
        modifierFlags: NSEvent.ModifierFlags = [],
        isAutorepeat: Bool = false,
        isArmed: Bool
    ) -> EscapeCancelDetector.Decision {
        detector.handle(
            .keyDown,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isAutorepeat: isAutorepeat,
            isArmed: isArmed
        )
    }

    private func release(
        _ detector: inout EscapeCancelDetector,
        keyCode: UInt16 = escape,
        isArmed: Bool
    ) -> EscapeCancelDetector.Decision {
        detector.handle(.keyUp, keyCode: keyCode, modifierFlags: [], isAutorepeat: false, isArmed: isArmed)
    }

    @Test func armedEscapeCancelsAndSwallowsBothHalvesOfThePress() {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, isArmed: true) == .cancel)
        // Cancelling disarms immediately, so the keyUp arrives unarmed and still
        // has to be swallowed: the focused app never saw the keyDown.
        #expect(release(&detector, isArmed: false) == .consume)
    }

    @Test func unarmedEscapePassesThrough() {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, isArmed: false) == .ignore)
        #expect(release(&detector, isArmed: false) == .ignore)
    }

    @Test func heldEscapeCancelsOnlyOnce() {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, isArmed: true) == .cancel)
        #expect(press(&detector, isAutorepeat: true, isArmed: false) == .consume)
        #expect(press(&detector, isAutorepeat: true, isArmed: false) == .consume)
        #expect(release(&detector, isArmed: false) == .consume)
    }

    @Test func escapeAlreadyHeldWhenArmingLandsDoesNotCancel() {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, isAutorepeat: true, isArmed: true) == .ignore)
    }

    @Test(arguments: [
        NSEvent.ModifierFlags.command,
        .control,
        .option,
        .shift,
        .function,
    ])
    func modifiedEscapeBelongsToTheFocusedApp(modifier: NSEvent.ModifierFlags) {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, modifierFlags: modifier, isArmed: true) == .ignore)
    }

    @Test func capsLockDoesNotBlockCancel() {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, modifierFlags: [.capsLock], isArmed: true) == .cancel)
    }

    @Test func otherKeysAreNeverClaimed() {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, keyCode: Self.letterA, isArmed: true) == .ignore)
        #expect(release(&detector, keyCode: Self.letterA, isArmed: true) == .ignore)
        #expect(
            detector.handle(
                .flagsChanged,
                keyCode: Self.escape,
                modifierFlags: [],
                isAutorepeat: false,
                isArmed: true
            ) == .ignore)
    }

    @Test func consecutiveSessionsEachCancel() {
        var detector = EscapeCancelDetector()

        #expect(press(&detector, isArmed: true) == .cancel)
        #expect(release(&detector, isArmed: false) == .consume)
        #expect(press(&detector, isArmed: true) == .cancel)
        #expect(release(&detector, isArmed: false) == .consume)
    }
}

/// Drives the real router with real `CGEvent`s, so the CGEvent → NSEvent bridge, the
/// keycode/flag extraction, and the ordering between Globe suppression, the Escape
/// claim, and the Fn toggle are all covered without installing an event tap or
/// holding Accessibility.
@Suite("Hotkey Event Router")
struct HotkeyEventRouterTests {
    private static let escape: CGKeyCode = 53
    private static let fn: CGKeyCode = 63
    private static let globeAssignedAction: CGKeyCode = 179

    private func key(
        _ keyCode: CGKeyCode,
        down: Bool,
        flags: CGEventFlags = [],
        autorepeat: Bool = false
    ) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
        event.flags = flags
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }

    private func modifierChange(_ keyCode: CGKeyCode, flags: CGEventFlags) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        return event
    }

    @Test func armedEscapeCancelsAndBothHalvesOfThePressAreSuppressed() throws {
        var router = HotkeyEventRouter()
        router.isCancelArmed = true

        #expect(try router.routeTapped(key(Self.escape, down: true)) == .cancel)
        router.isCancelArmed = false
        #expect(try router.routeTapped(key(Self.escape, down: false)) == .consume)
    }

    @Test func escapeReachesTheAppWhenNoSessionIsRunning() throws {
        var router = HotkeyEventRouter()

        #expect(try router.routeTapped(key(Self.escape, down: true)) == .pass)
        #expect(try router.routeTapped(key(Self.escape, down: false)) == .pass)
    }

    @Test func modifiedEscapeReachesTheAppEvenWhileArmed() throws {
        var router = HotkeyEventRouter()
        router.isCancelArmed = true

        #expect(try router.routeTapped(key(Self.escape, down: true, flags: .maskCommand)) == .pass)
    }

    @Test func heldEscapeCancelsOnceAndSwallowsTheRepeats() throws {
        var router = HotkeyEventRouter()
        router.isCancelArmed = true

        #expect(try router.routeTapped(key(Self.escape, down: true)) == .cancel)
        router.isCancelArmed = false
        #expect(try router.routeTapped(key(Self.escape, down: true, autorepeat: true)) == .consume)
        #expect(try router.routeTapped(key(Self.escape, down: false)) == .consume)
    }

    @Test func standaloneFnTapStillToggles() throws {
        var router = HotkeyEventRouter()

        #expect(try router.routeTapped(modifierChange(Self.fn, flags: .maskSecondaryFn)) == .pass)
        #expect(try router.routeTapped(modifierChange(Self.fn, flags: [])) == .toggle)
    }

    @Test func tapTeardownClearsPendingFnPressBeforeRebuild() throws {
        let binder = KeyboardShortcutsBinder()

        #expect(try binder.handleTap(modifierChange(Self.fn, flags: .maskSecondaryFn)) == false)
        binder.teardownTap()

        // A release that the rebuilt tap did not observe being pressed must not toggle.
        #expect(try binder.handleTap(modifierChange(Self.fn, flags: [])) == false)
    }

    /// The other half of a rebuild: the detectors are cleared, but Escape must still
    /// cancel a session that is on screen right now. Arming mirrors session state, which
    /// a tap coming or going does not change, so the binder restores it onto the fresh
    /// router — otherwise a rebuild silently handed Escape back to the focused app for a
    /// live dictation.
    @Test func tapRebuildKeepsEscapeArmedForASessionAlreadyOnScreen() throws {
        let binder = KeyboardShortcutsBinder()
        binder.setCancelArmed(true)

        binder.teardownTap()

        #expect(try binder.handleTap(key(Self.escape, down: true)) == true)
    }

    /// The Escape claim must not steal the arming state the Fn toggle depends on.
    @Test func standaloneFnTapStillTogglesWhileArmed() throws {
        var router = HotkeyEventRouter()
        router.isCancelArmed = true

        #expect(try router.routeTapped(modifierChange(Self.fn, flags: .maskSecondaryFn)) == .pass)
        #expect(try router.routeTapped(modifierChange(Self.fn, flags: [])) == .toggle)
    }

    @Test func globeAssignedActionKeyIsSuppressedRegardlessOfArming() throws {
        var router = HotkeyEventRouter()

        #expect(try router.routeTapped(key(Self.globeAssignedAction, down: true)) == .consume)
        #expect(try router.routeTapped(key(Self.globeAssignedAction, down: false)) == .consume)
    }

    @Test func passiveGlobeAssignedActionWhileFnHeldDoesNotDisarm() {
        var router = HotkeyEventRouter()

        #expect(
            router.route(
                .flagsChanged,
                keyCode: Self.fn,
                modifierFlags: [.function],
                isAutorepeat: false
            ) == .pass
        )
        #expect(
            router.route(
                .keyDown,
                keyCode: Self.globeAssignedAction,
                modifierFlags: [.function],
                isAutorepeat: false
            ) == .pass
        )
        #expect(
            router.route(
                .keyUp,
                keyCode: Self.globeAssignedAction,
                modifierFlags: [.function],
                isAutorepeat: false
            ) == .pass
        )

        #expect(
            router.route(
                .flagsChanged,
                keyCode: Self.fn,
                modifierFlags: [],
                isAutorepeat: false
            ) == .toggle
        )
    }

    @Test func ordinaryTypingIsNeverClaimed() throws {
        var router = HotkeyEventRouter()
        router.isCancelArmed = true

        #expect(try router.routeTapped(key(0, down: true)) == .pass)
        #expect(try router.routeTapped(key(0, down: false)) == .pass)
    }
}
