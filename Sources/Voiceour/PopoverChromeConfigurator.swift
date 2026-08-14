import AppKit
import SwiftUI

/// Popover-only host-window configuration. Touches exactly three properties and
/// nothing else — not the style mask, the title, the minimum size, movability,
/// activation policy, key/main eligibility or level. `WindowChromeConfigurator`
/// is deliberately NOT reused: it also inserts `.fullSizeContentView`, hides the
/// title, enables background dragging and forces a 1180 pt minimum width, all of
/// which are wrong for a 280 pt `MenuBarExtra` window and can change drag, focus
/// and auto-dismiss behaviour.
///
/// `NSWindow.appearance` is `NSAppearance?` and `.vibrantDark` is an
/// `NSAppearance.Name`, so the name has to be wrapped.
struct PopoverChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PopoverChromeConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PopoverChromeConfigurationView)?.configureWindowIfAvailable()
    }

    private final class PopoverChromeConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowIfAvailable()
        }

        func configureWindowIfAvailable() {
            guard let window else { return }

            window.backgroundColor = .clear
            window.isOpaque = false
            window.appearance = NSAppearance(named: .vibrantDark)
        }
    }
}
