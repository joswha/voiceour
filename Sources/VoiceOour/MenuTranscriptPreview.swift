import Foundation
import SwiftUI

/// The last transcript, and the control that copies it.
///
/// The copy affordance belongs to the object it acts on. It used to live in the
/// global command list on the far side of a group separator, 133 pt below the
/// card, where it survived as a permanently-disabled dead row whenever the card
/// it belonged to was absent. Attached to the card, the action appears and
/// disappears with the transcript and the separator goes back to separating
/// unrelated things.
///
/// The box is pinned to one height for every transcript it can hold: `Row.list`
/// of content, `Space.sm` of well padding, an 80 pt press target that does not
/// move between a one-, two- and three-line transcript.
struct MenuTranscriptPreview: View {
    let text: String
    let isCopied: Bool
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
                HStack(spacing: VoiceOourMetrics.Space.sm) {
                    Text("LAST TRANSCRIPT")
                        .roleStyle(.micro)

                    Spacer(minLength: VoiceOourMetrics.Space.sm)

                    Text(isCopied ? "COPIED" : "CLICK TO COPY")
                        .roleStyle(.micro)
                        .foregroundStyle(
                            isCopied
                                ? VoiceOourPalette.Signal.mint
                                : VoiceOourPalette.Text.low
                        )
                }

                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(VoiceOourTypography.caption)
                    .foregroundStyle(VoiceOourPalette.Text.high)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Pinned rather than content-sized, for two reasons that resolve to
            // the same number. The popover must not reflow its own height as
            // transcripts change length, and `lineLimit(3)` bounds the content
            // at 62 pt — the 13 pt eyebrow row, `Space.xs`, and three 15 pt
            // caption lines — so `Row.list` clears the tallest case. It is also
            // the smallest measure that keeps the press target on the control
            // scale: 64 plus the well's own `Space.sm` padding is 80.
            .frame(minHeight: VoiceOourMetrics.Row.list, alignment: .topLeading)
        }
        .buttonStyle(MenuWellButtonStyle())
        .accessibilityLabel("Copy last transcript")
        .accessibilityValue(text)
        .help("Click to copy the last transcript.")
    }
}

/// A well that is also the control. `PlateSurface(kind: .well)` pins itself to
/// `.rest`, so an interactive well cannot escalate through it; the tokens and
/// the derived radius are the shared ones either way.
private struct MenuWellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuWellBody(configuration: configuration)
    }
}

private struct MenuWellBody: View {
    let configuration: ButtonStyle.Configuration

    init(configuration: ButtonStyle.Configuration) {
        self.configuration = configuration
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.surfaceGround) private var inheritedGround
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
            .padding(VoiceOourMetrics.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    MenuLayout.innerShape
                        .fill(VoiceOourPalette.Ink.well)
                    // A well recesses by darkening; on a near-black ground the
                    // only headroom left is upward, so interaction lifts the
                    // fill rather than deepening it.
                    MenuLayout.innerShape
                        .fill(wash)
                }
            }
            .overlay {
                MenuLayout.innerShape
                    .strokeBorder(stroke, lineWidth: strokeWidth)
            }
            // This body paints `Ink.well` by hand rather than routing through
            // `PlateSurface`, so it also has to declare what it painted — otherwise
            // every transcript sample is measured against the popover's ground
            // instead of the recess the text actually sits in.
            .environment(\.surfaceGround, inheritedGround.painting(VoiceOourPalette.Ink.well).painting(wash))
            .contentShape(MenuLayout.innerShape)
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceOourMotion.quick, value: state)
            .onHover { isHovering = $0 }
    }

    private var stroke: Color {
        switch state {
        case .focused, .selected:
            VoiceOourPalette.Line.focus
        case .hover, .pressed, .inFlight:
            VoiceOourPalette.Line.controlHover
        case .rest, .disabled:
            a11y.lineControl
        }
    }

    private var wash: Color {
        switch state {
        case .pressed:
            VoiceOourPalette.Plate.hover
        case .hover, .focused, .selected:
            VoiceOourPalette.Plate.rest
        case .rest, .disabled, .inFlight:
            Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        state == .focused || state == .selected
            ? VoiceOourMetrics.Stroke.selected(a11y.contrast)
            : VoiceOourMetrics.Stroke.hairline(a11y.contrast)
    }
}
