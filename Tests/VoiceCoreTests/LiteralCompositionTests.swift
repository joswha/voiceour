import Testing

@testable import VoiceCore

@Suite("Literal composition")
struct LiteralCompositionTests {
    @Test func composesSpelledAndLetterByLetterText() {
        #expect(LiteralComposition.apply("spell that k u b e") == "kube")
        #expect(LiteralComposition.apply("letter-by-letter S w i f t U I") == "SwiftUI")
        #expect(LiteralComposition.apply("letter by letter v o i c e") == "voice")
    }

    @Test func emitsLiteralText() {
        #expect(LiteralComposition.apply("literal kubectl") == "kubectl")
        #expect(LiteralComposition.apply("run literal xcode") == "run xcode")
    }

    @Test func composesSnakeCase() {
        #expect(LiteralComposition.apply("snake case Hello World") == "hello_world")
        #expect(LiteralComposition.apply("use snake case Voice Capture") == "use voice_capture")
    }

    @Test func composesCamelCase() {
        #expect(LiteralComposition.apply("camel case hello WORLD") == "helloWorld")
        #expect(LiteralComposition.apply("use camel case voice capture") == "use voiceCapture")
    }

    @Test func uppercasesOnlyTheNextToken() {
        #expect(LiteralComposition.apply("capital n s pasteboard") == "N s pasteboard")
        #expect(LiteralComposition.apply("say uppercase swift now") == "say SWIFT now")
    }

    @Test func composesSpokenSymbolsWithinTokens() {
        #expect(LiteralComposition.apply("dash dash verbose") == "--verbose")
        #expect(LiteralComposition.apply("well dash known") == "well-known")
        #expect(LiteralComposition.apply("example dot com") == "example.com")
        #expect(LiteralComposition.apply("voice underscore core") == "voice_core")
    }

    @Test func composesOperatorsInsideSpelledText() {
        #expect(LiteralComposition.apply("spell that v one dot two dash beta") == "vone.two-beta")
        #expect(LiteralComposition.apply("spell that capital n s pasteboard") == "Nspasteboard")
    }

    @Test(arguments: [
        "This is an ordinary sentence.",
        "  Preserve repeated   spaces and newlines.\n",
        "NSPasteboard already has exact orthography.",
        "foo_bar --verbose version.2",
    ])
    func leavesOrdinaryTranscriptsExactlyUntouched(_ transcript: String) {
        #expect(LiteralComposition.apply(transcript) == transcript)
    }

    @Test func neverAltersWordsThatOnlyContainOperatorNames() {
        let transcript = "The dashboard camelcase snake_case dash_dot foo.dot dotted capitalization is literalism."
        #expect(LiteralComposition.apply(transcript) == transcript)
    }

    @Test(arguments: [
        "snake case Voice Core",
        "camel case voice core",
        "spell that v dot one",
        "dash dash verbose",
    ])
    func isIdempotentAfterComposition(_ command: String) {
        let composed = LiteralComposition.apply(command)
        #expect(LiteralComposition.apply(composed) == composed)
    }
}
