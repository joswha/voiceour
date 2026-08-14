import SwiftUI

/// A labeled group of rows encapsulated in a `ContentCard`: the eyebrow becomes
/// the card's eyebrow, and the container overlays rules between its row bounds
/// so the last row never draws a trailing rule against empty card padding.
/// The section owns ONE eyebrow-to-content step: `SettingsSectionLayout` trims
/// whatever dead space the first and last child declare through
/// `settingsContentLead(_:)`, so a card that opens on a `SettingsRow` sits the
/// same distance below its eyebrow as one that opens on a bare control or a
/// grid.
struct SettingsSectionBlock<Content: View>: View {
    var eyebrow: String
    let content: Content

    init(eyebrow: String, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        ContentCard(eyebrow: eyebrow) {
            SettingsSectionLayout {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayPreferenceValue(SettingsRowBoundsPreferenceKey.self) { rowBounds in
                SettingsRowRules(rowBounds: rowBounds)
            }
        }
    }
}

/// The dead space a `SettingsSectionBlock` child carries outside its own ink:
/// a `SettingsRow`'s vertical padding, or the slack a table band leaves above
/// a header that is centred in a taller row. Declared statically so the
/// section can trim it at layout time instead of measuring the render.
private struct SettingsContentLeadKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

extension View {
    /// Declare how far this section child's first ink row sits below its own
    /// top edge, and its last ink row above its bottom edge. The section
    /// subtracts it at both card edges, so the eyebrow-to-ink step and the
    /// bottom margin stay `Space.md` whatever the child turns out to be.
    func settingsContentLead(_ inset: CGFloat) -> some View {
        layoutValue(key: SettingsContentLeadKey.self, value: inset)
    }
}

/// Stacks a section's children flush on the card's leading edge and removes the
/// lead the first child declares and the trail the last one does. A plain
/// `VStack` cannot: the padding that gives two rows their pitch is the same
/// padding that pushes the first row away from the eyebrow, and only the child
/// knows how much of its own box is empty.
private struct SettingsSectionLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = measure(subviews, width: proposal.width)
        let height = sizes.reduce(0) { $0 + $1.height } - lead(subviews) - trail(subviews)
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: max(height, 0))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = measure(subviews, width: bounds.width)
        var y = bounds.minY - lead(subviews)

        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: sizes[index].height)
            )
            y += sizes[index].height
        }
    }

    private func measure(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }

    private func lead(_ subviews: Subviews) -> CGFloat {
        subviews.first?[SettingsContentLeadKey.self] ?? 0
    }

    private func trail(_ subviews: Subviews) -> CGFloat {
        subviews.last?[SettingsContentLeadKey.self] ?? 0
    }
}
