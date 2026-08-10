import Foundation

public let asrProtocolVersion = 1

public enum ASRModelContract {
    public static let modelId = "mlx-community/parakeet-tdt-0.6b-v3"
    public static let revision = "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
}

public enum BackendStatus: String, Codable, Equatable, Sendable {
    case ready
    case modelMissing = "model_missing"
    case backendUnavailable = "backend_unavailable"
}

public enum ASRErrorCode: String, Codable, Equatable, Sendable, CaseIterable {
    case invalidRequest = "invalid_request"
    case incompatibleProtocol = "incompatible_protocol"
    case audioNotFound = "audio_not_found"
    case unsupportedAudioFormat = "unsupported_audio_format"
    case modelNotInstalled = "model_not_installed"
    case manifestMismatch = "manifest_mismatch"
    case modelLoadFailed = "model_load_failed"
    case inferenceFailed = "inference_failed"
    case timeout
    case cancelled
    case backendUnavailable = "backend_unavailable"
    case internalError = "internal_error"
    case biasListTooLarge = "bias_list_too_large"
}

public struct ASRCapabilities: Codable, Equatable, Sendable {
    public var finalUtterance: Bool

    public init(finalUtterance: Bool) {
        self.finalUtterance = finalUtterance
    }
}

public struct ASRHello: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var sidecarVersion: String
    public var backendId: String
    public var backendStatus: BackendStatus
    public var capabilities: ASRCapabilities

    public init(
        type: String = "hello",
        protocolVersion: Int = asrProtocolVersion,
        sidecarVersion: String,
        backendId: String,
        backendStatus: BackendStatus,
        capabilities: ASRCapabilities
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.sidecarVersion = sidecarVersion
        self.backendId = backendId
        self.backendStatus = backendStatus
        self.capabilities = capabilities
    }
}

public struct ASRHealthRequest: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String

    public init(type: String = "health", protocolVersion: Int = asrProtocolVersion, requestId: String) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
    }
}

public struct ASRHealthResponse: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var ready: Bool
    public var modelLoaded: Bool
    public var cacheOk: Bool

    public init(
        type: String = "health",
        protocolVersion: Int = asrProtocolVersion,
        requestId: String,
        ready: Bool,
        modelLoaded: Bool,
        cacheOk: Bool
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.ready = ready
        self.modelLoaded = modelLoaded
        self.cacheOk = cacheOk
    }
}

public struct ASRBackendHealth: Equatable, Sendable {
    public var backendId: String
    public var backendStatus: BackendStatus
    public var ready: Bool
    public var modelLoaded: Bool
    public var cacheOk: Bool

    public init(backendId: String, backendStatus: BackendStatus, ready: Bool, modelLoaded: Bool, cacheOk: Bool) {
        self.backendId = backendId
        self.backendStatus = backendStatus
        self.ready = ready
        self.modelLoaded = modelLoaded
        self.cacheOk = cacheOk
    }
}

public struct ASRAudioMeta: Codable, Equatable, Sendable {
    public var path: String
    public var format: String
    public var sampleRateHz: Int
    public var channels: Int
    public var durationMs: Int
    public var byteCount: Int

    public init(path: String, format: String, sampleRateHz: Int, channels: Int, durationMs: Int, byteCount: Int) {
        self.path = path
        self.format = format
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.durationMs = durationMs
        self.byteCount = byteCount
    }
}

public struct ASRExpectedModel: Codable, Equatable, Sendable {
    public var modelId: String
    public var revision: String

    public init(modelId: String, revision: String) {
        self.modelId = modelId
        self.revision = revision
    }
}

public struct ASRBiasPhrase: Codable, Equatable, Sendable {
    public var text: String
    public var weight: Double?

    public init(text: String, weight: Double? = nil) {
        self.text = text
        self.weight = weight
    }
}

public struct ASRTranscribeRequest: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var audio: ASRAudioMeta
    public var expectedModel: ASRExpectedModel?
    public var timeoutMs: Int
    public var biasPhrases: [ASRBiasPhrase]?
    public var biasSnapshotId: String?

    public init(
        type: String = "transcribe",
        protocolVersion: Int = asrProtocolVersion,
        requestId: String,
        audio: ASRAudioMeta,
        expectedModel: ASRExpectedModel?,
        timeoutMs: Int,
        biasPhrases: [ASRBiasPhrase]? = nil,
        biasSnapshotId: String? = nil
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.audio = audio
        self.expectedModel = expectedModel
        self.timeoutMs = timeoutMs
        self.biasPhrases = biasPhrases
        self.biasSnapshotId = biasSnapshotId
    }
}

