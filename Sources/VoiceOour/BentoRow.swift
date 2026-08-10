import SwiftUI

// MARK: - The column grid

private struct BentoSpan: LayoutValueKey {
    static let defaultValue: Int = BentoRow.columns
}

extension View {
    /// How many of the shelf's twelve columns this cell claims.
    func bentoSpan(_ span: Int) -> some View {
        layoutValue(key: BentoSpan.self, value: span)
    }
}

/// One shelf of the dashboard's bento grid.
///
/// The pane runs on a single twelve-column measure with one gutter width, and a
/// cell claims a whole number of those columns. A cell spanning `s` columns also
/// swallows the `s − 1` gutters inside it, so every cell edge in every shelf
/// lands on the same vertical lines however many cells the shelf holds — which a
/// row of equal-flex cells only achieves when its cell count happens to divide
/// twelve. A shelf then hands every cell the height of its tallest, so the
/// shelf closes on one bottom edge instead of a stair-step. That is not the
/// same as stretching the *content*: `ContentCard` anchors its children
/// top-leading, so a short card's slack pools inside its own surface — where it
/// reads as breathing room — instead of outside it, against the next shelf.
struct BentoRow: Layout {
    static let columns = 12
    static let gutter = VoiceOourMetrics.Space.md

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let tallest = zip(subviews, cellWidths(total: width, subviews: subviews))
            .reduce(CGFloat.zero) { height, pair in
                max(height, pair.0.sizeThatFits(ProposedViewSize(width: pair.1, height: nil)).height)
            }
        return CGSize(width: width, height: tallest)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, cellWidths(total: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + Self.gutter
        }
    }

    private func cellWidths(total: CGFloat, subviews: Subviews) -> [CGFloat] {
        let column = (total - Self.gutter * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
        return subviews.map { subview in
            let span = CGFloat(min(max(subview[BentoSpan.self], 1), Self.columns))
            return column * span + Self.gutter * (span - 1)
        }
    }
}
