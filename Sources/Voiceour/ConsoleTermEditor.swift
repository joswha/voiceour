import AppKit
import SwiftUI
import VoiceCore

/// The one editor for a glossary term: the spelling dictation is held to, the
/// spoken forms that map onto it, and the scope it is active in.
///
/// It is presentational by construction. It holds no coordinator, reads no
/// settings and performs no write: it edits the bindings its host owns and
/// reports the commands the host may run. Both surfaces that author a term —
/// the Glossary row and History's ⌘T teach — render this view, so a term
/// created from either names the same two things the same way.
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
    @Binding var scope: VocabularyScope
    /// The scopes this term may be committed to, in offer order. One option
    /// means the choice does not exist and the picker is not drawn.
    var scopeOptions: [(scope: VocabularyScope, title: String)]
    /// The case and spacing variants matched without the user typing them. This
    /// readout is the answer to "why don't I have to list every variant".
    var derivedForms: [String]
    /// Surfaces the raw transcript held and the final text did not — the forms
    /// most likely worth adding, offered rather than retyped.
    var candidateForms: [String]
    var failure: String?
    var caption: String
    var submit: Command
    var cancel: () -> Void
    var destructive: Command?
    var identifierPrefix: String

    @State private var addText = ""
    /// Installed while the editor is on screen. Escape is AppKit's to report
    /// here: both hosts sit inside a grouped `Form`, which is an `NSScrollView`
    /// that consumes the key before SwiftUI offers it to `onExitCommand` — the
    /// same measurement that gave History its own input monitor. The modifier
    /// below is kept for a host that is not inside one.
    @State private var escapeMonitor: Any?
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case term
        case addForm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            termField
            heardAsField
            if !derivedForms.isEmpty {
                derivedReadout
            }
            if !candidateForms.isEmpty {
                candidateStrip
            }
            if scopeOptions.count > 1 {
                scopePicker
            }
            commandRow
            ConsoleCaption(failure ?? caption, color: failure.map { _ in Color.red })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand(perform: cancel)
        // Opening the editor is a request to type the spelling: History's teach
        // used to focus its first field in `onAppear`, and that affordance is
        // the editor's own rather than each host's.
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

    /// One labelled, bordered, full-measure well. The caption above the field is
    /// hidden from accessibility because the field itself publishes the same
    /// title. A `LabeledContent` here put a fixed-width unbordered field in the
    /// trailing column of the row, so the term being typed sat unframed against
    /// the right edge of the window.
    private var termField: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
            Text("Term")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Term", text: $term, prompt: Text("kubectl"))
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .autocorrectionDisabled(true)
                .labelsHidden()
                .focused($focused, equals: .term)
                .onSubmit(submitIfEnabled)
                // No explicit label: a hidden-label `TextField` still publishes
                // its title, and adding one made VoiceOver read "Term, Term".
                .accessibilityIdentifier("\(identifierPrefix).canonical")
        }
    }

    // MARK: - Heard as

    /// The spoken forms, one row each, plus the field that adds one. With no
    /// forms there are no rows: the label and the prompt already say what goes
    /// here, and a term with none is still matched by its spelling.
    private var heardAsField: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
            Text("Heard as")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Identity is the form itself, never its position: forms are unique
            // case-insensitively, so removing one leaves every surviving row the
            // row it was. The index is row data — it names the remove control.
            ForEach(Array(spokenForms.enumerated()), id: \.element) { entry in
                formRow(index: entry.offset, form: entry.element)
            }
            TextField("Heard as", text: $addText, prompt: Text("cube cuddle"))
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .autocorrectionDisabled(true)
                .labelsHidden()
                .focused($focused, equals: .addForm)
                .onSubmit { appendForms() }
                .accessibilityIdentifier("\(identifierPrefix).add-form")
        }
    }

    private func formRow(index: Int, form: String) -> some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Text(form)
                .font(.body.monospaced())
            Spacer(minLength: 0)
            Button {
                spokenForms.remove(at: index)
            } label: {
                // The glyph is 13 pt; the affordance has to be bigger than the
                // ink. A borderless button is exactly its label's size, so
                // without this frame the target is 13x13 — under this project's
                // own 22x22 hit floor. `Control.mini` is the first size that
                // clears the floor and sits on the control scale.
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .frame(width: VoiceourMetrics.Control.mini, height: VoiceourMetrics.Control.mini)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(form)")
            .accessibilityLabel("Remove spoken form \(form)")
            .accessibilityIdentifier("\(identifierPrefix).form.\(index).remove")
        }
    }

    // MARK: - Readouts

    private var derivedReadout: some View {
        LabeledContent("Also matched") {
            Text(derivedForms.joined(separator: " · "))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var candidateStrip: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.hair) {
            Text("Heard in the raw transcript")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VoiceourMetrics.Space.xs) {
                    ForEach(candidateForms, id: \.self) { candidate in
                        Button(candidate) { appendForm(candidate) }
                            .accessibilityLabel("Use detected surface \(candidate)")
                    }
                }
            }
        }
    }

    // MARK: - Scope and commands

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(scopeOptions, id: \.scope) { option in
                Text(option.title).tag(option.scope)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The affirmative pair leads; the destructive command is pushed to the
    /// trailing edge so it cannot be hit while reaching for Save.
    private var commandRow: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Button(submit.title, action: performSubmit)
                .keyboardShortcut(.defaultAction)
                .disabled(!isSubmitEnabled)
                .accessibilityIdentifier(submit.identifier)
            Button("Cancel", action: cancel)
                .accessibilityIdentifier("\(identifierPrefix).cancel")
            Spacer(minLength: 0)
            if let destructive {
                Button(destructive.title, role: .destructive, action: destructive.perform)
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
        if keepingFocus {
            focused = .addForm
        }
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
