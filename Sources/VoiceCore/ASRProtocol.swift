import Foundation

public let asrProtocolVersion = 1

/// The pinned model repository every real decode loads from.
///
/// One Hugging Face repository at one revision holding several conversions of the same
/// checkpoint. `ASRModelVariant` names those artifacts; this is the identity they all share,
/// which is what the backend registry advertises and what the sidecar's `expected_model`
/// check compares. It must move together with `Vendor/parakeet` and the protocol fixtures.
public enum ASRModelContract {
    public static let modelId = "ggml-org/parakeet-GGUF"
    public static let revision = "35156454d1a39de06863303dd209fd2bed6ee079"
}

/// The interchangeable weight artifacts of the pinned repository.
///
/// Every case is the same checkpoint at the same revision converted at a different precision:
/// same vocabulary, same TDT decoder, same wire protocol, and the same transcripts to within
/// the accuracy the committed corpus can resolve. Only the footprint differs, so the choice
/// offered to a reader is a disk and memory trade and never a quality claim. `f16` stays the
/// default because it is also the faster of the two on that corpus.
///
/// The raw value is the artifact's quantization tag: it is the only part of the file name that
/// varies, and it keeps a persisted choice readable.
public enum ASRModelVariant: String, Codable, Equatable, CaseIterable, Sendable {
    case f16
    case q8 = "q8_0"

    /// The compiled default, and where a stale or unknown persisted value lands.
    public static let `default` = ASRModelVariant.f16

    /// How the app names the selection to the sidecar it spawns. The launch environment is an
    /// allowlist that already passes `VOICEOUR_*`, so both sides read this one constant.
    public static let environmentKey = "VOICEOUR_MODEL_VARIANT"

    public var fileName: String { "ggml-parakeet-tdt-0.6b-v3-\(rawValue).bin" }

    public var sha256: String {
        switch self {
        case .f16: return "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f"
        case .q8: return "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e"
        }
    }

    public var sizeBytes: Int64 {
        switch self {
        case .f16: return 1_255_897_319
        case .q8: return 668_757_119
        }
    }

    /// What Settings calls it. Deliberately not the quantization tag: the reader is choosing a
    /// footprint, and `q8_0` names the conversion rather than the consequence.
    public var displayName: String {
        switch self {
        case .f16: return "Balanced"
        case .q8: return "Compact"
        }
    }

    /// Its own directory under the app's cache, so two artifacts can never share one manifest.
    ///
    /// `f16` keeps the directory name it has always had: an existing install must not be
    /// orphaned into re-downloading 1.26 GB the first time this build runs.
    public var cacheDirectoryName: String {
        switch self {
        case .f16: return "parakeet-tdt-0.6b-v3-ggml"
        case .q8: return "parakeet-tdt-0.6b-v3-ggml-q8_0"
        }
    }

    public var downloadURL: URL {
        URL(
            string:
                "https://huggingface.co/\(ASRModelContract.modelId)/resolve/\(ASRModelContract.revision)/\(fileName)"
        )!
    }

    /// Resolves a persisted or environment value, degrading to `default` rather than trapping:
    /// a variant written by a future build must not stop dictation working.
    public static func resolved(_ rawValue: String?) -> ASRModelVariant {
        guard let rawValue, let variant = ASRModelVariant(rawValue: rawValue) else { return .default }
        return variant
    }
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
    /// Bytes arrived but were not the pinned artifact: wrong length or wrong digest. Distinct
    /// from `manifestMismatch`, which is a refusal to overwrite a directory that deliberately
    /// holds a different artifact — that one needs a hand, this one needs another attempt.
    case artifactMismatch = "artifact_mismatch"
    /// The transfer never produced the artifact. One code for every transport reason, an
    /// offline Mac and an HTTP refusal alike: the sentence and the remedy are the same, and
    /// which one it was belongs in `detail`, never in a status line.
    case modelDownloadFailed = "model_download_failed"
    /// The volume cannot hold the artifact. Established before a byte is fetched, and the only
    /// acquisition failure a retry cannot clear.
    case insufficientDiskSpace = "insufficient_disk_space"
    case modelLoadFailed = "model_load_failed"
    case inferenceFailed = "inference_failed"
    case timeout
    case cancelled
    case backendUnavailable = "backend_unavailable"
    case internalError = "internal_error"
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

/// Why the backend's last model acquisition did not finish, latched until one succeeds.
///
/// The wire used to carry nothing at all here: the sidecar caught its preload error, logged it
/// to stderr, and dropped it, so the app could only infer a failure from the transition "was
/// acquiring, now neither, cache still absent" — which a *first* probe cannot see, and which an
/// immediate refusal such as `insufficientDiskSpace` never produces. The backend knows; this is
/// how it says so.
///
/// `code` is the one wire taxonomy, never a parallel acquisition enum, so the app's single
/// mapping from code to sentence covers this too. `detail` is the backend's own bounded
/// message — an HTTP status, a digest pair, a byte budget — and stays a diagnostic.
public struct ASRAcquisitionFailure: Codable, Equatable, Sendable {
    public var code: ASRErrorCode
    public var detail: String?

    public init(code: ASRErrorCode, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}

public struct ASRHealthResponse: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var ready: Bool
    public var modelLoaded: Bool
    public var cacheOk: Bool
    /// 0...1 while the backend is acquiring its artifact, nil when no download is running.
    public var downloadFraction: Double?
    /// True while the backend is loading the model and compiling its pipelines. Nil once the
    /// model is loaded, so an idle-unloaded backend does not read as warming.
    public var warming: Bool?
    /// The backend's last unresolved acquisition failure, or nil when it has none. Optional in
    /// both directions on purpose: an older sidecar never writes the key and a newer one's
    /// frame still decodes where nothing reads it.
    public var lastAcquisitionError: ASRAcquisitionFailure?

