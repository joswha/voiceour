import SwiftUI

struct GlassTextFieldStyle: TextFieldStyle {
    var font: Font = VoiceourTypography.body
    var harnessState: ControlState? = nil

    func _body(configuration: TextField<Self._Label>) -> some View {
        GlassTextFieldBody(
            configuration: configuration,
            font: font,
            harnessState: harnessState
        )
    }
}

/// Rest state composes `PlateSurface(.input)` — an `Ink.well` recess inside a
/// hairline outline (see `PlateSurface.restingFill`). Recessed, not raised: the
/// light plate a filled field would need is the thing that made an idle field
/// read as a solid gray block, while no fill at all made it the quietest
/// control on the surface. Hover and focus borrow the same `.hover`/`.selected`
/// kinds every other plate in the app already uses, so a field's interaction
/// ladder matches a row's or a nav item's instead of inventing its own — and
/// both lift *above* the recess. `.focusEffectDisabled()` kills the native
/// system-accent focus ring (previously unsuppressed — see design-bible §19.3)
/// so cyan-at-focus stays the only signal, per §4.4.
private struct GlassTextFieldBody<Label: View>: View {
    let configuration: TextField<Label>
    let font: Font
    let harnessState: ControlState?

    init(
        configuration: TextField<Label>,
        font: Font,
        harnessState: ControlState?
    ) {
        self.configuration = configuration
        self.font = font
        self.harnessState = harnessState
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    private var a11y = A11y()
    @State private var isHovering = false

    private var state: ControlState {
        ControlState.resolve(
            harnessState: harnessState,
            isEnabled: isEnabled,
            isFocused: isFocused,
            isHovering: isHovering
        )
    }

    private var baseState: ControlState {
        isHovering ? .hover : .rest
    }

    private var cornerRadius: CGFloat {
        VoiceourMetrics.Radius.nested(
            VoiceourMetrics.Radius.card,
            inset: VoiceourMetrics.Space.md
        )
    }

    var body: some View {
        configuration
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(state == .disabled ? a11y.textLow : VoiceourPalette.Text.high)
            .padding(.horizontal, VoiceourMetrics.TextField.horizontal)
            .frame(height: VoiceourMetrics.Control.medium)
            .plateSurface(
                kind: .input,
                cornerRadius: cornerRadius,
                state: state,
                baseState: baseState
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .disabled(harnessState == .disabled)
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
            .onHover { isHovering = $0 }
    }
}
