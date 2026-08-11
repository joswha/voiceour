import Foundation

public enum CasePolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case exact
    case lower
    case title
}

public enum MuteScope: String, Codable, Equatable, Sendable, CaseIterable {
    case builtInOutputOnly
    case allOutputs
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

public enum RefinementStyle: String, Codable, Equatable, Sendable {
    case standard, casual, formal
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
    public var refinerEnabled: Bool
    public var refinerProvider: RefinerProvider
    public var refinerModel: String
    public var refinerTimeoutMs: Int
    public var glossary: [ProtectedTerm]
    public var muteSystemAudioDuringCapture: Bool
    public var muteScope: MuteScope
    public var autoStopEnabled: Bool
    public var autoStopSilenceMs: Int
    public var speechLocale: String
    public var automaticTermCorrectionEnabled: Bool
    public var decoderBiasEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case cleanupEnabled = "cleanup_enabled"
        case asrBackend = "asr_backend"
        case refinerEnabled = "refiner_enabled"
        case refinerProvider = "refiner_provider"
        case refinerModel = "refiner_model"
        case refinerTimeoutMs = "refiner_timeout_ms"
        case glossary
        case muteSystemAudioDuringCapture = "mute_system_audio_during_capture"
        case muteScope = "mute_scope"
        case autoStopEnabled = "auto_stop_enabled"
        case autoStopSilenceMs = "auto_stop_silence_ms"
        case speechLocale = "speech_locale"
        case automaticTermCorrectionEnabled = "automatic_term_correction_enabled"
        case decoderBiasEnabled = "decoder_bias_enabled"
    }

    public init(
        cleanupEnabled: Bool = true,
        asrBackend: String = "fake",
        refinerEnabled: Bool = false,
        refinerProvider: RefinerProvider = .omp,
        refinerModel: String = "",
        refinerTimeoutMs: Int = 3000,
        glossary: [ProtectedTerm] = Settings.defaultGlossary,
        muteSystemAudioDuringCapture: Bool = true,
        muteScope: MuteScope = .builtInOutputOnly,
        autoStopEnabled: Bool = false,
        autoStopSilenceMs: Int = 2500,
        speechLocale: String = SpeechLocale.fallback,
        automaticTermCorrectionEnabled: Bool = false,
        decoderBiasEnabled: Bool = false
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.asrBackend = asrBackend
        self.refinerEnabled = refinerEnabled
        self.refinerProvider = refinerProvider
        self.refinerModel = refinerModel
        self.refinerTimeoutMs = refinerTimeoutMs
        self.glossary = glossary
        self.muteSystemAudioDuringCapture = muteSystemAudioDuringCapture
        self.muteScope = muteScope
        self.autoStopEnabled = autoStopEnabled
        self.autoStopSilenceMs = autoStopSilenceMs
        self.speechLocale = speechLocale
        self.automaticTermCorrectionEnabled = automaticTermCorrectionEnabled
        self.decoderBiasEnabled = decoderBiasEnabled
    }

    public init(from decoder: Decoder) throws {
        let defaults = Settings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? defaults.cleanupEnabled
        asrBackend = try container.decodeIfPresent(String.self, forKey: .asrBackend) ?? defaults.asrBackend
        let storedProviderID = try container.decodeIfPresent(String.self, forKey: .refinerProvider)
        let storedEnabled = try container.decodeIfPresent(Bool.self, forKey: .refinerEnabled) ?? defaults.refinerEnabled
        let storedModel = try container.decodeIfPresent(String.self, forKey: .refinerModel) ?? defaults.refinerModel
        if let storedProviderID, RefinerProvider(rawValue: storedProviderID) == nil {
            // A build that reached Gemini, OpenAI, OpenRouter or a hand-typed
            // endpoint directly wrote this file. OMP now brokers every network
            // destination, so the provider becomes OMP — but silently moving a
            // running refiner onto a different destination is a consent
            // question, not a rename, so refinement switches off until the user
            // opts in again against the destination now on screen. The stored
            // model was a bare vendor id (`gpt-4.1-nano`) that OMP's
            // provider/model selector cannot name, so it goes too.
            refinerProvider = defaults.refinerProvider
            refinerEnabled = false
            refinerModel = ""
        } else {
            refinerProvider = storedProviderID.flatMap(RefinerProvider.init(rawValue:)) ?? defaults.refinerProvider
            refinerEnabled = storedEnabled
            refinerModel = storedModel
        }
        refinerTimeoutMs =
            try container.decodeIfPresent(Int.self, forKey: .refinerTimeoutMs) ?? defaults.refinerTimeoutMs
        glossary = try container.decodeIfPresent([ProtectedTerm].self, forKey: .glossary) ?? defaults.glossary
        muteSystemAudioDuringCapture =
            try container.decodeIfPresent(Bool.self, forKey: .muteSystemAudioDuringCapture)
            ?? defaults.muteSystemAudioDuringCapture
        muteScope = try container.decodeIfPresent(MuteScope.self, forKey: .muteScope) ?? defaults.muteScope
        autoStopEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoStopEnabled) ?? defaults.autoStopEnabled
        autoStopSilenceMs =
            try container.decodeIfPresent(Int.self, forKey: .autoStopSilenceMs) ?? defaults.autoStopSilenceMs
        let storedLocale = try container.decodeIfPresent(String.self, forKey: .speechLocale) ?? defaults.speechLocale
        speechLocale = SpeechLocale.canonical(storedLocale) ?? defaults.speechLocale
        automaticTermCorrectionEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .automaticTermCorrectionEnabled)
            ?? defaults.automaticTermCorrectionEnabled
        decoderBiasEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .decoderBiasEnabled) ?? defaults.decoderBiasEnabled
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
