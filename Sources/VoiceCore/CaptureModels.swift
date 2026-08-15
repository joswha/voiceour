import Foundation

public struct CaptureAudioFormat: Codable, Equatable, Sendable {
    public var sampleRateHz: Int
    public var channels: Int
    public var encoding: String

    public init(sampleRateHz: Int, channels: Int, encoding: String) {
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.encoding = encoding
    }
}

public enum CaptureProcessingMode: String, Codable, Equatable, Sendable, CaseIterable {
    case standard
    case native
    case voiceProcessing = "voice-processing"
    case voiceProcessingNoAGC = "voice-processing-no-agc"
    case soundIsolation = "sound-isolation"
    case soundIsolationHighQuality = "sound-isolation-high-quality"
}

public struct CaptureTelemetry: Codable, Equatable, Sendable {
    public var inputFormat: CaptureAudioFormat
    public var outputFormat: CaptureAudioFormat
    public var clipRatio: Double
    public var activeSpeechRatio: Double
    public var peakDBFS: Double
    public var noiseFloorDBFS: Double
    public var snrDB: Double
    public var leadingSilenceMs: Int
    public var trailingSilenceMs: Int
    public var routeChangeCount: Int
    public var droppedBufferCount: Int
    public var zeroBufferCount: Int
    public var processingMode: CaptureProcessingMode

    public init(
        inputFormat: CaptureAudioFormat,
        outputFormat: CaptureAudioFormat,
        clipRatio: Double,
        activeSpeechRatio: Double,
        peakDBFS: Double,
        noiseFloorDBFS: Double,
        snrDB: Double,
        leadingSilenceMs: Int,
        trailingSilenceMs: Int,
        routeChangeCount: Int,
        droppedBufferCount: Int,
        zeroBufferCount: Int,
        processingMode: CaptureProcessingMode
    ) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.clipRatio = clipRatio
        self.activeSpeechRatio = activeSpeechRatio
        self.peakDBFS = peakDBFS
        self.noiseFloorDBFS = noiseFloorDBFS
        self.snrDB = snrDB
        self.leadingSilenceMs = leadingSilenceMs
        self.trailingSilenceMs = trailingSilenceMs
        self.routeChangeCount = routeChangeCount
        self.droppedBufferCount = droppedBufferCount
        self.zeroBufferCount = zeroBufferCount
        self.processingMode = processingMode
    }
}

public struct RecordedAudio: Equatable, Sendable {
    public var url: URL
    public var meta: ASRAudioMeta
    public var telemetry: CaptureTelemetry?
    /// True only for the fake recorder, which writes literal silence and whose
    /// transcript is synthesised. The no-speech gate in
    /// `DictationPolicy.capturedSpeechIsAbsent` must not fire on it: fabricating a
    /// transcript from silence is that recorder's contract. Declared by the producer
    /// rather than inferred downstream, because only the recorder knows.
    public var isSynthetic: Bool

    public init(
        url: URL,
        meta: ASRAudioMeta,
        telemetry: CaptureTelemetry? = nil,
        isSynthetic: Bool = false
    ) {
        self.url = url
        self.meta = meta
        self.telemetry = telemetry
        self.isSynthetic = isSynthetic
    }
}

public enum TargetSafetyClass: String, Codable, Equatable, Sendable, CaseIterable {
    case normalText
    case terminal
    case codeEditor
    case secure
    case unknownRisky
}

public struct TargetSnapshot: Equatable, Sendable {
    public var bundleId: String?
    public var pid: pid_t
    public var safety: TargetSafetyClass
    public var secureInputActive: Bool

    public init(
        bundleId: String?,
        pid: pid_t,
        safety: TargetSafetyClass,
        secureInputActive: Bool = false
    ) {
        self.bundleId = bundleId
        self.pid = pid
        self.safety = safety
        self.secureInputActive = secureInputActive
    }
}

public enum InsertionOutcome: Equatable, Sendable {
    case pasteAttempted
    case copiedOnly(reason: String)
    case failed(reason: String)
}

public enum StatusSeverity: String, Codable, Equatable, Sendable {
    case neutral
    case ok
    case warn
    case crit
}

public struct InsertionOutcomeSummary: Equatable, Sendable {
    public var label: String
    public var detail: String
    public var severity: StatusSeverity

    public init(label: String, detail: String, severity: StatusSeverity) {
        self.label = label
        self.detail = detail
        self.severity = severity
    }
}

extension InsertionOutcome {
    public var summary: InsertionOutcomeSummary {
        switch self {
        case .pasteAttempted:
            InsertionOutcomeSummary(
                label: "PASTE ATTEMPTED",
                detail: "Command-V was posted to the captured target.",
                severity: .ok
            )
        case .copiedOnly(let reason):
            InsertionOutcomeSummary(
                label: "COPIED ONLY",
                detail: insertionOutcomeDetail(for: reason),
                severity: .warn
            )
        case .failed(let reason):
            InsertionOutcomeSummary(
                label: "PASTE FAILED",
                detail: insertionOutcomeDetail(for: reason),
                severity: .crit
            )
        }
    }
}

private func insertionOutcomeDetail(for reason: String) -> String {
    switch reason {
    case "target_terminal":
        "Terminal target protected."
    case "target_codeEditor":
        "Code editor target protected."
    case "target_secure":
        "Secure target protected."
    case "target_unknownRisky":
        "Unknown-risk target protected."
    case "synth_paste_permission":
        "Accessibility or synthetic paste permission missing."
    case "target_changed_before_copy":
        "Target changed before clipboard write."
    case "target_changed_after_copy":
        "Target changed after clipboard write."
    case "post_event_failed":
        "Command-V event post failed."
    case "cancelled":
        "Session cancelled."
    default:
        humanizedInsertionOutcomeReason(reason)
    }
}

private func humanizedInsertionOutcomeReason(_ reason: String) -> String {
    let spaced = reason.replacingOccurrences(of: "_", with: " ")
    guard let first = spaced.first else {
        return ""
    }

    return first.uppercased() + spaced.dropFirst()
}

public enum PermissionState: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}
