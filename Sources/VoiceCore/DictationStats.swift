import Foundation

/// Constants the lifetime dictation ledger and its derivations share.
public enum DictationStatsPolicy {
    /// The typing baseline "time saved" is measured against. A single fixed
    /// number, not a setting: it is the one figure in this feature the app
    /// cannot observe, and a control for it would invite tuning the claim
    /// rather than reading it.
    ///
    /// Deliberately conservative. The largest published measurement of
    /// unconstrained typing is 51.56 wpm (Dhakal, Feit, Kristensson &
    /// Oulasvirta, CHI 2018, 168,000 typists); 40 wpm understates the saving
    /// rather than overstating it.
    public static let assumedTypingWordsPerMinute = 40

    /// How many day buckets the ledger keeps. Totals, active-day count and the
    /// longest streak survive pruning, so the only thing a pruned day loses is
    /// its place in the heatmap — which spans at most `heatmapMaxWeeks`.
    public static let dayRetentionDays = 400

    public static let heatmapMaxWeeks = 30
    public static let heatmapMinWeeks = 12
}

/// One local calendar day's dictation counts.
public struct DictationDayStat: Codable, Equatable, Sendable {
    public var sessions: Int
    public var words: Int
    public var seconds: Double

    public init(sessions: Int = 0, words: Int = 0, seconds: Double = 0) {
        self.sessions = sessions
        self.words = words
        self.seconds = seconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        words = try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
        seconds = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
    }
}

/// One app's lifetime dictation counts, keyed in the ledger by bundle id.
public struct DictationAppStat: Codable, Equatable, Sendable {
    public var sessions: Int
    public var words: Int
    public var seconds: Double
    /// Last-seen localized display name; nil for folds recorded before names existed.
    public var name: String?
    /// Most recent ledger day key this app received a dictation.
    public var lastDay: String?

    public init(
        sessions: Int = 0,
        words: Int = 0,
        seconds: Double = 0,
        name: String? = nil,
        lastDay: String? = nil
    ) {
        self.sessions = sessions
        self.words = words
        self.seconds = seconds
        self.name = name
        self.lastDay = lastDay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        words = try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
        seconds = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        lastDay = try container.decodeIfPresent(String.self, forKey: .lastDay)
    }
}

/// The delivery target a fold is attributed to.
public struct DictationAppIdentity: Equatable, Sendable {
    public var bundleId: String
    public var name: String?

    public init(bundleId: String, name: String? = nil) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// Lifetime dictation counts, per-day counts for the recent window, and
/// per-app tallies.
///
/// Aggregates only: no transcript text and no session ids. It exists because
/// the transcript journal is capped at 500 rows, so totals read off that file
/// plateau at the cap and then fall — a tally needs a bound of its own, and
/// this one is small enough to be a tally rather than a record of what the user
/// said. Per-app tallies are aggregate counts keyed by bundle id, added
/// deliberately so Home can rank destinations beyond that 500-row cap. Clear
/// History erases them with the rest of the ledger.
public struct DictationStatsLedger: Codable, Equatable, Sendable {
    public var totalSessions: Int
    public var totalWords: Int
    public var totalSeconds: Double
    /// Distinct active days over the ledger's whole life, not just the days it
    /// still holds buckets for.
    public var totalActiveDays: Int
    public var longestStreakDays: Int
    /// Keyed `yyyy-MM-dd` in the recording calendar's local day. The key format
    /// is ISO-ordered, so lexicographic comparison is chronological comparison.
    public var days: [String: DictationDayStat]
    /// Keyed by delivery-target bundle id. Uncapped and never pruned: the map
    /// is bounded by the apps the user actually dictates into, each entry is
    /// about a hundred bytes, and evicting one would make the per-app totals
    /// lie the way the day-pruned totals deliberately do not.
    public var apps: [String: DictationAppStat]

    public init(
        totalSessions: Int = 0,
        totalWords: Int = 0,
        totalSeconds: Double = 0,
        totalActiveDays: Int = 0,
        longestStreakDays: Int = 0,
        days: [String: DictationDayStat] = [:],
        apps: [String: DictationAppStat] = [:]
    ) {
        self.totalSessions = totalSessions
        self.totalWords = totalWords
        self.totalSeconds = totalSeconds
        self.totalActiveDays = totalActiveDays
        self.longestStreakDays = longestStreakDays
        self.days = days
        self.apps = apps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSessions = try container.decodeIfPresent(Int.self, forKey: .totalSessions) ?? 0
        totalWords = try container.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
        totalSeconds = try container.decodeIfPresent(Double.self, forKey: .totalSeconds) ?? 0
        totalActiveDays = try container.decodeIfPresent(Int.self, forKey: .totalActiveDays) ?? 0
        longestStreakDays = try container.decodeIfPresent(Int.self, forKey: .longestStreakDays) ?? 0
        days = try container.decodeIfPresent([String: DictationDayStat].self, forKey: .days) ?? [:]
        apps = try container.decodeIfPresent([String: DictationAppStat].self, forKey: .apps) ?? [:]
    }