public struct ASRCancelRequest: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String

    public init(type: String = "cancel", protocolVersion: Int = asrProtocolVersion, requestId: String) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
    }
}

public enum ASRConfidenceMode: String, Codable, Equatable, Sendable {
    case none
    case greedyEntropy = "greedy_entropy"
    case beamLogprob = "beam_logprob"
}

public struct ASRWord: Codable, Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double?

    public init(text: String, startMs: Int, endMs: Int, confidence: Double? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
    }
}

public struct ASRSegment: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var words: [ASRWord]?

    public init(startMs: Int, endMs: Int, text: String, words: [ASRWord]? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.words = words
    }
}

public struct ASRTranscript: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?
    public var segments: [ASRSegment]?
    public var confidence: Double?
    public var confidenceMode: ASRConfidenceMode?

    public init(
        text: String,
        language: String?,
        segments: [ASRSegment]?,
        confidence: Double? = nil,
        confidenceMode: ASRConfidenceMode? = nil
    ) {
        self.text = text
        self.language = language
        self.segments = segments
        self.confidence = confidence
        self.confidenceMode = confidenceMode
    }
}

public struct ASRTimings: Codable, Equatable, Sendable {
    public var load: Int
    public var inference: Int
    public var total: Int

    public init(load: Int, inference: Int, total: Int) {
        self.load = load
        self.inference = inference
        self.total = total
    }
}

public struct ASRHypothesis: Codable, Equatable, Sendable {
    public var rank: Int
    public var text: String
    public var score: Double
    public var rawScore: Double?
    public var transcript: ASRTranscript?

    public init(rank: Int, text: String, score: Double, rawScore: Double? = nil, transcript: ASRTranscript? = nil) {
        self.rank = rank
        self.text = text
        self.score = score
        self.rawScore = rawScore
        self.transcript = transcript
    }
}

public struct ASRDecoderInfo: Codable, Equatable, Sendable {
    public var mode: String
    public var beamSize: Int?
    public var biasEnabled: Bool
    public var biasSnapshotId: String?

    public init(mode: String, beamSize: Int? = nil, biasEnabled: Bool = false, biasSnapshotId: String? = nil) {
        self.mode = mode
        self.beamSize = beamSize
        self.biasEnabled = biasEnabled
        self.biasSnapshotId = biasSnapshotId
    }
}

public struct ASRResult: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var backendId: String
    public var modelId: String
    public var modelRevision: String
    public var transcript: ASRTranscript
    public var timingsMs: ASRTimings
    public var hypotheses: [ASRHypothesis]?
    public var decoder: ASRDecoderInfo?

    public init(
        type: String = "result",
        protocolVersion: Int = asrProtocolVersion,
        requestId: String,
        backendId: String,
        modelId: String,
        modelRevision: String,
        transcript: ASRTranscript,
        timingsMs: ASRTimings,
        hypotheses: [ASRHypothesis]? = nil,
        decoder: ASRDecoderInfo? = nil
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.backendId = backendId
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.transcript = transcript
        self.timingsMs = timingsMs
        self.hypotheses = hypotheses
        self.decoder = decoder
    }
}

public struct ASRErrorMessage: Codable, Error, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String?
    public var code: ASRErrorCode
    public var category: String
    public var retryable: Bool
    public var userMessageKey: String
    public var detail: String?

    public init(
        type: String = "error",
        protocolVersion: Int = asrProtocolVersion,
        requestId: String?,
        code: ASRErrorCode,
        category: String,
        retryable: Bool,
        userMessageKey: String,
        detail: String?
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.code = code
        self.category = category
        self.retryable = retryable
        self.userMessageKey = userMessageKey
        self.detail = detail
    }
}

public struct ASRCancelledMessage: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String

    public init(type: String = "cancelled", protocolVersion: Int = asrProtocolVersion, requestId: String) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
    }
}

public enum ASRWire {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }
}