    public init(
        type: String = "health",
        protocolVersion: Int = asrProtocolVersion,
        requestId: String,
        ready: Bool,
        modelLoaded: Bool,
        cacheOk: Bool,
        downloadFraction: Double? = nil,
        warming: Bool? = nil,
        lastAcquisitionError: ASRAcquisitionFailure? = nil
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.ready = ready
        self.modelLoaded = modelLoaded
        self.cacheOk = cacheOk
        self.downloadFraction = downloadFraction
        self.warming = warming
        self.lastAcquisitionError = lastAcquisitionError
    }
}

public struct ASRBackendHealth: Equatable, Sendable {
    public var backendId: String
    public var backendStatus: BackendStatus
    public var ready: Bool
    public var modelLoaded: Bool
    public var cacheOk: Bool
    public var downloadFraction: Double?
    public var warming: Bool?
    public var lastAcquisitionError: ASRAcquisitionFailure?

    public init(
        backendId: String,
        backendStatus: BackendStatus,
        ready: Bool,
        modelLoaded: Bool,
        cacheOk: Bool,
        downloadFraction: Double? = nil,
        warming: Bool? = nil,
        lastAcquisitionError: ASRAcquisitionFailure? = nil
    ) {
        self.backendId = backendId
        self.backendStatus = backendStatus
        self.ready = ready
        self.modelLoaded = modelLoaded
        self.cacheOk = cacheOk
        self.downloadFraction = downloadFraction
        self.warming = warming
        self.lastAcquisitionError = lastAcquisitionError
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

/// What the client requires the sidecar to have loaded.
///
/// `file` is load-bearing rather than decorative: every artifact in the pinned repository
/// shares `modelId` and `revision`, so those two alone cannot tell `f16` from `q8_0` and a
/// sidecar left over from the previous selection would satisfy the check while decoding with
/// the wrong weights.
public struct ASRExpectedModel: Codable, Equatable, Sendable {
    public var modelId: String
    public var revision: String
    public var file: String

    public init(modelId: String, revision: String, file: String) {
        self.modelId = modelId
        self.revision = revision
        self.file = file
    }
}

public struct ASRTranscribeRequest: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var audio: ASRAudioMeta
    public var expectedModel: ASRExpectedModel?
    public var timeoutMs: Int

    public init(
        type: String = "transcribe",
        protocolVersion: Int = asrProtocolVersion,
        requestId: String,
        audio: ASRAudioMeta,
        expectedModel: ASRExpectedModel?,
        timeoutMs: Int
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.audio = audio
        self.expectedModel = expectedModel
        self.timeoutMs = timeoutMs
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

/// How a transcript's `confidence` was derived, so consumers can refuse to trust a number
/// whose basis is not calibrated. Neither of these is calibrated today.
public enum ASRConfidenceMode: String, Codable, Equatable, Sendable {
    /// No confidence basis at all: the value, if any, is not a decoder posterior.
    case none
    /// Mean of the decoder's per-token posteriors from a greedy TDT decode.
    case greedyTokenProb = "greedy_token_prob"
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
    /// Second-opinion transcript from the optional assist model, decoded from the
    /// same audio. Optional in both directions: a sidecar without an assist model
    /// omits it and a client that ignores it decodes unchanged. The client-side
    /// text stage arbitrates between `text` and this after cleanup.
    public var assistText: String?

    public init(
        text: String,
        language: String?,
        segments: [ASRSegment]?,
        confidence: Double? = nil,
        confidenceMode: ASRConfidenceMode? = nil,
        assistText: String? = nil
    ) {
        self.text = text
        self.language = language
        self.segments = segments
        self.confidence = confidence
        self.confidenceMode = confidenceMode
        self.assistText = assistText
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

public struct ASRResult: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int
    public var requestId: String
    public var backendId: String
    public var modelId: String
    public var modelRevision: String
    public var transcript: ASRTranscript
    public var timingsMs: ASRTimings

    public init(
        type: String = "result",
        protocolVersion: Int = asrProtocolVersion,
        requestId: String,
        backendId: String,
        modelId: String,
        modelRevision: String,
        transcript: ASRTranscript,
        timingsMs: ASRTimings
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.backendId = backendId
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.transcript = transcript
        self.timingsMs = timingsMs
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

extension ASRErrorMessage {
    /// The one place the wire's error taxonomy is derived from a code. Mirrors the retired
    /// Python `protocol_error`: the client's retry policy and its localized strings key off
    /// these three derived fields, so sidecar and native backends must agree byte for byte.
    public init(code: ASRErrorCode, requestId: String?, detail: String?) {
        // The acquisition codes are setup, not runtime: nothing about the request is wrong and
        // resending it now cannot help, which is also why none of them joins `retryable`.
        let setup: Set<ASRErrorCode> = [
            .modelNotInstalled, .manifestMismatch, .artifactMismatch, .modelDownloadFailed,
            .insufficientDiskSpace, .backendUnavailable,
        ]
        let retryable: Set<ASRErrorCode> = [.timeout, .internalError, .inferenceFailed]
        self.init(
            requestId: requestId,
            code: code,
            category: setup.contains(code) ? "setup" : "runtime",
            retryable: retryable.contains(code),
            userMessageKey: "asr.\(code.rawValue)",
            detail: detail
        )
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
