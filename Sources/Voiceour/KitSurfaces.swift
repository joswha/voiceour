import SwiftUI

extension Kit {
    /// The ground every console tab draws its content on: the theme's `ground`.
    ///
    /// The colour runs under the window's safe area so it meets the tab strip without
    /// a seam; the content keeps to the safe area. It declares the ground as the
    /// surface text outside any card is measured on.
    struct Screen<Content: View>: View {
        private let content: Content
        @Environment(\.theme) private var theme

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    theme.ground
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }
                .environment(\.surfaceGround, SurfaceGround(theme.ground))
        }
    }

    /// A raised surface that holds one group of content: a figure, a section of a page,
    /// a list of preferences.
    ///
    /// Elevation reads differently per appearance, so the theme decides how it shows: a
    /// soft shadow in light, a 1 pt top highlight in dark, where shadows vanish into the
    /// ground. The outline is quiet beside the light shadow, which already lifts the card,
    /// and steps up to the border wherever no shadow draws; under Increase Contrast it is
    /// what identifies the card, so it takes the strong border there. The card clips its
    /// content to its corners, so a hover plate or an overflowing line never paints past
    /// the rounded edge.
    struct Card<Content: View>: View {
        private let padding: CGFloat
        private let content: Content

        init(padding: CGFloat = Kit.Metrics.cardPadding, @ViewBuilder content: () -> Content) {
            self.padding = padding
            self.content = content()
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Kit.Metrics.cardRadius, style: .continuous)
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(shape)
                .modifier(PaintedSurface(shape: shape, fill: \.raised))
        }
    }

    /// A System Settings group: an optional quiet header, a card holding the rows, and
    /// an optional footer that explains them.
    ///
    /// The card has no padding of its own, so each row owns its insets and its hover
    /// plate reaches the card's edge. Callers place `Kit.Rule(inset: 12)` between rows;
    /// the group never inserts separators itself, because it cannot see where one row
    /// ends inside a `ForEach`.
    struct Group<Content: View>: View {
        private let title: String?
        private let footer: String?
        private let rows: Content

        init(_ title: String? = nil, footer: String? = nil, @ViewBuilder rows: () -> Content) {
            self.title = title
            self.footer = footer
            self.rows = rows()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                if let title {
                    Text(title)
                        .roleStyle(.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, VoiceourMetrics.Space.xs)
                        .accessibilityAddTraits(.isHeader)
                }
                Kit.Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        rows
                    }
                }
                if let footer {
                    Text(footer)
                        .roleStyle(.meta)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, VoiceourMetrics.Space.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A 1 pt `separator` line between two regions: rows in a group, the columns of a
    /// browsing tab. `inset` pulls both ends in, so a separator between grouped rows
    /// starts where their text does rather than at the card's edge.
    struct Rule: View {
        private let axis: Axis
        private let inset: CGFloat
        @Environment(\.theme) private var theme

        init(_ axis: Axis = .horizontal, inset: CGFloat = 0) {
            self.axis = axis
            self.inset = inset
        }

        var body: some View {
            Rectangle()
                .fill(theme.separator)
                .frame(
                    width: axis == .vertical ? Self.thickness : nil,
                    height: axis == .horizontal ? Self.thickness : nil
                )
                .padding(axis == .horizontal ? .horizontal : .vertical, inset)
                .accessibilityHidden(true)
        }

        /// One point. A column draws its rule inside its own width, so the widths beside
        /// it stay on the grid. Increase Contrast darkens the colour instead.
        static let thickness: CGFloat = 1
    }

    /// A transient confirmation: what just happened, in the same sentence VoiceOver
    /// hears, on the `overlay` surface. It names no control and holds none, so a press
    /// never lands on it by accident. A message too long for one line wraps to a second
    /// and then truncates in the middle; VoiceOver still hears all of it.
    struct Toast: View {
        private let message: String
        private let systemImage: String
        @Environment(\.theme) private var theme

        init(_ message: String, systemImage: String = "checkmark.circle.fill") {
            self.message = message
            self.systemImage = systemImage
        }

        var body: some View {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.success.text)
                    .accessibilityHidden(true)
                Text(message)
                    .roleStyle(.body)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VoiceourMetrics.Space.lg)
            .padding(.vertical, VoiceourMetrics.Space.sm)
            .frame(minHeight: Kit.Metrics.toastHeight)
            .frame(maxWidth: Kit.Metrics.toastMaxWidth)
            .modifier(
                PaintedSurface(
                    shape: RoundedRectangle(cornerRadius: Self.radius, style: .continuous),
                    fill: \.overlay
                )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
        }

        private static let radius: CGFloat = 10
    }

    /// Shows a ``Kit/Flash`` as a ``Kit/Toast`` centred along the bottom edge, 16 pt
    /// above it, and publishes the space the toast covers as `\.kitToastInset`, so the
    /// scrolling columns beneath extend their content past it and the last line is
    /// never hidden behind the confirmation.
    fileprivate struct ToastPresenter: ViewModifier {
        private let flash: Kit.Flash
        private let identifier: String

        init(flash: Kit.Flash, identifier: String) {
            self.flash = flash
            self.identifier = identifier
        }

        func body(content: Content) -> some View {
            content
                .environment(\.kitToastInset, flash.message == nil ? 0 : Self.inset)
                .overlay(alignment: .bottom) {
                    if let message = flash.message {
                        Kit.Toast(message)
                            .accessibilityIdentifier(identifier)
                            .padding(.horizontal, Self.edge)
                            .padding(.bottom, Self.edge)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
        }

        private static let edge: CGFloat = VoiceourMetrics.Space.lg
        /// The toast's height and its gap above the edge. A column adds it to its own
        /// bottom padding, which covers a toast that wraps to a second line.
        static let inset: CGFloat = Kit.Metrics.toastHeight + edge
    }
}

extension View {
    /// Shows `flash`'s message as a ``Kit/Toast`` along the bottom edge while it lasts.
    func kitToast(_ flash: Kit.Flash, identifier: String) -> some View {
        modifier(Kit.ToastPresenter(flash: flash, identifier: identifier))
    }
}

/// The painted stack every raised kit surface shares: an opaque theme fill, a 1 pt
/// outline, then the theme's elevation — its shadow in light, its top highlight in
/// dark. It declares the fill as the ground under the surface's text.
///
/// Reduce Transparency changes nothing here except the shadow, which drops, and the
/// outline, which steps up to the border in its place: every fill is already opaque, and
/// a shadow is the one soft, see-through layer left.
private struct PaintedSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: KeyPath<Theme, Color>
    @Environment(\.theme) private var theme
    private var a11y = A11y()

    init(shape: S, fill: KeyPath<Theme, Color>) {
        self.shape = shape
        self.fill = fill
    }

    func body(content: Content) -> some View {
        let color = theme[keyPath: fill]
        let shadow = a11y.reduceTransparency ? nil : theme.cardShadow
        content
            .background { surface(color, shadow: shadow) }
            // The outline sits over the content, so a row's hover plate reaching the
            // card's edge never paints over the boundary that identifies the card.
            .overlay {
                shape
                    .strokeBorder(outline(beside: shadow), lineWidth: Kit.Rule.thickness)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .environment(\.surfaceGround, SurfaceGround(color))
    }

    /// The strong border under Increase Contrast, where the outline alone identifies the
    /// surface; the quiet separator beside the light theme's shadow, which already lifts
    /// it; the border wherever no shadow draws.
    private func outline(beside shadow: Theme.Shadow?) -> Color {
        if theme.isIncreasedContrast { return theme.borderStrong }
        return shadow == nil ? theme.border : theme.separator
    }

    private func surface(_ color: Color, shadow: Theme.Shadow?) -> some View {
        ZStack {
            shape.fill(color)
            if let highlight = theme.topHighlight {
                // A line across the top, short of the corners so it never draws a
                // second, brighter curve inside the outline.
                Rectangle()
                    .fill(highlight)
                    .frame(height: Kit.Rule.thickness)
                    .padding(.horizontal, Kit.Metrics.cardRadius)
                    .padding(.top, Kit.Rule.thickness)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .shadow(color: shadow?.color ?? .clear, radius: shadow?.radius ?? 0, y: shadow?.y ?? 0)
        .accessibilityHidden(true)
    }
}
