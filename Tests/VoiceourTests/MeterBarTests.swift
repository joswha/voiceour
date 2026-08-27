import Testing

@testable import Voiceour

@Suite("MeterBar")
struct MeterBarTests {
    @Test func clampsToUnitRangeAndSurvivesNonFiniteInput() {
        #expect(MeterBar.clamped(0.6) == 0.6)
        #expect(MeterBar.clamped(-0.5) == 0)
        #expect(MeterBar.clamped(1.7) == 1)
        #expect(MeterBar.clamped(.nan) == 0)
        #expect(MeterBar.clamped(.infinity) == 1)
    }
}
