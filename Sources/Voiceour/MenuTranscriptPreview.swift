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
/// The well holds the transcript and nothing else: its tooltip and accessibility
/// label name the action, and `MenuReportBlock` confirms a copy under the well.
struct MenuTranscriptPreview: View {
    let text: String
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(VoiceourTypography.caption)
                .foregroundStyle(VoiceourPalette.Text.high)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .buttonStyle(MenuWellButtonStyle())
        .accessibilityLabel("Copy last transcript")
        .accessibilityValue(text)
        .help("Click to copy the last transcript.")
    }
}

/// A well that is also the control, so this style owns the recess: it paints
/// `Ink.well`, escalates that fill with the interaction ladder, and derives its
/// radius concentrically from the popover.
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
            .padding(VoiceourMetrics.Space.sm)
            // Pinned rather than content-sized: the popover must not reflow its
            // own height as transcripts change length. Three 15 pt caption lines
            // and the `Space.sm` padding come to 61 pt, so one `Row.list` pitch
            // holds the tallest transcript and keeps the press target on the row
            // scale.
            .frame(maxWidth: .infinity, minHeight: VoiceourMetrics.Row.list, alignment: .topLeading)
            .background {
                ZStack {
                    MenuLayout.innerShape
                        .fill(VoiceourPalette.Ink.well)
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
            // This body paints `Ink.well` and its wash by hand, so it also has
            // to declare what it painted — otherwise every transcript sample is
            // measured against the popover's ground instead of the recess the
            // text actually sits in.
            .environment(\.surfaceGround, inheritedGround.painting(VoiceourPalette.Ink.well).painting(wash))
            .contentShape(MenuLayout.innerShape)
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
            .onHover { isHovering = $0 }
    }

    private var stroke: Color {
        switch state {
        case .focused, .selected:
            VoiceourPalette.Line.focus
        case .hover, .pressed, .inFlight:
            VoiceourPalette.Line.controlHover
        case .rest, .disabled:
            a11y.lineControl
        }
    }

    private var wash: Color {
        switch state {
        case .pressed:
            VoiceourPalette.Plate.hover
        case .hover, .focused, .selected:
            VoiceourPalette.Plate.rest
        case .rest, .disabled, .inFlight:
            Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        state == .focused || state == .selected
            ? VoiceourMetrics.Stroke.selected(a11y.contrast)
            : VoiceourMetrics.Stroke.hairline(a11y.contrast)
    }
}
