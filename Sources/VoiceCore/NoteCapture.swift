import Foundation

/// What a dictation is for.
public enum CaptureIntent: Equatable, Sendable {
    /// The transcript goes to the target the user dictated into.
    case deliver
    /// The transcript is saved to memory and delivered nowhere.
    case note
}

/// The spoken command that files a dictation as a note instead of delivering it.
///
/// The command is read from the delivered text, after the text stages ran, so it sees the words
/// the user would otherwise have pasted: Granite's punctuation and capitals included.
public enum NotePrefix {
    /// The command's words, lower-cased. Each must be a whole word, separated by whitespace.
    private static let command = ["note", "to", "self"]

    /// Marks that recognition or the user put between the command and the note. They belong to
    /// the command, not to the note, so they are dropped with it.
    private static let separators: Set<Character> = [",", ".", ":", ";", "-", "\u{2013}", "\u{2014}"]

    /// The spoken command that turns a dictation into a note: the words "note to self" at the very start.
    /// Returns the note text with the command and the punctuation that follows it removed, or nil when `text`
    /// does not start with the command, when the remainder is empty, or when `language` is neither English nor nil.
    ///
    /// The words compare without case. A first lower-case letter of the note is upper-cased,
    /// because the command took the sentence's start; every other character stays as dictated.
    public static func strip(from text: String, language: DictationLanguage?) -> String? {
        guard DictationLanguage.usesEnglishRules(language) else { return nil }

        var rest = text[...].drop(while: \.isWhitespace)
        for (offset, expected) in command.enumerated() {
            let word = rest.prefix(while: isWordCharacter)
            guard word.lowercased() == expected else { return nil }
            rest = rest[word.endIndex...]
            if offset < command.count - 1 {
                guard rest.first?.isWhitespace == true else { return nil }
                rest = rest.drop(while: \.isWhitespace)
            }
        }

        // "note to self's list" is a sentence about a note, not the command.
        if let next = rest.first, !next.isWhitespace, !separators.contains(next) {
            return nil
        }

        let note = rest.drop { $0.isWhitespace || separators.contains($0) }
        guard let first = note.first else { return nil }
        guard first.isLowercase else { return String(note) }
        return first.uppercased() + String(note.dropFirst())
    }

    /// Letters and digits make words, as `LiteralComposition` splits them.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
