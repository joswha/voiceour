import Foundation
import VoiceCore

/// How Home states a duration, a count, a day tally and one heatmap square's
/// hover sentence.
///
/// English literals, like the rest of this app's readouts: there is no
/// localization layer to route them through, and inventing one for a handful of
/// strings would be the wrong place to start.
enum StatsFormatting {
    /// A duration split into the parts a tile renders as value + unit.
    ///
    /// Under an hour reads as minutes alone; an hour or more always states both,
    /// so "18 hr 0 min" is correct rather than absent — the reader is comparing
    /// this figure with itself over time, and a unit that appears and disappears
    /// makes that harder than a zero does.
    ///
    /// Floored, never rounded up: a claim about time already spent should not
    /// exceed the time actually measured.
    static func durationParts(seconds: Double) -> [(value: String, unit: String)] {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        guard minutes >= 60 else { return [(String(minutes), "min")] }
        return [(String(minutes / 60), "hr"), (String(minutes % 60), "min")]
    }

    /// One line for a duration: "4 hr 32 min", "18 min".
    static func duration(seconds: Double) -> String {
        durationParts(seconds: seconds)
            .map { "\($0.value) \($0.unit)" }
            .joined(separator: " ")
    }

    /// Thousands and millions to one decimal, with a bare integer below 1,000.
    /// "36.1K" rather than "36,127": the tile states a magnitude, and six digits
    /// of precision on a lifetime word count is precision nobody reads.
    static func compactCount(_ count: Int) -> String {
        guard count >= 0 else { return "0" }
        if count < 1_000 { return String(count) }
        if count < 1_000_000 { return scaled(count, by: 1_000, suffix: "K") }
        return scaled(count, by: 1_000_000, suffix: "M")
    }

    private static func scaled(_ count: Int, by divisor: Int, suffix: String) -> String {
        // One decimal, truncated rather than rounded, so a compacted count never
        // claims a magnitude the exact number has not reached.
        let tenths = count * 10 / divisor
        let whole = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 ? "\(whole)\(suffix)" : "\(whole).\(fraction)\(suffix)"
    }

    static func dayLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "day" : "days")"
    }

    /// One heatmap square's hover sentence: the words first — that is what the
    /// level ladder encodes — then the day.
    ///
    /// The calendar carries all three Foundation seams (calendar, locale, time
    /// zone), resolved by the caller the way `ConsoleHomeTab.calendar` resolves
    /// them, so the rendered day is the same local day the ledger keyed. The
    /// key is parsed by `DictationStatsLedger.date(forDayKey:calendar:)`, the one
    /// place a day key is validated, and resolved through that calendar at local
    /// midnight rather than through the ledger's UTC arithmetic: a UTC midnight
    /// formatted in a western zone would name the previous day.
    ///
    /// Returns nil for a string that is not a day key this app wrote.
    static func heatmapTooltip(words: Int, dayKey: String, calendar: Calendar) -> String? {
        guard let date = DictationStatsLedger.date(forDayKey: dayKey, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy"
        let count = words == 1 ? "1 word" : "\(words) words"
        return "\(words > 0 ? count : "No dictation") · \(formatter.string(from: date))"
    }
}
