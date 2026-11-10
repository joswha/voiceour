import AppKit
import SwiftUI
import VoiceCore

extension Kit {
    /// The console's appearance, chosen the way macOS System Settings offers it: three
    /// tiles, each a drawn miniature of the console in that appearance — sidebar, a
    /// selected row, a card with its primary button — so the reader picks a look they
    /// can see rather than a word. System shows Light and Dark side by side, because it
    /// follows the Mac. Every miniature is painted from `Theme.resolve(...)` for its own
    /// scheme with the reader's accent and contrast, so it shows exactly what choosing
    /// it gives.
    struct AppearancePicker: View {
        @Binding private var selection: ConsoleAppearance
        @Environment(\.theme) private var theme

        init(selection: Binding<ConsoleAppearance>) {
            self._selection = selection
        }

        var body: some View {
            let light = Kit.previewTheme(.light, like: theme)
            let dark = Kit.previewTheme(.dark, like: theme)
            HStack(alignment: .top, spacing: VoiceourMetrics.Space.lg) {
                ForEach(ConsoleAppearance.allCases, id: \.self) { option in
                    tile(option, light: light, dark: dark)
                }
            }
        }

        private func tile(_ option: ConsoleAppearance, light: Theme, dark: Theme) -> some View {
            let isSelected = option == selection
            let name = Self.name(option)
            let shape = RoundedRectangle(cornerRadius: Self.thumbRadius, style: .continuous)
            return SwiftUI.Button {
                selection = option
            } label: {
                VStack(spacing: VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair) {
                    thumbnail(option, light: light, dark: dark)
                        .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(theme.border, lineWidth: 1) }
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Self.thumbRadius + 3, style: .continuous)
                                    .strokeBorder(theme.focusRing, lineWidth: 2)
                                    .padding(-3)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(theme.onAccent)
                                    .frame(width: 14, height: 14)
                                    .background { Circle().fill(theme.accent) }
                                    .padding(VoiceourMetrics.Space.xs)
                            }
                        }
                        .accessibilityHidden(true)
                    Text(name)
                        .roleStyle(.meta)
                        .foregroundStyle(isSelected ? theme.text1 : theme.text2)
                        .lineLimit(1)
                }
                .padding(VoiceourMetrics.Space.xs)
                .frame(height: Self.tileHeight, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(FocusRingStyle(radius: Self.thumbRadius + VoiceourMetrics.Space.xs, outset: 0))
            .focusEffectDisabled()
            .accessibilityLabel(name)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("settings.appearance.\(option.rawValue)")
        }

        @ViewBuilder
        private func thumbnail(_ option: ConsoleAppearance, light: Theme, dark: Theme) -> some View {
            switch option {
            case .light:
                ConsoleThumbnail(theme: light)
            case .dark:
                ConsoleThumbnail(theme: dark)
            case .system:
                ConsoleThumbnail(theme: light)
                    .overlay(alignment: .trailing) {
                        ConsoleThumbnail(theme: dark)
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: Self.thumbSize.width / 2)
                            }
                    }
            }
        }

        private static let thumbSize = CGSize(width: 88, height: 60)
        private static let thumbRadius: CGFloat = 6
        /// The whole tile: the thumbnail, its name and the insets around them, fixed rather
        /// than left to the name's line height so it stays a multiple of 4, as the grid
        /// asks of anything taller than 64 pt.
        private static let tileHeight: CGFloat = 88

        private static func name(_ appearance: ConsoleAppearance) -> String {
            switch appearance {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// The console's accent: a row of swatches, each the accent the theme would actually
    /// paint for this appearance and contrast (a requested hue can move to keep its
    /// contrast), so a swatch never promises a colour the console then does not show.
    /// System, which follows the Mac's accent, shows a four-colour sweep. The chosen one
    /// carries a ring, and its name sits under the row.
    struct AccentPicker: View {
        @Binding private var selection: ConsoleAccent
        @Environment(\.theme) private var theme

        init(selection: Binding<ConsoleAccent>) {
            self._selection = selection
        }

        var body: some View {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
                HStack(spacing: VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair) {
                    ForEach(ConsoleAccent.allCases, id: \.self) { accent in
                        swatch(accent)
                    }
                }
                Text(Self.name(selection))
                    .roleStyle(.meta)
                    .foregroundStyle(theme.text2)
                    .accessibilityHidden(true)
            }
        }

        private func swatch(_ accent: ConsoleAccent) -> some View {
            let isSelected = accent == selection
            let name = Self.name(accent)
            let diameter: CGFloat = 22
            return SwiftUI.Button {
                selection = accent
            } label: {
                fill(accent)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(theme.border, lineWidth: 1) }
                    .overlay {
                        if isSelected {
                            Circle()
                                .strokeBorder(theme.focusRing, lineWidth: 2)
                                .padding(-5)
                        }
                    }
                    .frame(width: Kit.Metrics.controlHeight, height: Kit.Metrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FocusRingStyle(radius: Kit.Metrics.controlHeight / 2, outset: 3))
            .focusEffectDisabled()
            .help(name)
            .accessibilityLabel(name)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("settings.accent.\(accent.rawValue)")
        }

        @ViewBuilder
        private func fill(_ accent: ConsoleAccent) -> some View {
            if accent == .system {
                AngularGradient(colors: Self.systemSweep.map(resolvedAccent), center: .center)
            } else {
                resolvedAccent(accent)
            }
        }

        private func resolvedAccent(_ accent: ConsoleAccent) -> Color {
            Theme.resolve(
                scheme: theme.scheme,
                accent: accent,
                increasedContrast: theme.isIncreasedContrast
            ).accent
        }

        /// The four hues System's swatch sweeps through: it stands for whatever the Mac
        /// is set to, so it shows the family rather than one colour.
        private static let systemSweep: [ConsoleAccent] = [.blue, .pink, .orange, .green, .blue]

        private static func name(_ accent: ConsoleAccent) -> String {
            switch accent {
            case .system: "System"
            case .green: "Green"
            case .blue: "Blue"
            case .purple: "Purple"
            case .pink: "Pink"
            case .red: "Red"
            case .orange: "Orange"
            case .yellow: "Yellow"
            case .graphite: "Graphite"
            }
        }
    }

    /// The theme `theme`'s reader would get in `scheme`: same accent, same contrast.
    /// The System accent resolves against the Mac's accent, as the console root does.
    @MainActor
    fileprivate static func previewTheme(_ scheme: ColorScheme, like theme: Theme) -> Theme {
        Theme.resolve(
            scheme: scheme,
            accent: theme.accentChoice,
            increasedContrast: theme.isIncreasedContrast,
            systemAccent: theme.accentChoice == .system ? macAccent : nil
        )
    }

    @MainActor
    private static var macAccent: ThemeRGB? {
        guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return nil }
        return ThemeRGB(
            r: Double(color.redComponent),
            g: Double(color.greenComponent),
            b: Double(color.blueComponent)
        )
    }

    /// An 88 × 60 miniature of the console painted in `theme`: the sunken sidebar with
    /// its selected item, the list's focused selection with its bar, a line of text, and
    /// a raised card holding a primary button. Shapes only, no text, so it reads at any
    /// size and stays out of the contrast lint.
    private struct ConsoleThumbnail: View {
        let theme: Theme

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.selectionInactive)
                        .frame(height: 8)
                        .overlay(alignment: .leading) {
                            Circle()
                                .fill(theme.accentText)
                                .frame(width: 3, height: 3)
                                .padding(.leading, 3)
                        }
                    bar(theme.text3, width: 12)
                    bar(theme.text3, width: 15)
                    bar(theme.text3, width: 10)
                }
                .padding(4)
                .frame(width: 24, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(theme.sunken)

                Rectangle()
                    .fill(theme.separator)
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.selection)
                        .frame(height: 10)
                        .overlay(alignment: .leading) {
                            HStack(spacing: 3) {
                                Capsule()
                                    .fill(theme.focusRing)
                                    .frame(width: 1.5, height: 6)
                                bar(theme.text1, width: 22)
                            }
                            .padding(.leading, 2)
                        }
                    bar(theme.text2, width: 28)
                        .padding(.leading, 5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.raised)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(theme.border, lineWidth: 0.5)
                        }
                        .overlay(alignment: .topLeading) {
                            bar(theme.text2, width: 18)
                                .padding(4)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: 14, height: 5)
                                .padding(4)
                        }
                }
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(theme.ground)
        }

        private func bar(_ color: Color, width: CGFloat) -> some View {
            Capsule()
                .fill(color)
                .frame(width: width, height: 2.5)
        }
    }
}
