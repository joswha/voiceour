import SwiftUI

struct LeftRail: View {
    @Binding var selection: ConsoleSection
    var coordinator: DictationCoordinator

    @Environment(\.surfaceGround) private var inheritedGround

    init(
        selection: Binding<ConsoleSection>,
        coordinator: DictationCoordinator,
    ) {
        _selection = selection
        self.coordinator = coordinator
    }

    private var status: RailStatus {
        switch coordinator.state {
        case .recording:
            .live
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .readyToInsert:
            .working
        case .error(_):
            .error
        default:
            .idle
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RailNavigation(selection: $selection)
            Spacer(minLength: VoiceourMetrics.Space.xl)
            RailFooter(coordinator: coordinator, status: status)
        }
        .padding(.top, VoiceourMetrics.Space.lg)
        .frame(width: VoiceourMetrics.Column.rail, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        // The rail stays a region of ground (§1.3) — no card fill, no rim, no
        // radius — but the nav labels, the wordmark and the status word sit
        // straight on the window material, where their contrast is a property of
        // the user's desktop. The scrim is the floor. No taper: every edge of it
        // is already a boundary — the window on three sides, the trailing rule on
        // the fourth — so there is nothing to fade into, and a fade under the
        // footer would give the text back the undefined ground it just lost.
        .background(alignment: .top) {
            GroundScrim()
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: VoiceourMetrics.Radius.window,
                        bottomLeadingRadius: VoiceourMetrics.Radius.window,
                        style: .continuous
                    )
                )
                .padding(.top, -VoiceourMetrics.Space.titlebar)
        }
        // The scrim IS the contrast floor for everything above it, so it has to say
        // so: `text-contrast` resolves each sample against the declared paint stack,
        // and without this the rail's labels are measured against the bare window
        // material they were specifically given a floor to escape. Under Reduce
        // Transparency that material is `Ink.frost`, where `Text.low` reads 3.86:1 —
        // a failure the lint would report against a ground no pixel actually has.
        // Composited, the real floor is sRGB(0.0404, 0.0504, 0.0704) and `Text.low`
        // reads 5.93:1.
        .environment(\.surfaceGround, inheritedGround.painting(GroundScrim.ink))
    }

}

struct RailItem: View {
    var section: ConsoleSection
    var isSelected: Bool
    var action: () -> Void

    private var a11y = A11y()

    init(
        section: ConsoleSection,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.section = section
        self.isSelected = isSelected
        self.action = action
    }

    /// One body on both paths. The rail is a region of the window ground, and the
    /// ground is already this app's one glass surface, so a second `.glassEffect`
    /// on the selected pill is glass on glass.
    ///
    /// That stack was removed after it erased the rail in the harness as a
    /// contiguous band from the rail's top edge down to the selected item's
    /// bottom edge, growing monotonically with selection index. The cause is the
    /// capture, not the renderer: `cacheDisplay(in:to:)` does not rasterise
    /// `.glassEffect`, so the band came back fully transparent rather than
    /// flattened. Dropping `.glassEffectID` and `.glassEffectTransition`
    /// reproduced the erasure byte for byte, and so did removing
    /// `GlassEffectContainer`, because none was implicated. A standalone probe
    /// of the same stack in a real onscreen window rendered every row, with the
    /// nested pill visibly lensing the desktop a second time. There is no
    /// shipping renderer defect here. The accessibility tree stayed
    /// byte-identical throughout, which a rasterisation gap by definition will:
    /// an AX golden cannot gate a visual regression.
    ///
    /// Selection therefore stays a fill-and-rim overlay on the ground as a
    /// deliberate, revisitable choice — the same one `SegmentOption` reached
    /// independently for the same question — and not because the renderer forbids
    /// glass here. Restoring it needs evidence that probe did not collect: an
    /// onscreen capture of the animated selection change, plus Reduce Transparency,
    /// Increase Contrast and light appearance. Until then functional glass is the
    /// window ground, the overlay island, the system popover chrome and the
    /// scroll-edge effects, and every control that sits on glass is painted.
    var body: some View {
        railButton
            .buttonStyle(PlateButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(section.label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var railButton: some View {
        Button(action: action) {
            HStack(spacing: VoiceourMetrics.Space.md) {
                Image(systemName: section.symbol)
                    .font(.system(size: VoiceourMetrics.Icon.nav))
                    .foregroundStyle(isSelected ? VoiceourPalette.Text.high : a11y.textLow)
                    .frame(width: VoiceourMetrics.Icon.navSlot, alignment: .center)
                    .accessibilityHidden(true)

                Text(section.label)
                    .roleStyle(.label)
                    .foregroundStyle(isSelected ? VoiceourPalette.Text.high : a11y.textMid)
                    .fontWeight(isSelected && a11y.differentiateWithoutColor ? .semibold : .medium)

                Spacer(minLength: VoiceourMetrics.Space.sm)
            }
            .padding(.horizontal, VoiceourMetrics.Space.md)
            .frame(minHeight: VoiceourMetrics.Row.nav)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isSelected && a11y.differentiateWithoutColor {
                    // A 3x16 bar is a pill by shape, not a rounded rectangle whose
                    // radius borrowed a spacing token.
                    Capsule(style: .continuous)
                        .fill(VoiceourPalette.Text.high)
                        .frame(
                            width: VoiceourMetrics.Space.xs - VoiceourMetrics.Stroke.hairline * 2,
                            height: VoiceourMetrics.Space.lg
                        )
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
