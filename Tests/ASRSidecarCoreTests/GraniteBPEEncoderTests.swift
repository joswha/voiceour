import Foundation
import Testing

@testable import ASRSidecarCore

/// Regression vectors for the encoder over the pinned model's own tables: spotting patterns are
/// these ids, so a drift here silently moves every spot. The ids come from
/// `voiceour-bench granite-tokenize` on the pinned Q8_0 file (the encoder matched IBM's tokenizer on
/// 18,800 strings in wave 1). Opt-in: needs the pinned GGUF at `VOICEOUR_GRANITE_MODEL` or in the
/// default Granite cache; enable with `VOICEOUR_GRANITE_INTEGRATION=1`.
@Suite("GraniteBPEEncoderTests", .timeLimit(.minutes(1)))
struct GraniteBPEEncoderTests {
    @Test func thePinnedModelsTokenizerEncodesTheRegressionVectors() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICEOUR_GRANITE_INTEGRATION"] != nil else { return }
        let modelPath =
            environment["VOICEOUR_GRANITE_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ModelCache.granite(environment: [:]).modelURL.path
        try #require(FileManager.default.fileExists(atPath: modelPath), "no Granite model at \(modelPath)")
        let encoder = try GraniteContext(modelPath: modelPath).makeEncoder()

        let vectors: [(text: String, ids: [Int32])] = [
            ("kubectl", [531, 4372, 2099, 941]),
            ("SwiftUI", [13601, 5565, 16363, 16374]),
            ("swift u i", [3967, 5565, 527, 533]),
            ("HorizontalPodAutoscaler", [14309, 2233, 2426, 2051, 16368, 2127, 16383, 2073, 2060, 944, 2051, 2034]),
            ("OAuth 2.0", [13460, 16383, 5104, 6436, 978]),
            ("naïve café, ﬁne", [2427, 1445, 2079, 2962, 948, 966, 951, 4739]),
        ]
        for vector in vectors {
            #expect(encoder.encode(vector.text) == vector.ids, "\(vector.text)")
        }
    }
}
