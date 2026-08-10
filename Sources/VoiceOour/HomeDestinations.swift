import SwiftUI
import VoiceCore

// MARK: - Destinations

/// Ranked destination apps (top five, plus an honest remainder): a summary line
/// and one meter per app on a shared axis.
///
/// Every row prints the count it earned and fills its share of that same total,
/// so the length and the figure are one quantity read two ways. Rank is carried
/// by order and by the leader's name weight, not by a tinted bar: a ranking is
/// not a current datum, so this card spends no resting accent. Hovering a row
/// brightens its name and moves the summary onto that row, honoring
/// reduce-motion. Lives beside the other Home chart components
/// (HomeHourChart.swift, HomeDayChart.swift).
struct DestinationRows: View {
    var destinations: [DictationInsights.Destination]
    /// The whole this ranking is measured against: every outcome that named an
    /// app (`DictationInsights.attributedOutcomeCount`). Never `sessionCount`,
    /// and never a sum over `destinations` — that list is truncated to eight,
    /// so a local sum understates the denominator the shares were computed
    /// against whenever more than eight apps were attributed.
    var attributedTotal: Int

    private var a11y = A11y()
    @State private var hoveredIndex: Int?

    /// The list is a ranking, not a directory; past five the tail is aggregated
    /// so the shares still account for the whole.
    private static let visibleRows = 5

    init(destinations: [DictationInsights.Destination], attributedTotal: Int) {
        self.destinations = destinations
        self.attributedTotal = attributedTotal
    }

    var body: some View {
        let capped = Array(destinations.prefix(Self.visibleRows))
        let remainder = max(0, 1 - capped.reduce(0) { $0 + $1.share })
        let remainderCount = attributedTotal - capped.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.sm) {
            Text(readout)
                .roleStyle(.micro)
                .monospacedDigit()
                .foregroundStyle(hoveredIndex == nil ? a11y.textLow : VoiceOourPalette.Text.mono)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(capped.enumerated()), id: \.element.id) { index, destination in
                DestinationRow(
                    name: HomeAppNames.name(for: destination.bundleId),
                    count: destination.count,
                    share: destination.share,
                    isTop: index == 0,
                    isHovered: hoveredIndex == index
                )
                .onHover { hovering in
                    let next: Int? = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
                    if a11y.reduceMotion {
                        hoveredIndex = next
                    } else {
                        withAnimation(VoiceOourMotion.quick) { hoveredIndex = next }
                    }
                }
            }

            // Everything the ranking leaves out, stated. Without it the bars
            // stop short of the axis and the printed counts stop short of the
            // total the summary line quotes.
            if remainderCount > 0 {
                DestinationRow(
                    name: "OTHER",
                    count: remainderCount,
                    share: remainder,
                    isTop: false,
                    isHovered: false
                )
            }
        }
    }

    /// Peer to the readout the other two Home charts carry, at the same face and
    /// the same place in the card: at rest the leader and how much of the whole
    /// it holds, and while a row is hovered that row's own tally.
    private var readout: String {
        if let index = hoveredIndex, destinations.indices.contains(index) {
            let destination = destinations[index]
            return "\(HomeAppNames.name(for: destination.bundleId)) · "
                + destinationDictations(destination.count)
        }
        guard let leader = destinations.first else { return "No app recorded yet." }
        return "\(HomeAppNames.name(for: leader.bundleId)) leads · "
            + "\(HomeFormat.grouped(leader.count)) of \(HomeFormat.grouped(attributedTotal))"
    }

}

/// The unit every figure in this card carries: dictations aimed at an app,
/// including the ones that only reached the clipboard and the ones that failed
/// on the way in — which is why "pastes" would overclaim.
private func destinationDictations(_ count: Int) -> String {
    "\(HomeFormat.grouped(count)) \(count == 1 ? "dictation" : "dictations")"
}

struct DestinationRow: View {
    var name: String
    var count: Int
    var share: Double
    var isTop: Bool
    var isHovered: Bool

    private var a11y = A11y()

    init(
        name: String,
        count: Int,
        share: Double,
        isTop: Bool,
        isHovered: Bool
    ) {
        self.name = name
        self.count = count
        self.share = share
        self.isTop = isTop
        self.isHovered = isHovered
    }

    /// Fixed name and value columns with the meter flexing between them: a
    /// content-driven name column would let one long app name shift every bar's
    /// origin, which is the thing a shared axis exists to prevent. The name
    /// column holds two `Space.section` steps rather than three so the meter
    /// keeps an honest track: on a short track a small share cannot clear the
    /// meter's own minimum fill, and the axis starts rounding small shares up
    /// into each other.
    private static let nameWidth = VoiceOourMetrics.Space.section * 2
    private static let valueWidth = VoiceOourMetrics.Space.section

    /// The row's own tally, printed.
    private var countLabel: String {
        HomeFormat.grouped(count)
    }

    private var nameColor: Color {
        (isHovered || isTop) ? VoiceOourPalette.Text.high : a11y.textMid
    }

    var body: some View {
        HStack(spacing: VoiceOourMetrics.Space.md) {
            Text(name)
                .roleStyle(.label)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.nameWidth, alignment: .leading)

            MeterBar(fraction: share, fill: a11y.meterRest)

            Text(countLabel)
                .roleStyle(.bodyMono)
                .monospacedDigit()
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .frame(height: VoiceOourMetrics.Control.mini)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    /// A bar's length is not perceivable to VoiceOver, so the row announces the
    /// same pair the eye reads: the app, and the dictations it took, with the
    /// unit spelled out.
    private var rowAccessibilityLabel: String {
        "\(name), \(destinationDictations(count))"
    }
}
