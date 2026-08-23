import AppKit
import SwiftUI

/// The console window's ground: system glass behind native controls.
///
/// Both halves are AppKit's, so both live here. A window paints an opaque
/// `windowBackgroundColor` until it is told not to, and no material can sample
/// what is behind a window that is still painting itself — `NSWindow.isOpaque`
/// and a clear `backgroundColor` are the documented preconditions for
/// `NSVisualEffectBlendingMode.behindWindow` ("Blend with the area behind the
/// window (such as the Desktop or other windows)", `NSVisualEffectView.h`). The
/// material itself is an `NSView`, so the view that clears the window is the
/// same view that fills it.
///
/// Deliberately NOT SwiftUI `.glassEffect`. That is element glass — macOS 26
/// only, documented for floating controls, and it cannot sample other glass — so
/// a window-filling `.glassEffect` over a window-filling material is two blurs
/// arguing. AppKit's `NSGlassEffectView` (macOS 26) is the window-scale Liquid
/// Glass surface, with `NSVisualEffectView` as the macOS 14/15 path.
///
/// Deliberately NOT ``FrostedGlassBackground`` either: that one pins
/// `.vibrantDark` and a corner radius for the recording island, and this window
/// keeps the appearance the user chose.
struct ConsoleGlassGround: View {
    private var a11y = A11y()

    var body: some View {
        surface
            .ignoresSafeArea()
            // The ground is a surface, not content: it must not add a node to
            // the accessibility tree the flow journals and goldens assert on.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var surface: some View {
        // Two reasons to paint the plain window colour instead of a material.
        // Reduce Transparency is the user asking for it. `forceLegacyGlass` is
        // the offscreen harness, which cannot rasterise either glass path —
        // `cacheDisplay` flattens a behind-window material to an opaque fill and
        // drops `.glassEffect` entirely — so a golden has to record a real
        // ground rather than a hole. It is also why nothing below this branch
        // ever touches the harness's parked window.
        if a11y.reduceTransparency || RenderOverrides.forceLegacyGlass {
            Color(nsColor: .windowBackgroundColor)
        } else {
            WindowGlassSurface()
        }
    }
}

/// The material, and the window mutation it needs to be visible at all.
private struct WindowGlassSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            return ConsoleGlassView()
        }
        return ConsoleVibrancyView()
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// macOS 26 Liquid Glass. `contentView` stays nil: the SwiftUI content is a
/// sibling above this view, not a child of it, because a glass view hosting the
/// whole console would put every native control inside a surface that samples
/// them.
@available(macOS 26, *)
private final class ConsoleGlassView: NSGlassEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        style = .regular
        clearHostWindowBackground()
    }
}

/// macOS 14/15. `.underWindowBackground` is the window-scale vibrancy material;
/// the island's `.hudWindow` is a floating-panel material and reads far darker
/// than a window ground should.
private final class ConsoleVibrancyView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        clearHostWindowBackground()
    }
}

extension NSView {
    /// Stops the host window painting over the material. Two properties and
    /// nothing else: the style mask, titlebar, level, movability and activation
    /// policy all stay the system's, so this remains a native window that merely
    /// does not fill itself in.
    fileprivate func clearHostWindowBackground() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
