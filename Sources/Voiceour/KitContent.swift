import AppKit
import SwiftUI

extension Kit {
    /// A state word in a capsule: "Pasted", "Copy only", "Not sent", "Idea".
    ///
    /// The word carries the state; the hue repeats it, and a glyph adds a third channel where
    /// hue alone would fail a reader: always for critical, and for every tone under
    /// Differentiate Without Color. Text shows exactly as given, so callers pass sentence case
    /// (``sentence(_:)`` converts a stored uppercase word).
    ///
    /// A pill annotates and is never pressed, so it has a fill and no border; Increase
    /// Contrast adds a 1 px border in the text colour because the wash alone no longer bounds
    /// it clearly enough. A long word truncates at its tail instead of pushing its row's other
    /// text out: the pill takes its width first, then yields when the line runs out.
    ///
    /// Inside a disabled group a pill keeps its word and glyph and loses only its hue, because
    /// the state is still true; the group it grades is simply not in effect.
    ///
    /// To accessibility it is plain text, so inside a row that combines its children it joins
    /// the row's label instead of becoming the row's value.
    struct Pill: View {
        enum Tone {
            case neutral
            case accent
            case success
            case caution
            case critical
            case info
        }

        enum Size {
            case small
            case regular
        }

        private let text: String
        private let tone: Tone
        private let size: Size
        private let systemImage: String?
        private var a11y = A11y()
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.surfaceGround) private var inheritedGround

        init(_ text: String, tone: Tone = .neutral, size: Size = .small, systemImage: String? = nil) {
            self.text = text
            self.tone = tone
            self.size = size
            self.systemImage = systemImage
        }

        /// A stored uppercase word in the case a pill shows: the first letter upper, the rest
        /// lower ("COPY-ONLY RISK" → "Copy-only risk").
        static func sentence(_ upper: String) -> String {
            guard let first = upper.first else { return upper }
            return String(first).uppercased() + upper.dropFirst().lowercased()
        }

