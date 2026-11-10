import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// One note an agent saved under the memory folder's `agents/`: who wrote it and what it says.
///
/// The body is text and nothing else. It is never parsed as Markdown, never turned into a
/// link and never opened, because an agent wrote it and Voiceour vouches for none of it;
/// it stays selectable so the reader can take a passage out by hand. It is not an entry,
/// so a click copies nothing and there is no menu. The row draws no surface of its own: it
/// sits full width inside its section's card, marked with the sparkles tile so a reader
/// tells an agent's words from their own at a glance, and the section rules it off from
/// the next note.
struct JournalAgentNoteRow: View {
    /// How much of a body the lens renders. An agent file may run to 256 KB, and one
    /// unbroken text view that long stalls the page it sits in.
    static let displayLimit = 4_000

    private let caption: String
    private let text: String

    init(_ note: AgentNote) {
        caption = Self.caption(of: note, calendar: RenderOverrides.calendar ?? Calendar.current)
        text = Self.displayedBody(note.body)
    }

    /// "<title or file name> · by <author> · YYYY-MM-DD HH:mm". An agent's note is a claim
    /// made at one moment, so the caption dates it by the file's own modification time in
    /// the lens calendar; the digits are padded by hand so no locale can reach them.
    nonisolated static func caption(of note: AgentNote, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: note.modifiedAt)
        let day = "\(padded(parts.year ?? 0, 4))-\(padded(parts.month ?? 0, 2))-\(padded(parts.day ?? 0, 2))"
        let time = "\(padded(parts.hour ?? 0, 2)):\(padded(parts.minute ?? 0, 2))"
        return "\(note.title ?? note.id) \u{00B7} by \(note.author) \u{00B7} \(day) \(time)"
    }

    private nonisolated static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Kit.IconTile(systemImage: "sparkles", size: .small)
                Text(caption)
                    .roleStyle(.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(verbatim: text)
                .roleStyle(.reading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                // Keep mouse selection while exposing the text once, not both the
                // native selection wrapper and its identical accessibility child.
                .accessibilityRepresentation { Text(verbatim: text) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The body cut at `displayLimit` characters, ending with "…" when anything was cut.
    /// Walks at most `displayLimit` characters, so a long body costs no more than a short one.
    static func displayedBody(_ body: String) -> String {
        guard let end = body.index(body.startIndex, offsetBy: displayLimit, limitedBy: body.endIndex),
            end < body.endIndex
        else { return body }
        return String(body[..<end]) + "\u{2026}"
    }
}

/// A kit button that copies a prompt for the user's own coding agent, confirmed by the
/// page's toast in the sentence VoiceOver hears.
///
/// The prompt is built only when the button is pressed, so a page pays nothing for
/// offering it. A refused clipboard write shows and says nothing, because the toast is a
/// claim about the clipboard.
struct JournalPromptCopyButton: View {
    private let title: String
    private let help: String
    private let announcement: String
    private let identifier: String
    private let prominence: Kit.Button.Prominence
    private let flash: Kit.Flash
    private let prompt: () -> String

    private var a11y = A11y()

    /// `identifier` names the button alone, so the confirmation never answers to it.
    init(
        _ title: String,
        help: String,
        announcement: String,
        identifier: String,
        prominence: Kit.Button.Prominence = .secondary,
        flash: Kit.Flash,
        prompt: @escaping () -> String
    ) {
        self.title = title
        self.help = help
        self.announcement = announcement
        self.identifier = identifier
        self.prominence = prominence
        self.flash = flash
        self.prompt = prompt
    }

    var body: some View {
        Kit.Button(title, systemImage: "doc.on.clipboard", prominence: prominence, action: copy)
            .help(help)
            .accessibilityIdentifier(identifier)
    }

    private func copy() {
        guard GeneralPasteboard.copy(prompt()) != nil else { return }
        flash.show(announcement, animation: Kit.Motion.quick(a11y))
    }
}
