// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import AppKit
    import Foundation

    /// Bridge for the accessibility press action.
    ///
    /// SHOWSTOPPER: `accessibilityPerformPress` returns a BOOL. Reaching it through
    /// `object.perform(selector)?.takeUnretainedValue()` dereferences that BOOL as an object
    /// pointer and segfaults (verified: exit 139). An `@objc protocol` plus `unsafeBitCast`
    /// is the only safe call path — do not "simplify" this back to `perform(_:)`.
    @objc private protocol AXPressable {
        func accessibilityPerformPress() -> Bool
    }

    /// Bridge for the live accessibility accessors used to re-resolve a step target.
    ///
    /// SwiftUI's nodes are `SwiftUI.AccessibilityNode`: NSObjects that implement the informal
    /// protocol but never declare Swift conformance, so `as? NSAccessibilityProtocol` returns
    /// nil for every one of them and the accessors have to be sent as raw selectors. The
    /// Swift names are deliberately different from AppKit's so these declarations can never
    /// collide with AppKit's own nullability-annotated versions of the same methods.
    @objc private protocol AXLiveAccessors {
        @objc(accessibilityChildren) func liveChildren() -> [Any]?
        @objc(accessibilityIdentifier) func liveIdentifier() -> String?
        @objc(accessibilityLabel) func liveLabel() -> String?
        @objc(accessibilityTitle) func liveTitle() -> String?
    }

    /// Applies a scene's interaction script to an offscreen, never-key window.
    ///
    /// Every step is best-effort and bounded: a step that cannot find its target returns a
    /// human-readable warning and the script continues. There is no waiting on a condition
    /// anywhere in this file — only fixed pump budgets — because a harness that can hang is
    /// worse than a harness that reports a miss.
    ///
    /// Known limitation, measured: `NSTableView`/SwiftUI `List` row selection by synthetic
    /// click requires the app to be ACTIVE, so it cannot work here. Drive list selection
    /// through the model instead.
    @MainActor
    enum UIInteraction {
        /// Fixed post-action settle. Every interaction pays the same bounded budget so a
        /// scene with steps stays exactly as reproducible as one without.
        private static let actionSettleIterations = 30

        /// Traversal budgets. Nothing in a real hierarchy comes close; they exist so a
        /// pathological or cyclic tree degrades into a warning instead of a hang.
        private static let maximumViewDepth = 64
        private static let maximumLiveDepth = 64
        private static let maximumLiveNodes = 4096

        /// Floor for accepting an AppKit view as the control behind an accessibility node.
        private static let minimumFrameTolerance: CGFloat = 24

        /// `NSTextInputClient`'s sentinel for "replace the current selection".
        private static let replaceCurrentSelection = NSRange(location: NSNotFound, length: 0)

        private static let pressSelector = NSSelectorFromString("accessibilityPerformPress")
        private static let childrenSelector = NSSelectorFromString("accessibilityChildren")
        private static let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
        private static let labelSelector = NSSelectorFromString("accessibilityLabel")
        private static let titleSelector = NSSelectorFromString("accessibilityTitle")
        private static let labelSelectors = [labelSelector, titleSelector]

        /// Runs `steps` in order and returns one warning per step that could not be applied.
        /// An empty result means the whole script ran.
        static func apply(_ steps: [UIStep], in view: NSView, window: NSWindow) -> [String] {
            guard !steps.isEmpty else { return [] }
            var warnings: [String] = []
            warnings.reserveCapacity(steps.count)
            for step in steps {
                guard let warning = perform(step, in: view, window: window) else { continue }
                warnings.append(warning)
            }
            return warnings
        }

        private static func perform(_ step: UIStep, in view: NSView, window: NSWindow) -> String? {
            switch step {
            case .settle(let milliseconds):
                return settle(milliseconds: milliseconds)
            case .press(let target):
                return press(target, in: view)
            case .click(let target):
                return click(target, in: view, window: window)
            case .type(let text, let target):
                return typeText(text, into: target, in: view, window: window)
            }
        }

        // MARK: - Steps

        private static func settle(milliseconds: Int) -> String? {
            guard milliseconds > 0 else { return nil }
            UIHarnessRuntime.pump(iterations: UIHarnessRuntime.pumpIterations(forMilliseconds: milliseconds))
            return nil
        }

        /// The default activation path: an accessibility press, which is what a real
        /// assistive client sends and what SwiftUI actually implements.
        ///
        /// AX actions are serviced inline by AppKit on the calling thread, and a background
        /// call crashed with EXC_BREAKPOINT — `@MainActor` on this enum is what keeps that
        /// from being possible.
        private static func press(_ target: String, in view: NSView) -> String? {
            guard let node = locate(target, in: view) else { return missingTarget("press", target) }
            guard let element = liveElement(matching: target, in: view) else {
                return
                    "press(\"\(target)\"): matched accessibility node \(node.role) but its live element could not be re-resolved; nothing pressed."
            }
            guard element.responds(to: pressSelector) else {
                return
                    "press(\"\(target)\"): \(node.role) does not implement accessibilityPerformPress; nothing pressed."
            }
            // SHOWSTOPPER: see AXPressable — perform(_:)?.takeUnretainedValue() segfaults on
            // the returned BOOL.
            let pressable = unsafeBitCast(element, to: AXPressable.self)
            guard pressable.accessibilityPerformPress() else {
                return "press(\"\(target)\"): accessibilityPerformPress returned false."
            }
            UIHarnessRuntime.pump(iterations: actionSettleIterations)
            return nil
        }

        /// The escape hatch for controls with no press action: a synthetic mouse click.
        ///
        /// `NSButton.performClick(nil)` is NOT a shortcut here — it was measured not to drive
        /// a SwiftUI `Toggle` at all (target/action are nil, so the NSButton's own state flips
        /// while the binding never changes). Only a synthetic mouse or an AX press works.
        private static func click(_ target: String, in view: NSView, window: NSWindow) -> String? {
            guard let node = locate(target, in: view) else { return missingTarget("click", target) }
            guard node.frame.width > 0, node.frame.height > 0 else {
                return "click(\"\(target)\"): \(node.role) has an empty frame \(node.frame); no synthetic mouse sent."
            }
            // SHOWSTOPPER: the tracking loop below matches the queued mouseUp by window, so a
            // window with no window device would never see it and `sendEvent` would hang with
            // no way to interrupt it from this thread. `defer: false` at construction is what
            // guarantees the device exists; this turns any regression into a warning.
            guard window.windowNumber > 0 else {
                return
                    "click(\"\(target)\"): window has no window device (number \(window.windowNumber)); refusing to send a synthetic mouse that could wedge the tracking loop."
            }
            // SHOWSTOPPER: NSHostingView is flipped (isFlipped == true) but NSEvent locations
            // live in the window's UNFLIPPED base space. Converting through the view is the
            // only correct mapping; a raw hosting-space point lands mirrored about the middle
            // of the window and clicks whatever happens to be there.
            let centre = NSPoint(x: node.frame.midX, y: node.frame.midY)
            let locationInWindow = view.convert(centre, to: nil)
            guard let downEvent = mouseEvent(.leftMouseDown, at: locationInWindow, in: window),
                let upEvent = mouseEvent(.leftMouseUp, at: locationInWindow, in: window)
            else {
                return
                    "click(\"\(target)\"): NSEvent.mouseEvent refused to build a synthetic event at \(locationInWindow)."
            }
            // SHOWSTOPPER: -mouseDown: on an AppKit-backed control runs its own
            // nextEventMatchingMask tracking loop and HANGS FOREVER unless the matching
            // mouseUp is ALREADY enqueued (a probe wedged for 150 s). Post the up first, then
            // send the down. Never reorder these two lines.
            NSApp.postEvent(upEvent, atStart: false)
            window.sendEvent(downEvent)
            UIHarnessRuntime.pump(iterations: actionSettleIterations)
            return nil
        }

        /// Types into the AppKit control behind an accessibility node.
        ///
        /// SHOWSTOPPER: command-key equivalents provably never fire here —
        /// `-performKeyEquivalent:` is only consulted for the KEY window, and an offscreen
        /// window in a non-active app never becomes key. Select-all/delete/insert therefore
        /// go straight to the field editor rather than through Cmd-A / Cmd-X.
        private static func typeText(_ text: String, into target: String, in view: NSView, window: NSWindow) -> String?
        {
            guard let node = locate(target, in: view) else { return missingTarget("type", target) }
            guard let field = textResponder(near: node.frame, in: view) else {
                return
                    "type(\"\(target)\"): no NSTextField or NSTextView sits behind \(node.role) at \(node.frame); SwiftUI leaves no AppKit view for some controls."
            }
            guard window.makeFirstResponder(field) else {
                return "type(\"\(target)\"): \(type(of: field)) refused to become first responder."
            }
            UIHarnessRuntime.pump(iterations: actionSettleIterations)
            guard let editor = fieldEditor(for: field, in: window) else {
                return "type(\"\(target)\"): no field editor was installed for the focused control."
            }
            editor.selectAll(nil)
            editor.delete(nil)
            editor.insertText(text, replacementRange: replaceCurrentSelection)
            UIHarnessRuntime.pump(iterations: actionSettleIterations)
            return nil
        }

        // MARK: - Target resolution

        /// Resolves a step target against a freshly walked accessibility tree, so each step
        /// sees the hierarchy as it is *after* the previous step, not as it was at hosting.
        private static func locate(_ target: String, in view: NSView) -> AXNode? {
            AXDump.find(target, in: AXDump.tree(of: view))
        }

        private static func missingTarget(_ step: String, _ target: String) -> String {
            "\(step)(\"\(target)\"): no accessibility node matched; step skipped."
        }

        private static func mouseEvent(
            _ eventType: NSEvent.EventType,
            at location: NSPoint,
            in window: NSWindow
        ) -> NSEvent? {
            NSEvent.mouseEvent(
                with: eventType,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: eventType == .leftMouseDown ? 1.0 : 0.0
            )
        }

        // MARK: - Field editor

        /// Picks the closest text control to the node's centre. Frame matching rather than
        /// name matching is deliberate: SwiftUI's `AppKitTextField` inherits its accessibility
        /// identity from the SwiftUI layer above it, so the AppKit view often has no usable
        /// label of its own.
        private static func textResponder(near frame: CGRect, in root: NSView) -> NSView? {
            var candidates: [NSView] = []
            collectTextViews(in: root, into: &candidates, depth: 0)
            let target = CGPoint(x: frame.midX, y: frame.midY)
            let tolerance = max(minimumFrameTolerance, max(frame.width, frame.height))
            var best: NSView?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for candidate in candidates {
                let converted = candidate.convert(candidate.bounds, to: root)
                let distance = hypot(converted.midX - target.x, converted.midY - target.y)
                guard distance < bestDistance else { continue }
                bestDistance = distance
                best = candidate
            }
            guard bestDistance <= tolerance else { return nil }
            return best
        }

        private static func collectTextViews(in view: NSView, into found: inout [NSView], depth: Int) {
            guard depth < maximumViewDepth else { return }
            if view is NSTextView || view is NSTextField { found.append(view) }
            for subview in view.subviews {
                collectTextViews(in: subview, into: &found, depth: depth + 1)
            }
        }

        private static func fieldEditor(for field: NSView, in window: NSWindow) -> NSTextView? {
            if let textView = field as? NSTextView { return textView }
            if let editor = window.fieldEditor(false, for: field) as? NSTextView { return editor }
            return window.firstResponder as? NSTextView
        }

        // MARK: - Live accessibility search

        private struct LiveSearch {
            let needle: String
            let loweredNeedle: String
            var visited = 0
            var identifierHit: NSObject?
            var labelHit: NSObject?
            var looseHit: NSObject?
        }

        /// Re-resolves a target to the live accessibility object behind it.
        ///
        /// `AXDump` returns value types that cannot receive AX actions, so live re-resolution
        /// walks the object hierarchy independently. It checks the exact modern identifier,
        /// then an exact modern label or title, then a case-insensitive label or title
        /// substring, taking the first node in document order within each tier. It does not
        /// consult placeholder or legacy accessibility attributes. If no live element resolves,
        /// `press` returns a warning and performs no press.
        private static func liveElement(matching target: String, in view: NSView) -> NSObject? {
            var search = LiveSearch(needle: target, loweredNeedle: target.lowercased())
            walkLive(view, into: &search, depth: 0)
            return search.identifierHit ?? search.labelHit ?? search.looseHit
        }

        private static func walkLive(_ element: NSObject, into search: inout LiveSearch, depth: Int) {
            guard canContinue(search, depth: depth) else { return }
            search.visited += 1
            classify(element, into: &search)
            for child in liveChildren(of: element) {
                walkLive(child, into: &search, depth: depth + 1)
            }
        }

        /// An identifier hit is the top tier, so nothing can beat it and the walk stops. The
        /// node and depth budgets bound every other outcome.
        private static func canContinue(_ search: LiveSearch, depth: Int) -> Bool {
            search.identifierHit == nil && search.visited < maximumLiveNodes && depth < maximumLiveDepth
        }

        private static func classify(_ element: NSObject, into search: inout LiveSearch) {
            if liveString(element, selector: identifierSelector) == search.needle {
                search.identifierHit = element
                return
            }
            for label in liveLabels(of: element) {
                recordLabelMatch(element, label: label, into: &search)
            }
        }

        private static func recordLabelMatch(_ element: NSObject, label: String, into search: inout LiveSearch) {
            if search.labelHit == nil, label == search.needle {
                search.labelHit = element
            }
            if search.looseHit == nil, label.lowercased().contains(search.loweredNeedle) {
                search.looseHit = element
            }
        }

        /// `accessibilityTitle` is consulted alongside `accessibilityLabel` because AppKit
        /// controls answer one or the other, never reliably both.
        private static func liveLabels(of element: NSObject) -> [String] {
            var values: [String] = []
            values.reserveCapacity(labelSelectors.count)
            for selector in labelSelectors {
                guard let value = liveString(element, selector: selector), !value.isEmpty else { continue }
                values.append(value)
            }
            return values
        }

        /// SHOWSTOPPER: every accessor is individually `responds(to:)`-guarded. An
        /// `AccessibilityNode` answers `accessibilityRole` but NOT `accessibilityTitle`, and
        /// an unguarded send raises NSInvalidArgumentException "unrecognized selector".
        private static func liveString(_ element: NSObject, selector: Selector) -> String? {
            guard element.responds(to: selector) else { return nil }
            let bridged = unsafeBitCast(element, to: AXLiveAccessors.self)
            if selector == identifierSelector { return bridged.liveIdentifier() }
            if selector == labelSelector { return bridged.liveLabel() }
            return bridged.liveTitle()
        }

        private static func liveChildren(of element: NSObject) -> [NSObject] {
            guard element.responds(to: childrenSelector) else { return [] }
            let bridged = unsafeBitCast(element, to: AXLiveAccessors.self)
            guard let children = bridged.liveChildren() else { return [] }
            return children.compactMap { $0 as? NSObject }
        }
    }

#endif
