import Foundation

public let asrProtocolVersion = 1

/// Precision tags of a model variant setting no backend reads.
///
/// Every recognizer Voiceour runs has exactly one artifact, so nothing resolves a variant: the
/// type, `Settings.asrModelVariant` and its `asr_model_variant` key are kept only for VoiceCore's
/// external consumers (../syncour compiles against them, and its settings round-trip the key).
/// Its cases are the retired Parakeet conversions' quantization tags. NEVER give Granite a case.
public enum ASRModelVariant: String, Codable, Equatable, CaseIterable, Sendable {
    case f16
    case q8 = "q8_0"

    /// Where an absent, stale or unknown persisted value lands.
    public static let `default` = ASRModelVariant.f16

    /// Resolves a persisted value, degrading to `default` rather than trapping: a value written
    /// by another build must not quarantine the settings file.
    public static func resolved(_ rawValue: String?) -> ASRModelVariant {
        guard let rawValue, let variant = ASRModelVariant(rawValue: rawValue) else { return .default }
        return variant
    }
}

/// Granite Speech 5.0 TurboCTC 470M (IBM, Apache-2.0), Oct-21 multilingual checkpoint, the Q8_0 file of the
/// reproducible GGUF set the maintainers publish: every file there rebuilds byte for byte from IBM's checkpoint.
/// The recognizer's pin. It must move together with `Vendor/granite` and the protocol fixtures.
public enum GraniteModelContract {
    public static let modelId = "vladers/granite-speech-5.0-470m-turboctc-GGUF"
    public static let revision = "bd7db273aa69a26fc81e370c84597fa738fe2ad0"
    public static let fileName = "granite-speech-5.0-470m-turboctc-Q8_0.gguf"
    public static let sha256 = "fc34cbe71f979a6aeb8bea08bfac88d5c62c1736c0bc845827e37c90f28e336c"
    public static let sizeBytes: Int64 = 505_663_136
    public static let cacheDirectoryName = "granite-speech-5.0-470m-turboctc-q8_0"
    public static let sourceCheckpoint = "ibm-granite/granite-speech-5.0-470m-turboctc"
    public static let sourceRevision = "1dd23f46f6d4e6eae2531982ba2e33220086dd97"
    public static var downloadURL: URL {
        URL(string: "https://huggingface.co/\(modelId)/resolve/\(revision)/\(fileName)")!
    }
    public static var expectedModel: ASRExpectedModel {
        ASRExpectedModel(modelId: modelId, revision: revision, file: fileName)
    }
}

extension GraniteModelContract {
    /// Pins earlier builds downloaded into Granite's app cache directory. An artifact cached
    /// under one of them is a pin Voiceour itself replaced, not a deliberately kept file, so
    /// acquisition replaces it instead of refusing the directory. Under a caller-owned
    /// `VOICEOUR_MODEL_CACHE` it is refused like any other mismatch.
    public static let supersededPins: [ASRExpectedModel] = [
        ASRExpectedModel(
            modelId: "17slever17/granite-speech-5.0-470m-turboctc-multilingual-GGUF",
            revision: "62f64d9d5ad35989b06caf199cafe7155944a22b",
            file: "granite-speech-5.0-470m-turboctc-multilingual-Q8_0.gguf"
        )
    ]
}

/// The one weight artifact a running model-backed backend loads, whichever backend that is.
///
/// Every surface that names or sizes "the model" — the download readout, Diagnostics, the
/// Settings Model section, benchmark metadata — reads this rather than restating the pin.
public struct ASRModelArtifact: Equatable, Sendable {
    public let modelId: String
    public let revision: String
    public let file: String
    public let sizeBytes: Int64
    /// What a reader calls it: the model's name.
    public let displayName: String
    /// What tells this artifact apart within its pinned revision: its file name.
    public let tag: String

    public init(modelId: String, revision: String, file: String, sizeBytes: Int64, displayName: String, tag: String) {
        self.modelId = modelId
        self.revision = revision
        self.file = file
        self.sizeBytes = sizeBytes
        self.displayName = displayName
        self.tag = tag
    }

    public static let granite = ASRModelArtifact(
        modelId: GraniteModelContract.modelId,
        revision: GraniteModelContract.revision,
        file: GraniteModelContract.fileName,
        sizeBytes: GraniteModelContract.sizeBytes,
        displayName: "Granite Speech 5.0 TurboCTC 470M",
        tag: GraniteModelContract.fileName
    )

    /// `<id>@<revision> (<tag>)`: the string a bug report needs to name the exact weights.
    public var identifier: String { "\(modelId)@\(revision) (\(tag))" }

    /// The pin the sidecar must have loaded, echoed on every transcribe.
    public var expectedModel: ASRExpectedModel {
        ASRExpectedModel(modelId: modelId, revision: revision, file: file)
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
    /// Mean of greedy decoder token posteriors (for Granite, the CTC first-frame posterior).
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
