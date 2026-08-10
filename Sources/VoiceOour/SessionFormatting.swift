import Foundation
import VoiceCore

extension RecentSessionOutcomeMetadata {
    var chipLabel: String {
        switch disposition {
        case .pasteAttempted:
            "PASTED"
        case .copiedOnly:
            "COPIED"
        case .failed:
            "FAILED"
        }
    }

    var chipMode: StatusChip.Mode {
        switch disposition {
        case .pasteAttempted:
            .ok
        case .copiedOnly:
            .warn
        case .failed:
            .crit
        }
    }
}

extension RefinementTrace {
    var badgeLabel: String {
        switch kind {
        case .refined: "REFINED"
        case .fellBack: "RAW · FELL BACK"
        case .skipped: "CLEANUP ONLY"
        }
    }

    var badgeMode: StatusChip.Mode {
        switch kind {
        case .refined: .ok
        case .fellBack: .warn
        case .skipped: .neutral
        }
    }

    /// The provider is genuinely absent for a skipped trace, so it is omitted
    /// rather than joined in as an em dash that reads like a value.
    var detailLine: String {
        var parts: [String] = []
        if let provider, !provider.isEmpty { parts.append(provider) }
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
        let formatter = DateFormatter()
        formatter.calendar = RenderOverrides.calendar ?? Calendar.current
        formatter.locale = RenderOverrides.locale ?? Locale.current
        formatter.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let detailStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = RenderOverrides.calendar ?? Calendar.current
        formatter.locale = RenderOverrides.locale ?? Locale.current
        formatter.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        formatter.dateFormat = "MMM d, yyyy · HH:mm"
        return formatter
    }()

    static let dayHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = RenderOverrides.calendar ?? Calendar.current
        formatter.locale = RenderOverrides.locale ?? Locale.current
        formatter.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        formatter.dateFormat = "EEEE · MMM d · yyyy"
        return formatter
    }()
}
