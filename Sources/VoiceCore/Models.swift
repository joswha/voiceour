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
    public var scope: VocabularyScope
    public var cloudEligible: Bool
    public var labeledAliases: [AliasLabel]
    public var tombstonedAt: Date?

    enum CodingKeys: String, CodingKey {
        case termId = "term_id"
        case canonical
        case spokenAliases = "spoken_aliases"
        case casePolicy = "case_policy"
        case protected
        case source
        case scope
        case cloudEligible = "cloud_eligible"
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
        scope: VocabularyScope = .global,
        cloudEligible: Bool = true,
        labeledAliases: [AliasLabel] = [],
        tombstonedAt: Date? = nil
    ) {
        self.canonical = canonical
        self.termId = termId ?? canonical
        self.spokenAliases = spokenAliases
        self.casePolicy = casePolicy
        self.protected = protected
        self.source = source
        self.scope = scope
        self.cloudEligible = cloudEligible
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
        scope = try container.decodeIfPresent(VocabularyScope.self, forKey: .scope) ?? .global
        cloudEligible = try container.decodeIfPresent(Bool.self, forKey: .cloudEligible) ?? true
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

/// The one normalizer for the `speech_locale` setting.
///
/// This is the only free-text field the app hands straight to a system
/// recogniser, so a value Foundation cannot resolve is not a cosmetic problem:
/// `SpeechTranscriber.supportedLocale(equivalentTo:)` returns nil and the whole
/// Apple backend refuses every request. A build before the settings pane moved
/// to commit-on-submit persisted the field on each keystroke and could leave
/// `" "` on disk, which bricked that backend permanently with no in-app way
/// back. Decode heals such a value rather than carrying it to the recogniser.
public enum SpeechLocale {
    /// The identifier used when the stored one cannot be resolved.
    public static let fallback = "en_US"

    /// BCP-47 spells subtags with hyphens and `Locale` with underscores; accept
    /// either and return the identifier Foundation will match, or nil when no
    /// available identifier does.
    public static func canonical(_ value: String) -> String? {
        let candidate =
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
        guard known.contains(candidate.lowercased()) else { return nil }
        return candidate
    }

    private static let known: Set<String> = Set(Locale.availableIdentifiers.map { $0.lowercased() })
}

public struct Settings: Codable, Equatable, Sendable {
    public var cleanupEnabled: Bool
    public var asrBackend: String
    public var glossary: [ProtectedTerm]
    public var muteSystemAudioDuringCapture: Bool
    public var autoStopEnabled: Bool
    public var autoStopSilenceMs: Int
    public var speechLocale: String
    /// Words per minute this reader types, used by Home as the counterfactual
    /// every time-saved figure is measured against. Defaults to a measured
    /// population average (`DictationInsights.defaultTypingWPM`) because the
    /// app cannot observe the user's keyboard, and is editable on Home itself
    /// so the assumption is corrigible where it is stated.
    public var typingSpeedWPM: Int

    enum CodingKeys: String, CodingKey {
        case cleanupEnabled = "cleanup_enabled"
        case asrBackend = "asr_backend"
        case glossary
        case muteSystemAudioDuringCapture = "mute_system_audio_during_capture"
        case autoStopEnabled = "auto_stop_enabled"
        case autoStopSilenceMs = "auto_stop_silence_ms"
        case speechLocale = "speech_locale"
        case typingSpeedWPM = "typing_speed_wpm"
    }

    public init(
        cleanupEnabled: Bool = true,
        asrBackend: String = "fake",
        glossary: [ProtectedTerm] = Settings.defaultGlossary,
        muteSystemAudioDuringCapture: Bool = true,
        autoStopEnabled: Bool = false,
        autoStopSilenceMs: Int = 2500,
        speechLocale: String = SpeechLocale.fallback,
        typingSpeedWPM: Int = DictationInsights.defaultTypingWPM
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.asrBackend = asrBackend
        self.glossary = glossary
        self.muteSystemAudioDuringCapture = muteSystemAudioDuringCapture
        self.autoStopEnabled = autoStopEnabled
        self.autoStopSilenceMs = autoStopSilenceMs
        self.speechLocale = speechLocale
        self.typingSpeedWPM = DictationInsights.clamp(typingSpeedWPM)
    }

    public init(from decoder: Decoder) throws {
        let defaults = Settings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? defaults.cleanupEnabled
        asrBackend = try container.decodeIfPresent(String.self, forKey: .asrBackend) ?? defaults.asrBackend
        glossary = try container.decodeIfPresent([ProtectedTerm].self, forKey: .glossary) ?? defaults.glossary
        muteSystemAudioDuringCapture =
            try container.decodeIfPresent(Bool.self, forKey: .muteSystemAudioDuringCapture)
            ?? defaults.muteSystemAudioDuringCapture
        autoStopEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoStopEnabled) ?? defaults.autoStopEnabled
        autoStopSilenceMs =
            try container.decodeIfPresent(Int.self, forKey: .autoStopSilenceMs) ?? defaults.autoStopSilenceMs
        let storedLocale = try container.decodeIfPresent(String.self, forKey: .speechLocale) ?? defaults.speechLocale
        speechLocale = SpeechLocale.canonical(storedLocale) ?? defaults.speechLocale
        typingSpeedWPM = DictationInsights.clamp(
            try container.decodeIfPresent(Int.self, forKey: .typingSpeedWPM) ?? defaults.typingSpeedWPM
        )
    }

    public static let defaultGlossary: [ProtectedTerm] = [
        ProtectedTerm(canonical: "OMPi", spokenAliases: ["oh m pi", "om pi"]),
        ProtectedTerm(canonical: "NVIDIA Parakeet", spokenAliases: ["nvidia parakeet", "envidia parakeet"]),
        ProtectedTerm(canonical: "FastConformer-TDT", spokenAliases: ["fast conformer t d t", "fastconformer tdt"]),
        ProtectedTerm(canonical: "NSPasteboard", spokenAliases: ["n s pasteboard", "ns paste board"]),
        ProtectedTerm(canonical: "CGEvent", spokenAliases: ["c g event", "cg event"]),
        ProtectedTerm(canonical: "AXUIElement", spokenAliases: ["a x ui element", "ax ui element"]),
        ProtectedTerm(canonical: "AVAudioEngine", spokenAliases: ["a v audio engine", "av audio engine"]),
        ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle", "kube cuddle"], casePolicy: .exact),
    ]
}
