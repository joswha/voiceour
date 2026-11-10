import SwiftUI

extension Kit {
    /// The kit's one path onto Liquid Glass, and the opaque surface that replaces it.
    ///
    /// Reduce Transparency asks for an opaque surface, so the material becomes the
    /// system's control fill with a drawn rim. Under that setting SwiftUI would frost
    /// the glass on its own; the kit draws the replacement itself because the setting
    /// also reaches it through the harness's pin, which SwiftUI cannot see, and an
    /// adaptation no golden can show is an adaptation nobody checks.
    struct GlassSurface<S: Shape>: ViewModifier {
        private let shape: S
        private let isInteractive: Bool
        private var a11y = A11y()

        init(shape: S, isInteractive: Bool) {
            self.shape = shape
            self.isInteractive = isInteractive
        }

        @ViewBuilder
        func body(content: Content) -> some View {
            if a11y.reduceTransparency {
                content
                    .background(Color(nsColor: .controlBackgroundColor), in: shape)
                    .overlay(shape.stroke(Kit.Colors.rule(a11y), lineWidth: Kit.Colors.hairline(a11y)))
            } else {
                content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
            }
        }
    }

    /// Glass controls that sit side by side, sampled as one group.
    ///
    /// Glass cannot sample other glass, so two neighbouring glass shapes in separate
    /// containers each refract a different backdrop and read as two materials. One
    /// container gives the group one sampling region, and lets a control that appears
    /// or leaves blend into its neighbours instead of popping.
    struct GlassGroup<Content: View>: View {
        private let spacing: CGFloat
        private let content: Content

        init(spacing: CGFloat = VoiceourMetrics.Space.sm, @ViewBuilder content: () -> Content) {
            self.spacing = spacing
            self.content = content()
        }

        var body: some View {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) {
                    content
                }
            }
        }
    }

    /// The floating panel the sidebar is: glass over the screen's ground, inset from
    /// the window's edges the way a macOS sidebar floats.
    struct GlassPanel<Content: View>: View {
        private let content: Content
        private var a11y = A11y()

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.panelRadius, style: .continuous)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(GlassSurface(shape: shape, isInteractive: false))
        }
    }

    /// The ground every console tab draws its content on: Home's near-black with
    /// Home's dot grid, fixed dark.
    ///
    /// Fixed dark because the islands, marks and rows are app-painted with a text
    /// ladder authored for near-black; following a light system appearance would put
    /// `Text.high` on a light plate. The dark colour scheme reaches everything inside,
    /// so native controls, glass and semantic colours render dark too, while the
    /// window's own title bar and tab strip keep the system's appearance. The ground
    /// ignores the safe area so it runs under the tab strip; the content does not.
    /// It declares `Ink.void` as the ground text outside an island is measured on.
    struct Screen<Content: View>: View {
        private let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    ZStack {
                        Kit.Colors.ground
                        DotGrid()
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                }
                .environment(\.surfaceGround, SurfaceGround(Kit.Colors.ground))
                .environment(\.colorScheme, .dark)
        }
    }

    /// Home's dark pane, the surface every group of content sits on: a heading at its
    /// top (``Kit/SectionTitle``) and what it heads under it.
    ///
    /// Painted rather than glass. The console window already has a system Liquid
    /// Glass ground, and glass cannot sample other glass — a glass island on a glass
    /// window is two blurs arguing. Painting keeps one system material in the window
    /// and keeps the offscreen harness able to prove the island's structure, which it
    /// cannot do for either real glass path. `glow: false` drops the neon rim alone,
    /// for an island that sits inside a glowing one or beside a dozen others.
    struct Island<Content: View>: View {
        private let padding: CGFloat
        private let glow: Bool
        private let content: Content

        init(
            padding: CGFloat = Kit.Metrics.islandPadding,
            glow: Bool = true,
            @ViewBuilder content: () -> Content
        ) {
            self.padding = padding
            self.glow = glow
            self.content = content()
        }

        var body: some View {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .kitIslandSurface(cornerRadius: Kit.Metrics.islandRadius, glow: glow, elevated: true)
        }
    }

    /// The painted stack an island is, as a background any kit surface can take: a
    /// metric tile, the menu's transcript well.
    ///
    /// Void at 55 %, `Ink.pane` and the `glassTint` gradient, then the neon rim, the
    /// white specular rim and an inner dark hairline; two soft shadows when
    /// `elevated`. Under Reduce Transparency it is flat `Ink.surface` with a drawn
    /// `lineEdge` rim: with the material gone there is nothing for a highlight to be a
    /// highlight of, and a plus-lighter edge over an opaque fill is just a bright line.
    ///
    /// It declares its opaque fills as the ground under its text. Only the opaque
    /// ones: `glassTint` is a gradient, and reporting its lightest stop would
    /// understate the ground under text near the top edge.
    struct IslandSurface: ViewModifier {
        private let cornerRadius: CGFloat
        private let glow: Bool
        private let elevated: Bool
        private var a11y = A11y()
        @Environment(\.surfaceGround) private var inheritedGround

        init(cornerRadius: CGFloat, glow: Bool, elevated: Bool) {
            self.cornerRadius = cornerRadius
            self.glow = glow
            self.elevated = elevated
        }

        func body(content: Content) -> some View {
            content
                .background { surface }
                .environment(
                    \.surfaceGround,
                    a11y.reduceTransparency
                        ? SurfaceGround(VoiceourPalette.Ink.surface)
                        : inheritedGround
                            .painting(VoiceourPalette.Ink.void.opacity(0.55))
                            .painting(VoiceourPalette.Ink.pane)
                )
        }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        }

        @ViewBuilder
        private var surface: some View {
            let hairline = VoiceourMetrics.Stroke.hairline(a11y.contrast)
            if a11y.reduceTransparency {
                shape
                    .fill(VoiceourPalette.Ink.surface)
                    .overlay {
                        shape.strokeBorder(a11y.lineEdge, lineWidth: hairline)
                    }
            } else {
                ZStack {
                    shape.fill(VoiceourPalette.Ink.void.opacity(0.55))
                    shape.fill(VoiceourPalette.Ink.pane)
                    shape.fill(VoiceourPalette.glassTint)
                    if glow {
                        // The neon rim. A drop shadow cannot do this job: the fills
                        // above are translucent, so a green shadow behind the stack
                        // shows through the pane, tints the whole island and spills
                        // into the ground. A blurred stroke lights only the edge.
                        shape
                            .strokeBorder(VoiceourPalette.Alien.bloomGlow, lineWidth: 1.5)
                            .blur(radius: 2.5)
                            .blendMode(.plusLighter)
                    }
                    shape
                        .strokeBorder(
                            VoiceourPalette.specularRim,
                            lineWidth: a11y.contrast == .increased ? 1 : VoiceourMetrics.Stroke.specular
                        )
                        .blendMode(.plusLighter)
                    RoundedRectangle(
                        cornerRadius: VoiceourMetrics.Radius.nested(cornerRadius, inset: hairline),
                        style: .continuous
                    )
                    .strokeBorder(VoiceourPalette.Ink.rimDark, lineWidth: hairline)
                    .padding(hairline)
                }
                .shadow(
                    color: elevated ? VoiceourMetrics.Shadow.homeOuter.color : .clear,
                    radius: VoiceourMetrics.Shadow.homeOuter.radius,
                    y: VoiceourMetrics.Shadow.homeOuter.y
                )
                .shadow(
                    color: elevated ? VoiceourMetrics.Shadow.homeInner.color : .clear,
                    radius: VoiceourMetrics.Shadow.homeInner.radius,
                    y: VoiceourMetrics.Shadow.homeInner.y
                )
            }
        }
    }

    /// A hairline between two regions, at the weight the kit's rims use.
    struct Rule: View {
        private let axis: Axis
        private var a11y = A11y()

        init(_ axis: Axis = .horizontal) {
            self.axis = axis
        }

        var body: some View {
            let thickness = Kit.Colors.hairline(a11y)
            Rectangle()
                .fill(Kit.Colors.rule(a11y))
                .frame(
                    width: axis == .vertical ? thickness : nil,
                    height: axis == .horizontal ? thickness : nil
                )
                .accessibilityHidden(true)
        }
    }

    /// A transient confirmation in a glass capsule: what just happened, in the same
    /// sentence VoiceOver hears. It names no control and holds none, so a press never
    /// lands on it by accident.
    struct Toast: View {
        private let message: String
        private let systemImage: String

        init(_ message: String, systemImage: String = "checkmark.circle.fill") {
            self.message = message
            self.systemImage = systemImage
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(VoiceourPalette.Signal.mint)
                    .accessibilityHidden(true)
                Text(message)
                    .roleStyle(.label)
                    .lineLimit(1)
            }
            .padding(.horizontal, VoiceourMetrics.Space.lg)
            .frame(height: Kit.Metrics.toast)
            .modifier(GlassSurface(shape: Capsule(), isInteractive: false))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
        }
    }
}

