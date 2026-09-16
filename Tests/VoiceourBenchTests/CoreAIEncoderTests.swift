import Foundation
import Testing

@testable import VoiceourBench

@Suite("CoreAIEncoderTests")
struct CoreAIEncoderTests {
    @Test func loadRefusesADirectoryThatIsNotACoreAIModel() async throws {
        let model = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceour-coreai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: model) }

        do {
            _ = try await CoreAIEncoder.load(configuration: CoreAIEncoderConfiguration(modelURL: model))
            Issue.record("Expected the load of \(model.path) to fail")
        } catch {
            #expect(String(describing: error).contains(model.path))
        }
    }
}
