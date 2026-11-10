import AppKit
import SwiftUI
import VoiceCore

/// The one editor for a glossary term: the spelling dictation is held to and the
/// spoken forms that map onto it.
///
/// It is presentational by construction. It holds no coordinator, reads no
/// settings and performs no write: it edits the bindings its host owns and
/// reports the commands the host may run. Both surfaces that author a term —
/// the Glossary page and History's ⌘T teach — render this view, so a term
/// created from either names the same two things the same way.
///
/// It is drawn from the kit on the console's fixed-dark ground: each field is a
/// dark well with a hairline rim that lights cyan while it holds focus, each
/// spoken form is a plate with its remove control, and the commands are kit
/// buttons. A host places it inside a `Kit.Island`.
struct ConsoleTermEditor: View {
    /// A command the host performs, named by the host.
    ///
    /// `identifier` is the accessibility identifier flows address, so the editor
    /// never invents an identifier for a button whose meaning — Save, Teach,
    /// Remove Term — belongs to the surface that hosts it.
    struct Command {
        let title: String
        let identifier: String
        let isEnabled: Bool
        let perform: () -> Void
    }

    @Binding var term: String
    @Binding var spokenForms: [String]
    /// The case and spacing variants matched without the user typing them. This
    /// readout is the answer to "why don't I have to list every variant".
    var derivedForms: [String]
    /// Whether this host offers a well for a form beyond the ones already listed.
    /// Authoring terms is the Glossary's whole job, so it always offers one.
    /// History's teach arrives with the surface it was aimed at already in the
    /// set, so a well under that row would ask for a form nobody had heard yet and
    /// stand between the reader and the Teach button.
    var offersAdditionalForms: Bool
    var failure: String?
    var caption: String
    var submit: Command
    var cancel: () -> Void
    var destructive: Command?
    var identifierPrefix: String

    @State private var addText = ""
    /// Installed while the editor is on screen. Escape is AppKit's to report
    /// here: both hosts sit inside a scrolling page, an `NSScrollView` that
    /// consumes the key before SwiftUI offers it to `onExitCommand`. The
    /// modifier below covers a host that is not inside one.
    @State private var escapeMonitor: Any?
    @FocusState private var focused: Field?
    @Environment(\.surfaceGround) private var inheritedGround
    private var a11y = A11y()

    private enum Field: Hashable {
        case term
        case addForm
    }

    init(
        term: Binding<String>,
        spokenForms: Binding<[String]>,
        derivedForms: [String],
        offersAdditionalForms: Bool,
        failure: String?,
        caption: String,
        submit: Command,
        cancel: @escaping () -> Void,
        destructive: Command?,
        identifierPrefix: String
    ) {
        self._term = term
        self._spokenForms = spokenForms
        self.derivedForms = derivedForms
        self.offersAdditionalForms = offersAdditionalForms
        self.failure = failure
        self.caption = caption
        self.submit = submit
        self.cancel = cancel
        self.destructive = destructive
        self.identifierPrefix = identifierPrefix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
            termField
            heardAsField
            if !derivedForms.isEmpty {
                derivedReadout
            }
            commandRow
            Text(failure ?? caption)
                .roleStyle(.caption)
                .foregroundStyle(failure == nil ? a11y.textMid : VoiceourPalette.Signal.crimson)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand(perform: cancel)
        // Opening the editor is a request to type the spelling, so the affordance
        // is the editor's own rather than each host's.
        .defaultFocus($focused, .term)
        .onAppear {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53,
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                    event.window?.isKeyWindow == true
                else { return event }
                cancel()
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
            escapeMonitor = nil
        }
    }

    // MARK: - Term

