import SwiftUI
import VoiceCore

/// The dark glass pane every Home section sits on.
///
/// Deliberately app-drawn rather than `.glassEffect` per island. The console
/// window already has a system Liquid Glass *ground* (``ConsoleGlassGround``),
/// and element glass cannot sample other glass — a glass island on a glass
/// window is two blurs arguing. Painting the island keeps one system material in
/// the window, keeps the console's no-macOS-26-branch invariant, and keeps the
/// offscreen harness able to prove the island's structure, which it cannot do
/// for either real glass path.
///
/// Fixed dark in both system appearances. The island is a self-contained
/// surface with its own text ladder; letting it follow the window's appearance
/// would put `Text.high` on a light plate.
struct HomeIsland<Content: View>: View {
    private var a11y = A11y()
    @Environment(\.surfaceGround) private var inheritedGround

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VoiceourMetrics.Radius.card, style: .continuous)
    }

    var body: some View {
        content
            .padding(VoiceourMetrics.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { surface }
            // The contrast lint resolves text against the stack painted beneath
            // it, so the island has to declare its own fills. Only the opaque
            // ones: `glassTint` is a gradient, and reporting its lightest stop
            // would understate the ground under text near the island's top edge.
            .environment(
                \.surfaceGround,
                a11y.reduceTransparency
                    ? SurfaceGround(VoiceourPalette.Ink.surface)
                    : inheritedGround
                        .painting(VoiceourPalette.Ink.void.opacity(0.55))
                        .painting(VoiceourPalette.Ink.pane)
            )
    }

    @ViewBuilder
    private var surface: some View {
        if a11y.reduceTransparency {
            // No tint, no specular gradient, no glow: with the material gone
            // there is nothing for a highlight to be a highlight *of*, and a
            // plus-lighter edge over an opaque fill is just a bright line.
            shape
                .fill(VoiceourPalette.Ink.surface)
                .overlay {
                    shape.strokeBorder(
                        a11y.lineEdge,
                        lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                    )
                }
        } else {
            ZStack {
                shape.fill(VoiceourPalette.Ink.void.opacity(0.55))
                shape.fill(VoiceourPalette.Ink.pane)
                shape.fill(VoiceourPalette.glassTint)
                // The neon rim. A drop shadow cannot do this job: the fills
                // above are translucent, so a green shadow *behind* the stack
                // showed through the pane and tinted the whole island — and
                // spilled far enough into the window ground to wash the page
                // green. A blurred stroke lights only the edge.
                shape
                    .strokeBorder(VoiceourPalette.Alien.bloomGlow, lineWidth: 1.5)
                    .blur(radius: 2.5)
                    .blendMode(.plusLighter)
                shape
                    .strokeBorder(
                        VoiceourPalette.specularRim,
                        lineWidth: a11y.contrast == .increased ? 1 : VoiceourMetrics.Stroke.specular
                    )
                    .blendMode(.plusLighter)
                RoundedRectangle(
                    cornerRadius: VoiceourMetrics.Radius.nested(
                        VoiceourMetrics.Radius.card,
                        inset: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                    ),
                    style: .continuous
                )
                .strokeBorder(
                    VoiceourPalette.Ink.rimDark,
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                )
                .padding(VoiceourMetrics.Stroke.hairline(a11y.contrast))
            }
            .shadow(
                color: VoiceourMetrics.Shadow.overlayOuter.color,
                radius: VoiceourMetrics.Shadow.overlayOuter.radius,
                y: VoiceourMetrics.Shadow.overlayOuter.y
            )
            .shadow(
                color: VoiceourMetrics.Shadow.overlayInner.color,
                radius: VoiceourMetrics.Shadow.overlayInner.radius,
                y: VoiceourMetrics.Shadow.overlayInner.y
            )
        }
    }
}

/// One lifetime figure: an icon, the number, its unit, and what it counts.
///
/// The whole tile is a single accessibility element. Read as four separate
/// nodes, VoiceOver announced "clock", "4", "hr", "32", "min", "Total dictation
/// time" — five stops for one fact.
struct HomeStatTile: View {
    private var a11y = A11y()

    let icon: String
    let value: String
    let unit: String?
    let caption: String

