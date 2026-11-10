import Foundation
import VoiceCore

extension RecentSessionOutcomeMetadata {
    /// The outcome's word and the tone it carries as a pill.
    ///
    /// Copy-only reads "Copy only", the word the menu uses for the same outcome,
    /// so "Copied" is left to mean only "you just copied this".
    var outcomeMark: (label: String, tone: Kit.Pill.Tone) {
        switch disposition {
        case .pasteAttempted:
            ("Pasted", .success)
        case .copiedOnly:
            ("Copy only", .caution)
        case .failed:
            ("Failed", .critical)
        }
    }
}

extension SessionStageTimings {
    var detailLine: String {
        var parts: [String] = []
        if let asrMs { parts.append("ASR \(asrMs) ms") }
        if let insertMs { parts.append("insert \(insertMs) ms") }
        if let startLatencyMs { parts.append("start \(startLatencyMs) ms") }
        return parts.joined(separator: " · ")
    }
}

extension TargetSafetyClass {
    /// `rawValue` is a serialisation key; capitalising it destroys the word
    /// boundary and ships "Codeeditor" on the highest-stakes pill in the row.
    var displayLabel: String {
        switch self {
        case .normalText: "Text"
        case .terminal: "Terminal"
        case .codeEditor: "Code editor"
        case .secure: "Secure"
        case .unknownRisky: "Unknown"
        }
    }
}

@MainActor
enum SessionsFormatters {
    static let timestamp: DateFormatter = {
        let formatter = RenderFormatters.dateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let detailStamp: DateFormatter = {
        let formatter = RenderFormatters.dateFormatter()
        formatter.dateFormat = "MMM d, yyyy · HH:mm"
        return formatter
    }()

    static let dayHeader: DateFormatter = {
        let formatter = RenderFormatters.dateFormatter()
        formatter.dateFormat = "EEEE · MMM d · yyyy"
        return formatter
    }()

    static func wordCountLabel(_ count: Int, pluralOnly: Bool = false) -> String {
        "\(count) \(pluralOnly || count != 1 ? "words" : "word")"
    }
}
