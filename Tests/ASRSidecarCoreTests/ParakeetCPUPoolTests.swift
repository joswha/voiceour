import Testing

@testable import ASRSidecarCore

struct ParakeetCPUPoolTests {
    @Test func absentKeyResolvesToDefault() throws {
        #expect(try ParakeetCPUPool.resolve(environment: [:]) == .default)
    }

    @Test func namedValuesResolve() throws {
        #expect(try ParakeetCPUPool.resolve(environment: [ParakeetCPUPool.environmentKey: "default"]) == .default)
        #expect(
            try ParakeetCPUPool.resolve(environment: [ParakeetCPUPool.environmentKey: "persistent"]) == .persistent)
    }

    @Test func unknownValueFailsClosed() {
        #expect(throws: ParakeetCPUPoolError.self) {
            try ParakeetCPUPool.resolve(environment: [ParakeetCPUPool.environmentKey: "pooled"])
        }
    }
}
