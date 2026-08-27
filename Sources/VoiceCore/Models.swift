import Foundation

public enum CasePolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case exact
    case lower
    case title
}

public struct ProtectedTerm: Codable, Equatable, Identifiable, Sendable {
    public var id: String { termId }
    public var termId: String
    public var canonical: String
    public var spokenAliases: [String]
    public var casePolicy: CasePolicy
    public var protected: Bool
    public var source: TermSource
    public var labeledAliases: [AliasLabel]
    public var tombstonedAt: Date?

    enum CodingKeys: String, CodingKey {
        case termId = "term_id"
        case canonical
        case spokenAliases = "spoken_aliases"
        case casePolicy = "case_policy"
        case protected
        case source
        case labeledAliases = "labeled_aliases"
        case tombstonedAt = "tombstoned_at"
    }

    public init(
        canonical: String,
        spokenAliases: [String],
        casePolicy: CasePolicy = .exact,
        protected: Bool = true,
        termId: String? = nil,
        source: TermSource = .bundled,
        labeledAliases: [AliasLabel] = [],
        tombstonedAt: Date? = nil
    ) {
        self.canonical = canonical
        self.termId = termId ?? canonical
        self.spokenAliases = spokenAliases
        self.casePolicy = casePolicy
        self.protected = protected
        self.source = source
        self.labeledAliases = labeledAliases
        self.tombstonedAt = tombstonedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let canonical = try container.decode(String.self, forKey: .canonical)
        self.canonical = canonical
        termId = try container.decodeIfPresent(String.self, forKey: .termId) ?? canonical
        spokenAliases = try container.decodeIfPresent([String].self, forKey: .spokenAliases) ?? []
        casePolicy = try container.decodeIfPresent(CasePolicy.self, forKey: .casePolicy) ?? .exact
        protected = try container.decodeIfPresent(Bool.self, forKey: .protected) ?? true
        source = try container.decodeIfPresent(TermSource.self, forKey: .source) ?? .bundled
        labeledAliases = try container.decodeIfPresent([AliasLabel].self, forKey: .labeledAliases) ?? []
        tombstonedAt = try container.decodeIfPresent(Date.self, forKey: .tombstonedAt)
    }

