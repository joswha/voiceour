import AppKit
import SwiftUI

/// Read-only, mouse-selectable transcript text that reports completed selection
/// changes and prepends a "Fix / Teach" item to the native context menu.
/// SwiftUI's `Text.textSelection` exposes neither the selected substring nor
/// an extensible selection menu on
/// the macOS 14 deployment target, so this wraps `NSTextView` directly.
///
/// The text and selection colours come from the caller, which reads them from the
/// console theme: the transcript sits in a themed well, and a system colour such as
/// `labelColor` follows the Mac's appearance rather than the one the console chose.
struct SelectableTranscriptText: NSViewRepresentable {
    /// Identifies the transcript the text belongs to, not just its characters.
    /// SwiftUI reuses the backing `NSTextView` across sessions, and two sessions
    /// can hold byte-identical text; without this, switching between them leaves
    /// the previous session's `selectedRange` live, so a right-click ignores the
    /// click point and teaches the stale range.
    var identity: UUID
    var text: String
    var onFixTeach: (String) -> Void
    var onSelectionChange: ((String?) -> Void)?
    /// A single click that selected nothing — the whole transcript is what the
    /// reader asked for, so History copies it. A drag, a double-click and a
    /// right-click all leave a selection behind and never reach this.
    var onPlainClick: (() -> Void)?
    /// The point size the transcript is set at. A page that gives the transcript
    /// its own reading measure sets it larger than the system's body size.
    var fontSize: CGFloat
    /// The words' colour, the theme's primary text on the well it sits in.
    var textColor: NSColor
    /// The selection wash. Never `selectedTextBackgroundColor`: that one follows the
    /// user's System Settings accent, which no environment key overrides, so a
    /// committed golden containing it would not port between machines. The theme's
    /// selection is opaque and keeps the words legible at full strength on it.
    var selectionColor: NSColor

    init(
        identity: UUID,
        text: String,
        fontSize: CGFloat = NSFont.systemFontSize,
        textColor: NSColor,
        selectionColor: NSColor,
        onFixTeach: @escaping (String) -> Void,
        onSelectionChange: ((String?) -> Void)? = nil,
        onPlainClick: (() -> Void)? = nil
    ) {
        self.identity = identity
        self.text = text
        self.fontSize = fontSize
        self.textColor = textColor
        self.selectionColor = selectionColor
        self.onFixTeach = onFixTeach
        self.onSelectionChange = onSelectionChange
        self.onPlainClick = onPlainClick
    }

    private var attributed: NSAttributedString {
        Self.attributedText(text, fontSize: fontSize, color: textColor)
    }

    /// The one place the transcript's attributes are decided, so the text the live view
    /// draws and the text `Measurer` sizes cannot be set differently. The colour does not
    /// change a line break, so the measurer typesets without one.
    fileprivate static func attributedText(
        _ text: String,
        fontSize: CGFloat,
        color: NSColor? = nil
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = VoiceourMetrics.Space.hair
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .paragraphStyle: paragraph,
        ]
        if let color {
            attributes[.foregroundColor] = color
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// The container geometry the live view and `Measurer` share: no padding at the line
    /// ends and room for every line, so a width wraps the same way in both.
    fileprivate static func prepare(_ container: NSTextContainer) {
        container.lineFragmentPadding = .zero
        container.size = NSSize(width: container.size.width, height: .greatestFiniteMagnitude)
    }

    func makeCoordinator() -> Measurer {
        Measurer()
    }

    func makeNSView(context: Context) -> FixTeachTextView {
        // TextKit 1 from the start, because `Measurer` typesets on TextKit 1 and the two
        // must break lines identically. Reading `layoutManager` later, as the right-click
        // word lookup does, would otherwise swap the view to TextKit 1 after it was sized.
        let view = FixTeachTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        if let container = view.textContainer {
            Self.prepare(container)
            container.widthTracksTextView = true
        }
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        applySelectionStyle(to: view)
        view.onFixTeach = onFixTeach
        view.onSelectionChange = onSelectionChange
        view.onPlainClick = onPlainClick
        view.install(
            identity: identity,
            attributedText: attributed,
            selectionSurface: RenderOverrides.transcriptSelectionSurface ?? ""
        )
        return view
    }

    func updateNSView(_ view: FixTeachTextView, context: Context) {
        applySelectionStyle(to: view)
        view.onFixTeach = onFixTeach
        view.onSelectionChange = onSelectionChange
        view.onPlainClick = onPlainClick
        if view.installedIdentity != identity || view.string != text {
            view.install(
                identity: identity,
                attributedText: attributed,
                selectionSurface: RenderOverrides.transcriptSelectionSurface ?? ""
            )
            view.invalidateIntrinsicContentSize()
        } else {
            // An appearance or accent change recolours the words in place, keeping the
            // reader's selection.
            view.recolor(textColor)
        }
    }

    /// Left unset, NSTextView paints the user's system accent across the widest
    /// selectable surface in the app, which no golden can reproduce on another
    /// Mac. Reapplied on every update: the theme may have changed, and a recycled
    /// view may be carrying another mount's attributes.
    private func applySelectionStyle(to view: FixTeachTextView) {
        view.selectedTextAttributes = [
            .backgroundColor: selectionColor,
            .foregroundColor: textColor,
        ]
    }

    /// SwiftUI asks for a size at several widths before it places the view — the widths
    /// its stacks and splits probe, then the one it settles on — and caches each answer.
    /// The answer comes from `Measurer`, never from the live view: a probe that resized
    /// the live view would leave it at the probed width whenever the placement does not
    /// set its frame again, and the text would wrap at that width, spilling past a height
    /// reserved for another.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FixTeachTextView, context: Context) -> CGSize? {
        context.coordinator.size(of: text, fontSize: fontSize, proposedWidth: proposal.width)
    }

