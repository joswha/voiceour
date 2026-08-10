import SwiftUI

struct ConsoleScaffold: View {
    @Binding var section: ConsoleSection
    var coordinator: DictationCoordinator

    /// No `GlassEffectContainer` here. A container exists to combine and morph
    /// several descendant glass shapes, and after the nav pill and the primary
    /// action were both found erasing their own content on glass, this window has
    /// exactly one: the ground itself, applied by `glassSurface` below. Wrapping a
    /// single effect combines nothing, and Apple warns that superfluous containers
    /// cost rendering performance. Reinstate one here — not anywhere else — if the
    /// console ever floats a second genuinely-functional glass element above the
    /// ground.
    var body: some View {
        scaffold
    }

    private var scaffold: some View {
        HStack(spacing: 0) {
            LeftRail(
                selection: $section,
                coordinator: coordinator,
            )
            // The rail is a region of ground, not a second surface, and the rule
            // that delimits it is an OVERLAY on its own trailing edge rather than
            // a laid-out sibling. A 0.5pt `HairlineDivider` in this HStack put the
            // content column on a half-pixel x origin (201 rather than 200), which
            // spread every vertical card edge in every pane across two device
            // pixels. An overlay consumes no layout width, so content starts at
            // exactly x=200 and the scroll region is exactly 988 wide at the
            // 1164pt default window — the Glossary table plus its two gutters.
            .overlay(alignment: .trailing) {
                HairlineDivider(axis: .vertical)
                    .allowsHitTesting(false)
            }
            ConsoleContent(section: section, coordinator: coordinator)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, VoiceOourMetrics.Space.titlebar)
        .glassSurface(cornerRadius: VoiceOourMetrics.Radius.window)
        .overlay(alignment: .top) {
            // The native title-bar strip directly above our content (traffic lights,
            // outside this view — see `WindowChromeConfigurator`) is an opaque AppKit
            // view our own glass can't bleed into. Taper a matching dark tone across
            // the same reserved `Space.titlebar` band so the seam reads as one
            // continuous dark rail instead of a hard vibrancy cut; the glass tint
            // takes over fully below the reserved strip.
            LinearGradient(
                colors: [GroundScrim.ink, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: VoiceOourMetrics.Space.titlebar)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        // Safe-area expansion is applied OUTSIDE the glass so the surface (and
        // its rounded corners) extends up behind the opaque native titlebar
        // strip instead of terminating below it — otherwise the panel's top
        // corner rounding and any panel shadow read as a floating-card seam
        // right under the traffic lights. The scaffold IS the window, so it
        // also carries no drop shadow of its own.
        .ignoresSafeArea(.container, edges: .top)
        .frame(
            minWidth: VoiceOourMetrics.Window.minWidth,
            maxWidth: .infinity,
            minHeight: VoiceOourMetrics.Window.minHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

private struct ConsoleContent: View {
    var section: ConsoleSection
    var coordinator: DictationCoordinator

    @Environment(\.surfaceGround) private var inheritedGround

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(section: section, coordinator: coordinator)
                .padding(.horizontal, VoiceOourMetrics.Space.xl)
                // The header's substrate is painted OUTSIDE the column gutter and
                // up to the window's own top edge, so no strip of bare material
                // survives beside or above the text whose contrast floor it has to
                // define. It is a background, so it never enters the hit-test path
                // and the window stays draggable by its own chrome.
                .background(alignment: .top) {
                    GroundScrim(taper: VoiceOourMetrics.Space.xl)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topTrailingRadius: VoiceOourMetrics.Radius.window,
                                style: .continuous
                            )
                        )
                        .padding(.top, -VoiceOourMetrics.Space.titlebar)
                }
                // Same floor, same reason as the rail's: the eyebrow, title,
                // subtitle and metadata chip all sit on this scrim, not on the
                // bare window material.
                .environment(\.surfaceGround, inheritedGround.painting(GroundScrim.ink))

            section.descriptor.content(coordinator)
                .padding(.horizontal, VoiceOourMetrics.Space.xl)
                .padding(.bottom, section.contentBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
