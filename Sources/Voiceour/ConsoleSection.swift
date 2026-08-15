import SwiftUI

enum ConsoleSection: String, CaseIterable, Identifiable {
    case home
    case sessions
    case voice
    case glossary
    case system
    case diagnostics

    var id: String { rawValue }

    var descriptor: ConsolePaneDescriptor {
        ConsolePaneRegistry.descriptor(for: self)
    }

    var label: String { descriptor.label }
    var eyebrow: String { descriptor.eyebrow }
    var subtitle: String { descriptor.subtitle }
    var symbol: String { descriptor.symbol }

    /// The pane's own content measure, and therefore the cap on `SectionHeader`, so
    /// the header and the body it labels declare the same left AND right edge. The
    /// header used to span the full scroll width while a capped pane stopped 116pt
    /// short of it, which read as a stray label floating over empty glass rather than
    /// as a header field.
    ///
    /// `nil` means the region IS the measure: Home clamps its grid to the region and
    /// centres it, and Sessions' master/detail layout is full width by design, so
    /// capping either would strand the header inside its own content.
    var headerMeasure: CGFloat? { descriptor.headerMeasure }

    /// Bottom margin the shell owes the pane. Panes that own a scroll container get
    /// none, so the viewport runs to the window's inner edge and the clip lands ON the
    /// boundary: a clip at the edge reads as "more below", a clip floating above a
    /// dead band reads as damage. Sessions lays out full-height cards instead of
    /// scrolling, so it keeps a real margin.
    var contentBottomInset: CGFloat { descriptor.contentBottomInset }
}

enum ConsolePaneRailPlacement {
    case primary
    case standard
    /// Machine-facing panes: paths, model ids, probe evidence, a CLI command.
    /// Real facts, but not the app a user bought — the rail hides them unless
    /// `LaunchOptions.showsDebugPanes` is on or one of them is the open pane.
    case debug
}

enum ConsolePaneHeaderMetadata {
    case recentSessionCount(singular: String, plural: String)
    case backendID
    case glossaryCount
    case systemReadiness
    case diagnosticsStatus
}
