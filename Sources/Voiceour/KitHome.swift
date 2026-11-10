import SwiftUI

extension Kit {
    /// The one oversized line a page may open with: Home's greeting. A heading to VoiceOver,
    /// so a reader landing on the page hears where they are. It wraps at word boundaries in a
    /// narrow window rather than running off the page.
    struct Hero: View {
        private let text: String

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Text(text)
                .roleStyle(.hero)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// One lifetime figure, read the way a tile is read: what it counts, then the number,
    /// then its unit. Card content: the caller places it in a ``Card``.
    ///
    /// The label (up to two lines) sits at the top and the value is pinned to the bottom
    /// by a flexible spacer, so in a row of equal-height cards the values share one line
    /// even when one label wraps. The value stays on one line and scales down to 60 %
    /// before it would truncate, so a seven-digit count or "12345 hr 59 min" stays whole
    /// in a narrow grid cell; the unit keeps its size beside it. The whole tile is one
    /// accessibility element, named by the label and valued by the number and unit —
    /// read as parts, VoiceOver stopped on every fragment of a single fact.
    struct StatTile: View {
        private let label: String
        private let value: String
        private let unit: String?
        private let systemImage: String?
        @Environment(\.theme) private var theme

        init(label: String, value: String, unit: String? = nil, systemImage: String? = nil) {
            self.label = label
            self.value = value
            self.unit = unit
            self.systemImage = systemImage
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: VoiceourMetrics.Space.sm) {
                    if let systemImage {
                        Kit.IconTile(systemImage: systemImage, size: .mini)
                    }
                    Text(label)
                        .roleStyle(.meta)
                        .lineLimit(2)
                }
                Spacer(minLength: VoiceourMetrics.Space.sm)
                HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.xs) {
                    Text(value)
                        .roleStyle(.figure)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .allowsTightening(true)
                    if let unit {
                        Text(unit)
                            .roleStyle(.body)
                            .foregroundStyle(theme.text2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(unit.map { "\(value) \($0)" } ?? value)
        }
    }

    /// A smaller figure: the value in the small figure face over what it counts. Three share
    /// a row where a stat tile would crowd it. The value scales rather than wraps, so "400
    /// days" stays one figure in a narrow column. One accessibility element, named by the
    /// label and valued by the figure.
    struct Figure: View {
        private let value: String
        private let label: String

        init(value: String, label: String) {
            self.value = value
            self.label = label
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
                Text(value)
                    .roleStyle(.figureSmall)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .roleStyle(.meta)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(value)
        }
    }

    /// One ranked share: a leading app icon, the name over a share meter in the accent, and
    /// the figure over what it counts.
    ///
    /// The figure column takes its width first, so a long app name truncates instead of the
    /// count. One accessibility element, named by `title` and valued by
    /// `accessibilityValue`, which spells out what the shortened caption abbreviates; the
    /// meter is silent because the value already states it.
    struct MeterRow<Leading: View>: View {
        private let title: String
        private let fraction: Double
        private let value: String
        private let caption: String
        private let accessibilityValue: String
        private let leading: Leading

        init(
            title: String,
            fraction: Double,
            value: String,
            caption: String,
            accessibilityValue: String,
            @ViewBuilder leading: () -> Leading
        ) {
            self.title = title
            self.fraction = fraction
            self.value = value
            self.caption = caption
            self.accessibilityValue = accessibilityValue
            self.leading = leading()
        }

        var body: some View {
            HStack(alignment: .center, spacing: VoiceourMetrics.Space.md) {
                leading

                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                    Text(title)
                        .roleStyle(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Kit.Meter(fraction: fraction)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: VoiceourMetrics.Space.hair) {
                    Text(value)
                        .roleStyle(.figureSmall)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(caption)
                        .roleStyle(.meta)
                        .lineLimit(1)
                }
                .layoutPriority(1)
            }
            .frame(minHeight: Kit.Metrics.rowHeightOne)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
        }
    }
}
