import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The `expected_model` check is what stands between a transcript and the wrong weights. Every
/// file of the pinned repository revision shares its model id and revision, so `file` is the
/// only field in the request that can tell one artifact of that revision from another.
@Suite("SidecarRequestValidationTests")
struct SidecarRequestValidationTests {
    /// Another conversion in the pinned revision's reproducible GGUF set.
    private static let otherFile = "granite-speech-5.0-470m-turboctc-F16.gguf"

    /// Validation reaches its verdict on the model before it looks at the audio, so pointing at
    /// a real file is what keeps a rejection attributable to the artifact rather than the path.
    private func temporaryAudioFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-validation-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("capture.wav")
        try Data().write(to: url)
        return url
    }

    private func request(audio: URL, expecting expected: ASRExpectedModel?) -> ASRTranscribeRequest {
        ASRTranscribeRequest(
            requestId: "r1",
            audio: ASRAudioMeta(
                path: audio.path,
                format: "wav",
                sampleRateHz: 16_000,
                channels: 1,
                durationMs: 1_000,
                byteCount: 0
            ),
            expectedModel: expected,
            timeoutMs: 30_000
        )
    }

    /// Always the pinned identity, so only the loaded artifact varies between cases.
    private func validate(
        _ request: ASRTranscribeRequest,
        loaded file: String
    ) -> SidecarRequestValidation.Outcome {
        SidecarRequestValidation.validate(
            request,
            modelId: GraniteModelContract.modelId,
            modelRevision: GraniteModelContract.revision,
            modelFile: file
        )
    }

    private func failure(_ outcome: SidecarRequestValidation.Outcome) -> (code: ASRErrorCode, detail: String?)? {
        guard case .failure(let code, let detail) = outcome else { return nil }
        return (code, detail)
    }

    private func acceptedPath(_ outcome: SidecarRequestValidation.Outcome) -> URL? {
        guard case .audioPath(let url) = outcome else { return nil }
        return url
    }

    /// The request pins one artifact; this sidecar holds another of the same revision. Model id
    /// and revision match, which is exactly why they cannot catch it.
    @Test func aRequestNamingADifferentArtifactOfThePinnedRevisionIsRefused() throws {
        let audio = try temporaryAudioFile()
        let outcome = validate(
            request(
                audio: audio,
                expecting: ASRExpectedModel(
                    modelId: GraniteModelContract.modelId,
                    revision: GraniteModelContract.revision,
                    file: Self.otherFile
                )
            ),
            loaded: GraniteModelContract.fileName
        )

        let rejection = try #require(failure(outcome), "a stale artifact must not transcribe")
        #expect(rejection.code == .manifestMismatch)
        #expect(rejection.detail == "expected_model file mismatch")
    }

    /// The same request against the sidecar it was written for. Without this the refusal above
    /// could be any blanket rejection of a populated `file`.
    @Test func aRequestNamingTheLoadedArtifactIsAccepted() throws {
        let audio = try temporaryAudioFile()
        let outcome = validate(
            request(
                audio: audio,
                expecting: ASRExpectedModel(
                    modelId: GraniteModelContract.modelId,
                    revision: GraniteModelContract.revision,
                    file: Self.otherFile
                )
            ),
            loaded: Self.otherFile
        )

        #expect(acceptedPath(outcome)?.path == audio.path)
    }

    /// An empty field stays a wildcard, the same as an empty model id or revision: a client that
    /// pins no artifact keeps working against a sidecar that loads one.
    @Test func anEmptyFileIsAWildcardRatherThanAMismatch() throws {
        let audio = try temporaryAudioFile()
        let outcome = validate(
            request(
                audio: audio,
                expecting: ASRExpectedModel(
                    modelId: GraniteModelContract.modelId,
                    revision: GraniteModelContract.revision,
                    file: ""
                )
            ),
            loaded: GraniteModelContract.fileName
        )

        #expect(acceptedPath(outcome)?.path == audio.path)
    }
}