    init(icon: String, value: String, unit: String? = nil, caption: String) {
        self.icon = icon
        self.value = value
        self.unit = unit
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            glyph
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

    private var glyph: some View {
        Image(systemName: icon)
            .font(.system(size: VoiceourMetrics.Icon.row, weight: .semibold))
            .foregroundStyle(VoiceourPalette.Alien.bloom)
            .frame(width: VoiceourMetrics.Control.medium, height: VoiceourMetrics.Control.medium)
            .background {
                Circle().fill(VoiceourPalette.Plate.rest)
            }
            .overlay {
                Circle().strokeBorder(
                    a11y.reduceTransparency ? a11y.lineEdge : VoiceourPalette.Line.rule,
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                )
            }
            .accessibilityHidden(true)
    }
}

/// One streak figure. Smaller than a tile: three of these share a row, and the
/// number is the whole payload.
struct HomeStreakStat: View {
    private var a11y = A11y()

    let value: String
    let label: String

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

/// The deterministic stand-in for an app icon: its display name's first letter
/// on the island's own plate.
///
/// Never `NSWorkspace.icon(forFile:)`. A real icon would make Home's goldens
/// depend on which apps the rendering Mac has installed, and the offscreen
/// harness resolves names from persisted strings precisely so it does not have
/// to ask the workspace anything.
struct AppMonogram: View {
    private var a11y = A11y()

    let label: String

    init(label: String) {
        self.label = label
    }

    var body: some View {
        Text(String(label.prefix(1)).uppercased())
            .roleStyle(.label)
            .foregroundStyle(VoiceourPalette.Alien.bloom)
            .frame(width: VoiceourMetrics.Control.medium, height: VoiceourMetrics.Control.medium)
            .background {
                Circle().fill(VoiceourPalette.Plate.rest)
            }
            .overlay {
                Circle().strokeBorder(
                    a11y.reduceTransparency ? a11y.lineEdge : VoiceourPalette.Line.rule,
                    lineWidth: VoiceourMetrics.Stroke.hairline(a11y.contrast)
                )
            }
            .accessibilityHidden(true)
    }
}

/// One app's rank on Home: its monogram, its name over a share bar, and its
/// counts.
///
/// One accessibility element for the same reason `HomeStatTile` is: read as
/// parts, VoiceOver stops on the monogram, the name, the number and the unit
/// for a single fact.
struct HomeAppRow: View {
    private var a11y = A11y()

    let figure: DictationAppFigure

    init(figure: DictationAppFigure) {
        self.figure = figure
    }

    private var name: String {
        AppDisplayName.label(bundleId: figure.bundleId, name: figure.name)
    }

    private var counts: String {
        "sessions · \(StatsFormatting.compactCount(figure.words)) words"
    }

    var body: some View {
        HStack(alignment: .center, spacing: VoiceourMetrics.Space.sm) {
            AppMonogram(label: name)

            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                Text(name)
                    .roleStyle(.label)
                    .lineLimit(1)
                shareBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: VoiceourMetrics.Space.xs) {
                Text(String(figure.sessions))
                    .roleStyle(.tileValue)
                    .monospacedDigit()
                Text(counts)
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue("\(figure.sessions) sessions, \(figure.words) words")
    }

    /// Magnitude encoded by length, so Differentiate Without Color needs no
    /// branch here: the bar says the same thing with the colour removed.
    private var shareBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(VoiceourPalette.Plate.rest)
            GeometryReader { proxy in
                Capsule()
                    .fill(VoiceourPalette.Alien.bloom)
                    .frame(width: proxy.size.width * figure.share)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Decorative dot field behind the islands, so the page reads as a surface
/// rather than as forms floating in the window ground.
///
/// One `Canvas`, not a grid of views: at a 24pt pitch a full console page is
/// ~2,000 dots, and 2,000 `Circle`s is 2,000 layout participants and 2,000
/// accessibility nodes for something nobody can address. Skipped outright under
/// Reduce Transparency, which asks for fewer decorative layers, not more.
struct HomeDotGrid: View {
    private var a11y = A11y()

    private static let pitch: CGFloat = 24
    private static let diameter: CGFloat = 2

    var body: some View {
        if a11y.reduceTransparency {
            Color.clear
        } else {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let dot = Path(
                    ellipseIn: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
                )
                let shading = GraphicsContext.Shading.color(Color.white.opacity(0.03))
                var y = Self.pitch
                while y < size.height {
                    var x = Self.pitch
                    while x < size.width {
                        context.translateBy(x: x, y: y)
                        context.fill(dot, with: shading)
                        context.translateBy(x: -x, y: -y)
                        x += Self.pitch
                    }
                    y += Self.pitch
                }
            }
            .accessibilityHidden(true)
        }
    }
}
