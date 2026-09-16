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
/// AppKit's `NSGlassEffectView` supplies the window-scale material through an
/// `NSViewRepresentable`-backed view. The window keeps the user's appearance,
/// and native section plates keep text off the sampled desktop.
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
        // Reduce Transparency requests an opaque system window ground.
        if a11y.reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            WindowGlassSurface()
        }
    }
}

/// The material, and the window mutation it needs to be visible at all.
private struct WindowGlassSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConsoleGlassView()
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Window-scale Liquid Glass. `contentView` stays nil: the SwiftUI content is a
/// sibling above this view, not a child of it, because a glass view hosting the
/// whole console would put every native control inside a surface that samples
/// them.
private final class ConsoleGlassView: NSGlassEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        style = .regular
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
