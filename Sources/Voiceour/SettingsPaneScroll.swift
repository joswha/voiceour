import SwiftUI

/// Scrollable pane shell. Content sits on one fixed-width column **centred**
/// in the region, sharing its measure — both edges — with the section header
/// above it instead of stretching edge to edge with the window or pinning
/// left and stranding a dead band on the right. Tables (Glossary) opt into
/// the wider measure; every plain settings pane uses the narrower form
/// measure. At the default window the Glossary measure fits the region
/// exactly, so centring and flush are the same x there; wider windows grow
/// symmetric gutters instead of one growing void.
struct SettingsPaneScroll<Content: View>: View {
    var maxContentWidth: CGFloat = VoiceourMetrics.Content.form
    let content: Content

    init(maxContentWidth: CGFloat = VoiceourMetrics.Content.form, @ViewBuilder content: () -> Content) {
        self.maxContentWidth = maxContentWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
                content
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, VoiceourMetrics.Space.section)
        }
        .scrollEdge(.hard, for: .top)
    }
}

/// The bottom half of a settings pane's scroll-edge pair, for the panes whose
/// ledger runs past the fold at the default window size.
///
/// The viewport deliberately runs flush to the window's inner edge so the clip
/// lands *on* the boundary (`ConsoleSection.contentBottomInset`), but a clip
/// alone carries no signal: a section that ends on a crisp, complete line reads
/// as the end of the pane, or as damage, rather than as the top of the next
/// screenful.
///
/// macOS 26 has the system effect; `SettingsPaneScroll` already carries the
/// `.top` half of the pair and the pane adds `.bottom`. Below 26 the effect
/// does not exist, so the fade is painted: the page dissolves into the ground's
/// own floor over the last `Space.xl`, at an opacity driven by how much content
/// is still below the fold (§1.4). It lifts as the page bottoms out, so the
/// treatment never veils a page that has genuinely ended.
private struct PaintedBottomScrollEdge: ViewModifier {
    private static let band = VoiceourMetrics.Space.xl

    private var a11y = A11y()

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !RenderOverrides.forceLegacyGlass {
            content
        } else {
            content.overlay {
                GeometryReader { proxy in
                    // The overlay spans the scrolled content, so the viewport
                    // rect resolved into that space gives both where the fold
                    // is and how much ledger is still under it.
                    if let viewport = proxy.bounds(of: .scrollView) {
                        LinearGradient(
                            colors: [a11y.ground.opacity(0), a11y.ground],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: viewport.width, height: Self.band)
                        .position(x: viewport.midX, y: viewport.maxY - Self.band / 2)
                        .opacity(min(max((proxy.size.height - viewport.maxY) / Self.band, 0), 1))
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Applied to the scrolled content, not the scroll view: the modifier reads
    /// the viewport out of the content's own coordinate space.
    func paintedBottomScrollEdge() -> some View {
        modifier(PaintedBottomScrollEdge())
    }
}