    /// The ledger's day key for `date` in `calendar`.
    ///
    /// Formatted by hand rather than with a `DateFormatter`: the key is a
    /// storage identity, and a formatter would resolve the current locale's
    /// numbering system into it — Arabic-Indic digits would key the same day
    /// differently than Latin ones did the launch before.
    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    /// Folds one dictation into `day`'s bucket, the lifetime totals, and — when
    /// the delivery target is known — that app's bucket.
    ///
    /// Idempotence is not attempted: the caller records each dictation once, at
    /// the single site that also writes the transcript journal.
    public mutating func record(words: Int, seconds: Double, day: String, app: DictationAppIdentity? = nil) {
        let isNewDay = days[day] == nil
        var bucket = days[day] ?? DictationDayStat()
        bucket.sessions += 1
        bucket.words += max(0, words)
        bucket.seconds += max(0, seconds)
        days[day] = bucket

        totalSessions += 1
        totalWords += max(0, words)
        totalSeconds += max(0, seconds)
        if isNewDay {
            totalActiveDays += 1
        }

        longestStreakDays = max(longestStreakDays, runLength(containing: day))
        prune(relativeTo: day)

        if let app {
            recordApp(app, words: words, seconds: seconds, day: day)
        }
    }

    /// Folds one dictation into `app`'s bucket only — totals and day buckets
    /// untouched. `record` calls this; the apps-only backfill calls it directly
    /// for sessions the totals already counted.
    public mutating func recordApp(_ app: DictationAppIdentity, words: Int, seconds: Double, day: String) {
        var bucket = apps[app.bundleId] ?? DictationAppStat()
        bucket.sessions += 1
        bucket.words += max(0, words)
        bucket.seconds += max(0, seconds)
        // Last non-nil name seen wins: a rename is the newer truth, and a fold
        // that could not name the app must not erase one that could.
        bucket.name = app.name ?? bucket.name
        // Day keys are ISO-ordered, so the lexicographic max is the
        // chronological max even when folds arrive out of order.
        bucket.lastDay = max(bucket.lastDay ?? day, day)
        apps[app.bundleId] = bucket
    }

    /// Consecutive active days ending at `day`, counted backwards while the
    /// preceding day still has a bucket. This is what "current streak" means:
    /// the run has to reach the day being asked about.
    func streakLength(endingAt day: String) -> Int {
        guard days[day] != nil else { return 0 }
        return 1 + activeRun(from: day, step: -1)
    }

    /// The whole consecutive run `day` sits in, counted in both directions.
    ///
    /// `record` measures this rather than `streakLength(endingAt:)`. A run is
    /// only fully visible from its own end, and a fold that arrives out of
    /// chronological order — the one-time backfill, a day amended after a later
    /// one was already recorded — would otherwise leave the reader's longest
    /// streak permanently understated, with no later dictation able to correct
    /// it.
    func runLength(containing day: String) -> Int {
        guard days[day] != nil else { return 0 }
        return 1 + activeRun(from: day, step: -1) + activeRun(from: day, step: 1)
    }

    /// Active days reachable from `day` by repeated `step`, excluding `day`.
    private func activeRun(from day: String, step: Int) -> Int {
        var length = 0
        var cursor = day
        while let next = Self.dayKey(offsetting: cursor, byDays: step), days[next] != nil {
            length += 1
            cursor = next
        }
        return length
    }

    /// Drops buckets older than `DictationStatsPolicy.dayRetentionDays` before
    /// `day`. Totals, `totalActiveDays` and `longestStreakDays` are untouched:
    /// they are the reason this file exists, and the retention window bounds
    /// only how far back the heatmap can look.
    private mutating func prune(relativeTo day: String) {
        guard
            let cutoff = Self.dayKey(
                offsetting: day,
                byDays: -DictationStatsPolicy.dayRetentionDays
            )
        else { return }
        days = days.filter { $0.key > cutoff }
    }

    /// A day key `offset` days away from `key`, or nil when `key` is not a day
    /// key this type wrote.
    ///
    /// Uses a UTC calendar over the parsed components rather than the recording
    /// calendar: the keys are already resolved local days, so re-resolving them
    /// through a zone with daylight saving would land two adjacent keys on the
    /// same instant-plus-24-hours and skip a day once a year.
    static func dayKey(offsetting key: String, byDays offset: Int) -> String? {
        guard let start = date(forDayKey: key, calendar: utcCalendar) else { return nil }
        guard let moved = utcCalendar.date(byAdding: .day, value: offset, to: start) else { return nil }
        return dayKey(for: moved, calendar: utcCalendar)
    }

    /// The instant `key` names in `calendar`, or nil when `key` is not a day key
    /// this type wrote. The exact inverse of `dayKey(for:calendar:)`, and the one
    /// place a day key is validated and parsed.
    ///
    /// The calendar belongs to the caller because a day key is an already-resolved
    /// local day rather than an instant. This type's own arithmetic passes
    /// `utcCalendar`, so a daylight-saving boundary cannot fold two adjacent keys
    /// onto one instant; a reader rendering a key as a date passes the calendar it
    /// reads the ledger with, so the rendered day is the day the ledger keyed.
    public static func date(forDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
}

/// The app's one word count.
///
/// Contiguous runs of non-whitespace, which is what a reader means by "words"
/// for dictated prose and what the transcript journal has always reported. Kept
/// here rather than on `RecentSession` because the stats ledger counts words for
/// sessions it never holds a transcript of.
public enum WordCount {
    public static func count(in text: String) -> Int {
        var count = 0
        var isInWord = false

        for character in text {
            if character.isWhitespace {
                isInWord = false
            } else if !isInWord {
                count += 1
                isInWord = true
            }
        }

        return count
    }
}
