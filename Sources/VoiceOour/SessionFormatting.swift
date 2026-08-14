import Foundation
import VoiceCore

extension RecentSessionOutcomeMetadata {
    var chip: (label: String, mode: StatusChip.Mode) {
        switch disposition {
        case .pasteAttempted:
            ("PASTED", .ok)
        case .copiedOnly:
            ("COPIED", .warn)
        case .failed:
            ("FAILED", .crit)
        }
    }
}

extension RefinementTrace {
    var badge: (label: String, mode: StatusChip.Mode) {
        switch kind {
        case .refined: ("REFINED", .ok)
        case .fellBack: ("RAW · FELL BACK", .warn)
        case .skipped: ("CLEANUP ONLY", .neutral)
        }
    }

    /// The provider is genuinely absent for a skipped trace, so it is omitted
    /// rather than joined in as an em dash that reads like a value. `model` is
    /// only ever present when it says something `provider` does not — the
    /// on-device model's asset ids — so it is shown whenever it is recorded.
    var detailLine: String {
        var parts: [String] = []
        if let provider, !provider.isEmpty { parts.append(provider) }
        if let model, !model.isEmpty { parts.append(model) }
        if let latencyMs { parts.append("\(latencyMs) ms") }
        if let reason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}

extension SessionStageTimings {
    var detailLine: String {
        var parts: [String] = []
        if let asrMs { parts.append("ASR \(asrMs) ms") }
        if let asrPath, !asrPath.isEmpty { parts.append(asrPath) }
        if let insertMs { parts.append("insert \(insertMs) ms") }
        if let startLatencyMs { parts.append("start \(startLatencyMs) ms") }
        return parts.joined(separator: " · ")
    }
}

extension TargetSafetyClass {
    /// `rawValue` is a serialisation key; uppercasing it destroys the word
    /// boundary and ships "CODEEDITOR" on the highest-stakes chip in the row.
    var displayLabel: String {
        switch self {
        case .normalText: "TEXT"
        case .terminal: "TERMINAL"
        case .codeEditor: "CODE EDITOR"
        case .secure: "SECURE"
        case .unknownRisky: "UNKNOWN"
        }
    }
}

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
