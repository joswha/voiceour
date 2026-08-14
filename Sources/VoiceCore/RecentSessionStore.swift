import Foundation

public enum RecentSessionInsertionDisposition: String, Codable, Equatable, Sendable {
    case pasteAttempted = "paste_attempted"
    case copiedOnly = "copied_only"
    case failed
}

public struct RecentSessionOutcomeMetadata: Codable, Equatable, Sendable {
    public var disposition: RecentSessionInsertionDisposition
    public var reason: String?
    public var targetSafety: TargetSafetyClass?
    public var targetBundleId: String?

    public init(
        disposition: RecentSessionInsertionDisposition,
        reason: String? = nil,
        targetSafety: TargetSafetyClass? = nil,
        targetBundleId: String? = nil
    ) {
        self.disposition = disposition
        self.reason = reason
        self.targetSafety = targetSafety
        self.targetBundleId = targetBundleId
    }
}

public struct RefinementTrace: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case refined
        case fellBack = "fell_back"
        case skipped
    }

    public var kind: Kind
    public var provider: String?
    /// The model that actually produced this text, as the backend identifies it
    /// — not the configured selector, which `provider` already carries.
    ///
    /// It exists for Apple's on-device provider, whose configured model is the
    /// constant `on-device` while the model behind it is swapped by the OS:
    /// Apple changed it in macOS 26.4 and changes it again in macOS 27, and
    /// documents both as a reason to re-test prompts. Without a recorded
    /// identity every session before and after such an update reads the same,
    /// and a refinement regression cannot be attributed to the swap. The
    /// on-device refiner reports the response's model asset ids verbatim
    /// (`com.apple.fm.language.instruct_3b.…`), which change with the model.
    ///
    /// Absent for traces recorded before this field existed, for skipped
    /// traces, and for any backend whose configured model is already exact.
    public var model: String?
    public var reason: String?
    public var latencyMs: Int?

    public init(
        kind: Kind,
        provider: String? = nil,
        model: String? = nil,
        reason: String? = nil,
        latencyMs: Int? = nil
    ) {
        self.kind = kind
        self.provider = provider
        self.model = model
        self.reason = reason
        self.latencyMs = latencyMs
    }
}

public struct SessionStageTimings: Codable, Equatable, Sendable {
    /// Wall-clock microphone capture duration for the session's audio, as
    /// reported by the recorder at finalize. Absent for sessions recorded
    /// before this field existed; treat only positive values as measured.
    public var captureMs: Int?
    public var asrMs: Int?
    public var insertMs: Int?
    public var startLatencyMs: Int?
    public var asrPath: String?
    public var stopReleaseToInsertionOutcomeMs: Int?
    public var asrBackendId: String?
    public var asrLoadMs: Int?
    public var asrInferenceMs: Int?
    public var asrTotalMs: Int?

    public init(
        captureMs: Int? = nil,
        asrMs: Int? = nil,
        insertMs: Int? = nil,
        startLatencyMs: Int? = nil,
        asrPath: String? = nil,
        stopReleaseToInsertionOutcomeMs: Int? = nil,
        asrBackendId: String? = nil,
        asrLoadMs: Int? = nil,
        asrInferenceMs: Int? = nil,
        asrTotalMs: Int? = nil
    ) {
        self.captureMs = captureMs
        self.asrMs = asrMs
        self.insertMs = insertMs
        self.startLatencyMs = startLatencyMs
        self.asrPath = asrPath
        self.stopReleaseToInsertionOutcomeMs = stopReleaseToInsertionOutcomeMs
        self.asrBackendId = asrBackendId
        self.asrLoadMs = asrLoadMs
        self.asrInferenceMs = asrInferenceMs
        self.asrTotalMs = asrTotalMs
    }
}

public struct RecentSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var mutedDuringCapture: Bool
    public var outcome: RecentSessionOutcomeMetadata?
    public var rawTranscript: String?
    public var refinement: RefinementTrace?
    public var stages: SessionStageTimings?
    public var wordCount: Int {
        var count = 0
        var isInWord = false

        for character in text {
            if character.isWhitespace {
                isInWord = false
            } else if !isInWord {
                count += 1
                isInWord = true
            }
        }

        return count
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case text
        case mutedDuringCapture
        case outcome
        case rawTranscript
        case refinement
        case stages
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        mutedDuringCapture: Bool = false,
        outcome: RecentSessionOutcomeMetadata? = nil,
        rawTranscript: String? = nil,
        refinement: RefinementTrace? = nil,
        stages: SessionStageTimings? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.mutedDuringCapture = mutedDuringCapture
        self.outcome = outcome
        self.rawTranscript = rawTranscript
        self.refinement = refinement
        self.stages = stages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
        mutedDuringCapture = try container.decodeIfPresent(Bool.self, forKey: .mutedDuringCapture) ?? false
        outcome = try container.decodeIfPresent(RecentSessionOutcomeMetadata.self, forKey: .outcome)
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        refinement = try container.decodeIfPresent(RefinementTrace.self, forKey: .refinement)
        stages = try container.decodeIfPresent(SessionStageTimings.self, forKey: .stages)
    }
}

extension RecentSessionOutcomeMetadata {
    public init(outcome: InsertionOutcome, target: TargetSnapshot) {
        switch outcome {
        case .pasteAttempted:
            self.init(
                disposition: .pasteAttempted,
                targetSafety: target.safety,
                targetBundleId: target.bundleId
            )
        case .copiedOnly(let reason):
            self.init(
                disposition: .copiedOnly,
                reason: reason,
                targetSafety: target.safety,
                targetBundleId: target.bundleId
            )
        case .failed(let reason):
            self.init(
                disposition: .failed,
                reason: reason,
                targetSafety: target.safety,
                targetBundleId: target.bundleId
            )
        }
    }
}

public struct RecentSessionStore: Sendable {
    public var url: URL
    public var limit: Int

    public init(url: URL = RecentSessionStore.defaultURL, limit: Int = 500) {
        self.url = url
        self.limit = limit
    }

    public func load() throws -> [RecentSession] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let sessions = try decoder.decode([RecentSession].self, from: data)
        return normalized(sessions)
    }

    public func save(_ sessions: [RecentSession]) throws {
        let sessions = normalized(sessions)
        guard !sessions.isEmpty else {
            try clear()
            return
        }

        try writeVoiceourPrivateJSON(sessions, to: url)
    }

    public func clear() throws {
        try removeVoiceourPrivateState(at: url)
    }

    public static var defaultURL: URL {
        URL.voiceourSupportDirectory.appendingPathComponent("recent-sessions.json")
    }

    public func normalized(_ sessions: [RecentSession]) -> [RecentSession] {
        let cappedLimit = max(0, limit)
        let sorted = sessions.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return Array(sorted.prefix(cappedLimit))
    }
}