    /// A TextKit 1 stack of its own that lays the transcript out exactly as
    /// `FixTeachTextView` will — same attributed text, same container geometry, no
    /// insets — so a width can be measured without touching the view on screen.
    @MainActor
    final class Measurer {
        private let storage = NSTextStorage()
        private let layoutManager = NSLayoutManager()
        private let container = NSTextContainer(size: .zero)
        private var measuredText: String?
        private var measuredFontSize: CGFloat?

        init() {
            SelectableTranscriptText.prepare(container)
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
        }

        /// Answers every proposal SwiftUI makes. A finite width keeps that width and
        /// reports the wrapped height. No width, or an unbounded one, asks for the ideal
        /// size: the text on one line, but never wider than the reading measure, wrapped
        /// there; that width rounds up to a whole point, so a placement at the answered
        /// width cannot land a fraction below the text's own and wrap its last word. A
        /// width of zero or less is the narrowest probe: no width, and one line's height,
        /// because a transcript never takes less than a line and text laid out zero
        /// points wide shows a reader nothing.
        func size(of text: String, fontSize: CGFloat, proposedWidth: CGFloat?) -> CGSize {
            if text != measuredText || fontSize != measuredFontSize {
                storage.setAttributedString(SelectableTranscriptText.attributedText(text, fontSize: fontSize))
                measuredText = text
                measuredFontSize = fontSize
            }
            let width: CGFloat
            if let proposedWidth, proposedWidth.isFinite {
                width = proposedWidth
            } else {
                width = min(ceil(usedRect(width: .greatestFiniteMagnitude).width), Kit.Metrics.readableWidth)
            }
            guard width > 0 else {
                return CGSize(width: 0, height: ceil(firstLineHeight()))
            }
            return CGSize(width: width, height: ceil(usedRect(width: width).height))
        }

        private func usedRect(width: CGFloat) -> CGRect {
            if container.size.width != width {
                container.size = NSSize(width: width, height: container.size.height)
            }
            layoutManager.ensureLayout(for: container)
            return layoutManager.usedRect(for: container)
        }

        private func firstLineHeight() -> CGFloat {
            _ = usedRect(width: .greatestFiniteMagnitude)
            guard layoutManager.numberOfGlyphs > 0 else {
                return layoutManager.extraLineFragmentUsedRect.height
            }
            return layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil).height
        }
    }
}

private let fixTeachSurfaceTrim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

/// NSTextView that reports completed selection changes, reports a plain click that
/// selected nothing, prepends a "Fix / Teach" item to the selection context menu
/// (keeping the native Copy/Look Up items), and reports the chosen context-menu
/// surface — the active selection, or the word under the click when nothing is
/// selected — back through `onFixTeach`.
final class FixTeachTextView: NSTextView {
    var onFixTeach: ((String) -> Void)?
    var onSelectionChange: ((String?) -> Void)?
    var onPlainClick: (() -> Void)?

    /// The transcript currently in the text storage. Read by the representable so
    /// a switch between two sessions holding identical text still reinstalls, and
    /// the previous session's selection cannot outlive it.
    private(set) var installedIdentity: UUID?

