import Testing

@testable import ASRSidecarCore

struct CoreMLWarmModeTests {
    @Test func absentKeyResolvesToDefault() throws {
        #expect(try CoreMLWarmMode.resolve(environment: [:]) == .default)
    }

    @Test func namedValuesResolve() throws {
        #expect(try CoreMLWarmMode.resolve(environment: [CoreMLWarmMode.environmentKey: "default"]) == .default)
        #expect(try CoreMLWarmMode.resolve(environment: [CoreMLWarmMode.environmentKey: "tiers"]) == .tiers)
    }

    @Test func unknownValueFailsClosed() {
        #expect(throws: CoreMLWarmModeError.self) {
            try CoreMLWarmMode.resolve(environment: [CoreMLWarmMode.environmentKey: "eager"])
        }
    }
}
