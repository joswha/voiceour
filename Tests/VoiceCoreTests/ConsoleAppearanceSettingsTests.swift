import Foundation
import Testing

@testable import VoiceCore

/// The console's appearance and accent live in the file that holds the glossary, so no value
/// under either key may throw: a throw would quarantine the file and reset the glossary.
@Suite("Console appearance settings")
struct ConsoleAppearanceSettingsTests {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test func missingKeysGiveTheDefaults() throws {
        let settings = try decode("{}")
        #expect(settings.consoleAppearance == .system)
        #expect(settings.consoleAccent == .green)
        #expect(Settings().consoleAppearance == .system)
        #expect(Settings().consoleAccent == .green)
    }

    @Test func storedValuesDecode() throws {
        let settings = try decode(#"{"console_appearance": "light", "console_accent": "yellow"}"#)
        #expect(settings.consoleAppearance == .light)
        #expect(settings.consoleAccent == .yellow)
    }

    @Test func unknownValuesFallBackWithoutThrowing() throws {
        let settings = try decode(#"{"console_appearance": "sepia", "console_accent": "teal"}"#)
        #expect(settings.consoleAppearance == .system)
        #expect(settings.consoleAccent == .green)
    }

    @Test func mistypedValuesFallBackWithoutThrowing() throws {
        let settings = try decode(#"{"console_appearance": 3, "console_accent": {"hue": 120}}"#)
        #expect(settings.consoleAppearance == .system)
        #expect(settings.consoleAccent == .green)
    }

    @Test func aBadValueLeavesTheGlossaryIntact() throws {
        let settings = try decode(
            #"{"console_accent": null, "glossary": [{"canonical": "Voiceour", "spoken_aliases": ["voice hour"]}]}"#)
        #expect(settings.consoleAccent == .green)
        #expect(settings.glossary.map(\.canonical) == ["Voiceour"])
    }

    @Test(arguments: ConsoleAppearance.allCases, ConsoleAccent.allCases)
    func theChoiceSurvivesAnEncodeDecodeRoundTrip(appearance: ConsoleAppearance, accent: ConsoleAccent) throws {
        let original = Settings(consoleAppearance: appearance, consoleAccent: accent)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.consoleAppearance == appearance)
        #expect(decoded.consoleAccent == accent)
        #expect(decoded == original)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["console_appearance"] as? String == appearance.rawValue)
        #expect(object?["console_accent"] as? String == accent.rawValue)
    }

    @Test func resolvedMapsMissingAndUnknownTags() {
        #expect(ConsoleAppearance.resolved(nil) == .system)
        #expect(ConsoleAppearance.resolved("") == .system)
        #expect(ConsoleAppearance.resolved("dark") == .dark)
        #expect(ConsoleAccent.resolved(nil) == .green)
        #expect(ConsoleAccent.resolved("Graphite") == .green)
        #expect(ConsoleAccent.resolved("graphite") == .graphite)
    }
}