    private var lastSelectionSurface: String?
    private var textInstallationGeneration = 0
    private var suppressesSelectionReporting = false

    /// SwiftUI reserves the height `SelectableTranscriptText.Measurer` reports for the
    /// width it places this view at, so the text must wrap at exactly that width. The
    /// container follows every frame change here, whichever path set the frame, rather
    /// than relying on `widthTracksTextView` alone to have caught it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let textContainer else { return }
        let width = max(newSize.width - 2 * textContainerInset.width, 0)
        if textContainer.size.width != width {
            textContainer.size = NSSize(width: width, height: textContainer.size.height)
        }
    }

    /// A click is "plain" only if it began and ended a single click that left no
    /// selection: `mouseDown` runs AppKit's whole tracking loop, so by the time it
    /// returns a drag has already produced its range and a double-click its word.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange.length == 0 else { return }
        onPlainClick?()
    }

    override func isAccessibilityEnabled() -> Bool { true }

    /// NSTextView funnels mouse, keyboard, and Select All changes through this
    /// primitive on macOS 14. Waiting for `stillSelecting == false` avoids
    /// publishing every intermediate range during a mouse drag.
    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting flag: Bool
    ) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: flag)
        guard !flag, !suppressesSelectionReporting else { return }
        reportSelectionChange(currentSelectionSurface)
    }

    func install(identity: UUID, attributedText: NSAttributedString, selectionSurface: String) {
        installedIdentity = identity
        textInstallationGeneration &+= 1
        setSelectedRange(
            NSRange(location: 0, length: 0),
            affinity: .downstream,
            stillSelecting: false
        )
        textStorage?.setAttributedString(attributedText)

        guard !selectionSurface.isEmpty else { return }
        let range = (string as NSString).range(of: selectionSurface)
        guard range.location != NSNotFound else { return }
        setSelectedRange(range, affinity: .downstream, stillSelecting: false)
    }

    /// Repaints the words in `color` without reinstalling them, so the selection and
    /// the reported surface survive a theme change. Free when the colour is unchanged.
    func recolor(_ color: NSColor) {
        guard let textStorage, textStorage.length > 0,
            (textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) != color
        else { return }
        textStorage.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: 0, length: textStorage.length)
        )
    }

    private var currentSelectionSurface: String? {
        let range = selectedRange
        let length = (string as NSString).length
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= length else {
            return nil
        }
        let surface = (string as NSString)
            .substring(with: range)
            .trimmingCharacters(in: fixTeachSurfaceTrim)
        return surface.isEmpty ? nil : surface
    }

    private func reportSelectionChange(_ surface: String?) {
        guard surface != lastSelectionSurface else { return }
        lastSelectionSurface = surface
        let generation = textInstallationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.textInstallationGeneration == generation else { return }
            self.onSelectionChange?(surface)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        guard let surface = fixTeachSurface(for: event), !surface.isEmpty else { return base }
        let menu = base ?? NSMenu()
        let item = NSMenuItem(
            title: "Fix / Teach \u{201C}\(surface)\u{201D}",
            action: #selector(invokeFixTeach(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = surface
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    /// The active selection, or — when nothing is selected — the word under the
    /// right-click point, which is also selected so the menu target is visible.
    private func fixTeachSurface(for event: NSEvent) -> String? {
        var range = selectedRange
        if range.length == 0, let word = wordRange(at: event) {
            range = word
            // Selecting the context-menu target is visual affordance, not the
            // user's live selection intent; the menu action remains the trigger.
            suppressesSelectionReporting = true
            setSelectedRange(range, affinity: .downstream, stillSelecting: false)
            suppressesSelectionReporting = false
        }
        guard range.length > 0 else { return nil }
        let substring = (string as NSString).substring(with: range)
        return substring.trimmingCharacters(in: fixTeachSurfaceTrim)
    }

    private func wordRange(at event: NSEvent) -> NSRange? {
        guard let layoutManager, let container = textContainer else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: viewPoint.x - textContainerOrigin.x, y: viewPoint.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let charIndex = min(layoutManager.characterIndexForGlyph(at: glyph), length - 1)
        return selectionRange(forProposedRange: NSRange(location: charIndex, length: 0), granularity: .selectByWord)
    }

    @objc private func invokeFixTeach(_ sender: NSMenuItem) {
        guard let surface = sender.representedObject as? String, !surface.isEmpty else { return }
        onFixTeach?(surface)
    }
}
