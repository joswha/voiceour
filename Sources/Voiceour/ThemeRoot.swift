import AppKit
import Combine
import SwiftUI
import VoiceCore

/// Resolves the theme for a root view and hands it to everything below.
///
/// Applied once at the console root and once at the menu root. It reads the user's appearance
/// and accent, the scheme the window is actually in (what System means), Increase Contrast,
/// and — for the System accent — the Mac's accent colour, refreshed whenever macOS changes
/// it. The theme travels as `\.theme`; the colour scheme travels with it so native controls
/// and dynamic system colours agree with the painted surfaces. An explicit Light or Dark is
/// also applied app-wide through AppKit (``applyAppAppearance(_:)``), so the console's title
/// bar and tab strip and the menu popover follow it.
struct ThemeRoot: ViewModifier {
    private let appearance: ConsoleAppearance
    private let accent: ConsoleAccent

    @Environment(\.colorScheme) private var environmentScheme
    private var a11y = A11y()
    @State private var systemAccent: ThemeRGB? = ThemeRoot.currentSystemAccent()

    init(appearance: ConsoleAppearance, accent: ConsoleAccent) {
        self.appearance = appearance
        self.accent = accent
    }

    func body(content: Content) -> some View {
        let theme = resolvedTheme
        content
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.scheme)
            .tint(theme.accent)
            .onChange(of: appearance, initial: true) { _, chosen in
                Self.applyAppAppearance(chosen)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
                    .receive(on: RunLoop.main)
            ) { _ in
                systemAccent = Self.currentSystemAccent()
            }
    }

    private var resolvedTheme: Theme {
        let scheme: ColorScheme =
            switch appearance {
            case .system: environmentScheme
            case .light: .light
            case .dark: .dark
            }
        return Theme.resolve(
            scheme: scheme,
            accent: accent,
            increasedContrast: a11y.contrast == .increased,
            systemAccent: systemAccent
        )
    }

    /// The Mac's accent colour in sRGB, or nil when AppKit cannot express it there (the
    /// generator then falls back to blue).
    nonisolated private static func currentSystemAccent() -> ThemeRGB? {
        guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return nil }
        return ThemeRGB(
            r: Double(color.redComponent),
            g: Double(color.greenComponent),
            b: Double(color.blueComponent)
        )
    }

    /// Makes an explicit Light or Dark the app's AppKit appearance, which every window of the
    /// app draws in — the console's chrome and the menu popover alike — and clears it for
    /// System, so macOS decides again. Called at launch, before any window exists, and
    /// whenever the choice changes; a call that changes nothing does nothing.
    static func applyAppAppearance(_ appearance: ConsoleAppearance) {
        let target: NSAppearance? =
            switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        let application = NSApplication.shared
        guard application.appearance?.name != target?.name else { return }
        application.appearance = target
    }
}

extension View {
    /// Themes this subtree for the user's appearance and accent. See ``ThemeRoot``.
    func themeRoot(appearance: ConsoleAppearance, accent: ConsoleAccent) -> some View {
        modifier(ThemeRoot(appearance: appearance, accent: accent))
    }
}
