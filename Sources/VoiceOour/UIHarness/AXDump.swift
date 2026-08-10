// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: eleven production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import AppKit
    import Foundation

    // The harness's primary regression signal.
    //
    // A rendered PNG costs an agent a lot of tokens and tells it almost nothing about
    // structure; this text tree tells it everything about hierarchy, labelling and layout
    // for a few hundred bytes, diffs cleanly in review, and needs no TCC grant of any kind
    // (proven with an ad-hoc-signed bundle where `AXIsProcessTrusted() == false` produced a
    // byte-identical tree with no prompt).
    //
    // Everything here walks the accessibility hierarchy IN-PROCESS. The out-of-process
    // `AXUIElement*` API is deliberately not used: it was measured to be non-deterministic at
    // this app's root (a lazily materialised nested `AXGroup` moved the node count from 30 to
    // 31 between runs) and it additionally requires an Accessibility grant, which would make
    // the harness unrunnable on a clean machine.

    /// In-process accessibility walker: turns a hosted `NSView` into a deterministic,
    /// diffable `AXNode` tree and renders it as committed golden text.
    ///
    /// `tree(of:)` and `enableEnhancedUserInterface()` message AppKit and must run on the
    /// main actor. The three pure functions over an already-captured tree (`text`, `find`,
    /// `nodeCount`) are `nonisolated` so lint rules and other non-isolated harness
    /// code can use them without hopping actors.
    @MainActor
    enum AXDump {
        /// Switches AppKit into "enhanced user interface" mode, which is what makes SwiftUI
        /// publish its accessibility hierarchy at all.
        ///
        /// THE BLOCKER this exists for: an `NSHostingView` reports ZERO accessibility children
        /// until this is set. Measured 1 node before the call and 23 after, same hierarchy.
        /// The deprecated public `accessibilitySetOverrideValue(_:forAttribute:)` route was
        /// tried and does NOT work.
        ///
        /// The selector exists at runtime but is absent from public AppKit headers, so it is
        /// `responds(to:)`-guarded and returns `false` if it ever disappears — the caller is
        /// expected to fail loudly rather than write a one-node golden.
        ///
        /// Note that `perform(_:with:)` passes the bridged `NSNumber` *pointer* where the
        /// method expects a `BOOL`, so any non-nil argument means YES. This call can only ever
        /// enable the mode; do not "fix" it into a toggle by passing `false`.
        static func enableEnhancedUserInterface() -> Bool {
            let application = NSApplication.shared
            guard application.responds(to: AXSelectors.setEnhancedUserInterface) else { return false }
            _ = application.perform(AXSelectors.setEnhancedUserInterface, with: true)
            return true
        }

        /// Walks `view` and every accessibility descendant into a deterministic tree.
        ///
        /// Call `enableEnhancedUserInterface()` once per process first, or a SwiftUI hierarchy
        /// returns a single childless root. Frames come back window-local, top-left origin,
        /// rounded to whole points; see `AXFrameConverter`.
        static func tree(of view: NSView) -> AXNode {
            let converter = AXFrameConverter(window: view.window, root: view)
            let budget = AXWalkBudget(limit: AXWalkLimits.maxNodes)
            return node(from: view, converter: converter, depth: 0, budget: budget)
        }

        /// Renders a tree as the committed golden text: one node per line, two spaces of
        /// indent per level, stable field order, trailing newline.
        ///
        /// ```text
        /// <indent><role> [subrole=…] ["label"] [value="…"] [placeholder="…"] [id=…] [help="…"] [DISABLED] [x,y wxh]
        ///
        /// AXButton "Start dictation" id=start.button [12,40 96x28]
        /// ```
        ///
        /// Content fields (label, value, placeholder, help) are always quoted so leading and
        /// trailing whitespace stays visible; token fields (subrole, id) are quoted only when
        /// they contain a space or a quote. Absent fields are omitted entirely rather than
        /// printed as `nil`/`?`, so a diff only ever highlights a real change. The frame is
        /// always printed: `[0,0 0x0]` reads loudly as "this element reported no geometry".
        nonisolated static func text(_ node: AXNode) -> String {
            var output = ""
            appendLines(for: node, depth: 0, into: &output)
            return output
        }

        /// Depth-first lookup used to resolve an interaction step's target.
        ///
        /// Matching is tiered so a precise identifier always beats a fuzzy label: exact
        /// `identifier`, then exact `label`, then `label` substring, then exact `placeholder`,
        /// then `placeholder` substring. Placeholder comes last because it is the weakest
        /// handle — a field that gains a real label must retarget to the label, not keep
        /// answering to its prompt text — but it is what makes an empty `TextField`
        /// addressable at all, since SwiftUI publishes no label for one. Within a tier the
        /// first node in document order wins, so the result never depends on tree shape luck.
        nonisolated static func find(_ needle: String, in node: AXNode) -> AXNode? {
            guard !needle.isEmpty else { return nil }
            if let hit = firstNode(in: node, matching: { $0.identifier == needle }) { return hit }
            if let hit = firstNode(in: node, matching: { $0.label == needle }) { return hit }
            if let hit = firstNode(in: node, matching: { $0.label?.contains(needle) ?? false }) { return hit }
            if let hit = firstNode(in: node, matching: { $0.placeholder == needle }) { return hit }
            return firstNode(in: node, matching: { $0.placeholder?.contains(needle) ?? false })
        }

        /// Total nodes in the tree, including the root.
        ///
        /// A diagnostic, not a settle signal. The runtime pumps a FIXED budget of run-loop
        /// iterations, identical on every run; pumping adaptively until this number stopped
        /// changing is exactly the nondeterminism the fixed budget exists to avoid, because
        /// any `.repeatForever` animation would keep perturbing the hierarchy. Use it to
        /// report tree size and to assert a scene is not the one-node hierarchy you get when
        /// `enableEnhancedUserInterface()` failed.
        nonisolated static func nodeCount(_ node: AXNode) -> Int {
            node.children.reduce(1) { total, child in total + nodeCount(child) }
        }
    }

    // MARK: - Walk

    extension AXDump {
        fileprivate static func node(
            from element: AnyObject,
            converter: AXFrameConverter,
            depth: Int,
            budget: AXWalkBudget
        ) -> AXNode {
            guard let reader = AXElementReader(element) else { return unknownNode() }
            let role = reader.role() ?? AXWalkLimits.unknownRole
            return AXNode(
                role: role,
                subrole: reader.subrole(),
                label: reader.label(),
                value: reader.value(),
                placeholder: reader.placeholder(),
                identifier: reader.identifier(),
                help: reader.help(),
                enabled: reader.enabled(role: role),
                frame: converter.windowLocal(reader.screenFrame()),
                children: childNodes(of: reader, converter: converter, depth: depth, budget: budget)
            )
        }

        fileprivate static func childNodes(
            of reader: AXElementReader,
            converter: AXFrameConverter,
            depth: Int,
            budget: AXWalkBudget
        ) -> [AXNode] {
            let rawChildren = reader.children()
            guard !rawChildren.isEmpty else { return [] }
            guard depth < AXWalkLimits.maxDepth else {
                return truncationMarker("depth cap \(AXWalkLimits.maxDepth)", budget: budget)
            }
            var nodes: [AXNode] = []
            nodes.reserveCapacity(rawChildren.count)
            for child in rawChildren {
                guard budget.consume() else {
                    nodes.append(contentsOf: truncationMarker("node cap \(AXWalkLimits.maxNodes)", budget: budget))
                    break
                }
                nodes.append(node(from: child, converter: converter, depth: depth + 1, budget: budget))
            }
            return nodes
        }

        /// A pathological hierarchy must never hang the harness, and it must never silently
        /// shrink a golden either — the first cap we hit leaves one visible marker node.
        fileprivate static func truncationMarker(_ reason: String, budget: AXWalkBudget) -> [AXNode] {
            guard budget.claimTruncationReport() else { return [] }
            return [
                AXNode(
                    role: "AXHarnessTruncated",
                    subrole: nil,
                    label: "accessibility walk stopped: \(reason)",
                    value: nil,
                    placeholder: nil,
                    identifier: nil,
                    help: nil,
                    enabled: nil,
                    frame: .zero,
                    children: []
                )
            ]
        }

        /// Emitted for a child that is not an Objective-C object at all, which should be
        /// impossible; a stable placeholder beats trapping mid-walk.
        fileprivate static func unknownNode() -> AXNode {
            AXNode(
                role: AXWalkLimits.unknownRole,
                subrole: nil,
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: nil,
                help: nil,
                enabled: nil,
                frame: .zero,
                children: []
            )
        }
    }

    // MARK: - Text rendering

    extension AXDump {
        fileprivate nonisolated static func appendLines(for node: AXNode, depth: Int, into output: inout String) {
            output += String(repeating: "  ", count: depth)
            output += line(for: node)
            output += "\n"
            for child in node.children {
                appendLines(for: child, depth: depth + 1, into: &output)
            }
        }

        /// `role [subrole=…] ["label"] [value="…"] [placeholder="…"] [id=…] [help="…"] [DISABLED] [x,y wxh]`
        ///
        /// The label is the bare quoted token because it is what a human scans for; every
        /// other text field is keyed so the line stays unambiguous. Only `DISABLED` is printed
        /// for enablement — an enabled control and a container that never models enablement
        /// both print nothing, which keeps the golden quiet and makes a control going disabled
        /// show up as a single added word.
        fileprivate nonisolated static func line(for node: AXNode) -> String {
            var parts = [node.role]
            if let subrole = axNonEmpty(node.subrole) { parts.append(axKeyed("subrole", subrole)) }
            if let label = axNonEmpty(node.label) { parts.append(axQuoted(label)) }
            if let value = axNonEmpty(node.value) { parts.append("value=" + axQuoted(value)) }
            if let placeholder = axNonEmpty(node.placeholder) {
                parts.append("placeholder=" + axQuoted(placeholder))
            }
            if let identifier = axNonEmpty(node.identifier) { parts.append(axKeyed("id", identifier)) }
            if let help = axNonEmpty(node.help) { parts.append("help=" + axQuoted(help)) }
            if node.enabled == false { parts.append("DISABLED") }
            parts.append(axFrameToken(node.frame))
            return parts.joined(separator: " ")
        }

        fileprivate nonisolated static func firstNode(in node: AXNode, matching predicate: (AXNode) -> Bool) -> AXNode?
        {
            if predicate(node) { return node }
            for child in node.children {
                if let hit = firstNode(in: child, matching: predicate) { return hit }
            }
            return nil
        }
    }

    // MARK: - Objective-C bridges

    /// The modern (10.10+) accessibility accessors, redeclared locally.
    ///
    /// SwiftUI's elements are `SwiftUI.AccessibilityNode`: `NSObject`s that implement the
    /// informal accessibility protocol without declaring Swift conformance, so
    /// `element as? NSAccessibilityProtocol` returns nil for EVERY one of them and the public
    /// API is simply unreachable. Bridging an `AnyObject` through a local `@objc protocol`
    /// plus `unsafeBitCast` gives plain `objc_msgSend` dispatch with the correct return-type
    /// ABI, which matters twice over: `accessibilityFrame` returns a struct, and
    /// `isAccessibilityEnabled` returns a `BOOL` that `perform(_:)` + `takeUnretainedValue()`
    /// would dereference as a pointer and segfault on (verified exit 139).
    ///
    /// Every one of these is messaged only behind an individual `responds(to:)` check:
    /// `AccessibilityNode` answers `accessibilityRole` but NOT `accessibilityTitle`, and an
    /// unguarded call raises `NSInvalidArgumentException`.
    @objc private protocol AXModernElement {
        func accessibilityRole() -> String?
        func accessibilitySubrole() -> String?
        func accessibilityLabel() -> String?
        func accessibilityTitle() -> String?
        func accessibilityValue() -> Any?
        func accessibilityPlaceholderValue() -> String?
        func accessibilityIdentifier() -> String?
        func accessibilityHelp() -> String?
        func isAccessibilityEnabled() -> Bool
        func accessibilityFrame() -> NSRect
        func accessibilityChildren() -> [Any]?
    }

    /// The pre-10.10 attribute API, still the only one some AppKit elements answer.
    ///
    /// SwiftUI `List` content is the concrete case: `NSOutlineRow`, `NSTableViewCellMockElement`
    /// and `NSTableColumn` implement none of the modern accessors and only respond to
    /// `accessibilityAttributeValue:` keyed by `AXRole` / `AXChildren` / `AXPosition` / `AXSize`.
    /// Without this fallback the entire list — the part of the UI most likely to regress —
    /// dumps as bare `AXUnknown` lines.
    @objc private protocol AXLegacyElement {
        func accessibilityAttributeValue(_ attribute: String) -> Any?
    }

    /// Reads one accessibility element, preferring the modern accessors and falling back to
    /// the legacy attribute API per field, so a hierarchy that mixes both (a SwiftUI hosting
    /// view containing an AppKit-backed `List`) walks through a single code path.
    @MainActor
    private struct AXElementReader {
        private let element: AnyObject
        private let responder: NSObjectProtocol

        init?(_ element: AnyObject) {
            guard let responder = element as? NSObjectProtocol else { return nil }
            self.element = element
            self.responder = responder
        }

        private var modern: AXModernElement { unsafeBitCast(element, to: AXModernElement.self) }
        private var legacy: AXLegacyElement { unsafeBitCast(element, to: AXLegacyElement.self) }

        private func answers(_ selector: Selector) -> Bool { responder.responds(to: selector) }

        private func legacyAttribute(_ key: String) -> Any? {
            guard answers(AXSelectors.legacyAttributeValue) else { return nil }
            return legacy.accessibilityAttributeValue(key)
        }

        private func legacyText(_ key: String) -> String? {
            axNonEmpty(legacyAttribute(key) as? String)
        }

        func role() -> String? {
            if answers(AXSelectors.role), let role = axNonEmpty(modern.accessibilityRole()) { return role }
            return legacyText(AXLegacyKey.role)
        }

        func subrole() -> String? {
            if answers(AXSelectors.subrole), let subrole = axNonEmpty(modern.accessibilitySubrole()) { return subrole }
            return legacyText(AXLegacyKey.subrole)
        }

        /// SwiftUI publishes its text through `accessibilityLabel`; AppKit-backed controls
        /// publish theirs through `accessibilityTitle` (or legacy `AXDescription`/`AXTitle`).
        /// One field in the golden, four possible sources.
        func label() -> String? {
            if answers(AXSelectors.label), let label = axNonEmpty(modern.accessibilityLabel()) { return label }
            if answers(AXSelectors.title), let title = axNonEmpty(modern.accessibilityTitle()) { return title }
            if let described = legacyText(AXLegacyKey.descriptionAttribute) { return described }
            return legacyText(AXLegacyKey.title)
        }

        func value() -> String? {
            if answers(AXSelectors.value), let value = AXValueFormatter.string(from: modern.accessibilityValue()) {
                return value
            }
            return AXValueFormatter.string(from: legacyAttribute(AXLegacyKey.value))
        }

        /// The prompt text an empty text field displays.
        ///
        /// Measured on this SDK: a SwiftUI `TextField("…", text:)` materialises a
        /// `SystemTextFieldCell` that publishes NO label and NO title — the placeholder is the
        /// only text on the element, and without it an empty field dumps as a bare
        /// `AXTextField [x,y wxh]` that `find` cannot address. It answers both the modern
        /// `accessibilityPlaceholderValue` selector and legacy `AXPlaceholderValue` with the
        /// same string, so both paths are wired for the same reason every sibling accessor is:
        /// AppKit-backed elements inside a `List` implement only the legacy one.
        ///
        /// It stays readable once the field has text (verified: value `already typed`,
        /// placeholder `Prefilled field`), which is deliberate — the golden should keep
        /// recording what the field asks for even after an interaction step fills it.
        func placeholder() -> String? {
            if answers(AXSelectors.placeholder),
                let placeholder = axNonEmpty(modern.accessibilityPlaceholderValue())
            {
                return placeholder
            }
            return legacyText(AXLegacyKey.placeholder)
        }

        func identifier() -> String? {
            if answers(AXSelectors.identifier), let identifier = axNonEmpty(modern.accessibilityIdentifier()) {
                return identifier
            }
            return legacyText(AXLegacyKey.identifier)
        }

        func help() -> String? {
            if answers(AXSelectors.help), let help = axNonEmpty(modern.accessibilityHelp()) { return help }
            return legacyText(AXLegacyKey.help)
        }

        /// Enablement is only read for roles that actually model it. Containers (`AXGroup`,
        /// `AXHostingView`, `AXScrollArea`) answer `isAccessibilityEnabled` with `false`
        /// despite having no notion of being disabled, which would stamp a bogus `DISABLED`
        /// on nearly every line of every golden.
        func enabled(role: String) -> Bool? {
            guard AXControlRoles.modelsEnablement(role) else { return nil }
            if answers(AXSelectors.enabled) { return modern.isAccessibilityEnabled() }
            if let flag = legacyAttribute(AXLegacyKey.enabled) as? NSNumber { return flag.boolValue }
            return nil
        }

        /// Screen coordinates, bottom-left origin. `AXFrameConverter` makes them window-local.
        func screenFrame() -> CGRect? {
            if answers(AXSelectors.frame) { return modern.accessibilityFrame() }
            guard let position = legacyAttribute(AXLegacyKey.position) as? NSValue,
                let size = legacyAttribute(AXLegacyKey.size) as? NSValue
            else { return nil }
            return CGRect(origin: position.pointValue, size: size.sizeValue)
        }

        /// Document order is preserved exactly as AppKit reports it; the probe measured
        /// byte-identical trees across runs, so no sorting is needed and any sort would only
        /// hide a real reordering regression.
        func children() -> [AnyObject] {
            if answers(AXSelectors.children), let children = modern.accessibilityChildren(), !children.isEmpty {
                return children.map { $0 as AnyObject }
            }
            guard let legacyChildren = legacyAttribute(AXLegacyKey.children) as? [Any] else { return [] }
            return legacyChildren.map { $0 as AnyObject }
        }
    }

    // MARK: - Geometry

    /// Converts screen rects (bottom-left origin) into window-local rects with a top-left
    /// origin, rounded to whole points.
    ///
    /// Both halves matter for a golden: raw screen coordinates would bake in the offscreen
    /// window's origin (currently -30000,-30000), and unrounded values let sub-pixel layout
    /// jitter churn a committed file for no reason.
    private struct AXFrameConverter {
        /// Screen-space rect that window-local (0,0) sits at the top-left of.
        private let reference: CGRect?

        @MainActor
        init(window: NSWindow?, root: NSView) {
            if let window {
                reference = window.contentRect(forFrameRect: window.frame)
            } else {
                // No window (a bare hosting view in a unit test): fall back to root-relative
                // coordinates so the dump is still usable instead of collapsing to zeroes.
                reference = AXElementReader(root)?.screenFrame()
            }
        }

        func windowLocal(_ screenRect: CGRect?) -> CGRect {
            guard let screenRect, let reference else { return .zero }
            return CGRect(
                x: axRoundedInt(screenRect.minX - reference.minX),
                y: axRoundedInt(reference.maxY - screenRect.maxY),
                width: axRoundedInt(screenRect.width),
                height: axRoundedInt(screenRect.height)
            )
        }
    }

    // MARK: - Walk limits

    private final class AXWalkBudget {
        private var remaining: Int
        private var reportedTruncation = false

        init(limit: Int) {
            remaining = limit
        }

        func consume() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }

        /// True exactly once per walk, so a truncated tree carries a single marker instead of
        /// one per unwound recursion level.
        func claimTruncationReport() -> Bool {
            guard !reportedTruncation else { return false }
            reportedTruncation = true
            return true
        }
    }

    private enum AXWalkLimits {
        /// Deep enough for any real SwiftUI hierarchy (the console measures well under 20),
        /// shallow enough that a cyclic parent/child pair cannot spin forever.
        static let maxDepth = 64
        /// Two orders of magnitude above the largest real scene.
        static let maxNodes = 5000
        static let unknownRole = "AXUnknown"
    }

    /// Roles whose elements genuinely model enablement. Everything else reports `nil`.
    private enum AXControlRoles {
        private static let enablementAware: Set<String> = [
            "AXButton",
            "AXCheckBox",
            "AXColorWell",
            "AXComboBox",
            "AXDisclosureTriangle",
            "AXIncrementor",
            "AXLink",
            "AXMenuBarItem",
            "AXMenuButton",
            "AXMenuItem",
            "AXPopUpButton",
            "AXRadioButton",
            "AXSlider",
            "AXTextArea",
            "AXTextField",
        ]

        static func modelsEnablement(_ role: String) -> Bool {
            enablementAware.contains(role)
        }
    }

    private enum AXSelectors {
        static let setEnhancedUserInterface = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        static let role = NSSelectorFromString("accessibilityRole")
        static let subrole = NSSelectorFromString("accessibilitySubrole")
        static let label = NSSelectorFromString("accessibilityLabel")
        static let title = NSSelectorFromString("accessibilityTitle")
        static let value = NSSelectorFromString("accessibilityValue")
        static let placeholder = NSSelectorFromString("accessibilityPlaceholderValue")
        static let identifier = NSSelectorFromString("accessibilityIdentifier")
        static let help = NSSelectorFromString("accessibilityHelp")
        static let enabled = NSSelectorFromString("isAccessibilityEnabled")
        static let frame = NSSelectorFromString("accessibilityFrame")
        static let children = NSSelectorFromString("accessibilityChildren")
        static let legacyAttributeValue = NSSelectorFromString("accessibilityAttributeValue:")
    }

    private enum AXLegacyKey {
        static let role = "AXRole"
        static let subrole = "AXSubrole"
        static let children = "AXChildren"
        static let position = "AXPosition"
        static let size = "AXSize"
        static let title = "AXTitle"
        static let value = "AXValue"
        static let placeholder = "AXPlaceholderValue"
        /// What the modern API calls the label.
        static let descriptionAttribute = "AXDescription"
        static let identifier = "AXIdentifier"
        static let help = "AXHelp"
        static let enabled = "AXEnabled"
    }

    // MARK: - Field formatting

    /// Turns an accessibility value of any type into a stable string.
    ///
    /// The point of the default branch is that it never prints an address or a `description`
    /// we do not control: an unexpected type shows up as its class name, which is loud in a
    /// diff and identical on every run.
    private enum AXValueFormatter {
        static func string(from raw: Any?) -> String? {
            guard let raw else { return nil }
            if let text = raw as? String { return axNonEmpty(text) }
            if let attributed = raw as? NSAttributedString { return axNonEmpty(attributed.string) }
            if let number = raw as? NSNumber { return describe(number) }
            if let list = raw as? [Any] { return "<array:\(list.count)>" }
            return "<\(type(of: raw))>"
        }

        private static func describe(_ number: NSNumber) -> String {
            // Toggles arrive as boolean NSNumbers; printing them as true/false rather than 1/0
            // keeps the golden readable and distinguishes them from numeric values.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
    }

    /// Longest field text kept verbatim. Beyond this the overflow count is printed instead of
    /// the tail, so a long transcript cannot bloat a golden while a length change is still
    /// caught by the diff.
    private let axMaxFieldCharacters = 160

    /// Nil for absent and for whitespace-only text, otherwise the string unchanged.
    ///
    /// Deliberately does not trim: leading/trailing space inside a real label is content, and
    /// silently normalising it would hide the regression that introduced it.
    private func axNonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private func axQuoted(_ text: String) -> String {
        "\"" + axEscaped(text) + "\""
    }

    /// Quotes only when the token would otherwise be ambiguous, so the common
    /// `id=console.tab.home` stays easy to read and to grep.
    private func axKeyed(_ key: String, _ text: String) -> String {
        let escaped = axEscaped(text)
        let needsQuotes = escaped.isEmpty || escaped.contains(" ") || escaped.contains("\"")
        return needsQuotes ? "\(key)=\"\(escaped)\"" : "\(key)=\(escaped)"
    }

    private func axEscaped(_ text: String) -> String {
        let total = text.count
        var output = ""
        output.reserveCapacity(total)
        for character in text.prefix(axMaxFieldCharacters) {
            output += axEscapedFragment(for: character)
        }
        if total > axMaxFieldCharacters { output += "…+\(total - axMaxFieldCharacters)" }
        return output
    }

    /// One node per line means nothing in a field may be a newline, and quoting means nothing
    /// may be a bare quote. Control characters become `\xNN` so a stray one is visible in
    /// review instead of corrupting the golden.
    private func axEscapedFragment(for character: Character) -> String {
        switch character {
        case "\\": return "\\\\"
        case "\"": return "\\\""
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default: break
        }
        guard let scalar = character.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7F else {
            return String(character)
        }
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return hex.count < 2 ? "\\x0" + hex : "\\x" + hex
    }

    private func axFrameToken(_ frame: CGRect) -> String {
        let left = axRoundedInt(frame.origin.x)
        let top = axRoundedInt(frame.origin.y)
        let width = axRoundedInt(frame.size.width)
        let height = axRoundedInt(frame.size.height)
        return "[\(left),\(top) \(width)x\(height)]"
    }

    /// Whole points, and never a trap: `Int(_:)` on a NaN or an out-of-range float crashes,
    /// and accessibility frames are not a source we control.
    private func axRoundedInt(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1_000_000), 1_000_000).rounded())
    }

#endif
