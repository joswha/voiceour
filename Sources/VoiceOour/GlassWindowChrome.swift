import AppKit
import SwiftUI

/// Resolves the app-owned harness overrides against SwiftUI's read-only
/// accessibility environments. Shared primitives use this reader so the
/// shipping behavior and offscreen accessibility fixtures exercise one path.
struct A11y: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var envDifferentiate
    @Environment(\.colorSchemeContrast) private var envContrast

    var reduceTransparency: Bool {
        RenderOverrides.reduceTransparency ?? envReduceTransparency
    }

    var reduceMotion: Bool {
        RenderOverrides.reduceMotion ?? envReduceMotion
    }

    var differentiateWithoutColor: Bool {
        RenderOverrides.differentiateWithoutColor ?? envDifferentiate
    }

    var contrast: ColorSchemeContrast {
        (RenderOverrides.increasedContrast ?? (envContrast == .increased))
            ? .increased
            : .standard
    }

    var textLow: Color {
        contrast == .increased ? VoiceOourPalette.Text.mid : VoiceOourPalette.Text.low
    }

    var textMid: Color {
        contrast == .increased ? VoiceOourPalette.Text.high : VoiceOourPalette.Text.mid
    }

    var markFaint: Color {
        contrast == .increased ? VoiceOourPalette.Text.low : VoiceOourPalette.Mark.faint
    }

    /// Reduce Transparency deletes the material that was drawing every boundary
    /// for us, so the painted rules have to draw them instead. Both adaptations
    /// land on one escalated ladder rather than inventing a third set of values:
    /// Increase Contrast asks for a contrasting border, Reduce Transparency asks
    /// for a border where a gradient used to be, and the answer is the same line.
    private var escalatedLines: Bool {
        contrast == .increased || reduceTransparency
    }

    var lineRule: Color {
        escalatedLines ? VoiceOourPalette.Contrast.lineRule : VoiceOourPalette.Line.rule
    }

    var lineEdge: Color {
        escalatedLines ? VoiceOourPalette.Contrast.lineEdge : VoiceOourPalette.Line.edge
    }

    var lineControl: Color {
        escalatedLines ? VoiceOourPalette.Contrast.lineControl : VoiceOourPalette.Line.control
    }

    var surface: Color {
        contrast == .increased ? VoiceOourPalette.Ink.void : VoiceOourPalette.Ink.surface
    }

    /// The opaque colour the window ground resolves to, for anything that has to
    /// blend *into* it — a scroll-edge fade, a scrim, a taper. Under Reduce
    /// Transparency `GlassSurface` paints `Ink.frost`, so a fade that still ran
    /// to `Ink.void` would lay a dark band across a light ground. One decision,
    /// one place; callers stop mirroring the branch.
    var ground: Color {
        reduceTransparency ? VoiceOourPalette.Ink.frost : VoiceOourPalette.Ink.void
    }

    var meterRest: Color {
        contrast == .increased ? VoiceOourPalette.Contrast.meterRest : VoiceOourPalette.Meter.rest
    }
}
/// Configures the host window for VoiceOour's edge-to-edge glass console using
/// only public AppKit window chrome APIs available on macOS 13.
///
/// Note on the native title bar strip: AppKit inserts an opaque
/// `NSTitlebarContainerView` above the content view for any `.titled` window
/// (confirmed at runtime by walking `standardWindowButton(.closeButton)`'s
/// ancestor chain — `NSTitlebarView`/`NSTitlebarContainerView`, both
/// `isOpaque == true`). `titlebarAppearsTransparent` only changes what that
/// container paints; it does not make it see-through to content behind it, so
/// the traffic-light strip can never show our own vibrancy/gradient through it
/// while `.titled` remains in the style mask. Dynamically dropping `.titled`
/// after the window has appeared (to reclaim that strip for content) was
/// tried and reproducibly crashes deep in AppKit's constraint-based layout
/// engine (`-[NSView _layoutSubtreeWithOldSize:]`, `EXC_BAD_ACCESS`) — every
/// button re-hosting order tested hit the same internal AppKit fault, so that
/// transition is unsupported here, not a fixable ordering bug on our side.
/// `ConsoleScaffold`'s own top overlay tapers to a matching dark tone at its top
/// edge instead (see `ConsoleScaffold.swift`, using the existing `Ink.void` token),
/// so the seam reads as a deliberate two-tone rail rather than a broken
/// vibrancy boundary.
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowChromeConfigurationView)?.configureWindowIfAvailable()
    }

    private final class WindowChromeConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowIfAvailable()
        }

        func configureWindowIfAvailable() {
            guard let window = window else {
                return
            }

            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .vibrantDark)
            window.minSize = NSSize(
                width: VoiceOourMetrics.Window.minWidth,
                height: VoiceOourMetrics.Window.minHeight
            )
        }
    }
}
