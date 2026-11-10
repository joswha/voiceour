import AppKit
import SwiftUI

/// The console's component kit: the parts the Journal is built from.
///
/// Two layers, and the line between them is the design. Content — rows, cards,
/// transcripts, figures — sits on an opaque ground in system semantic colours,
/// because it is what a reader reads. Navigation and controls — the sidebar, the
/// search and action bars, the copy confirmation — float above it in Liquid
/// Glass, because they are what a reader steers with.
///
/// Glass never sits on glass. Every kit surface samples the Journal's opaque
/// ground or the content scrolling under it, never ``ConsoleGlassGround``: glass
/// cannot sample other glass, and two stacked blurs read as mud. Reduce
/// Transparency swaps every kit glass surface for an opaque control fill with a
/// drawn rim, so a reader who turned the material off still sees each boundary.
///
/// The kit owns no state of the app's. A component takes plain values and
/// closures; what a press means belongs to the lens that placed it.
enum Kit {}

extension Kit {
    /// The kit's measures. Spacing stays on the 4 pt grid `VoiceourMetrics.Space`
    /// already uses; the column widths are what the console's 1164 pt minimum
    /// window divides into.
    enum Metrics {
        /// The inset around the floating sidebar, and the gap beside it.
        static let gutter: CGFloat = VoiceourMetrics.Space.sm
        /// Wide enough for "Timeline" and a three-digit count at 13 pt. With the tab's own
        /// 3 pt insets it leaves the page column a width on the 4 pt grid at the console's
        /// 1164 pt minimum.
        static let sidebarWidth: CGFloat = 206
        /// The sidebar as a rail of glyphs, in a window too narrow for its names: one
        /// 32 pt item and the panel's 8 pt insets on either side, plus its rim.
        static let railWidth: CGFloat = 52
        /// The width under which a browser's sidebar folds to its rail. The console opens
        /// at 1164 pt, but a window the user narrowed keeps its size across launches, and
        /// at 1000 pt the page column would otherwise drop under 440 pt.
        static let railBelow: CGFloat = 1_000
        /// A two-line preview at 13 pt holds roughly a sentence at this width.
        static let listWidth: CGFloat = 344
        /// The reading measure: about 90 characters of 15 pt text.
        static let readableWidth: CGFloat = 720
        static let pagePadding: CGFloat = 32
        static let panelRadius: CGFloat = 16
        static let cardRadius: CGFloat = 12
        static let rowRadius: CGFloat = 8
        /// Every glass control — a button, a menu, the search field, a chip: the Control
        /// scale's 28, the height a large glass button takes with a boxed glyph.
        static let control: CGFloat = VoiceourMetrics.Control.small
        /// The transient confirmation capsule, which holds a sentence rather than a verb.
        static let toast: CGFloat = VoiceourMetrics.Control.medium
        /// The smallest press target the kit draws, for a glyph inside a field or a chip.
        static let glyphControl: CGFloat = VoiceourMetrics.Control.mini
        /// A list row that previews text: a meta line and two lines of words, on the
        /// Row scale's 64.
        static let previewRow: CGFloat = VoiceourMetrics.Row.list
        /// A list row that names something: a title and one meta line, on the Row scale's 44.
        static let titleRow: CGFloat = 44
        static let markHeight: CGFloat = 18
        /// The timestamp column of a reading row: "00:00:00" at 12 pt monospaced digits.
        static let stampGutter: CGFloat = 60
        /// The label column of a fact row.
        static let factLabel: CGFloat = 96
    }

    /// The kit's type ramp. Explicit sizes rather than text styles: macOS has no
    /// Dynamic Type for these, and a golden must not depend on a setting.
    enum Fonts {
        static let columnTitle = Font.system(size: 20, weight: .bold)
        static let pageTitle = Font.system(size: 22, weight: .semibold)
        static let eyebrow = Font.system(size: 12, weight: .medium)
        static let sectionTitle = Font.system(size: 13, weight: .semibold)
        static let groupHeader = Font.system(size: 12, weight: .semibold)
        static let rowTitle = Font.system(size: 13, weight: .semibold)
        static let rowBody = Font.system(size: 13)
        static let reading = Font.system(size: 14)
        /// The open transcript, the one place the kit sets text to be read slowly.
        static let readingLarge: CGFloat = 15
        static let meta = Font.system(size: 12)
        static let stamp = Font.system(size: 12).monospacedDigit()
        static let mark = Font.system(size: 10, weight: .semibold)
        static let metricValue = Font.system(size: 20, weight: .semibold).monospacedDigit()
        static let sidebarItem = Font.system(size: 13)
        static let toast = Font.system(size: 13, weight: .medium)
    }

