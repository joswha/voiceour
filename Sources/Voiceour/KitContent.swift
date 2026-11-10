import AppKit
import SwiftUI

extension Kit {
    /// A state word in a tinted capsule: PASTED, COPY ONLY, NOT SENT, NOTE, IDEA.
    ///
    /// A mark annotates; it is never pressed, so it has a fill and no rim. The word is
    /// the carrier, the colour only repeats it, and Differentiate Without Color adds the
    /// tone's symbol as a second carrier for a reader who cannot rely on the hue.
    struct Mark: View {
        enum Tone {
            case neutral
            case success
            case caution
            case critical
            case info

            var color: Color {
                switch self {
                case .neutral: .secondary
                case .success: .green
                case .caution: .orange
                case .critical: .red
                case .info: .blue
                }
            }

            var symbol: String? {
                switch self {
                case .neutral: nil
                case .success: "checkmark"
                case .caution: "exclamationmark.triangle.fill"
                case .critical: "xmark.octagon.fill"
                case .info: "info.circle.fill"
                }
            }
        }

        private let word: String
        private let tone: Tone
        private var a11y = A11y()

        init(_ word: String, tone: Tone = .neutral) {
            self.word = word
            self.tone = tone
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.hair + 1) {
                if a11y.differentiateWithoutColor, let symbol = tone.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(word)
                    .font(Kit.Fonts.mark)
                    .tracking(0.3)
                    .lineLimit(1)
            }
            .foregroundStyle(tone.color)
            .padding(.horizontal, VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair)
            .frame(height: Kit.Metrics.markHeight)
            .background(tone.color.opacity(a11y.contrast == .increased ? 0.26 : 0.14), in: Capsule())
            .fixedSize()
            // A state word, so never a selectable text wrapper whose value lags the state.
            .textSelection(.disabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(word)
        }
    }

    /// One figure of a day or a thread: a label, the value, and what the value counts.
    ///
    /// VoiceOver hears the label as the name and the value with its detail as the
    /// value, "Entries" and "3 · 37 words", the reading the tile shows.
    struct MetricTile: View {
        private let label: String
        private let value: String
        private let detail: String?
        private var a11y = A11y()

        init(_ label: String, value: String, detail: String? = nil) {
            self.label = label
            self.value = value
            self.detail = detail
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.cardRadius, style: .continuous)
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                Text(label)
                    .font(Kit.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(Kit.Fonts.metricValue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail ?? " ")
                    .font(Kit.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(VoiceourMetrics.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Kit.Colors.cardFill(a11y), in: shape)
            .overlay(shape.stroke(Kit.Colors.rule(a11y), lineWidth: Kit.Colors.hairline(a11y)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(detail.map { "\(value) \u{00B7} \($0)" } ?? value)
            // A group publishes no value; static text does, so a reader and a flow both
            // find the figure where the label names it.
            .accessibilityAddTraits(.isStaticText)
        }
    }

    /// One labelled fact on a page: Target, Agent, Timings, Session, Folder.
    struct Fact<Value: View>: View {
        private let label: String
        private let value: Value

        init(_ label: String, @ViewBuilder value: () -> Value) {
            self.label = label
            self.value = value()
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.md) {
                Text(label)
                    .font(Kit.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .frame(width: Kit.Metrics.factLabel, alignment: .leading)
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        }
    }

    /// A destination app as its icon and name, the icon only while this Mac has the app.
    struct AppLabel: View {
        private let name: String
        private let icon: NSImage?

        init(_ name: String, icon: NSImage?) {
            self.name = name
            self.icon = icon
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.xs + 1) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: VoiceourMetrics.Icon.row + 1, height: VoiceourMetrics.Icon.row + 1)
                        .accessibilityHidden(true)
                }
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// A small tinted tile with a white symbol: how a list tells an agent session, a
    /// note or a day from an app at a glance.
    struct Glyph: View {
        private let systemImage: String
        private let tint: Color
        private let size: CGFloat

        init(systemImage: String, tint: Color, size: CGFloat = 22) {
            self.systemImage = systemImage
            self.tint = tint
            self.size = size
        }

        var body: some View {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
