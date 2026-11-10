import Foundation
import SwiftUI

/// The last transcript, and the control that copies it.
///
/// The copy affordance belongs to the object it acts on: attached to the well,
/// the action appears and disappears with the transcript instead of surviving as
/// a dead row in the command list whenever there is nothing to copy.
///
/// The well holds the transcript and nothing else: its tooltip and accessibility
/// label name the action, and `MenuReportBlock` confirms a copy under the well.
struct MenuTranscriptPreview: View {
    let text: String
    let copy: () -> Void

    @Environment(\.theme) private var theme

    init(text: String, copy: @escaping () -> Void) {
        self.text = text
        self.copy = copy
    }

    var body: some View {
        Button(action: copy) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .roleStyle(.meta)
                .foregroundStyle(theme.text1)
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

/// A well that is also the control, so this style owns the surface: the theme's
/// recessed `sunken` ground inside a `border`, lifted to `hover` / `pressed` by
/// interaction and ringed by `focusRing` under keyboard focus.
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

    @Environment(\.theme) private var theme
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
            // own height as transcripts change length. Three 15 pt `meta` lines
            // and the 8 pt padding come to 61 pt, so one preview-row pitch holds
            // the tallest transcript and keeps the press target on the row scale.
            .frame(maxWidth: .infinity, minHeight: Kit.Metrics.rowHeightPreview, alignment: .topLeading)
            .background(MenuLayout.innerShape.fill(fill))
            .overlay {
                MenuLayout.innerShape.strokeBorder(stroke, lineWidth: 1)
            }
            .overlay {
                // Outset so the ring never covers the first line, and dropped
                // while pressed so focus and press never read as one state.
                if state == .focused {
                    RoundedRectangle(cornerRadius: MenuLayout.innerRadius + 3, style: .continuous)
                        .strokeBorder(theme.focusRing, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            // The fill is opaque, so the transcript is measured against it alone.
            .environment(\.surfaceGround, inheritedGround.painting(fill))
            .contentShape(MenuLayout.innerShape)
            .focusEffectDisabled()
            .animation(a11y.reduceMotion ? nil : VoiceourMotion.quick, value: state)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        switch state {
        case .pressed: theme.pressed
        case .hover, .focused, .selected: theme.hover
        case .rest, .disabled, .inFlight: theme.sunken
        }
    }

    /// Interaction strengthens the outline so hover is not carried by the fill's
    /// small lightness step alone.
    private var stroke: Color {
        switch state {
        case .hover, .pressed: theme.borderStrong
        case .rest, .disabled, .inFlight, .focused, .selected: theme.border
        }
    }
}