    /// Colours. Every one is a system semantic colour or a fraction of one, so the
    /// kit follows the appearance the reader chose and Increase Contrast escalates
    /// it; the app palette stays with the menu, the island and Home.
    @MainActor
    enum Colors {
        static let ground = Color(nsColor: .windowBackgroundColor)

        static func cardFill(_ a11y: A11y) -> Color {
            Color.primary.opacity(a11y.contrast == .increased ? 0.08 : 0.045)
        }

        static func rule(_ a11y: A11y) -> Color {
            Color.primary.opacity(escalated(a11y) ? 0.3 : 0.1)
        }

        /// A selected row: the accent the History list always used, escalated under
        /// Increase Contrast so a reader who asked for more is not handed a hint.
        static func selection(_ a11y: A11y) -> Color {
            Color.accentColor.opacity(a11y.contrast == .increased ? 0.34 : 0.2)
        }

        static func hover(_ a11y: A11y) -> Color {
            Color.primary.opacity(a11y.contrast == .increased ? 0.1 : 0.05)
        }

        static func pressed(_ a11y: A11y) -> Color {
            Color.primary.opacity(a11y.contrast == .increased ? 0.16 : 0.09)
        }

        static func hairline(_ a11y: A11y) -> CGFloat {
            VoiceourMetrics.Stroke.hairline(a11y.contrast)
        }

        /// Reduce Transparency deletes the material that drew a surface's edge, so the
        /// drawn rule takes its place at the escalated weight Increase Contrast uses.
        private static func escalated(_ a11y: A11y) -> Bool {
            a11y.contrast == .increased || a11y.reduceTransparency
        }
    }

    /// Motion, nil under Reduce Motion so a state change lands without travel.
    @MainActor
    enum Motion {
        static func quick(_ a11y: A11y) -> Animation? {
            a11y.reduceMotion ? nil : .easeInOut(duration: VoiceourMotion.quickDuration)
        }

        static func standard(_ a11y: A11y) -> Animation? {
            a11y.reduceMotion ? nil : .smooth(duration: VoiceourMotion.deliberateDuration)
        }
    }

    /// Speaks `sentence` to VoiceOver. A confirmation that appears beside a control the
    /// VoiceOver cursor has already left confirms nothing, so every visible
    /// confirmation is also spoken. A no-op when VoiceOver is not running.
    @MainActor
    static func announce(_ sentence: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    /// One transient confirmation at a time — "Transcript copied to clipboard" — shown
    /// by ``Kit/Toast`` and spoken through ``Kit/announce(_:)``.
    ///
    /// A lens holds one in `@State` and every copy it offers reports through it, so a
    /// second copy replaces the first message instead of stacking a second toast. The
    /// message is a claim about something that already happened: a caller shows it only
    /// after the write it describes succeeded.
    @MainActor
    @Observable
    final class Flash {
        private(set) var message: String?
        @ObservationIgnored private var clearTask: Task<Void, Never>?

        /// How long a confirmation stays, the hold every console copy mark used.
        static let hold: Duration = .milliseconds(1_400)

        func show(_ message: String, animation: Animation?) {
            Kit.announce(message)
            clearTask?.cancel()
            withAnimation(animation) {
                self.message = message
            }
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: Self.hold)
                guard !Task.isCancelled, let self else { return }
                withAnimation(animation) {
                    self.message = nil
                }
            }
        }

        /// Retires the message at once, for a move that makes it about something no
        /// longer on screen.
        func dismiss() {
            clearTask?.cancel()
            clearTask = nil
            message = nil
        }
    }
}

extension EnvironmentValues {
    /// Whether the kit's controls show their glyph alone, because the bar they sit in is
    /// too narrow for their titles. Every control keeps its title as its accessibility
    /// label and its tooltip, so only the drawing changes.
    @Entry var kitCompactControls: Bool = false
}
