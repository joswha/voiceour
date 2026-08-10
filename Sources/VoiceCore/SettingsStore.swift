import Foundation

public struct SettingsStore: Sendable {
    public var url: URL

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
    }

    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Settings()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Settings.self, from: data)
    }

    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try writeVoiceOourPrivateState(data, to: url)
    }

    public static var defaultURL: URL {
        URL.voiceOourSupportDirectory.appendingPathComponent("settings.json")
    }
}
