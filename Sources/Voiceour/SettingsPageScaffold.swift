import SwiftUI
import VoiceMac

/// One Settings page: the section's name in the display face, one sentence
/// saying what it governs, then the page's groups.
///
/// No bar: no Settings page has an action that belongs to the page rather than
/// to one of its rows. `identity` is the section, so each page opens at its top.
struct SettingsPage<Content: View>: View {
    private let section: SettingsSection
    private let content: Content

    init(_ section: SettingsSection, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        Kit.PageColumn(identity: section) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                Text(section.title)
                    .roleStyle(.display)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(section.sentence)
                    .roleStyle(.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content
        }
    }
}

/// A second sentence under a row inside a `Kit.Group`, in the row caption's
/// voice and inset to the row's text: a fact that holds only for now, such as a
/// change waiting for the next recording.
struct SettingsNote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .roleStyle(.meta)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiceourMetrics.Space.md)
            .padding(.bottom, VoiceourMetrics.Space.md)
    }
}

/// Every copy a Settings page offers writes through here, so the clipboard
/// helper, the success rule and the confirmation cannot drift between them.
@MainActor
enum SettingsClipboard {
    /// Copies `text` and, only when the clipboard took it, confirms `sentence` in
    /// the page toast, which also speaks it to VoiceOver. A refused write shows
    /// and says nothing.
    static func copy(_ text: String, confirming sentence: String, through flash: Kit.Flash, a11y: A11y) {
        guard GeneralPasteboard.copy(text) != nil else { return }
        flash.show(sentence, animation: Kit.Motion.quick(a11y))
    }
}