        var body: some View {
            let colors = self.colors
            HStack(spacing: VoiceourMetrics.Space.xs) {
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: size == .small ? 9 : 10, weight: .semibold))
                        .foregroundStyle(colors.text)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .roleStyle(.label)
                    .foregroundStyle(colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, VoiceourMetrics.Space.sm)
            .frame(height: size == .small ? Kit.Metrics.pillHeightSmall : Kit.Metrics.pillHeightRegular)
            .background(colors.wash, in: Capsule())
            .overlay {
                if theme.isIncreasedContrast {
                    Capsule().strokeBorder(colors.text, lineWidth: 1)
                }
            }
            .environment(\.surfaceGround, inheritedGround.painting(colors.wash))
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .textSelection(.disabled)
            .accessibilityRepresentation {
                Text(text).textSelection(.disabled)
            }
        }

        /// The caller's glyph, else the tone's own: always for critical, for every stateful
        /// tone under Differentiate Without Color.
        private var glyph: String? {
            if let systemImage { return systemImage }
            if tone == .critical || a11y.differentiateWithoutColor { return tone.symbol }
            return nil
        }

        private var colors: (text: Color, wash: Color) {
            guard isEnabled else { return (theme.text2, theme.hover) }
            return switch tone {
            case .neutral: (theme.text2, theme.hover)
            case .accent: (theme.accentText, theme.accentWash)
            case .success: (theme.success.text, theme.success.wash)
            case .caution: (theme.caution.text, theme.caution.wash)
            case .critical: (theme.critical.text, theme.critical.wash)
            case .info: (theme.info.text, theme.info.wash)
            }
        }
    }

    /// A rounded square holding an SF Symbol in the accent: how a figure, a row or a command
    /// shows what it is at a glance. Decoration: the element beside it names the thing, so the
    /// tile is hidden from VoiceOver.
    struct IconTile: View {
        enum Size {
            /// A figure's or a card heading's tile, 28 pt.
            case regular
            /// A list row's tile, 20 pt.
            case small
            /// A stat label's, a sidebar's or a menu command's tile, 16 pt.
            case mini

            var side: CGFloat {
                switch self {
                case .regular: Kit.Metrics.iconTileRegular
                case .small: Kit.Metrics.iconTileSmall
                case .mini: Kit.Metrics.iconTileMini
                }
            }

            var radius: CGFloat {
                switch self {
                case .regular: 7
                case .small: 5
                case .mini: 4
                }
            }

            var glyph: CGFloat {
                switch self {
                case .regular: 14
                case .small: 11
                case .mini: 9
                }
            }
        }

        private let systemImage: String
        private let size: Size
        @Environment(\.theme) private var theme

        init(systemImage: String, size: Size = .regular) {
            self.systemImage = systemImage
            self.size = size
        }

        var body: some View {
            Image(systemName: systemImage)
                .font(.system(size: size.glyph, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(width: size.side, height: size.side)
                .background(
                    theme.accentWash,
                    in: RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                )
                .accessibilityHidden(true)
        }
    }

    /// A destination app's icon while this Mac has the app, else the first character of its
    /// name in an ``IconTile``-like square.
    ///
    /// The icon is bare: a macOS icon already carries its own squircle and edge. The monogram
    /// stays the answer for a bundle id LaunchServices cannot resolve — a row can outlive the
    /// app that produced it — and goldens stay machine-independent because the harness pins
    /// the catalog through `RenderOverrides.installedApps`. The monogram is the name's first
    /// grapheme, so an emoji, a combining sequence or a right-to-left letter stays whole; a
    /// blank name shows a generic app glyph. Hidden from VoiceOver: the row names the app.
    struct AppIcon: View {
        private let name: String
        private let icon: NSImage?
        private let size: CGFloat
        @Environment(\.theme) private var theme
        @Environment(\.surfaceGround) private var inheritedGround

        init(name: String, icon: NSImage?, size: CGFloat = 20) {
            self.name = name
            self.icon = icon
            self.size = size
        }

        var body: some View {
            SwiftUI.Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size, height: size)
                } else {
                    monogram
                        .frame(width: size, height: size)
                        .background(
                            theme.accentWash,
                            in: RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                        )
                        .environment(\.surfaceGround, inheritedGround.painting(theme.accentWash))
                }
            }
            .accessibilityHidden(true)
        }

        @ViewBuilder
        private var monogram: some View {
            if let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(first).uppercased())
                    .roleStyle(size >= Kit.Metrics.iconTileRegular ? .rowTitle : .label)
                    .foregroundStyle(theme.accentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size / 2, weight: .semibold))
                    .foregroundStyle(theme.accentText)
            }
        }
    }

    /// A destination app as its icon and name, the icon only while this Mac has the app. The
    /// name takes the type and colour of the line it sits in (a preview row's meta line).
    struct AppLabel: View {
        private let name: String
        private let icon: NSImage?

        init(_ name: String, icon: NSImage?) {
            self.name = name
            self.icon = icon
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.xs) {
                if icon != nil {
                    AppIcon(name: name, icon: icon, size: 14)
                }
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// A 4 pt capsule meter: a share of the busiest app, or a model download.
    ///
    /// Magnitude is length, so neither Differentiate Without Color nor Increase Contrast
    /// needs a branch on the fill. A non-zero share keeps at least a dot so it never reads as
    /// none. The accent meter is silent — ``MeterRow`` states its counts — while the download
    /// meter announces its own percentage, because the sentence beside it does not carry the
    /// number. Determinate only: the offscreen harness cannot capture a perpetual fill.
    struct Meter: View {
        enum Style {
            /// A share, in the accent.
            case accent
            /// Model acquisition, in the info status hue.
            case download
        }

        private let fraction: Double
        private let style: Style
        private var a11y = A11y()
        @Environment(\.theme) private var theme

        init(fraction: Double, style: Style = .accent) {
            self.fraction = fraction
            self.style = style
        }

        /// NaN and −∞ read as zero rather than trapping (`Int(Double.nan * 100)` crashes); +∞
        /// saturates at full.
        static func clamped(_ fraction: Double) -> Double {
            guard fraction.isFinite else { return fraction > 0 ? 1 : 0 }
            return min(max(fraction, 0), 1)
        }

        var body: some View {
            let value = Self.clamped(fraction)
            Capsule()
                .fill(theme.meterTrack)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(style == .accent ? theme.accent : theme.info.text)
                            .frame(width: value > 0 ? max(proxy.size.width * value, Self.height) : 0)
                    }
                }
                .frame(height: Self.height)
                .frame(maxWidth: .infinity)
                .animation(Kit.Motion.standard(a11y), value: value)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Model download")
                .accessibilityValue("\(Int(value * 100))%")
                // A generic element publishes no value; static text does, so VoiceOver
                // reads the percentage the label names.
                .accessibilityAddTraits(.isStaticText)
                .accessibilityHidden(style == .accent)
        }

        private static let height: CGFloat = 4
    }

    /// One row of a page's properties grid: Agent, Folder, Timings. The label takes a fixed
    /// 120 pt column so a page's properties align into a table; the value reads in `body`
    /// unless the caller styles it (a path in `code`, middle-truncated).
    struct Property<Value: View>: View {
        private let label: String
        private let value: Value
        @Environment(\.theme) private var theme

        init(_ label: String, @ViewBuilder value: () -> Value) {
            self.label = label
            self.value = value()
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.md) {
                Text(label)
                    .roleStyle(.meta)
                    .lineLimit(2)
                    .frame(width: Kit.Metrics.propertyLabelWidth, alignment: .leading)
                value
                    .roleStyle(.body, color: theme.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        }
    }

    /// A labelled fact on a page — Target, Agent, Timings, Session, Folder — drawn as a
    /// ``Property`` row so facts and properties align into one table.
    struct Fact<Value: View>: View {
        private let label: String
        private let value: Value

        init(_ label: String, @ViewBuilder value: () -> Value) {
            self.label = label
            self.value = value()
        }

        var body: some View {
            Property(label) { value }
        }
    }

    /// A key as it reads on the keyboard: "fn", "⌘", "Esc". `micro` on the hover plate with a
    /// 1 px border (the strong border under Increase Contrast).
    struct KeyCap: View {
        private let text: String
        @Environment(\.theme) private var theme
        @Environment(\.surfaceGround) private var inheritedGround

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            Text(text)
                .roleStyle(.micro)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(minWidth: Kit.Metrics.glyphControl, minHeight: Kit.Metrics.glyphControl)
                .background(theme.hover, in: shape)
                .environment(\.surfaceGround, inheritedGround.painting(theme.hover))
                .overlay {
                    shape.strokeBorder(theme.isIncreasedContrast ? theme.borderStrong : theme.border, lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                // Static text, for the reason a meter is: a caller's value, such as the
                // menu's "Fn or Globe", reaches VoiceOver only through an element that
                // publishes one.
                .accessibilityAddTraits(.isStaticText)
        }
    }

    /// One figure of a day or a thread, as its own small card: the label, the value in the
    /// small figure face, and what the value counts. It paints its card because callers lay
    /// tiles straight into a grid.
    ///
    /// The value scales down to 60 % before it would truncate, so "12345 hr 59 min" stays
    /// whole in a two-up grid. VoiceOver hears the label as the name and the value with its
    /// detail as the value, "Entries" and "3 · 37 words", the reading the tile shows.
    struct MetricTile: View {
        private let label: String
        private let value: String
        private let detail: String?

        init(_ label: String, value: String, detail: String? = nil) {
            self.label = label
            self.value = value
            self.detail = detail
        }

        var body: some View {
            Kit.Card {
                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                    Text(label)
                        .roleStyle(.meta)
                        .lineLimit(1)
                    Text(value)
                        .roleStyle(.figureSmall)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    // A blank line when there is no detail keeps tiles in a row the same height.
                    Text(detail ?? " ")
                        .roleStyle(.meta)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(detail.map { "\(value) \u{00B7} \($0)" } ?? value)
            // A group publishes no value; static text does, so a reader and a flow both find
            // the figure where the label names it.
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

extension Kit.Pill.Tone {
    /// The tone a readout's severity reads as.
    init(_ severity: ConsoleReadout.Severity) {
        switch severity {
        case .neutral: self = .neutral
        case .ok: self = .success
        case .warn: self = .caution
        case .crit: self = .critical
        }
    }

    /// The glyph the tone adds when hue alone must not carry the state.
    fileprivate var symbol: String? {
        switch self {
        case .neutral: nil
        case .accent: "circle.fill"
        case .success: "checkmark"
        case .caution: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }
}
