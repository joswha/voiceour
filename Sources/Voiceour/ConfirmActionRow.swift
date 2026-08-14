import Foundation
import SwiftUI

// MARK: - ConfirmActionRow

/// A destructive row with its typed-confirmation gate inline on the grid.
///
/// The state machine is unchanged from the card this replaces. The gate lives
/// inside `confirm()`, the only caller of the mutation, so the button,
/// `.onSubmit` and any accessibility activation all pass through it. Binding
/// `.onSubmit` straight to the mutation is what makes `.disabled(text !=
/// token)` on the button a decoration: Return commits whatever is typed.
///
/// In flight is a state of the button rather than a `.disabled` predicate, so
/// `CLEARING…` keeps its enabled foreground instead of rendering the one
/// moment the user most needs feedback at 1.74:1. Activation is still blocked
/// on every path, because `GlassButtonStyle` disables the control it wraps.
///
/// Collapsed and armed both present a single `Control.medium` band, so the
/// row does not resize and shove its neighbour when the branch opens, and the
/// action keeps one label across both. Failure adds a line *below* the band
/// instead of a chip beside the controls: field, confirm, cancel and a chip
/// do not fit the 536pt content slot, and the moment a destructive action
/// reports that it erased nothing is the worst possible moment to reflow.
///
/// The pane owns `isConfirming` because arming has to scroll the danger
/// section into view, which is the pane's business and not the row's.
struct ConfirmActionRow: View {
    var label: String
    /// What the flow destroys, in sentence case. The row label is a grid
    /// designator; VoiceOver should not have to read the pane's typography.
    var subject: String
    /// The explanatory sentence shown while the row is collapsed.
    var scope: String
    var token: String
    var actionTitle: String
    var inFlightTitle: String
    var failureLabel: String
    var failureText: String
    var identifier: String
    var isAvailable: Bool
    @Binding var isConfirming: Bool
    /// Reports whether the mutation reached disk.
    var perform: () async -> Bool

    @State private var confirmation = ""
    @State private var isInFlight = false
    @State private var didFail = false
    @FocusState private var isFieldFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    /// Explicit: a private stored property makes the synthesised memberwise
    /// initializer private too.
    init(
        label: String,
        subject: String,
        scope: String,
        token: String = "CLEAR",
        actionTitle: String,
        inFlightTitle: String,
        failureLabel: String,
        failureText: String,
        identifier: String,
        isAvailable: Bool,
        isConfirming: Binding<Bool>,
        perform: @escaping () async -> Bool
    ) {
        self.label = label
        self.subject = subject
        self.scope = scope
        self.token = token
        self.actionTitle = actionTitle
        self.inFlightTitle = inFlightTitle
        self.failureLabel = failureLabel
        self.failureText = failureText
        self.identifier = identifier
        self.isAvailable = isAvailable
        self._isConfirming = isConfirming
        self.perform = perform
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            HStack(alignment: .center, spacing: VoiceourMetrics.Space.xl) {
                Text(label)
                    .font(VoiceourTypography.label)
                    .foregroundStyle(labelForeground)
                    .recordTextRole(.label, foreground: labelForeground)
                    .frame(width: VoiceourMetrics.Column.settingsLabel, alignment: .leading)

                if isConfirming {
                    armedBand
                        .transition(.opacity)
                } else {
                    collapsedBand
                        .transition(.opacity)
                }
            }
            .frame(minHeight: VoiceourMetrics.Control.medium)

            if didFail {
                failureLine
                    .padding(.leading, PropertyGrid.valueOrigin)
            }
        }
        .padding(.vertical, VoiceourMetrics.Space.xs)
        .frame(
            maxWidth: .infinity,
            minHeight: didFail ? VoiceourMetrics.Row.settings : VoiceourMetrics.Row.table,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .anchorPreference(key: SettingsRowBoundsPreferenceKey.self, value: .bounds) { [$0] }
        .settingsContentLead(VoiceourMetrics.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var collapsedBand: some View {
        HStack(alignment: .center, spacing: VoiceourMetrics.Space.sm) {
            // The sentence explains what a destructive action erases, so it
            // must never truncate mid-clause: the row grows a line instead.
            // Arming already swaps this band for three controls (and scrolls
            // the row into view), so a height change here costs nothing.
            CaptionText(scope)

            Button(actionTitle) { setConfirming(true) }
                .buttonStyle(GlassButtonStyle(kind: .danger))
                .disabled(!isAvailable)
                .accessibilityIdentifier("\(identifier).arm")
        }
    }

    private var armedBand: some View {
        HStack(alignment: .center, spacing: VoiceourMetrics.Space.sm) {
            TextField("Type \(token)", text: $confirmation)
                .textFieldStyle(GlassTextFieldStyle(font: VoiceourTypography.bodyMono))
                .frame(width: VoiceourMetrics.Field.medium)
                .focused($isFieldFocused)
                // The field does not exist when the action that inserts it
                // runs, so focus is requested from the field itself.
                .onAppear { isFieldFocused = true }
                .onSubmit(confirm)
                .onExitCommand(perform: cancel)
                .onChange(of: confirmation) { didFail = false }
                .accessibilityLabel("\(subject) confirmation")
                .accessibilityIdentifier("\(identifier).confirmation")

            Button(isInFlight ? inFlightTitle : actionTitle, action: confirm)
                .buttonStyle(GlassButtonStyle(kind: .danger, isInFlight: isInFlight))
                .disabled(!canConfirm)
                .accessibilityIdentifier("\(identifier).confirm")

            Button("CANCEL", action: cancel)
                .buttonStyle(GlassButtonStyle(kind: .ghost))
                .disabled(isInFlight)
                .accessibilityLabel("Cancel clearing \(subject.lowercased())")
                .accessibilityIdentifier("\(identifier).cancel")

            Spacer(minLength: 0)
        }
    }

    /// The caption carries the reason and takes the width; the chip closes the
    /// line on the trailing rail like every other mark in the ledger.
    private var failureLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceourMetrics.Space.sm) {
            CaptionText(failureText, color: VoiceourPalette.Signal.crimson)

            StatusChip(label: failureLabel, mode: .crit, size: .compact)
        }
    }

    private var labelForeground: Color {
        isEnabled ? VoiceourPalette.Text.high : a11y.textLow
    }

    /// Surrounding whitespace on a typed token is a typo, not a different
    /// intent; the token itself still has to match exactly.
    private var canConfirm: Bool {
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines) == token && !isInFlight
    }

    // MARK: Actions

    /// The single guarded entry point. Nothing else calls the mutation.
    private func confirm() {
        guard canConfirm else { return }
        isInFlight = true
        didFail = false
        Task {
            let isDurable = await perform()
            isInFlight = false
            guard isDurable else {
                // A destructive action that half-succeeds must say so: the row
                // stays armed with the typed token intact, and reports that
                // the data survived on disk instead of reporting nothing.
                didFail = true
                return
            }
            confirmation = ""
            setConfirming(false)
        }
    }

    private func cancel() {
        guard !isInFlight else { return }
        confirmation = ""
        didFail = false
        setConfirming(false)
    }

    /// Replacing one button with three controls is a deliberate step, so it
    /// cross-fades rather than cutting. Reduce Motion keeps the state change
    /// and drops only the fade.
    private func setConfirming(_ isOpen: Bool) {
        if a11y.reduceMotion {
            isConfirming = isOpen
        } else {
            withAnimation(VoiceourMotion.deliberate) { isConfirming = isOpen }
        }
    }
}
