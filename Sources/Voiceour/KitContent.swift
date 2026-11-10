import AppKit
import SwiftUI

extension Kit {
    /// A state word in a tinted capsule: PASTED, COPY ONLY, NOT SENT, NOTE, READY.
    ///
    /// A mark annotates; it is never pressed, so it has a fill and no rim — fill plus
    /// rim is what says "you can press this". The word is the carrier, set uppercase
    /// in the micro voice; the hue only repeats it, in the app palette's state colours
    /// (mint success, amber caution, crimson critical, cyan info and live), and
    /// Differentiate Without Color adds the tone's symbol as a second carrier for a
    /// reader who cannot rely on the hue. Increase Contrast strengthens the fill,
    /// which is the only thing bounding the mark.
    ///
    /// Inside a switched-off group a mark keeps its shape, word and symbol and loses
    /// only its colour: the state is still true, the group it grades is simply not in
    /// effect, and at full strength a disabled block would be the brightest thing on
    /// the pane.
    ///
    /// To accessibility it is the word as shown, as plain text: one static text whose
    /// value is the word, so a reader hears what the eye reads and a flow finds the
    /// state where it looks. Never selectable: a selectable wrapper's value lags the
    /// state it reports.
    struct Mark: View {
        enum Tone {
            case neutral
            case success
            case caution
            case critical
            case info
            case live

            /// The tone a readout's severity reads as.
            init(_ severity: ConsoleReadout.Severity) {
                switch severity {
                case .neutral: self = .neutral
                case .ok: self = .success
                case .warn: self = .caution
                case .crit: self = .critical
                }
            }

            /// The tone's state colour; nil for neutral, which takes the text ladder.
            var hue: Color? {
                switch self {
                case .neutral: nil
                case .success: VoiceourPalette.Signal.mint
                case .caution: VoiceourPalette.Signal.amber
                case .critical: VoiceourPalette.Signal.crimson
                case .info, .live: VoiceourPalette.Signal.cyan
                }
            }

            /// The second carrier Differentiate Without Color adds.
            var symbol: String? {
                switch self {
                case .neutral: nil
                case .success: "checkmark"
                case .caution: "exclamationmark.triangle.fill"
                case .critical: "xmark.octagon.fill"
                case .info: "info.circle.fill"
                case .live: "circle.fill"
                }
            }
        }

        /// Compact marks annotate rows and readouts; a regular mark heads a block.
        enum Size {
            case compact
            case regular
        }

        private let word: String
        private let tone: Tone
        private let size: Size
        private var a11y = A11y()
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.surfaceGround) private var inheritedGround

        init(_ word: String, tone: Tone = .neutral, size: Size = .compact) {
            self.word = word
            self.tone = tone
            self.size = size
        }

        var body: some View {
            let shown = word.uppercased()
            let tint = self.foreground
            let plate = self.fill
            HStack(spacing: VoiceourMetrics.Space.xs) {
                if a11y.differentiateWithoutColor, let symbol = tone.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(shown)
                    .roleStyle(.micro)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(
                .horizontal,
                size == .compact
                    ? VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair : VoiceourMetrics.Chip.horizontal
            )
            .frame(height: size == .compact ? Kit.Metrics.markHeight : Kit.Metrics.markHeightRegular)
            .background(plate, in: Capsule())
            .environment(\.surfaceGround, inheritedGround.painting(plate))
            .fixedSize()
            .textSelection(.disabled)
            // Plain text to accessibility, as the word reads on screen: alone it is one static
            // text whose value is the word, and inside a row that combines its children it joins
            // the row's label like the row's other text instead of becoming the row's value.
            .accessibilityRepresentation {
                Text(shown).textSelection(.disabled)
            }
        }

        private var foreground: Color {
            guard isEnabled else { return a11y.textLow }
            return tone.hue ?? a11y.textMid
        }

        private var fill: Color {
            let increased = a11y.contrast == .increased
            guard isEnabled, let hue = tone.hue else {
                return increased ? VoiceourPalette.Plate.hover : VoiceourPalette.Plate.rest
            }
            return hue.opacity(increased ? 0.18 : 0.08)
        }
    }

    /// Home's glyph disc: an SF Symbol in the signal green on a faint plate with a
    /// hairline ring. How a figure, a list row or a command shows what it is at a
    /// glance, in the one colour the console signals with.
    ///
    /// Decoration: the element beside it names the thing, so the disc is hidden from
    /// VoiceOver. Reduce Transparency strengthens the ring, which then draws the edge
    /// the faint plate no longer can.
    struct Badge: View {
        enum Size {
            /// A figure's disc, the Control scale's 32.
            case regular
            /// A list row's disc.
            case small
            /// A sidebar item's or a menu command's disc.
            case mini

