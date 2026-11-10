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

    /// The floating panel the sidebar is: glass over the Journal's ground, inset from
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

    /// A content-layer grouping: a faint fill and a hairline, never glass. Cards hold
    /// what a reader reads — a transcript, a day's block, an agent's note — so they sit
    /// on the opaque ground with the text, under the glass that steers.
    struct Card<Content: View>: View {
        private let padding: CGFloat
        private let content: Content
        private var a11y = A11y()

        init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
            self.padding = padding
            self.content = content()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.cardRadius, style: .continuous)
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Kit.Colors.cardFill(a11y), in: shape)
                .overlay(shape.stroke(Kit.Colors.rule(a11y), lineWidth: Kit.Colors.hairline(a11y)))
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
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(message)
                    .font(Kit.Fonts.toast)
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
