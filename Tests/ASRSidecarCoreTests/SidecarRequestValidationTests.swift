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

    private func request(audio: URL, spotTerms: [ASRSpotTerm]?) -> ASRTranscribeRequest {
        var request = request(audio: audio, expecting: GraniteModelContract.expectedModel)
        request.spotTerms = spotTerms
        return request
    }

    /// Terms within bounds reach the decode; so does a request with none.
    @Test func boundedSpotTermsAndNoSpotTermsAreAccepted() throws {
        let audio = try temporaryAudioFile()
        let terms = [ASRSpotTerm(variants: TermSpotting.variants(for: "SwiftUI"))]
        for spotTerms in [terms, [], nil] {
            let outcome = validate(request(audio: audio, spotTerms: spotTerms), loaded: GraniteModelContract.fileName)
            #expect(acceptedPath(outcome)?.path == audio.path)
        }
    }

    @Test(arguments: [
        ([ASRSpotTerm(variants: [])], "spot_terms[0] must hold 1 to 64 variants"),
        (
            [ASRSpotTerm(variants: ["kubectl"]), ASRSpotTerm(variants: Array(repeating: "kubectl", count: 65))],
            "spot_terms[1] must hold 1 to 64 variants"
        ),
        (
            [ASRSpotTerm(variants: ["kubectl", ""])],
            "spot_terms[0] variants must be non-empty and at most 256 characters"
        ),
        (
            [ASRSpotTerm(variants: [String(repeating: "k", count: 257)])],
            "spot_terms[0] variants must be non-empty and at most 256 characters"
        ),
        (
            Array(repeating: ASRSpotTerm(variants: ["kubectl"]), count: 1_001),
            "spot_terms holds more than 1000 terms"
        ),
    ])
    func unboundedSpotTermsAreAnInvalidRequest(spotTerms: [ASRSpotTerm], detail: String) throws {
        let audio = try temporaryAudioFile()
        let outcome = validate(request(audio: audio, spotTerms: spotTerms), loaded: GraniteModelContract.fileName)

        let rejection = try #require(failure(outcome))
        #expect(rejection.code == .invalidRequest)
        #expect(rejection.detail == detail)
    }

    /// The server decodes `spot_terms` when present and leaves it nil when omitted; a malformed
    /// one is a schema error answered with the request's own id, like any other field.
    @Test func theServerDecodesSpotTermsWhenPresentAndOmitted() throws {
        let base =
            #"{"type":"transcribe","protocol_version":1,"request_id":"r1","audio":{"path":"/tmp/a.wav","format":"wav","sample_rate_hz":16000,"channels":1,"duration_ms":1,"byte_count":0},"timeout_ms":30000"#

        guard case .transcribe(let omitted) = SidecarRequestParser.parse(base + "}") else {
            Issue.record("a request without spot_terms must decode")
            return
        }
        #expect(omitted.spotTerms == nil)

        guard
            case .transcribe(let present) = SidecarRequestParser.parse(
                base + #","spot_terms":[{"variants":["kubectl","Kubectl"]},{"variants":["SwiftUI"]}]}"#)
        else {
            Issue.record("a request with spot_terms must decode")
            return
        }
        #expect(
            present.spotTerms == [ASRSpotTerm(variants: ["kubectl", "Kubectl"]), ASRSpotTerm(variants: ["SwiftUI"])])

        guard
            case .malformed(let error) = SidecarRequestParser.parse(base + #","spot_terms":[{"variants":"kubectl"}]}"#)
        else {
            Issue.record("a malformed spot_terms must be refused")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(error.requestId == "r1")
    }
}
