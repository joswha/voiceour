import SwiftUI

/// Two symbols set at the same point size do not share a bounding box — `tray`
/// measures 15pt shorter than `rectangle.stack` at 48pt — so an `EmptyState`
/// glyph gets a slot and sits on its bottom edge. Without one, two empty states
/// that start at the same y still have their titles out of line. The slot is
/// the glyph's own size plus the overshoot a symbol's box can take above it.
private let emptyStateGlyphSlot = VoiceourMetrics.Icon.empty + VoiceourMetrics.Space.lg

/// The app's one empty state: a faint glyph, a title, one sentence of body copy
/// and an optional hint or recovery action, all left-flush on the column the
/// populated state starts from.
///
/// Left-aligned *with* a glyph because the alternative shipped three treatments
/// — this pane's list read left-flush and glyphless, its detail read centred
/// behind a 48pt glyph, and the two sat side by side on one screen.
///
/// Deliberately not `private`: pane-specific empty states route through it so
/// their glyph, title, body, and hint share one treatment.
struct EmptyState<Hint: View>: View {
    private let glyph: String
    private let title: String
    private let message: String
    private let hint: Hint

    init(glyph: String, title: String, body: String, @ViewBuilder hint: () -> Hint) {
        self.glyph = glyph
        self.title = title
        self.message = body
        self.hint = hint()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
            Image(systemName: glyph)
                .roleStyle(.emptyGlyph)
                .frame(height: emptyStateGlyphSlot, alignment: .bottomLeading)
                .accessibilityHidden(true)

            Text(title)
                .roleStyle(.title)
                .fixedSize(horizontal: false, vertical: true)

            CaptionText(message)
                .frame(maxWidth: VoiceourMetrics.Content.form, alignment: .leading)

            hint
        }
    }
}

extension EmptyState where Hint == EmptyView {
    init(glyph: String, title: String, body: String) {
        self.init(glyph: glyph, title: title, body: body) { EmptyView() }
    }
}

/// The visible first-run instruction and its spoken label must carry the same
/// verb, and both must match what the binder does: `KeyboardShortcutsBinder`
/// toggles on RELEASE of a solitary Fn/Globe tap, so "HOLD" described a gesture
/// the app does not implement — holding Fn and speaking starts nothing.
struct DictationHotkeyHint: View {
    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.xs) {
            Text("TAP")
                .roleStyle(.micro)
            KeyCap("Fn")
            Text("or")
                .roleStyle(.caption)
            KeyCap("Globe")
            Text("TO DICTATE")
                .roleStyle(.micro)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tap Fn or Globe to dictate")
    }
}
