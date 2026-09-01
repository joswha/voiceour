import Testing

@testable import ASRSidecarCore

struct ParakeetTailQuantTests {
    @Test func absentKeyResolvesToDefault() throws {
        #expect(try ParakeetTailQuant.resolve(environment: [:]) == .default)
    }

    @Test func namedValuesResolve() throws {
        #expect(try ParakeetTailQuant.resolve(environment: [ParakeetTailQuant.environmentKey: "default"]) == .default)
        #expect(try ParakeetTailQuant.resolve(environment: [ParakeetTailQuant.environmentKey: "q8_0"]) == .q8)
    }

    @Test func unknownValueFailsClosed() {
        #expect(throws: ParakeetTailQuantError.self) {
            try ParakeetTailQuant.resolve(environment: [ParakeetTailQuant.environmentKey: "q8"])
        }
    }
}
