import AppKit
import Foundation

// MARK: - App names

/// Best-effort human name for a paste-target bundle id, falling back to a
/// cleaned-up fragment so a label never reads "nil"/"Optional(...)".
enum HomeAppNames {
    /// Resolved names memoised across renders — the dashboard re-derives its
    /// insights on every coordinator publish (including per-frame input level
    /// while recording), so an uncached LaunchServices lookup per destination
    /// per frame would be needless work. Touched only on the main thread
    /// (SwiftUI body).
    private static var cache: [String: String] = [:]

    static func name(for bundleId: String) -> String {
        if let cached = cache[bundleId] { return cached }
        let resolved = resolve(bundleId)
        cache[bundleId] = resolved
        return resolved
    }

    private static func resolve(_ bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
            let bundle = Bundle(url: url),
            let name = bundle.infoDictionary?["CFBundleName"] as? String,
            !name.isEmpty
        {
            return name
        }
        if let fragment = bundleId.split(separator: ".").last, !fragment.isEmpty {
            return String(fragment)
        }
        return bundleId
    }
}

// MARK: - Formatting

/// Shared readout formatting for the dashboard: durations (h/m/s), grouped
/// integers, speed ratios, dates and clock-hour labels. Every formatter
/// resolves through the same locale, calendar and time zone, which the harness
/// pins so a golden is portable.
enum HomeFormat {
    /// One numeral and the unit that qualifies it. `join` records only how the
    /// pair reads aloud; on screen the unit is always set at the small mono unit
    /// face a fixed `Space.xs` from its numeral.
    struct MetricPart: Identifiable {
        enum Join {
            /// `57s`, `295ms` — a symbol, closed up against the numeral.
            case tight
            /// `4 days`, `181 wpm` — a word, spaced.
            case spaced
        }

        let id: Int
        let value: String
        let unit: String?
        let join: Join

        var plain: String {
            guard let unit else { return value }
            return join == .tight ? value + unit : value + " " + unit
        }
    }

    /// Grouped integer (thousands separators) in the current locale.
    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = RenderOverrides.locale ?? Locale.current
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func grouped(_ value: Int) -> String {
        grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Duration readout: "4h 07m" at >= 1h, "12m 30s" at >= 1m, else "48s".
    static func durationParts(_ ms: Int) -> [MetricPart] {
        let totalSeconds = max(ms, 0) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours >= 1 {
            return [
                MetricPart(id: 0, value: "\(hours)", unit: "h", join: .tight),
                MetricPart(id: 1, value: String(format: "%02d", minutes), unit: "m", join: .tight),
            ]
        }
        if minutes >= 1 {
            return [
                MetricPart(id: 0, value: "\(minutes)", unit: "m", join: .tight),
                MetricPart(id: 1, value: String(format: "%02d", seconds), unit: "s", join: .tight),
            ]
        }
        return [MetricPart(id: 0, value: "\(seconds)", unit: "s", join: .tight)]
    }

    static func duration(_ ms: Int) -> String {
        durationParts(ms).plain
    }

    static func countParts(_ value: Int, unit: String? = nil) -> [MetricPart] {
        [MetricPart(id: 0, value: grouped(value), unit: unit, join: .spaced)]
    }

    /// Speed ratio readout: "2.8×", one decimal, the sign closed up against the
    /// numeral the way every other symbolic unit on the pane is.
    static func multiplierParts(_ value: Double) -> [MetricPart] {
        // The × belongs on the numeral face: as a unit part it renders at the
        // 10pt micro tier beside a 32pt numeral and reads as an exponent.
        [MetricPart(id: 0, value: oneDecimal(value) + "×", unit: nil, join: .tight)]
    }

    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Clock-hour label in the user's own convention: "1 PM" on a 12-hour
    /// locale, "13:00" on a 24-hour one. The hour axis is labelled in clock
    /// hours, so a hard-coded AM/PM string contradicts the menu-bar clock of
    /// every user whose locale does not use one.
    static func hourLabel(_ hour: Int) -> String {
        hourClock.string(from: referenceDate(hour: hour))
    }

    /// The hour axis cardinal labels — 00 / 06 / 12 / 18 in the user's own
    /// clock convention, compact enough to sit under the strip.
    static func cardinalHourLabel(_ hour: Int) -> String {
        let normalized = normalize(hour)
        guard usesTwelveHourClock else {
            return String(format: "%02d", normalized)
        }
        let twelve = normalized % 12 == 0 ? 12 : normalized % 12
        let marker = (normalized < 12 ? hourClock.amSymbol : hourClock.pmSymbol) ?? ""
        return "\(twelve)\(marker.prefix(1))"
    }

    static let since: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = RenderOverrides.calendar ?? Calendar.current
        formatter.locale = RenderOverrides.locale ?? Locale.current
        formatter.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter
    }()

    private static let hourClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = RenderOverrides.calendar ?? Calendar.current
        formatter.locale = RenderOverrides.locale ?? Locale.current
        formatter.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter
    }()

    private static let usesTwelveHourClock: Bool = {
        let locale = RenderOverrides.locale ?? Locale.current
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h a"
        return template.contains("a")
    }()

    private static func normalize(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }

    /// A fixed reference day: the hour axis plots hours, not dates, so no part of the
    /// day may reach the string and no wall-clock read may enter a golden.
    private static func referenceDate(hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = normalize(hour)
        var calendar = RenderOverrides.calendar ?? Calendar.current
        calendar.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}

extension Array where Element == HomeFormat.MetricPart {
    /// The readout as one string, for accessibility and for any caller that
    /// needs the value without its typography.
    var plain: String {
        map(\.plain).joined(separator: " ")
    }
}
