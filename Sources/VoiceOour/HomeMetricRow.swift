import SwiftUI

/// A metric cell keyed on its own label, which is unique within its shelf.
/// Membership is conditional, so positional identity would tell SwiftUI that
/// several cells changed contents when in fact one was inserted. A strip that
/// labels its cells prints that key; a strip whose units already name their
/// figures keeps it as identity only.
struct MetricCell: Identifiable {
    let id: String
    let parts: [HomeFormat.MetricPart]
    var color: Color?
}

// MARK: - Strip shelves

/// The interior of a strip shelf: equal-flex metric cells dividing the card's
/// own measure, separated by hairlines that run the full height of a cell.
///
/// This is the grammar the Sessions TOTALS strip speaks (`RecentSessionMetricStrip.swift`),
/// down to the rule geometry — the rules are an overlay on the resolved row, so
/// they run label-to-numeral and stop inside the card's content box instead of
/// crossing its padding or its rim, and each sits centred in the gutter between
/// two cells rather than pressed against one of them. The cells are card-local
/// flex quarters, not global bento columns: this shelf is one cell of the
/// twelve-column grid and divides itself.
struct HomeMetricRow: View {
    let cells: [MetricCell]
    let scale: MetricValue.Scale
    /// Whether each cell prints its key above its value. RECORDS labels its
    /// cells because "181 wpm" alone does not say *which* record it is; ALL
    /// TIME's units label their own numerals.
    let labels: Bool

    /// One 24pt gutter per boundary with the rule centred in it, so the cells
    /// divide the card's full measure instead of huddling to the left.
    private static let gutter = VoiceOourMetrics.Space.xl

    var body: some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            ForEach(cells) { cell in
                cellBody(cell)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay { rules }
    }

    /// A labelled cell reads as one element ("Longest dictation, 16 words");
    /// an unlabelled one is already a phrase, and `MetricValue` speaks it.
    @ViewBuilder
    private func cellBody(_ cell: MetricCell) -> some View {
        if labels {
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.md) {
                Text(cell.id)
                    .roleStyle(.micro)
                MetricValue(parts: cell.parts, scale: scale, color: cell.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(cell.id)
            .accessibilityValue(cell.parts.plain)
        } else {
            MetricValue(parts: cell.parts, scale: scale, color: cell.color)
        }
    }

    private var rules: some View {
        GeometryReader { proxy in
            let columns = CGFloat(cells.count)
            let column = (proxy.size.width - Self.gutter * (columns - 1)) / columns
            ForEach(cells.indices.dropFirst(), id: \.self) { index in
                HairlineDivider(axis: .vertical)
                    .frame(height: proxy.size.height)
                    .offset(x: CGFloat(index) * (column + Self.gutter) - Self.gutter / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The longest dictation in the user's own words, quoted under the record that
/// counts it — the one place on the pane where a figure is answered by the
/// thing it measured.
///
/// One line, truncated: the shelf reports a record, it does not reprint a
/// transcript (Sessions does that). The full text stays reachable both ways a
/// reader can ask for it — the pointer, through `help`, and VoiceOver, through
/// the line's own value — so the truncation costs nothing but height.
struct LongestDictationQuote: View {
    let text: String

    private var a11y = A11y()

    init(text: String) {
        self.text = text
    }

    var body: some View {
        Text("“\(text)”")
            .roleStyle(.caption)
            .foregroundStyle(a11y.textLow)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
            .accessibilityLabel("Longest dictation transcript")
            .accessibilityValue(text)
    }
}
