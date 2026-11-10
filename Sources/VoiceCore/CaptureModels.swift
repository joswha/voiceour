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

/// Which input-processing chain produced a capture, carried on its telemetry so
/// the measured numbers can be attributed to the chain that made them. The
/// shipping recorder runs the standard chain; `voiceProcessingNoAGC` names the
/// AGC-disabled variant the analyzer is exercised against.
public enum CaptureProcessingMode: String, Codable, Equatable, Sendable, CaseIterable {
    case standard
    case voiceProcessingNoAGC = "voice-processing-no-agc"
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
    /// Localized application name captured with the snapshot; nil when the
    /// running application could not name itself.
    public var appName: String?
    public var pid: pid_t
    public var safety: TargetSafetyClass
    public var secureInputActive: Bool

    public init(
        bundleId: String?,
        appName: String? = nil,
        pid: pid_t,
        safety: TargetSafetyClass,
        secureInputActive: Bool = false
    ) {
        self.bundleId = bundleId
        self.appName = appName
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
    /// The words the menu shows for this outcome. `app` is the display name of the
    /// app the text went to, so the sentence can say where it went; nil (or empty)
    /// when that is unknown, and every sentence still reads as a whole one then.
    ///
    /// The label says `PASTED` although Voiceour only posts Cmd-V and cannot see
    /// the text land: Timeline has always used the same word, and two words for
    /// one outcome was the complaint. The state name stays `pasteAttempted`.
    public func summary(in app: String?) -> InsertionOutcomeSummary {
        let app = app.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch self {
        case .pasteAttempted:
            return InsertionOutcomeSummary(
                label: "PASTED",
                detail: app.map { "Pasted into \($0)." } ?? "Pasted.",
                severity: .ok
            )
        case .copiedOnly(let reason):
            return InsertionOutcomeSummary(
                label: "COPY ONLY",
                detail: insertionReasonSentence(reason, app: app) ?? humanizedInsertionOutcomeReason(reason),
                severity: .warn
            )
        case .failed(let reason):
            return InsertionOutcomeSummary(
                label: "DELIVERY FAILED",
                detail: insertionReasonSentence(reason, app: app) ?? humanizedInsertionOutcomeReason(reason),
                severity: .crit
            )
        }
    }
}

/// The sentence for every reason `InsertionSafetyPolicy` and `PasteboardInserter`
/// can produce, or nil for a string neither produces. Nil is what lets a test
/// prove no real reason falls through to the humanizer, which would put a log
/// word such as "Target codeEditor" on the menu.
func insertionReasonSentence(_ reason: String, app: String?) -> String? {
    switch reason {
    // Spelled out because a call is not a switch pattern; the coverage test
    // derives these from `InsertionSafetyPolicy.disposition(for:)`, so a drift fails.
    case "target_terminal":
        "\(app ?? "This") is a terminal. Press ⌘V to paste."
    case "target_codeEditor":
        "\(app ?? "This") is a code editor. Press ⌘V to paste."
    case "target_secure":
        "This is a secure field. Press ⌘V to paste."
    case "target_unknownRisky":
        "Voiceour could not read this field. Press ⌘V to paste."
    case InsertionSafetyPolicy.missingSynthPastePermission:
        "Voiceour needs Accessibility to paste. Press ⌘V."
    case InsertionSafetyPolicy.targetChangedBeforeCopy, InsertionSafetyPolicy.targetChangedAfterCopy:
        "The focus moved before the paste. Press ⌘V to paste."
    case InsertionSafetyPolicy.postEventFailed:
        "The paste could not be sent. Press ⌘V to paste."
    case InsertionSafetyPolicy.cancelledAfterCopy:
        "Cancelled. The text is on the clipboard."
    case InsertionSafetyPolicy.pasteboardWriteFailed:
        "The transcript could not be written to the clipboard."
    // `PasteboardInserter` reports a cancel before the clipboard write with this
    // literal: nothing was pasted or copied.
    case "cancelled":
        "Cancelled before anything was pasted or copied."
    default:
        nil
    }
}

/// Only for a reason string no producer in the app emits (a fixture's free
/// text, a future reason): better a readable phrase than a raw key.
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
