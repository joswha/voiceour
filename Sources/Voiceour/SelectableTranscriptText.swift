import AppKit
import SwiftUI

/// Read-only, mouse-selectable transcript text that reports completed selection
/// changes and prepends a "Fix / Teach" item to the native context menu.
/// SwiftUI's `Text.textSelection` exposes neither the selected substring nor
/// an extensible selection menu on
/// the macOS 14 deployment target, so this wraps `NSTextView` directly.
///
/// Every colour here is a semantic system colour, so the transcript reads
/// correctly in both appearances. It used to paint the console's own near-white
/// ink on a cyan selection wash, which was legible only because the window
/// pinned a dark scheme — a native window follows the appearance the user chose,
/// and this is the one view in it that holds arbitrary user text.
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

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let textColor = NSColor.labelColor

    init(
        identity: UUID,
        text: String,
        onFixTeach: @escaping (String) -> Void,
        onSelectionChange: ((String?) -> Void)? = nil
    ) {
        self.identity = identity
        self.text = text
        self.onFixTeach = onFixTeach
        self.onSelectionChange = onSelectionChange
    }

    /// Deliberately not `selectedTextBackgroundColor`: that one is derived from
    /// the user's System Settings accent, which no environment key overrides, so a
    /// committed golden containing it would not port between machines. The
    /// unemphasized pair is the system's own answer for a selection in a text view
    /// that does not hold focus — appearance-aware, contrast-aware, and the same
    /// on every Mac. It also keeps the wash light enough not to swallow the words
    /// the user is reading to decide what to teach.
    private static let selectionFill = NSColor.unemphasizedSelectedTextBackgroundColor

    private var attributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = VoiceourMetrics.Space.hair
        return NSAttributedString(
            string: text,
            attributes: [
                .font: Self.font,
                .foregroundColor: Self.textColor,
                .paragraphStyle: paragraph,
            ])
    }

    func makeNSView(context: Context) -> FixTeachTextView {
        let view = FixTeachTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = .zero
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        applySelectionStyle(to: view)
        view.onFixTeach = onFixTeach
        view.onSelectionChange = onSelectionChange
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
        if view.installedIdentity != identity || view.string != text {
            view.install(
                identity: identity,
                attributedText: attributed,
                selectionSurface: RenderOverrides.transcriptSelectionSurface ?? ""
            )
            view.invalidateIntrinsicContentSize()
        }
    }

    /// Left unset, NSTextView paints the user's system accent across the widest
    /// selectable surface in the app, which no golden can reproduce on another
    /// Mac. Both colours are dynamic, so a single assignment survives an
    /// appearance or Increase Contrast change; it is still reapplied on update
    /// because a recycled view may be carrying another mount's attributes.
    private func applySelectionStyle(to view: FixTeachTextView) {
        view.selectedTextAttributes = [
            .backgroundColor: Self.selectionFill,
            .foregroundColor: Self.textColor,
        ]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FixTeachTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
            let layoutManager = nsView.layoutManager,
            let container = nsView.textContainer
        else { return nil }
        if abs(nsView.frame.width - width) > 0.5 {
            nsView.frame.size.width = width
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }
}

private let fixTeachSurfaceTrim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

/// NSTextView that reports completed selection changes, prepends a "Fix / Teach"
/// item to the selection context menu (keeping the native Copy/Look Up items),
/// and reports the chosen context-menu surface — the active selection, or the
/// word under the click when nothing is selected — back through `onFixTeach`.
final class FixTeachTextView: NSTextView {
    var onFixTeach: ((String) -> Void)?
    var onSelectionChange: ((String?) -> Void)?

    /// The transcript currently in the text storage. Read by the representable so
    /// a switch between two sessions holding identical text still reinstalls, and
    /// the previous session's selection cannot outlive it.
    private(set) var installedIdentity: UUID?

    private var lastSelectionSurface: String?
    private var textInstallationGeneration = 0
    private var suppressesSelectionReporting = false

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
