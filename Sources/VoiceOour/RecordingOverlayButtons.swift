import SwiftUI

/// The overlay's two controls are painted overlays on the island's glass on every
/// OS path. Unlike RowIconButton they keep a PERMANENT rest fill and stroke
/// (spec §5.16, bible §21.3 ¶4): the pill floats over arbitrary desktop content
/// with no window chrome to lean on, and the shared ghost ladder would make a
/// destructive control disappear against some backdrops. A second glass effect
/// here would be glass-on-glass. The interaction ladder is layered ON TOP of
/// that rest treatment, never instead of it.
struct RecordingOverlayButton: View {
    enum Kind {
        case cancel
        case finish
    }

    let kind: Kind
    let accessibilityLabel: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.glyph)
                .accessibilityHidden(true)
        }
        .buttonStyle(RecordingOverlayButtonStyle(kind: kind))
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

    /// The disc's own hue.
    fileprivate var tint: Color {
        switch self {
        case .cancel: VoiceOourPalette.Text.monoStrong
        case .finish: VoiceOourPalette.Signal.mint
        }
    }

    /// Discarding and committing used to be given identical weight, with the discard
    /// marginally the brighter of the two. Cancel is now the quiet escape at
    /// Text.mid (6.71:1 on the pill's glass) and finish stays mint (10.98:1), so the
    /// affirmative path out-ranks the destructive one.
    fileprivate var restForeground: Color {
        switch self {
        case .cancel: VoiceOourPalette.Text.mid
        case .finish: VoiceOourPalette.Signal.mint
        }
    }

    /// Where hover and press take the control: crimson names the discard before the
    /// pointer commits to it.
    fileprivate var activeForeground: Color {
        switch self {
        case .cancel: VoiceOourPalette.Signal.crimson
        case .finish: VoiceOourPalette.Signal.mint
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

    func makeBody(configuration: Configuration) -> some View {
        RecordingOverlayButtonBody(configuration: configuration, kind: kind)
    }
}

private struct RecordingOverlayButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: RecordingOverlayButton.Kind

    init(configuration: ButtonStyle.Configuration, kind: RecordingOverlayButton.Kind) {
        self.configuration = configuration
        self.kind = kind
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
            .font(.system(size: VoiceOourMetrics.Icon.mark, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(
                width: RecordingOverlayMetrics.Disc.visualSize,
                height: RecordingOverlayMetrics.Disc.visualSize
            )
            .background {
                ZStack {
                    Circle().fill(kind.tint.opacity(restFillOpacity))
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
                            VoiceOourPalette.Signal.focusHalo,
                            lineWidth: VoiceOourMetrics.Space.hair
                        )
                        .padding(-VoiceOourMetrics.Space.hair)
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
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: state)
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
            VoiceOourPalette.Plate.hover
        case .pressed:
            VoiceOourPalette.Plate.pressed
        case .focused:
            configuration.isPressed
                ? VoiceOourPalette.Plate.pressed
                : (isHovering ? VoiceOourPalette.Plate.hover : Color.clear)
        }
    }

    private var foreground: Color {
        switch state {
        case .disabled:
            a11y.textLow
        case .hover, .pressed:
            kind.activeForeground
        case .rest, .focused, .selected, .inFlight:
            kind.restForeground
        }
    }

    private var stroke: Color {
        switch state {
        case .rest, .disabled, .inFlight:
            kind.tint.opacity(restStrokeOpacity)
        case .hover:
            kind == .cancel
                ? VoiceOourPalette.Signal.crimson
                    .opacity(RecordingOverlayMetrics.Disc.activeStrokeOpacity)
                : VoiceOourPalette.Line.controlHover
        case .pressed:
            kind == .cancel
                ? VoiceOourPalette.Signal.crimson
                    .opacity(RecordingOverlayMetrics.Disc.pressedStrokeOpacity)
                : VoiceOourPalette.Line.controlHover
        case .focused:
            VoiceOourPalette.Line.focus
        case .selected:
            VoiceOourPalette.Signal.cyan
                .opacity(RecordingOverlayMetrics.Disc.activeStrokeOpacity)
        }
    }

    /// Width is reserved for focus and selection; hover and press escalate hue.
    private var strokeWidth: CGFloat {
        switch state {
        case .focused, .selected:
            VoiceOourMetrics.Stroke.selected(a11y.contrast)
        default:
            max(
                VoiceOourMetrics.Stroke.specular,
                VoiceOourMetrics.Stroke.hairline(a11y.contrast)
            )
        }
    }
}
