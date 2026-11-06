import Foundation
import Testing

@testable import VoiceCore

@Suite("ProtocolFixtureParityTests")
struct ProtocolFixtureParityTests {
    @Test func protocolFixtureDirectoryExactlyMatchesDecodeMapAndEachFixtureDecodes() throws {
        let fixtureDecoders: [String: (Data) throws -> Void] = [
            "hello.json": { _ = try ASRWire.decode(ASRHello.self, from: $0) },
            "health_request.json": { _ = try ASRWire.decode(ASRHealthRequest.self, from: $0) },
            "health_response.json": { _ = try ASRWire.decode(ASRHealthResponse.self, from: $0) },
            "health_response_acquisition_error.json": {
                _ = try ASRWire.decode(ASRHealthResponse.self, from: $0)
            },
            "transcribe.json": { _ = try ASRWire.decode(ASRTranscribeRequest.self, from: $0) },
            "transcribe_with_spot_terms.json": { _ = try ASRWire.decode(ASRTranscribeRequest.self, from: $0) },
            "result.json": { _ = try ASRWire.decode(ASRResult.self, from: $0) },
            "result_with_words.json": { _ = try ASRWire.decode(ASRResult.self, from: $0) },
            "result_with_term_spots.json": { _ = try ASRWire.decode(ASRResult.self, from: $0) },
            "cancel.json": { _ = try ASRWire.decode(ASRCancelRequest.self, from: $0) },
            "cancelled.json": { _ = try ASRWire.decode(ASRCancelledMessage.self, from: $0) },
            "error.json": { _ = try ASRWire.decode(ASRErrorMessage.self, from: $0) },
        ]
        let fixturesDirectory = repoRoot().appendingPathComponent("fixtures/protocol", isDirectory: true)
        let discoveredFixtures = Set(
            try FileManager.default.contentsOfDirectory(
                at: fixturesDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .map(\.lastPathComponent)
        )

        #expect(discoveredFixtures == Set(fixtureDecoders.keys))

        for filename in fixtureDecoders.keys.sorted() {
            let data = try Data(contentsOf: fixturesDirectory.appendingPathComponent(filename))
            try fixtureDecoders[filename]!(data)
        }
    }

    /// The fixtures are the wire's committed shape, so the request one has to name the artifact
    /// an install actually asks for. Without `file` two files of one revision are
    /// indistinguishable on the wire, which is the whole reason the field exists — a fixture
    /// that drops it, or names another artifact, is a protocol document that no shipped client
    /// would produce.
    @Test func transcribeFixtureNamesThePinnedGraniteArtifact() throws {
        let fixtureURL = repoRoot().appendingPathComponent("fixtures/protocol/transcribe.json")
        let request = try ASRWire.decode(ASRTranscribeRequest.self, from: Data(contentsOf: fixtureURL))

        let pinned = ASRExpectedModel(
            modelId: GraniteModelContract.modelId,
            revision: GraniteModelContract.revision,
            file: GraniteModelContract.fileName
        )

        #expect(request.expectedModel == pinned)
    }

    /// A `health` frame from a sidecar that has nothing to report must decode where the field
    /// exists, and one that reports must decode into the wire's own taxonomy. Both directions
    /// matter: the app and the sidecar are separately signed binaries that a user can end up
    /// running at different versions, and an optional field that only decodes when present is
    /// not optional.
    @Test func aHealthFrameDecodesWithAndWithoutAReportedAcquisitionError() throws {
        let silent = try ASRWire.decode(
            ASRHealthResponse.self,
            from: Data(contentsOf: repoRoot().appendingPathComponent("fixtures/protocol/health_response.json"))
        )
        #expect(silent.lastAcquisitionError == nil)
        // The neighbouring optionals are populated there, so the absent field is the subject
        // rather than a frame that simply omits everything optional.
        #expect(silent.downloadFraction == 0.42)
        #expect(silent.warming == false)

        let reporting = try ASRWire.decode(
            ASRHealthResponse.self,
            from: Data(
                contentsOf: repoRoot()
                    .appendingPathComponent("fixtures/protocol/health_response_acquisition_error.json"))
        )
        let failure = try #require(reporting.lastAcquisitionError)
        #expect(failure.code == .insufficientDiskSpace)
        #expect(failure.detail?.contains("bytes free for") == true)
        // The refusal happens before a byte is fetched, so there is no progress to report and
        // nothing is warming: absent, not zero.
        #expect(reporting.downloadFraction == nil)
        #expect(reporting.warming == nil)
    }

    /// The field has to survive a round trip through the shipped coder, not just decode from a
    /// hand-written fixture: `ASRWire` converts keys, so a nested payload is where a snake-case
    /// mismatch would hide.
    @Test func aReportedAcquisitionErrorSurvivesTheWireCoder() throws {
        let sent = ASRHealthResponse(
            requestId: "r1",
            ready: false,
            modelLoaded: false,
            cacheOk: false,
            lastAcquisitionError: ASRAcquisitionFailure(code: .modelDownloadFailed, detail: "HTTP 403")
        )

        let line = try ASRWire.encodeLine(sent)
        #expect(String(decoding: line, as: UTF8.self).contains("\"last_acquisition_error\""))
        #expect(try ASRWire.decode(ASRHealthResponse.self, from: line) == sent)
    }

    @Test func resultWithWordsDecodesPopulatedWordEvidence() throws {
        let fixtureURL = repoRoot()
            .appendingPathComponent("fixtures/protocol/result_with_words.json")
        let result = try ASRWire.decode(ASRResult.self, from: Data(contentsOf: fixtureURL))

        #expect(result.protocolVersion == 1)
        #expect(result.type == "result")

        let confidence = try #require(result.transcript.confidence)
        let confidenceMode = try #require(result.transcript.confidenceMode)
        #expect(confidence == 0.865)
        #expect(confidenceMode == .greedyTokenProb)

        let segments = try #require(result.transcript.segments)
        let segment = try #require(segments.first)
        #expect(segment.text == "get status")
        #expect(segment.startMs == 0)
        #expect(segment.endMs == 620)

        let words = try #require(segment.words)
        #expect(words.count == 2)
        let firstWord = try #require(words.first)
        let firstWordConfidence = try #require(firstWord.confidence)
        #expect(firstWord.text == "get")
        #expect(firstWord.startMs == 0)
        #expect(firstWord.endMs == 300)
        #expect(firstWordConfidence == 0.82)

        let lastWord = try #require(words.last)
        let lastWordConfidence = try #require(lastWord.confidence)
        #expect(lastWord.text == "status")
        #expect(lastWord.startMs == 320)
        #expect(lastWord.endMs == 620)
        #expect(lastWordConfidence == 0.91)

        #expect(result.backendId == "granite-ctc")
        // A reply attributed to the real backend has to claim the revision that backend loads:
        // this fixture answers the request in `transcribe.json`, and a client that pins one
        // revision while the recorded reply names another documents an exchange it would reject.
        #expect(result.modelId == GraniteModelContract.modelId)
        #expect(result.modelRevision == GraniteModelContract.revision)
    }

    /// `spot_terms` is optional in both directions: the fixture without it decodes to nil, the one
    /// with it to its terms in order, and the shipped coder writes it back under the same key.
    @Test func aTranscribeRequestDecodesWithAndWithoutSpotTerms() throws {
        let plain = try ASRWire.decode(
            ASRTranscribeRequest.self,
            from: Data(contentsOf: repoRoot().appendingPathComponent("fixtures/protocol/transcribe.json"))
        )
        #expect(plain.spotTerms == nil)
        let plainRaw = try #require(
            try JSONSerialization.jsonObject(with: ASRWire.makeEncoder().encode(plain)) as? [String: Any])
        #expect(plainRaw["spot_terms"] == nil)

        let spotting = try ASRWire.decode(
            ASRTranscribeRequest.self,
            from: Data(
                contentsOf: repoRoot().appendingPathComponent("fixtures/protocol/transcribe_with_spot_terms.json"))
        )
        #expect(spotting.expectedModel == GraniteModelContract.expectedModel)
        let terms = try #require(spotting.spotTerms)
        #expect(terms.map(\.variants.first) == ["kubectl", "SwiftUI"])
        #expect(terms[1].variants == TermSpotting.variants(for: "SwiftUI"))
        let raw = try #require(
            try JSONSerialization.jsonObject(with: ASRWire.makeEncoder().encode(spotting)) as? [String: Any])
        let encoded = try #require(raw["spot_terms"] as? [[String: Any]])
        #expect(encoded.count == 2)
        #expect(encoded[0]["variants"] as? [String] == ["kubectl", "Kubectl", "kubectl"])
    }

    /// `term_spots` is optional in both directions too, and its spots keep their snake-case keys.
    @Test func aResultDecodesWithAndWithoutTermSpots() throws {
        let plain = try ASRWire.decode(
            ASRResult.self,
            from: Data(contentsOf: repoRoot().appendingPathComponent("fixtures/protocol/result_with_words.json"))
        )
        #expect(plain.transcript.termSpots == nil)

        let spotted = try ASRWire.decode(
            ASRResult.self,
            from: Data(contentsOf: repoRoot().appendingPathComponent("fixtures/protocol/result_with_term_spots.json"))
        )
        #expect(
            spotted.transcript.termSpots == [
                TermSpot(term: 0, variant: 0, firstWord: 1, lastWord: 2, score: -3.25, tokenCount: 4)
            ])
        #expect(spotted.modelRevision == GraniteModelContract.revision)

        let raw = try #require(
            try JSONSerialization.jsonObject(with: ASRWire.makeEncoder().encode(spotted)) as? [String: Any])
        let transcript = try #require(raw["transcript"] as? [String: Any])
        let spots = try #require(transcript["term_spots"] as? [[String: Any]])
        #expect(
            Set(spots[0].keys) == ["term", "variant", "first_word", "last_word", "score", "token_count"])
    }
}