    public var renderedCanonical: String {
        switch casePolicy {
        case .exact:
            canonical
        case .lower:
            canonical.lowercased()
        case .title:
            canonical.split(separator: " ").map { word in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }.joined(separator: " ")
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var cleanupEnabled: Bool
    /// The backend a fresh install dictates through. `parakeet` is the shipped
    /// local sidecar; `fake` exists for development and the offscreen harness and
    /// is reachable only through `--asr-backend`/`VOICEOUR_ASR_BACKEND` or the
    /// debug pane, never by default. It used to BE the default, which meant a
    /// release build transcribed synthetic text until the user found the picker.
    public var asrBackend: String
    /// Which artifact of the pinned model repository the sidecar loads.
    ///
    /// Stored as its raw tag and resolved through `ASRModelVariant.resolved`, so a value
    /// written by a future build degrades to the default instead of throwing — a decode failure
    /// here would quarantine the whole settings file over one unknown word.
    public var asrModelVariant: ASRModelVariant
    public var glossary: [ProtectedTerm]
    public var muteSystemAudioDuringCapture: Bool
    public var sessionSoundsEnabled: Bool
    public var autoStopEnabled: Bool
    public var autoStopSilenceMs: Int
    /// The capture device dictations record from, as its durable CoreAudio UID,
    /// or nil for automatic choice (the system default input, with the
    /// Bluetooth-headset redirect the capture policy documents). A UID that no
    /// longer resolves at recording time falls back to automatic rather than
    /// failing the dictation.
    public var preferredMicrophoneUID: String?
    /// The device's human name at the moment it was chosen, so Settings can
    /// still name an unplugged selection — a bare UID is hardware plumbing no
    /// surface should show.
    public var preferredMicrophoneName: String?
    /// Whether this install has ever completed a dictation.
    ///
    /// Written once, from the stop pipeline, at the point a transcript exists and
    /// delivery is about to begin. Read only by Home's first-run guidance card and
    /// by the launch that opens the console on it.
    ///
    /// An absent key decodes to `false`, exactly like every other field here. The
    /// flag records a measured event, and a key that was never written is no
    /// evidence that the event happened — inferring "already onboarded" from
    /// silence would be a fabrication. An install upgrading into this build is
    /// still not shown onboarding, because ``DictationPolicy/owesFirstRunGuidance``
    /// additionally requires both durable records to be empty, and an install that
    /// has dictated has at least one of them.
    public var hasCompletedFirstRun: Bool

    enum CodingKeys: String, CodingKey {
        case cleanupEnabled = "cleanup_enabled"
        case asrBackend = "asr_backend"
        case asrModelVariant = "asr_model_variant"
        case glossary
        case muteSystemAudioDuringCapture = "mute_system_audio_during_capture"
        case sessionSoundsEnabled = "session_sounds_enabled"
        case autoStopEnabled = "auto_stop_enabled"
        case autoStopSilenceMs = "auto_stop_silence_ms"
        case preferredMicrophoneUID = "preferred_microphone_uid"
        case preferredMicrophoneName = "preferred_microphone_name"
        case hasCompletedFirstRun = "has_completed_first_run"
    }

    public init(
        cleanupEnabled: Bool = true,
        asrBackend: String = "parakeet",
        asrModelVariant: ASRModelVariant = .default,
        glossary: [ProtectedTerm] = Settings.defaultGlossary,
        muteSystemAudioDuringCapture: Bool = true,
        sessionSoundsEnabled: Bool = true,
        autoStopEnabled: Bool = false,
        autoStopSilenceMs: Int = 2500,
        preferredMicrophoneUID: String? = nil,
        preferredMicrophoneName: String? = nil,
        hasCompletedFirstRun: Bool = false
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.asrBackend = asrBackend
        self.asrModelVariant = asrModelVariant
        self.glossary = glossary
        self.muteSystemAudioDuringCapture = muteSystemAudioDuringCapture
        self.sessionSoundsEnabled = sessionSoundsEnabled
        self.autoStopEnabled = autoStopEnabled
        self.autoStopSilenceMs = autoStopSilenceMs
        self.preferredMicrophoneUID = preferredMicrophoneUID
        self.preferredMicrophoneName = preferredMicrophoneName
        self.hasCompletedFirstRun = hasCompletedFirstRun
    }

    public init(from decoder: Decoder) throws {
        let defaults = Settings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? defaults.cleanupEnabled
        asrBackend = try container.decodeIfPresent(String.self, forKey: .asrBackend) ?? defaults.asrBackend
        asrModelVariant = ASRModelVariant.resolved(
            try container.decodeIfPresent(String.self, forKey: .asrModelVariant)
        )
        glossary = try container.decodeIfPresent([ProtectedTerm].self, forKey: .glossary) ?? defaults.glossary
        muteSystemAudioDuringCapture =
            try container.decodeIfPresent(Bool.self, forKey: .muteSystemAudioDuringCapture)
            ?? defaults.muteSystemAudioDuringCapture
        sessionSoundsEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .sessionSoundsEnabled)
            ?? defaults.sessionSoundsEnabled
        autoStopEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoStopEnabled) ?? defaults.autoStopEnabled
        autoStopSilenceMs =
            try container.decodeIfPresent(Int.self, forKey: .autoStopSilenceMs) ?? defaults.autoStopSilenceMs
        preferredMicrophoneUID = try container.decodeIfPresent(String.self, forKey: .preferredMicrophoneUID)
        preferredMicrophoneName = try container.decodeIfPresent(String.self, forKey: .preferredMicrophoneName)
        hasCompletedFirstRun =
            try container.decodeIfPresent(Bool.self, forKey: .hasCompletedFirstRun)
            ?? defaults.hasCompletedFirstRun
    }

    public static let defaultGlossary: [ProtectedTerm] = [
        ProtectedTerm(canonical: "NVIDIA Parakeet", spokenAliases: ["nvidia parakeet", "envidia parakeet"]),
        ProtectedTerm(canonical: "FastConformer-TDT", spokenAliases: ["fast conformer t d t", "fastconformer tdt"]),
        ProtectedTerm(canonical: "NSPasteboard", spokenAliases: ["n s pasteboard", "ns paste board"]),
        ProtectedTerm(canonical: "CGEvent", spokenAliases: ["c g event", "cg event"]),
        ProtectedTerm(canonical: "AXUIElement", spokenAliases: ["a x ui element", "ax ui element"]),
        ProtectedTerm(canonical: "AVAudioEngine", spokenAliases: ["a v audio engine", "av audio engine"]),
        ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle", "kube cuddle"], casePolicy: .exact),
    ]
}