    /// One labelled, full-measure well. The label above the field is hidden from
    /// accessibility because the field itself publishes the same title.
    private var termField: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            fieldLabel("Term")
                .accessibilityHidden(true)
            TextField("Term", text: $term, prompt: Text("kubectl"))
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .autocorrectionDisabled(true)
                .labelsHidden()
                .focused($focused, equals: .term)
                .onSubmit(submitIfEnabled)
                // No explicit label: a hidden-label `TextField` still publishes
                // its title, and adding one made VoiceOver read "Term, Term".
                .accessibilityIdentifier("\(identifierPrefix).canonical")
                .modifier(EditorWell(isFocused: focused == .term))
        }
    }

    // MARK: - Heard as

    /// The spoken forms, one plate each, and — when this host offers one — the
    /// well that adds another. A set with nothing in it always gets the well: a
    /// term has to be able to reach its first form, and with no rows the label and
    /// the prompt are what say where it goes.
    private var heardAsField: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            fieldLabel("Heard as")
            // Identity is the form itself, never its position: forms are unique
            // case-insensitively, so removing one leaves every surviving row the
            // row it was. The index is row data — it names the remove control.
            ForEach(Array(spokenForms.enumerated()), id: \.element) { entry in
                formRow(index: entry.offset, form: entry.element)
            }
            if showsAddField {
                addFormField
            }
        }
    }

    private var showsAddField: Bool {
        offersAdditionalForms || spokenForms.isEmpty
    }

    private var addFormField: some View {
        TextField("Heard as", text: $addText, prompt: Text("cube cuddle"))
            .textFieldStyle(.plain)
            .font(.body.monospaced())
            .autocorrectionDisabled(true)
            .labelsHidden()
            .focused($focused, equals: .addForm)
            .onSubmit { appendForms() }
            .accessibilityIdentifier("\(identifierPrefix).add-form")
            .modifier(EditorWell(isFocused: focused == .addForm))
    }

    private func formRow(index: Int, form: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Kit.Metrics.rowRadius, style: .continuous)
        return HStack(spacing: VoiceourMetrics.Space.sm) {
            Text(form)
                .font(.body.monospaced())
                .foregroundStyle(VoiceourPalette.Text.high)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                spokenForms.remove(at: index)
            } label: {
                // The glyph is 13 pt; the affordance has to be bigger than the
                // ink. `glyphControl` is the kit's smallest press target and
                // clears this project's 22x22 hit floor.
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .frame(width: Kit.Metrics.glyphControl, height: Kit.Metrics.glyphControl)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(a11y.textMid)
            .help("Remove \(form)")
            .accessibilityLabel("Remove spoken form \(form)")
            .accessibilityIdentifier("\(identifierPrefix).form.\(index).remove")
        }
        .padding(.leading, VoiceourMetrics.Space.sm + VoiceourMetrics.Space.xs)
        .padding(.trailing, VoiceourMetrics.Space.xs)
        .frame(height: Kit.Metrics.control)
        .background(VoiceourPalette.Plate.rest, in: shape)
        .overlay(shape.strokeBorder(a11y.lineRule, lineWidth: Kit.Colors.hairline(a11y)))
        .environment(\.surfaceGround, inheritedGround.painting(VoiceourPalette.Plate.rest))
    }

    // MARK: - Readouts

    private var derivedReadout: some View {
        Kit.Fact("Also matched") {
            Text(derivedForms.joined(separator: " · "))
                .font(.callout.monospaced())
                .foregroundStyle(a11y.textMid)
                .textSelection(.enabled)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .roleStyle(.caption)
            .foregroundStyle(a11y.textMid)
    }

    // MARK: - Commands

    /// The affirmative pair leads; the destructive command is pushed to the
    /// trailing edge so it cannot be hit while reaching for Save.
    private var commandRow: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Kit.GlassGroup {
                Kit.ActionButton(submit.title, prominence: .primary, action: performSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isSubmitEnabled)
                    .accessibilityIdentifier(submit.identifier)
                Kit.ActionButton("Cancel", action: cancel)
                    .accessibilityIdentifier("\(identifierPrefix).cancel")
            }
            Spacer(minLength: 0)
            if let destructive {
                Kit.ActionButton(destructive.title, role: .destructive, action: destructive.perform)
                    .disabled(!destructive.isEnabled)
                    .accessibilityIdentifier(destructive.identifier)
            }
        }
    }

    // MARK: - Editing

    /// A form typed into the add field but never entered still counts, both for
    /// whether the command is offered and for what it commits. Typing a form and
    /// pressing Save is the obvious gesture, and dropping that text on the floor
    /// would report a save that saved less than the editor was showing.
    private var pendingForms: [String] {
        parsedGlossaryAliases(addText)
    }

    private var isSubmitEnabled: Bool {
        if submit.isEnabled { return true }
        return !pendingForms.isEmpty && !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performSubmit() {
        appendForms(keepingFocus: false)
        submit.perform()
    }

    private func submitIfEnabled() {
        guard isSubmitEnabled else { return }
        performSubmit()
    }

    /// Adds everything the add field currently holds. The comma-separated parse
    /// stays because a pasted list of forms is one of the ways a term arrives.
    private func appendForms(keepingFocus: Bool = true) {
        for form in pendingForms {
            appendForm(form)
        }
        addText = ""
        guard keepingFocus else { return }
        // A host that offers the well only until the set holds something loses it
        // right here, and focus cannot stay on a field that is gone.
        focused = showsAddField ? .addForm : .term
    }

    /// Adds a form the set does not already hold. Case-insensitive, because two
    /// spellings of one spoken form are one form and the glossary refuses the
    /// second anyway.
    private func appendForm(_ form: String) {
        guard !spokenForms.contains(where: { $0.caseInsensitiveCompare(form) == .orderedSame }) else {
            return
        }
        spokenForms.append(form)
    }
}

/// A text field's well on the dark ground: the `Ink.well` fill, a hairline rim,
/// and the cyan focus rim the plain field style no longer draws, so a reader
/// steering with the keyboard still sees where the caret is. The surface ground
/// is declared so the harness measures the field's text against the well.
private struct EditorWell: ViewModifier {
    private let isFocused: Bool
    private var a11y = A11y()

    init(isFocused: Bool) {
        self.isFocused = isFocused
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Kit.Metrics.rowRadius, style: .continuous)
        content
            .foregroundStyle(VoiceourPalette.Text.high)
            .padding(.horizontal, VoiceourMetrics.Space.sm + VoiceourMetrics.Space.xs)
            .frame(height: Kit.Metrics.control)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiceourPalette.Ink.well, in: shape)
            .overlay(
                shape.strokeBorder(
                    isFocused ? VoiceourPalette.Line.focus : a11y.lineEdge,
                    lineWidth: isFocused ? 1.5 : Kit.Colors.hairline(a11y)
                )
            )
            .environment(\.surfaceGround, SurfaceGround(VoiceourPalette.Ink.well))
    }
}