extension View {
    /// Liquid Glass in `shape`, or its opaque replacement under Reduce Transparency.
    func kitGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(Kit.GlassSurface(shape: shape, isInteractive: interactive))
    }

    /// Paints ``Kit/IslandSurface`` behind the view and declares its ground.
    func kitIslandSurface(
        cornerRadius: CGFloat = Kit.Metrics.islandRadius,
        glow: Bool = true,
        elevated: Bool = true
    ) -> some View {
        modifier(Kit.IslandSurface(cornerRadius: cornerRadius, glow: glow, elevated: elevated))
    }

    /// Shows `flash`'s message as a ``Kit/Toast`` along the bottom edge while it lasts.
    func kitToast(_ flash: Kit.Flash, identifier: String) -> some View {
        overlay(alignment: .bottom) {
            if let message = flash.message {
                Kit.Toast(message)
                    .accessibilityIdentifier(identifier)
                    .padding(.bottom, VoiceourMetrics.Space.lg)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }
}

/// Decorative dot field under a ``Kit/Screen``, so the page reads as a surface
/// rather than as panes floating in the window ground: 2 pt white-3 % dots every
/// ``Kit/Metrics/dotPitch``.
///
/// One `Canvas`, not a grid of views: at a 24 pt pitch a full console page is about
/// 2,000 dots, and 2,000 `Circle`s is 2,000 layout participants and 2,000
/// accessibility nodes for something nobody can address. Skipped outright under
/// Reduce Transparency, which asks for fewer decorative layers, not more.
private struct DotGrid: View {
    private var a11y = A11y()

    private static let diameter: CGFloat = 2

    var body: some View {
        if a11y.reduceTransparency {
            Color.clear
        } else {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let pitch = Kit.Metrics.dotPitch
                let dot = Path(
                    ellipseIn: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
                )
                let shading = GraphicsContext.Shading.color(Color.white.opacity(0.03))
                var y = pitch
                while y < size.height {
                    var x = pitch
                    while x < size.width {
                        context.translateBy(x: x, y: y)
                        context.fill(dot, with: shading)
                        context.translateBy(x: -x, y: -y)
                        x += pitch
                    }
                    y += pitch
                }
            }
            .accessibilityHidden(true)
        }
    }
}
