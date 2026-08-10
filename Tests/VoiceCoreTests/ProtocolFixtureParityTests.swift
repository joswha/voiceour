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
            "result_with_evidence.json": { _ = try ASRWire.decode(ASRResult.self, from: $0) },
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

    @Test func resultWithEvidenceDecodesPopulatedOptionalEvidence() throws {
        let fixtureURL = repoRoot()
            .appendingPathComponent("fixtures/protocol/result_with_evidence.json")
        let result = try ASRWire.decode(ASRResult.self, from: Data(contentsOf: fixtureURL))

        #expect(result.protocolVersion == 1)
        #expect(result.type == "result")

        let confidence = try #require(result.transcript.confidence)
        let confidenceMode = try #require(result.transcript.confidenceMode)
        #expect(confidence == 0.865)
        #expect(confidenceMode == .beamLogprob)

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

        let hypotheses = try #require(result.hypotheses)
        let alternate = try #require(hypotheses.first { $0.rank == 1 })
        let rawScore = try #require(alternate.rawScore)
        #expect(alternate.text == "git status")
        #expect(rawScore == -3.94)

        let decoder = try #require(result.decoder)
        let beamSize = try #require(decoder.beamSize)
        #expect(decoder.mode == "beam")
        #expect(beamSize == 5)
        #expect(decoder.biasEnabled == false)
        #expect(decoder.biasSnapshotId == nil)
    }
}
