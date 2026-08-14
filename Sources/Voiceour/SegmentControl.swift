import SwiftUI

/// A bounded segment plate. Its segments derive radius 4 from the group's 8 at
/// the `Space.xs` inset, and the group installs the matching container shape so
/// anything nested inside resolves against the group rather than reaching past
/// it to the card (SPEC C23).
struct SegmentGroup<Content: View>: View {
    var rows: Int
    let content: Content

    init(rows: Int = 1, @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.content = content()
    }

    var body: some View {
        SegmentRowsLayout(rows: max(rows, 1), spacing: VoiceourMetrics.Space.xs) {
            content
        }
        .padding(VoiceourMetrics.Space.xs)
        .plateSurface(kind: .group, cornerRadius: VoiceourMetrics.Radius.row)
        .containerShape(.rect(cornerRadius: VoiceourMetrics.Radius.row))
    }
}

private struct SegmentRowsLayout: Layout {
    let rows: Int
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let layout = measurements(for: subviews)
        return CGSize(
            width: layout.rowWidths.max() ?? 0,
            height: layout.rowHeights.reduce(0, +)
                + spacing * CGFloat(max(layout.rowHeights.count - 1, 0))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let layout = measurements(for: subviews)
        var y = bounds.minY

        for row in layout.rowHeights.indices {
            var x = bounds.minX
            let start = row * layout.columns
            let end = min(start + layout.columns, subviews.count)

            for index in start..<end {
                let size = layout.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (layout.rowHeights[row] - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += layout.rowHeights[row] + spacing
        }
    }

    private func measurements(for subviews: Subviews) -> (
        sizes: [CGSize],
        columns: Int,
        rowWidths: [CGFloat],
        rowHeights: [CGFloat]
    ) {
        guard !subviews.isEmpty else {
            return ([], 1, [], [])
        }

        let rowCount = min(max(rows, 1), subviews.count)
        let columns = Int(ceil(Double(subviews.count) / Double(rowCount)))
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rowWidths = Array(repeating: CGFloat.zero, count: rowCount)
        var rowHeights = Array(repeating: CGFloat.zero, count: rowCount)

        for (index, size) in sizes.enumerated() {
            let row = index / columns
            if rowWidths[row] > 0 {
                rowWidths[row] += spacing
            }
            rowWidths[row] += size.width
            rowHeights[row] = max(rowHeights[row], size.height)
        }

        return (sizes, columns, rowWidths, rowHeights)
    }
}

/// One segment of a segmented choice control (ASR backend, refiner
/// provider). Shared so every segmented picker in the console renders
/// identically.
///
/// Painted on both paths, deliberately. A segment is a plate inside a
/// `SegmentGroup` inside a content card, and neither the material law
/// (`local://SPEC.md` §1.1-1.4, which names functional glass exhaustively and
/// does not name a segment) nor `lg-standard` rule 2 allows a second glass
/// material there — an element on a surface takes a fill overlay. Dropping the
/// glass branch also restores the selected segment's geometry: the glass was
/// applied outside `PlateButtonStyle`, so the selected segment lost the padded
/// `Control.medium` frame its siblings keep and reported 151x16 against their
/// 175x32.
struct SegmentOption: View {
    var label: String
    var isSelected: Bool
    var action: () -> Void
    private var a11y = A11y()

    init(label: String, isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                if isSelected && a11y.differentiateWithoutColor {
                    Image(systemName: "checkmark")
                        .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(VoiceourTypography.label)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, VoiceourMetrics.Space.md)
            .frame(height: VoiceourMetrics.Control.medium)
        }
        .buttonStyle(
            PlateButtonStyle(
                isSelected: isSelected,
                cornerRadius: VoiceourMetrics.Radius.nested(
                    VoiceourMetrics.Radius.row,
                    inset: VoiceourMetrics.Space.xs
                )
            )
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(label)
    }
}
