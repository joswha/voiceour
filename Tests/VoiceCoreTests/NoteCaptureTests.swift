import Testing

@testable import VoiceCore

@Suite("Note prefix")
struct NoteCaptureTests {
    @Test func stripsTheCommandAndItsComma() {
        #expect(NotePrefix.strip(from: "Note to self, buy milk.", language: nil) == "Buy milk.")
    }

    @Test(arguments: [
        "Note to self: buy milk.",
        "Note to self. buy milk.",
        "Note to self - buy milk.",
        "Note to self \u{2013} buy milk.",
        "Note to self\u{2014}buy milk.",
        "Note to self buy milk.",
        "Note to self,:  buy milk.",
    ])
    func stripsEverySeparatorForm(text: String) {
        #expect(NotePrefix.strip(from: text, language: nil) == "Buy milk.")
    }

    @Test func comparesTheCommandWithoutCase() {
        #expect(NotePrefix.strip(from: "NOTE To sElF, buy milk.", language: nil) == "Buy milk.")
        #expect(NotePrefix.strip(from: "note to self buy milk", language: nil) == "Buy milk")
    }

    @Test func allowsWhitespaceBeforeAndInsideTheCommand() {
        #expect(NotePrefix.strip(from: "  \n Note to self, buy milk.", language: nil) == "Buy milk.")
        #expect(NotePrefix.strip(from: "Note  to\tself, buy milk.", language: nil) == "Buy milk.")
    }

    @Test func ignoresTheCommandAfterTheStart() {
        #expect(NotePrefix.strip(from: "I wrote a note to self, buy milk.", language: nil) == nil)
        #expect(NotePrefix.strip(from: "So, note to self, buy milk.", language: nil) == nil)
    }

    @Test func requiresWholeWords() {
        #expect(NotePrefix.strip(from: "Notes to self, buy milk.", language: nil) == nil)
        #expect(NotePrefix.strip(from: "Note to selfish people, nothing.", language: nil) == nil)
        #expect(NotePrefix.strip(from: "Note to self's list is long.", language: nil) == nil)
        #expect(NotePrefix.strip(from: "Noteto self, buy milk.", language: nil) == nil)
    }

    @Test func returnsNilWhenNothingRemains() {
        #expect(NotePrefix.strip(from: "Note to self.", language: nil) == nil)
        #expect(NotePrefix.strip(from: "note to self", language: nil) == nil)
        #expect(NotePrefix.strip(from: "Note to self, - \n", language: nil) == nil)
        #expect(NotePrefix.strip(from: "", language: nil) == nil)
    }

    @Test func stripsOnlyForEnglishOrAnUndeterminedLanguage() {
        let text = "Note to self, buy milk."
        #expect(NotePrefix.strip(from: text, language: nil) == "Buy milk.")
        #expect(NotePrefix.strip(from: text, language: .english) == "Buy milk.")
        #expect(NotePrefix.strip(from: text, language: .french) == nil)
        #expect(NotePrefix.strip(from: text, language: .japanese) == nil)
    }

    @Test func leavesARemainderThatDoesNotStartLowerCase() {
        #expect(NotePrefix.strip(from: "Note to self, Call Ana.", language: nil) == "Call Ana.")
        #expect(NotePrefix.strip(from: "Note to self: 3 eggs and bread.", language: nil) == "3 eggs and bread.")
        #expect(NotePrefix.strip(from: "Note to self, \"buy\" milk.", language: nil) == "\"buy\" milk.")
        #expect(
            NotePrefix.strip(from: "Note to self, \u{201C}buy\u{201D} milk.", language: nil)
                == "\u{201C}buy\u{201D} milk.")
    }

    @Test func upperCasesOnlyTheFirstCharacter() {
        #expect(
            NotePrefix.strip(from: "Note to self, iPhone cable in the car.", language: nil)
                == "IPhone cable in the car.")
        #expect(NotePrefix.strip(from: "Note to self, buy iOS stickers.", language: nil) == "Buy iOS stickers.")
    }

    @Test func keepsTheRestVerbatim() {
        let text = "Note to self: buy milk, eggs; bread.\nThen call Sam -- at 5:30.  \n"
        #expect(NotePrefix.strip(from: text, language: nil) == "Buy milk, eggs; bread.\nThen call Sam -- at 5:30.  \n")
        #expect(NotePrefix.strip(from: "Note to self:\nbuy milk.\n\nok", language: nil) == "Buy milk.\n\nok")
    }
}
