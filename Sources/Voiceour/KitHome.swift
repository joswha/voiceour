import SwiftUI

extension Kit {
    /// The one oversized line a page may open with: 64 pt thin monospaced, Home's
    /// greeting. A heading to VoiceOver, so a reader landing on the page hears where
    /// they are.
    struct Hero: View {
        private let text: String

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Text(text)
                .roleStyle(.heroMetric)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// One lifetime figure: a glyph disc, the number, its unit, and what it counts.
    ///
    /// The whole tile is a single accessibility element, named by the caption and
    /// valued by the number and unit. Read as separate nodes, VoiceOver announced
    /// "clock", "4", "hr", "32", "min", "Total dictation time" — five stops for one
    /// fact.
    struct StatTile: View {
        private let systemImage: String
        private let value: String
        private let unit: String?
        private let caption: String
        private var a11y = A11y()

        init(systemImage: String, value: String, unit: String?, caption: String) {
            self.systemImage = systemImage
            self.value = value
            self.unit = unit
            self.caption = caption
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                Kit.Badge(systemImage: systemImage)
                HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.xs) {
                    Text(value)
                        .roleStyle(.metric)
                        .monospacedDigit()
                    if let unit {
                        Text(unit)
                            .roleStyle(.label)
                            .foregroundStyle(a11y.textMid)
                    }
                }
                Text(caption)
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(caption)
            .accessibilityValue(unit.map { "\(value) \($0)" } ?? value)
        }
    }

    /// A smaller figure: the value in the 20 pt mono figure face over what it counts.
    /// Three share a row where a tile's disc and 32 pt number would crowd it, and the
    /// number is the whole payload. One accessibility element, named by the label and
    /// valued by the figure.
    struct Figure: View {
        private let value: String
        private let label: String
        private var a11y = A11y()

        init(value: String, label: String) {
            self.value = value
            self.label = label
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                Text(value)
                    .roleStyle(.tileValue)
                    .monospacedDigit()
                Text(label)
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(value)
        }
    }

    /// One ranked share: a leading badge, the name over a share bar in the signal
    /// green, and the figure over what it counts.
    ///
    /// One accessibility element, named by `title` and valued by
    /// `accessibilityValue`, which spells out what the shortened caption abbreviates.
    /// Read as parts, VoiceOver stopped on the icon, the name, the number and the unit
    /// for a single fact; the bar is silent because the value already states it.
    struct MeterRow<Leading: View>: View {
        private let title: String
        private let fraction: Double
        private let value: String
        private let caption: String
        private let accessibilityValue: String
        private let leading: Leading
        private var a11y = A11y()

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
            HStack(alignment: .center, spacing: VoiceourMetrics.Space.sm) {
                leading

                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    Text(title)
                        .roleStyle(.label)
                        .lineLimit(1)
                    MeterBar(fraction: fraction, style: .share)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: VoiceourMetrics.Space.xs) {
                    Text(value)
                        .roleStyle(.tileValue)
                        .monospacedDigit()
                    Text(caption)
                        .roleStyle(.caption)
                        .foregroundStyle(a11y.textMid)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
        }
    }
}
