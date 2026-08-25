import Foundation
import Testing
import VoiceCore

@testable import ASRSidecarCore

/// The `expected_model` check is what stands between a restart-to-apply model selection and a
/// transcript produced by the wrong weights. Every artifact of the pinned repository shares its
/// model id and revision, so `file` is the only field in the request that can tell a sidecar
/// serving the previous selection from one serving the current one.
@Suite("SidecarRequestValidationTests")
struct SidecarRequestValidationTests {
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
            modelId: ASRModelContract.modelId,
            modelRevision: ASRModelContract.revision,
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

    /// The request pins the artifact the app selected; this sidecar still holds the other one.
    /// Model id and revision match, which is exactly why they cannot catch it.
    @Test func aRequestNamingADifferentArtifactOfThePinnedRevisionIsRefused() throws {
        let audio = try temporaryAudioFile()
        let outcome = validate(
            request(
                audio: audio,
                expecting: ASRExpectedModel(
                    modelId: ASRModelContract.modelId,
                    revision: ASRModelContract.revision,
                    file: ASRModelVariant.q8.fileName
                )
            ),
            loaded: ASRModelVariant.f16.fileName
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
                    modelId: ASRModelContract.modelId,
                    revision: ASRModelContract.revision,
                    file: ASRModelVariant.q8.fileName
                )
            ),
            loaded: ASRModelVariant.q8.fileName
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
                    modelId: ASRModelContract.modelId,
                    revision: ASRModelContract.revision,
                    file: ""
                )
            ),
            loaded: ASRModelVariant.f16.fileName
        )

        #expect(acceptedPath(outcome)?.path == audio.path)
    }
}
