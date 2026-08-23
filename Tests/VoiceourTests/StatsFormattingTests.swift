import Foundation
import Testing

@testable import Voiceour

/// Home's four figures are the app's only claims about the reader's own
/// history, so their boundaries — the hour that appears, the thousand that
/// compacts, the single day that is not "days" — are pinned here rather than
/// left to a golden image to notice.
@Suite("Stats formatting")
struct StatsFormattingTests {
    // MARK: Durations

    @Test func belowAnHourReadsAsMinutesAlone() {
        #expect(StatsFormatting.duration(seconds: 0) == "0 min")
        #expect(StatsFormatting.duration(seconds: 59) == "0 min")
        #expect(StatsFormatting.duration(seconds: 60) == "1 min")
        #expect(StatsFormatting.duration(seconds: 3_599) == "59 min")
    }

    /// An hour or more always states both parts: the reader compares this figure
    /// with itself over time, and a unit that comes and goes makes that harder
    /// than a zero does.
    @Test func anHourOrMoreAlwaysStatesBothParts() {
        #expect(StatsFormatting.duration(seconds: 3_600) == "1 hr 0 min")
        #expect(StatsFormatting.duration(seconds: 16_320) == "4 hr 32 min")
        #expect(StatsFormatting.duration(seconds: 37_870.5) == "10 hr 31 min")
        #expect(StatsFormatting.duration(seconds: 65_940) == "18 hr 19 min")
        #expect(StatsFormatting.duration(seconds: 64_800) == "18 hr 0 min")
    }

    /// Floored, never rounded up: a claim about time already spent must not
    /// exceed the time actually measured.
    @Test func durationsFloorAndClampAtZero() {
        #expect(StatsFormatting.duration(seconds: 119.99) == "1 min")
        #expect(StatsFormatting.duration(seconds: -5) == "0 min")
    }

    @Test func durationPartsCarryTheirOwnUnits() {
        #expect(StatsFormatting.durationParts(seconds: 1_800).map(\.unit) == ["min"])
        #expect(StatsFormatting.durationParts(seconds: 16_320).map(\.unit) == ["hr", "min"])
        #expect(StatsFormatting.durationParts(seconds: 16_320).map(\.value) == ["4", "32"])
    }

    // MARK: Counts

    @Test func countsBelowAThousandAreExact() {
        #expect(StatsFormatting.compactCount(0) == "0")
        #expect(StatsFormatting.compactCount(1) == "1")
        #expect(StatsFormatting.compactCount(999) == "999")
    }

    @Test func thousandsCompactToOneDecimalWithoutATrailingZero() {
        #expect(StatsFormatting.compactCount(1_000) == "1K")
        #expect(StatsFormatting.compactCount(1_100) == "1.1K")
        #expect(StatsFormatting.compactCount(36_100) == "36.1K")
        #expect(StatsFormatting.compactCount(36_127) == "36.1K")
        #expect(StatsFormatting.compactCount(999_999) == "999.9K")
    }

    @Test func millionsCompactTheSameWay() {
        #expect(StatsFormatting.compactCount(1_000_000) == "1M")
        #expect(StatsFormatting.compactCount(1_250_000) == "1.2M")
        #expect(StatsFormatting.compactCount(12_000_000) == "12M")
    }

    /// Truncated, not rounded: a compacted count must never claim a magnitude
    /// the exact number has not reached.
    @Test func compactCountsTruncateRatherThanRound() {
        #expect(StatsFormatting.compactCount(1_999) == "1.9K")
        #expect(StatsFormatting.compactCount(1_099) == "1K")
        #expect(StatsFormatting.compactCount(-4) == "0")
    }

    // MARK: Days

    @Test func oneDayIsNotDays() {
        #expect(StatsFormatting.dayLabel(0) == "0 days")
        #expect(StatsFormatting.dayLabel(1) == "1 day")
        #expect(StatsFormatting.dayLabel(2) == "2 days")
        #expect(StatsFormatting.dayLabel(6) == "6 days")
    }
}