            var diameter: CGFloat {
                switch self {
                case .regular: VoiceourMetrics.Control.medium
                case .small: 22
                case .mini: 18
                }
            }

            var glyph: CGFloat {
                switch self {
                case .regular: VoiceourMetrics.Icon.row
                case .small: 10
                case .mini: 9
                }
            }
        }

        private let systemImage: String
        private let size: Size

        init(systemImage: String, size: Size = .regular) {
            self.systemImage = systemImage
            self.size = size
        }

        var body: some View {
            Image(systemName: systemImage)
                .font(.system(size: size.glyph, weight: .semibold))
                .foregroundStyle(Kit.Colors.signal)
                .modifier(BadgeDisc(diameter: size.diameter))
                .accessibilityHidden(true)
        }
    }

    /// A destination app's badge: its own icon while this Mac has the app, else the
    /// first letter of its name in a ``Kit/Badge``-style disc.
    ///
    /// The icon is bare at full badge size: a macOS icon already carries its own
    /// squircle and edge, so a plate behind it would be a second rounded shape around
    /// a rounded shape. The letter keeps the disc, because a letter has no shape of
    /// its own. The letter stays the answer for a bundle id LaunchServices cannot
    /// resolve — a row can outlive the app that produced it — and goldens stay
    /// machine-independent because the harness pins the catalog through
    /// `RenderOverrides.installedApps`. Hidden from VoiceOver: the row names the app.
    struct AppBadge: View {
        private let name: String
        private let icon: NSImage?

        init(name: String, icon: NSImage?) {
            self.name = name
            self.icon = icon
        }

        var body: some View {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: VoiceourMetrics.Control.medium, height: VoiceourMetrics.Control.medium)
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .roleStyle(.label)
                        .foregroundStyle(Kit.Colors.signal)
                        .modifier(BadgeDisc(diameter: VoiceourMetrics.Control.medium))
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// One figure of a day or a thread: a label, the value, and what the value counts,
    /// on a small island tile with the value in Home's mono figure face.
    ///
    /// The tile is an island without the neon rim or the shadows: tiles sit in rows
    /// inside a page's island, and a rim and a shadow per tile would light the row
    /// brighter than the island that holds it.
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
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                Text(label)
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
                    .lineLimit(1)
                Text(value)
                    .roleStyle(.tileValue)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail ?? " ")
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(VoiceourMetrics.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kitIslandSurface(cornerRadius: Kit.Metrics.cardRadius, glow: false, elevated: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(detail.map { "\(value) \u{00B7} \($0)" } ?? value)
            // A group publishes no value; static text does, so a reader and a flow both
            // find the figure where the label names it.
            .accessibilityAddTraits(.isStaticText)
        }
    }

    /// One labelled fact on a page: Target, Agent, Timings, Session, Folder. The label
    /// takes a fixed column so a page's facts align into a table.
    struct Fact<Value: View>: View {
        private let label: String
        private let value: Value
        private var a11y = A11y()

        init(_ label: String, @ViewBuilder value: () -> Value) {
            self.label = label
            self.value = value()
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.md) {
                Text(label)
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
                    .frame(width: Kit.Metrics.factLabel, alignment: .leading)
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        }
    }

    /// A destination app as its icon and name, the icon only while this Mac has the
    /// app. The name takes the type of the line it sits in.
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
}

/// The disc ``Kit/Badge`` and ``Kit/AppBadge``'s letter sit on: `Plate.rest` with a
/// `Line.rule` ring, the ring at `lineEdge` under Reduce Transparency. It declares the
/// plate as the ground under the letter.
private struct BadgeDisc: ViewModifier {
    let diameter: CGFloat
    private var a11y = A11y()
    @Environment(\.surfaceGround) private var inheritedGround

    init(diameter: CGFloat) {
        self.diameter = diameter
    }

    func body(content: Content) -> some View {
        content
            .frame(width: diameter, height: diameter)
            .background {
                Circle().fill(VoiceourPalette.Plate.rest)
            }
            .overlay {
                Circle().strokeBorder(
                    a11y.reduceTransparency ? a11y.lineEdge : VoiceourPalette.Line.rule,
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                )
            }
            .environment(\.surfaceGround, inheritedGround.painting(VoiceourPalette.Plate.rest))
    }
}
