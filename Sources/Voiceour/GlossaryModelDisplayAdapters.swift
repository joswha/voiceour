import VoiceCore

extension VocabularyScope {
    var displayLabel: String {
        switch self {
        case .global: "GLOBAL"
        case .bundleID(let id): "APP · \(id.split(separator: ".").last.map(String.init) ?? id)"
        case .projectID(let id): "PROJECT · \(id.split(separator: "/").last.map(String.init) ?? id)"
        }
    }
}
