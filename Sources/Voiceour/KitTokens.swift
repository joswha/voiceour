import AppKit
import SwiftUI

/// The console's component kit: the parts every console tab is built from.
///
/// Every colour comes from the resolved ``Theme`` in `@Environment(\.theme)`, so one
/// set of components serves the light and dark appearances, every accent and
/// Increase Contrast without a branch of its own. Surfaces are opaque and painted:
/// no Liquid Glass in content, bars or sidebars, because glass picks up whatever is
/// under it and the offscreen harness cannot see it. The window's own chrome
/// (``ConsoleGlassGround``) is the one material left.
///
/// Every kit text goes through ``TextRole`` and every painted surface under text
/// declares `\.surfaceGround`, so the harness's contrast lint measures what the
/// reader sees.
///
/// The kit owns no state of the app's. A component takes plain values and
/// closures; what a press means belongs to the lens that placed it.
enum Kit {}

extension Kit {
    /// The kit's measures, on the 4 pt grid. Columns are flush; each one draws its
    /// trailing 1 pt rule inside its own width, so the widths add up without odd
    /// points. At the 1164 pt default window a browsing tab (1158 pt inside its 3 pt
    /// insets) divides into 222 + 320 + 616, and Settings into 222 + 936; at the 800 pt
    /// minimum the rail leaves the page 420 pt.
    enum Metrics {
        /// The space between columns: none, because a 1 pt rule separates them.
        static let gutter: CGFloat = 0
        /// Wide enough for "Recent threads" and a loud badge at 13 pt. Includes the
        /// column's trailing 1 pt hairline.
        static let sidebarWidth: CGFloat = 222
        /// The sidebar folded to glyphs: a 36 pt item, 8 pt in from the leading edge and
        /// 10 pt from the trailing one, which includes the column's 1 pt hairline. 54
        /// keeps the page beside it on the grid.
        static let railWidth: CGFloat = 54
        /// The width under which a browsing tab folds its sidebar to the rail. A window
        /// the user narrowed keeps its size across launches, and below this the page
        /// column would drop under a readable width.
        static let railBelow: CGFloat = 1_000
        /// A two-line preview at 13 pt holds roughly a sentence at this width. Includes
        /// the column's trailing 1 pt hairline, which ``Kit/Split`` draws inside it.
        static let listWidth: CGFloat = 320
        /// The reading measure: about 70 characters of 15 pt text.
        static let readableWidth: CGFloat = 680
        static let pagePadding: CGFloat = 24
        /// List rows on the Row scale: a line, a title with one meta line, a preview.
        static let rowHeightOne: CGFloat = 32
        static let rowHeightTwo: CGFloat = 48
        static let rowHeightPreview: CGFloat = 64
        static let rowRadius: CGFloat = 6
        /// How far a row's plate sits in from its column's edge, so selection reads as
        /// a rounded plate rather than a full-bleed stripe.
        static let rowInset: CGFloat = 4
        /// Every kit control: a button, a menu, the search field.
        static let controlHeight: CGFloat = 28
        static let controlRadius: CGFloat = 6
        static let cardRadius: CGFloat = 12
        static let cardPadding: CGFloat = 16
        static let pillHeightSmall: CGFloat = 18
        static let pillHeightRegular: CGFloat = 22
        /// The confirmation toast's least height and widest measure; a message that
        /// outgrows one line wraps to a second rather than clipping.
        static let toastHeight: CGFloat = 36
        static let toastMaxWidth: CGFloat = 440
        static let iconTileRegular: CGFloat = 28
        static let iconTileSmall: CGFloat = 20
        static let iconTileMini: CGFloat = 16
        /// The gap between a page's sections; sections are told apart by space and a
        /// heading, not by rules.
        static let sectionGap: CGFloat = 24
        /// The label column of a properties grid.
        static let propertyLabelWidth: CGFloat = 120
        /// The smallest glyph box the kit draws, such as a key cap.
        static let glyphControl: CGFloat = 20
        /// The press target of a glyph inside a field or a chip, such as a clear button:
        /// the 24 pt control scale, so a small glyph is still easy to hit.
        static let glyphTarget: CGFloat = 24
        /// The timestamp column of a reading row: "00:00:00" at 12 pt monospaced digits.
        static let stampGutter: CGFloat = 60
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

        /// How long a confirmation stays: long enough to read a short sentence, short
        /// enough that it never outlives the moment it confirms.
        static let hold: Duration = .seconds(2)

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

    /// Whether the list a row sits in holds keyboard focus. A selected row in a focused
    /// list shows the accent-tinted selection and a focus bar; in an unfocused list it
    /// shows the neutral inactive selection, so a reader always knows which column the
    /// arrow keys move. ``Kit/ListColumn`` publishes it to its rows.
    @Entry var kitListFocused: Bool = false

    /// The bottom space a showing toast covers, published by `kitToast(_:identifier:)`
    /// so the scrolling columns under it extend their content past it and the last
    /// line is never hidden behind the confirmation. Zero while no toast shows.
    @Entry var kitToastInset: CGFloat = 0
}
