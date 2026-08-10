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
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .refining, .readyToInsert:
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
            Spacer(minLength: VoiceOourMetrics.Space.xl)
            RailFooter(coordinator: coordinator, status: status)
        }
        .padding(.top, VoiceOourMetrics.Space.lg)
        .frame(width: VoiceOourMetrics.Column.rail, alignment: .topLeading)
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
                        topLeadingRadius: VoiceOourMetrics.Radius.window,
                        bottomLeadingRadius: VoiceOourMetrics.Radius.window,
                        style: .continuous
                    )
                )
                .padding(.top, -VoiceOourMetrics.Space.titlebar)
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
    /// ground is already this app's one glass surface — so a second `.glassEffect`
    /// on the selected pill is glass on glass, which WWDC219 forbids outright and
    /// which the renderer punishes rather than merely discouraging.
    ///
    /// Measured on this macOS 26 host before removing it: the effect erased a
    /// contiguous band from the rail's top edge down to the selected item's bottom
    /// edge, growing monotonically with selection index — `console.home.os26` lost
    /// Home, `console.voice.os26` lost Home/Sessions/Voice, `console.diagnostics.os26`
    /// lost all seven. Dropping `.glassEffectID` and `.glassEffectTransition` while
    /// keeping `.glassEffect` reproduced the erasure byte for byte, so the effect
    /// itself is the cause, not the transition keying. Throughout, the accessibility
    /// tree stayed byte-identical to the legacy render, so an AX golden reported no
    /// change while up to seven nav items were invisible.
    ///
    /// Selection is therefore a fill-and-rim overlay on the ground, which is what
    /// `SegmentOption` independently concluded for the same question, and what the
    /// menu's primary action concluded after `.glassProminent` inside the popover's
    /// own glass lost its entire capsule and left a bare label. Functional glass is
    /// now only the window ground, the overlay island, the system popover chrome and
    /// the scroll-edge effects — every control that sits on glass is painted.
    var body: some View {
        railButton
            .buttonStyle(PlateButtonStyle(isSelected: isSelected))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(section.label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var railButton: some View {
        Button(action: action) {
            HStack(spacing: VoiceOourMetrics.Space.md) {
                Image(systemName: section.symbol)
                    .font(.system(size: VoiceOourMetrics.Icon.nav))
                    .foregroundStyle(isSelected ? VoiceOourPalette.Text.high : a11y.textLow)
                    .frame(width: VoiceOourMetrics.Icon.navSlot, alignment: .center)
                    .accessibilityHidden(true)

                Text(section.label)
                    .roleStyle(.label)
                    .foregroundStyle(isSelected ? VoiceOourPalette.Text.high : a11y.textMid)
                    .fontWeight(isSelected && a11y.differentiateWithoutColor ? .semibold : .medium)

                Spacer(minLength: VoiceOourMetrics.Space.sm)
            }
            .padding(.horizontal, VoiceOourMetrics.Space.md)
            .frame(minHeight: VoiceOourMetrics.Row.nav)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isSelected && a11y.differentiateWithoutColor {
                    // A 3x16 bar is a pill by shape, not a rounded rectangle whose
                    // radius borrowed a spacing token.
                    Capsule(style: .continuous)
                        .fill(VoiceOourPalette.Text.high)
                        .frame(
                            width: VoiceOourMetrics.Space.xs - VoiceOourMetrics.Stroke.hairline * 2,
                            height: VoiceOourMetrics.Space.lg
                        )
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
