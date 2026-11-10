import Testing

@testable import Voiceour

@Suite("Kit.Meter")
@MainActor
struct KitMeterTests {
    @Test func clampsToUnitRangeAndSurvivesNonFiniteInput() {
        #expect(Kit.Meter.clamped(0.6) == 0.6)
        #expect(Kit.Meter.clamped(-0.5) == 0)
        #expect(Kit.Meter.clamped(1.7) == 1)
        #expect(Kit.Meter.clamped(.nan) == 0)
        #expect(Kit.Meter.clamped(.infinity) == 1)
        #expect(Kit.Meter.clamped(-.infinity) == 0)
    }
}
