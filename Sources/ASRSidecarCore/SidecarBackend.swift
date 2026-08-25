import Foundation
import VoiceCore

/// The one terminal answer a transcribe request produces.
///
/// Exactly one of these is emitted per `transcribe`, which is the protocol's core promise;
/// modelling it as a value keeps that promise checkable instead of relying on every code
/// path remembering to write to stdout once.
public enum SidecarTerminal: Sendable {
    case result(
        transcript: ASRTranscript,
        backendId: String,
        modelId: String,
        modelRevision: String,
        timings: ASRTimings
    )
    /// `fatal` means the process cannot serve another request: ggml's Metal device is poisoned
    /// and logs "recreate the backend to recover", which is not something this process can do.
    /// The server exits on it so the client's tested respawn path produces a clean context.
    case failure(code: ASRErrorCode, detail: String?, fatal: Bool)
    case cancelled
}

/// What every sidecar backend must answer.
///
/// Deliberately synchronous and thread-confined: `health()` is called from the reader thread
/// while a decode may be running, and `transcribe` only ever runs on the server's single
/// decode queue.
public protocol SidecarBackend: AnyObject, Sendable {
    var backendId: String { get }
    /// Status reported in `hello`, before any request arrives.
    func startupStatus() -> BackendStatus
    func health() -> ASRBackendHealth
    func transcribe(_ request: ASRTranscribeRequest, isCancelled: @escaping () -> Bool) -> SidecarTerminal
    /// Acquire and warm whatever the first real request would otherwise pay for.
    /// Runs on a background thread; network work must not touch the decode queue.
    func warmUp() throws
    /// Release native resources before the process exits.
    ///
    /// Not optional hygiene for the parakeet backend: ggml's Metal device is owned by a C++
    /// static, and `exit()` runs its destructor, which asserts that no residency set still
    /// holds a buffer. A live context at exit turns a clean shutdown into SIGABRT.
    func shutdown()
}

extension SidecarBackend {
    public func warmUp() throws {}
    public func shutdown() {}
}

/// Request validation shared by every backend, in the order the Python `base.py` applied it.
public enum SidecarRequestValidation {
    public enum Outcome {
        case audioPath(URL)
        case failure(code: ASRErrorCode, detail: String?)
    }

    /// An empty `expected_model` field is a wildcard, so an older client that only pins the
    /// model id keeps working against a sidecar whose revision moved.
    public static func validate(
        _ request: ASRTranscribeRequest,
        modelId: String,
        modelRevision: String,
        modelFile: String
    ) -> Outcome {
        if let expected = request.expectedModel {
            if !expected.modelId.isEmpty, expected.modelId != modelId {
                return .failure(code: .manifestMismatch, detail: "expected_model model_id mismatch")
            }
            if !expected.revision.isEmpty, expected.revision != modelRevision {
                return .failure(code: .manifestMismatch, detail: "expected_model revision mismatch")
            }
            // The one field that distinguishes the artifacts of a single pinned revision, and so
            // the only one that catches a sidecar still holding the previously selected weights.
            if !expected.file.isEmpty, expected.file != modelFile {
                return .failure(code: .manifestMismatch, detail: "expected_model file mismatch")
            }
        }
        let path = URL(fileURLWithPath: request.audio.path)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .failure(code: .audioNotFound, detail: path.path)
        }
        guard request.audio.format.lowercased() == "wav" else {
            return .failure(code: .unsupportedAudioFormat, detail: request.audio.format)
        }
        return .audioPath(path)
    }
}
