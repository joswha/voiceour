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
            "transcribe.json": { _ = try ASRWire.decode(ASRTranscribeRequest.self, from: $0) },
            "result.json": { _ = try ASRWire.decode(ASRResult.self, from: $0) },
            "result_with_words.json": { _ = try ASRWire.decode(ASRResult.self, from: $0) },
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
    /// a default install actually asks for. Without `file` the pinned repository's variants are
    /// indistinguishable on the wire, which is the whole reason the field exists — a fixture
    /// that drops it, or names the artifact of a variant that is no longer the default, is a
    /// protocol document that no shipped client would produce.
    @Test func transcribeFixtureNamesTheDefaultVariantOfThePinnedRepository() throws {
        let fixtureURL = repoRoot().appendingPathComponent("fixtures/protocol/transcribe.json")
        let request = try ASRWire.decode(ASRTranscribeRequest.self, from: Data(contentsOf: fixtureURL))

        let pinned = ASRExpectedModel(
            modelId: ASRModelContract.modelId,
            revision: ASRModelContract.revision,
            file: ASRModelVariant.default.fileName
        )

        #expect(request.expectedModel == pinned)
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

        #expect(result.backendId == "parakeet-cpp")
        // A reply attributed to the real backend has to claim the revision that backend loads:
        // this fixture answers the request in `transcribe.json`, and a client that pins one
        // revision while the recorded reply names another documents an exchange it would reject.
        #expect(result.modelId == ASRModelContract.modelId)
        #expect(result.modelRevision == ASRModelContract.revision)
    }
}
