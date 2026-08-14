import SwiftUI

/// The popover's primary action: a painted capsule on every OS path, keeping the
/// capsule geometry this project uses for spacious emphasis.
///
/// This comment used to say that `.glassProminent` here erases the capsule while
/// inflating its hit frame. Measured in a real `MenuBarExtra` host on macOS 26.5.2,
/// it does neither. It draws a solid accent capsule at mean luminance 152.2 against
/// the bare host material's 65.5 — more visually present than the painted capsule
/// it would replace, which measures 81.5. The erasure was `cacheDisplay`: the same
/// content through the offscreen harness path measures 7.3 against a 7.7 backdrop
/// and vanishes, leaving exactly the bare label described here. It is the
/// rasterisation gap `RailItem` documents, not a renderer defect.
///
/// Painted still ships, for the three reasons that survive that measurement.
///
/// 1. macOS 14 is the deployment floor, so this capsule is built either way.
///    `.glassProminent` would only add a second path, not replace one.
/// 2. The system prominent style paints the system accent colour — green on this
///    host — discarding the app's cyan `Signal` semantic and the rim-contrast
///    ladder measured against it. That is a design cost, not a rendering one.
/// 3. Its natural height is 21pt, and 33pt at `.controlSize(.extraLarge)` with
///    `.buttonBorderShape(.capsule)`, against the 40pt `Control.large` this action
///    pins. `.frame(height: 40)` sizes the slot rather than the control: the 21pt
///    capsule centres inside it, so the AX golden's `START DICTATION
///    [12,90 256x40]` becomes 256x21 ten points lower, and tightening the frame
///    only fits the slot to the same capsule. Left at its natural height it
///    shrinks the popover from 215 to 196 and lifts every AX frame below this one
///    by 19pt. A true 40 is reachable — `.glassProminent` with
///    `.frame(maxWidth: .infinity, minHeight: 32)` on the LABEL measures 256x40
///    exactly — but only as a deliberate choice, never as a drop-in.
struct PrimaryActionButtonStyle: PrimitiveButtonStyle {
    var isInFlight: Bool = false
    var harnessState: ControlState? = nil

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let effectiveInFlight = isInFlight || harnessState == .inFlight

        paintedBody(configuration: configuration, effectiveInFlight: effectiveInFlight)
    }

    private func paintedBody(
        configuration: Configuration,
        effectiveInFlight: Bool
    ) -> some View {
        Button {
            guard !effectiveInFlight else { return }
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(
            PrimaryActionVisualStyle(
                isInFlight: effectiveInFlight,
                harnessState: harnessState
            )
        )
        .disabled(effectiveInFlight || harnessState == .disabled)
        .accessibilityValue(effectiveInFlight ? "In progress" : "")
    }

}

private struct PrimaryActionVisualStyle: ButtonStyle {
    let isInFlight: Bool
    let harnessState: ControlState?

    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionBody(
            configuration: configuration,
            isInFlight: isInFlight,
            harnessState: harnessState
        )
    }
}

private struct PrimaryActionBody: View {
    let configuration: ButtonStyle.Configuration
    let isInFlight: Bool
    let harnessState: ControlState?

    init(
        configuration: ButtonStyle.Configuration,
        isInFlight: Bool,
        harnessState: ControlState?
    ) {
        self.configuration = configuration
        self.isInFlight = isInFlight
        self.harnessState = harnessState
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.surfaceGround) private var inheritedGround
    private var a11y = A11y()
    @State private var isHovering = false

    private var state: ControlState {
        ControlState.resolve(
            harnessState: harnessState,
            isEnabled: isEnabled,
            isFocused: isFocused,
            isPressed: configuration.isPressed,
            isHovering: isHovering,
            isInFlight: isInFlight
        )
    }

    /// Cyan 0.42, not the 0.36 an earlier draft carried: at 0.36 the rim measured
    /// 2.63:1 against its own fill and failed the 3:1 non-text floor the rest of
    /// the control system is held to.
    private var stroke: Color {
        switch state {
        case .disabled: a11y.lineRule
        case .hover, .pressed, .focused, .selected: VoiceourPalette.Signal.cyan.opacity(0.62)
        case .rest, .inFlight: VoiceourPalette.Signal.cyan.opacity(0.42)
        }
    }

    private var fill: Color {
        switch state {
        case .disabled: .clear
        case .pressed: VoiceourPalette.Signal.cyanDeep.opacity(0.22)
        case .hover, .focused, .selected: VoiceourPalette.Signal.cyan.opacity(0.14)
        case .rest, .inFlight: VoiceourPalette.Signal.cyan.opacity(0.08)
        }
    }

    private var foreground: Color {
        state == .disabled ? a11y.textLow : VoiceourPalette.Signal.cyan
    }

    var body: some View {
        configuration.label
            .roleStyle(.micro, color: foreground)
            .padding(.horizontal, VoiceourMetrics.Space.lg)
            .frame(height: VoiceourMetrics.Control.large)
            .background(Capsule(style: .continuous).fill(fill))
            .environment(\.surfaceGround, inheritedGround.painting(fill))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: primaryStrokeWidth)
            }
            .overlay {
                if state == .focused {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            VoiceourPalette.Signal.focusHalo,
                            lineWidth: VoiceourMetrics.Space.hair
                        )
                        .padding(-VoiceourMetrics.Space.hair)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(state == .pressed ? VoiceourMetrics.Control.pressedScale : 1)
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovering = $0 }
            .focusEffectDisabled()
    }

    private var primaryStrokeWidth: CGFloat {
        if state == .focused || (state == .hover && a11y.differentiateWithoutColor) {
            return VoiceourMetrics.Stroke.selected(a11y.contrast)
        }
        return VoiceourMetrics.Stroke.hairline(a11y.contrast)
    }
}
