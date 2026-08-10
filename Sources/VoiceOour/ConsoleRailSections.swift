import SwiftUI

struct RailNavigation: View {
    @Binding var selection: ConsoleSection
    private var a11y = A11y()

    init(selection: Binding<ConsoleSection>) {
        self._selection = selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
            let home = ConsolePaneRegistry.primaryRailDescriptor
            RailItem(
                section: home.id,
                isSelected: selection == home.id,
            ) {
                select(home.id)
            }

            // No horizontal padding of its own: the enclosing stack already insets by
            // `Space.sm`, so the rule spans the pill column exactly, and the footer
            // rule below spans the same one. The two used to disagree by 8pt.
            HairlineDivider()
                .padding(.vertical, VoiceOourMetrics.Space.xs)

            ForEach(visibleDescriptors) { descriptor in
                RailItem(
                    section: descriptor.id,
                    isSelected: descriptor.id == selection,
                ) {
                    select(descriptor.id)
                }
            }
        }
        .padding(.horizontal, VoiceOourMetrics.Space.sm)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Debug panes are off the rail on a normal launch, but a rail that hid the pane
    /// it is currently showing would be lying about where the reader is. So they also
    /// appear whenever one of them is open, which is how `--console-section=` and the
    /// offscreen harness reach Diagnostics without `--debug`.
    private var visibleDescriptors: [ConsolePaneDescriptor] {
        let standard = ConsolePaneRegistry.standardRailDescriptors
        guard LaunchOptions.showsDebugPanes || ConsolePaneRegistry.isDebug(selection) else {
            return standard
        }
        return standard + ConsolePaneRegistry.debugRailDescriptors
    }

    private func select(_ item: ConsoleSection) {
        withAnimation(a11y.reduceMotion ? nil : VoiceOourMotion.quick) {
            selection = item
        }
    }
}

struct RailFooter: View {
    let coordinator: DictationCoordinator
    let status: RailStatus
    private var a11y = A11y()

    init(coordinator: DictationCoordinator, status: RailStatus) {
        self.coordinator = coordinator
        self.status = status
    }

    private var statusLabel: String {
        switch status {
        case .idle: "IDLE"
        case .working: "WORKING"
        case .live: "LIVE"
        case .error: "ERROR"
        }
    }

    private var accessibilityStatus: String {
        switch status {
        case .idle: "idle"
        case .working: "working"
        case .live: "live"
        case .error: "error"
        }
    }

    /// `Signal.cyan` stays reserved for the live case — it is the rail's one signal —
    /// so WORKING brightens rather than taking a colour of its own, and the shape of
    /// the mark carries the difference either way.
    private var statusTint: Color {
        switch status {
        case .idle: a11y.textLow
        case .working: a11y.textMid
        case .live: VoiceOourPalette.Signal.cyan
        case .error: VoiceOourPalette.Signal.crimson
        }
    }

    /// A tall sidebar is normal on macOS; a footer whispering 500pt below the nav is
    /// not. The rail resolves to two columns and the footer honours both: the
    /// `Icon.navSlot` mark gutter at x=20 and the text column at x=48, the same two
    /// every nav row uses. The dot sits in the gutter, so the wordmark and the status
    /// word share the nav labels' left edge instead of the wordmark being
    /// hang-indented 13pt past the line beneath it.
    var body: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.lg) {
            HairlineDivider()
            identity
            hotkey
        }
        .padding(.horizontal, VoiceOourMetrics.Space.sm)
        .padding(.bottom, VoiceOourMetrics.Space.lg)
    }

    private var statusMark: some View {
        RailStatusMark(status: status)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
            HStack(spacing: VoiceOourMetrics.Space.md) {
                statusMark
                    .frame(
                        width: VoiceOourMetrics.Icon.navSlot,
                        height: VoiceOourMetrics.Icon.navSlot
                    )
                    .scaleEffect(status == .live ? (a11y.reduceMotion ? 1 : 1.08) : 0.94)
                    .animation(
                        a11y.reduceMotion
                            ? nil
                            : (status == .live
                                ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                                : VoiceOourMotion.quick),
                        value: status
                    )
                    .accessibilityHidden(true)

                Text("VOICEOOUR")
                    .roleStyle(.eyebrow)
                    .foregroundStyle(a11y.textMid)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
                Text(statusLabel)
                    .roleStyle(.micro)
                    .foregroundStyle(statusTint)

                if coordinator.isSystemAudioMuted {
                    Text("AUDIO MUTED")
                        .roleStyle(.micro)
                        .foregroundStyle(VoiceOourPalette.Signal.amber)
                }
            }
            .padding(.leading, VoiceOourMetrics.Icon.navSlot + VoiceOourMetrics.Space.md)
        }
        .padding(.horizontal, VoiceOourMetrics.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            coordinator.isSystemAudioMuted
                ? "VoiceOour, \(accessibilityStatus), audio muted"
                : "VoiceOour, \(accessibilityStatus)"
        )
    }

    /// The app's one global affordance, promoted out of the Voice pane — and the only
    /// thing that earns a place in the rail's lower column. C46: a SIBLING
    /// accessibility element, because the identity block above combines its children
    /// under an overridden label that would otherwise swallow the keycaps.
    private var hotkey: some View {
        HStack(spacing: VoiceOourMetrics.Space.md) {
            Image(systemName: "mic")
                .font(.system(size: VoiceOourMetrics.Icon.row))
                .foregroundStyle(a11y.textLow)
                .frame(width: VoiceOourMetrics.Icon.navSlot, alignment: .center)
                .accessibilityHidden(true)

            HStack(spacing: VoiceOourMetrics.Space.xs) {
                KeyCap("Fn")
                Text("or")
                    // §4.2: the WORD `or` at `caption`/`Text.low` — it is the only
                    // thing distinguishing "Fn or Globe" from "Fn then Globe".
                    .roleStyle(.caption)
                KeyCap("Globe")
            }
        }
        .padding(.horizontal, VoiceOourMetrics.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture hotkey")
        .accessibilityValue("Fn or Globe")
        .accessibilityIdentifier("capture.hotkey")
    }
}
