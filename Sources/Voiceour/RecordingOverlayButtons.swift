import SwiftUI

/// The overlay's two controls are painted overlays on the island's surface on every OS
/// path. Unlike RowIconButton they keep a PERMANENT rest fill and stroke: the pill floats
/// over arbitrary desktop content with no window chrome to lean on, and the shared ghost
/// ladder would make a destructive control disappear against some backdrops. A second
/// glass effect here would be glass-on-glass, which cannot sample the capsule's own
/// material. The interaction ladder is layered ON TOP of that rest treatment, never
/// instead of it.
///
/// Every colour resolves through ``RecordingOverlaySurface``. The values these controls
/// used to name directly were all light-on-dark, and the contrast that justified them was
/// measured against the near-black painted pill; macOS 26's material is adaptive, so on a
/// light desktop those same values land on near-white.
struct RecordingOverlayButton: View {
    enum Kind {
        case cancel
        case finish
    }

    let kind: Kind
    let surface: RecordingOverlaySurface
    let accessibilityLabel: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.glyph)
                .accessibilityHidden(true)
        }
        .buttonStyle(RecordingOverlayButtonStyle(kind: kind, surface: surface))
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }
}

extension RecordingOverlayButton.Kind {
    fileprivate var glyph: String {
        switch self {
        case .cancel: "xmark"
        case .finish: "checkmark"
        }
    }

    /// The rest plate's hue. Cancel's plate carries no meaning, so on glass it follows the
    /// appearance; finish's does, so it keeps its hue on both grounds.
    fileprivate func plate(_ surface: RecordingOverlaySurface) -> Color {
        switch self {
        case .cancel: surface.neutral
        case .finish: surface.affirm
        }
    }

    /// Discarding and committing used to be given identical weight, with the discard
    /// marginally the brighter of the two. Cancel is now the quiet escape and finish the
    /// affirmative one, so the constructive path out-ranks the destructive one.
    fileprivate func restForeground(_ surface: RecordingOverlaySurface) -> Color {
        switch self {
        case .cancel: surface.quietLabel
        case .finish: surface.affirm
        }
    }

    /// Where hover and press take the control: crimson names the discard before the
    /// pointer commits to it.
    fileprivate func activeForeground(_ surface: RecordingOverlaySurface) -> Color {
        switch self {
        case .cancel: surface.destroy
        case .finish: surface.affirm
        }
    }

    fileprivate var restFillOpacity: Double {
        switch self {
        case .cancel: RecordingOverlayMetrics.Disc.cancelFillOpacity
        case .finish: RecordingOverlayMetrics.Disc.finishFillOpacity
        }
    }

    fileprivate var restStrokeOpacity: Double {
        switch self {
        case .cancel: RecordingOverlayMetrics.Disc.cancelStrokeOpacity
        case .finish: RecordingOverlayMetrics.Disc.finishStrokeOpacity
        }
    }
}

private struct RecordingOverlayButtonStyle: ButtonStyle {
    let kind: RecordingOverlayButton.Kind
    let surface: RecordingOverlaySurface

    func makeBody(configuration: Configuration) -> some View {
        RecordingOverlayButtonBody(configuration: configuration, kind: kind, surface: surface)
    }
}

private struct RecordingOverlayButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: RecordingOverlayButton.Kind
    let surface: RecordingOverlaySurface

    init(
        configuration: ButtonStyle.Configuration,
        kind: RecordingOverlayButton.Kind,
        surface: RecordingOverlaySurface
    ) {
        self.configuration = configuration
        self.kind = kind
        self.surface = surface
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    private var a11y = A11y()
    @State private var isHovering = false

    private var state: ControlState {
        ControlState.resolve(
            isEnabled: isEnabled,
            isFocused: isFocused,
            isPressed: configuration.isPressed,
            isHovering: isHovering
        )
    }

    var body: some View {
        configuration.label
            .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(
                width: RecordingOverlayMetrics.Disc.visualSize,
                height: RecordingOverlayMetrics.Disc.visualSize
            )
            .background {
                ZStack {
                    Circle().fill(kind.plate(surface).opacity(restFillOpacity))
                    Circle().fill(interactionWash)
                }
            }
            .overlay {
                Circle().strokeBorder(stroke, lineWidth: strokeWidth)
            }
            .overlay {
                if state == .focused {
                    Circle()
                        .strokeBorder(
                            surface.focusHalo,
                            lineWidth: VoiceourMetrics.Space.hair
                        )
                        .padding(-VoiceourMetrics.Space.hair)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(state == .pressed ? RecordingOverlayMetrics.Disc.pressedScale : 1)
            .frame(
                width: RecordingOverlayMetrics.Disc.hitSize,
                height: RecordingOverlayMetrics.Disc.hitSize
            )
            // The panel's mouse router tests this exact 28x28 rect, so the hit shape
            // is that rect and not the inscribed circle: a corner press must not fall
            // between the button and the drag branch.
            .contentShape(Rectangle())
            .focusEffectDisabled()
            .onHover { isHovering = $0 }
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
    }

    /// The permanent rest chrome, escalated one fixed step under Increase Contrast —
    /// which used to widen the two rims that already read at 10:1 and leave the two
    /// faintest things on the surface untouched.
    private var restFillOpacity: Double {
        a11y.contrast == .increased
            ? kind.restFillOpacity + RecordingOverlayMetrics.Disc.increasedFillBoost
            : kind.restFillOpacity
    }

    private var restStrokeOpacity: Double {
        a11y.contrast == .increased
            ? kind.restStrokeOpacity + RecordingOverlayMetrics.Disc.increasedStrokeBoost
            : kind.restStrokeOpacity
    }

    /// Layered over the rest fill, never replacing it.
    private var interactionWash: Color {
        switch state {
        case .rest, .disabled, .inFlight:
            Color.clear
        case .hover, .selected:
            surface.wash
        case .pressed:
            surface.washPressed
        case .focused:
            configuration.isPressed
                ? surface.washPressed
                : (isHovering ? surface.wash : Color.clear)
        }
    }

    private var foreground: Color {
        switch state {
        case .disabled:
            surface.isDarkGround ? a11y.textLow : Color.secondary.opacity(0.5)
        case .hover, .pressed:
            kind.activeForeground(surface)
        case .rest, .focused, .selected, .inFlight:
            kind.restForeground(surface)
        }
    }

    private var stroke: Color {
        switch state {
        case .rest, .disabled, .inFlight:
            kind.plate(surface).opacity(restStrokeOpacity)
        case .hover:
            kind == .cancel
                ? surface.destroy
                    .opacity(RecordingOverlayMetrics.Disc.activeStrokeOpacity)
                : surface.controlHover
        case .pressed:
            kind == .cancel
                ? surface.destroy
                    .opacity(RecordingOverlayMetrics.Disc.pressedStrokeOpacity)
                : surface.controlHover
        case .focused:
            surface.focusRing
        case .selected:
            surface.live
                .opacity(RecordingOverlayMetrics.Disc.activeStrokeOpacity)
        }
    }

    /// Width is reserved for focus and selection; hover and press escalate hue.
    private var strokeWidth: CGFloat {
        switch state {
        case .focused, .selected:
            VoiceourMetrics.Stroke.selected(a11y.contrast)
        default:
            max(
                VoiceourMetrics.Stroke.specular,
                VoiceourMetrics.Stroke.hairline(a11y.contrast)
            )
        }
    }
}
