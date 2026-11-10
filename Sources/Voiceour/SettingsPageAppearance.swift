import SwiftUI
import VoiceCore

/// Settings ▸ Appearance: the console's and the menu's appearance and accent
/// colour, with a preview drawn in the theme they resolve to.
///
/// Two choices and no more: every other colour is derived from them, so no
/// combination a reader can pick fails the contrast the console promises. Both
/// write through `settingBinding`, so a choice saves the moment it is made and
/// the whole window, this page included, repaints in it. The recording island
/// is not themed here: it keeps its own looks on the Island page.
struct SettingsAppearancePage: View {
    private let coordinator: DictationCoordinator

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        SettingsPage(.appearance) {
            Kit.Group(
                "Appearance",
                footer: "System follows macOS. Increase Contrast in System Settings › Accessibility raises "
                    + "contrast in every appearance."
            ) {
                Kit.AppearancePicker(selection: settingBinding(coordinator, \.consoleAppearance))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(VoiceourMetrics.Space.md)
            }

            Kit.Group("Accent colour") {
                Kit.AccentPicker(selection: settingBinding(coordinator, \.consoleAccent))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(VoiceourMetrics.Space.md)
            }

            Kit.Group("Preview") {
                SettingsAppearancePreview()
            }
        }
    }
}

/// A few of the console's parts drawn in the live theme: a selected row in a
/// focused list, the two button weights, the four status pills and a meter.
///
/// A picture, not controls: nothing in it acts, so it takes no clicks and
/// VoiceOver reads it as one described element instead of buttons that do
/// nothing.
private struct SettingsAppearancePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
            Kit.LineRow(
                "Selected row",
                isSelected: true,
                action: {},
                leading: { Kit.IconTile(systemImage: "text.bubble", size: .small) },
                trailing: { Kit.Pill("Note") }
            )
            // Selection as a focused list shows it: the accent-tinted plate and
            // the focus bar, the strongest selection the theme draws.
            .environment(\.kitListFocused, true)

            HStack(spacing: VoiceourMetrics.Space.sm) {
                Kit.Button("Primary", prominence: .primary) {}
                Kit.Button("Secondary", prominence: .secondary) {}
            }

            HStack(spacing: VoiceourMetrics.Space.sm) {
                Kit.Pill("Ready", tone: .success)
                Kit.Pill("Will prompt", tone: .caution)
                Kit.Pill("Denied", tone: .critical)
                Kit.Pill("Downloading", tone: .info)
            }

            Kit.Meter(fraction: 0.6)
                .frame(maxWidth: Self.meterWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiceourMetrics.Space.md)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue(
            "A selected row, a primary and a secondary button, the four status pills and a meter, "
                + "in the chosen appearance and accent colour"
        )
        .accessibilityIdentifier("settings.appearance.preview")
    }

    /// The meter's measure, the download meter's on the Readiness page.
    private static let meterWidth: CGFloat = 320
}
