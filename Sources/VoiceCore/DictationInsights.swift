import Foundation

/// A read-only statistical digest computed in a single construction from the
/// recent-session corpus.
///
/// Honesty rationale: every optional field here is an *honest absence*. When
/// the underlying data does not exist — no timed sessions, no recorded
/// outcomes, an empty store — the corresponding field is `nil` rather than a
/// fabricated `0`, so the view can omit the element instead of rendering a
/// misleading value. Every rate likewise guards its denominator and collapses
/// to `nil` when it would otherwise divide by zero. Counts that are genuine
/// tallies (a real absence *is* zero occurrences) stay as `Int`.
public struct DictationInsights: Equatable, Sendable {
    /// Assumed sustained typing speed, in words per minute, used as the
    /// baseline the time-saved figure is measured against.
    public static let typingBaselineWPM: Double = 40
    /// Assumed speaking speed, in words per minute, used to estimate capture
    /// time for sessions that were never actually measured.
    static let assumedSpeakingWPM: Double = 150

    public struct Destination: Equatable, Sendable, Identifiable {
        public var bundleId: String
        public var count: Int
        public var share: Double  // 0...1 of all outcomes carrying a bundle id
        public var id: String { bundleId }
    }

    // Corpus
    public var sessionCount: Int
    public var totalWords: Int
    public var totalCharacters: Int  // characters of final text, i.e. keystrokes spared
    public var uniqueWordCount: Int
    public var earliestDate: Date?
    public var spansMultipleDays: Bool

    // Time economy
    public var timedSessionCount: Int  // sessions with stages?.captureMs > 0
    public var totalCaptureMs: Int  // sum of measured captureMs
    public var timeSavedMs: Int  // see semantics below
    public var isTimeSavedEstimated: Bool  // timedSessionCount < sessionCount

    // Velocity (measured only)
    public var speakingWPM: Double?  // Σ words(timed) / Σ captureMinutes(timed); nil when no timed sessions
    public var speedMultiplier: Double?  // speakingWPM / typingBaselineWPM
    public var peakSessionWPM: Double?  // max per-session WPM over sessions with wordCount >= 8 && captureMs >= 2000

    // Rhythm
    public var hourBuckets: [Int]  // exactly 24
    public var dayWordCounts: [Int]  // exactly 14: words per calendar day, oldest -> newest, ending today
    public var streakDays: Int  // consecutive days with >=1 session, walking back from today

    // Records + destinations
    public var longestSessionWords: Int?
    public var longestSessionPreview: String?  // newline-collapsed, whitespace-trimmed final text; nil when no sessions
    public var destinations: [Destination]  // top 8 by count desc, ties by bundleId asc
    /// Every outcome that named a target app — the denominator `share` is
    /// computed against. `destinations` is truncated to eight; a consumer
    /// stating "N of M" must use this M, never a sum over the truncated list.
    public var attributedOutcomeCount: Int

    public init(sessions: [RecentSession], calendar: Calendar = .current, now: Date = Date()) {
        // Corpus
        var totalWords = 0
        var totalCharacters = 0
        var uniqueWords = Set<String>()
        var earliestDate: Date?
        var distinctDays = Set<Date>()

        // Time economy
        var timedSessionCount = 0
        var totalCaptureMs = 0
        var timeSavedMs = 0

        // Velocity
        var timedWordSum = 0
        var peakSessionWPM: Double?

        // Destinations
        var bundleCounts: [String: Int] = [:]

        // Rhythm
        var hourBuckets = [Int](repeating: 0, count: 24)
        var dayWordCounts = [Int](repeating: 0, count: 14)
        let today = calendar.startOfDay(for: now)

        // Records
        var longestWords = -1
        var longestText: String?

        for session in sessions {
            let words = session.wordCount
            totalWords += words
            totalCharacters += session.text.count

            // Unique words: lowercase, split on any non-alphanumeric, drop
            // empties, count distinct tokens across all sessions.
            for token in session.text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                uniqueWords.insert(String(token))
            }

            if let earliest = earliestDate {
                earliestDate = min(earliest, session.createdAt)
            } else {
                earliestDate = session.createdAt
            }

            let dayStart = calendar.startOfDay(for: session.createdAt)
            distinctDays.insert(dayStart)

            // Time saved: typing time it would have taken minus the speech
            // time (measured when available, otherwise assumed). Clamp at 0 so
            // slower-than-typing sessions never subtract, then round per session.
            let typingMs = Double(words) / Self.typingBaselineWPM * 60_000
            let speechMs: Double
            if let capture = session.stages?.captureMs, capture > 0 {
                speechMs = Double(capture)
            } else {
                speechMs = Double(words) / Self.assumedSpeakingWPM * 60_000
            }
            timeSavedMs += Int(max(0, typingMs - speechMs).rounded())

            if let capture = session.stages?.captureMs, capture > 0 {
                timedSessionCount += 1
                totalCaptureMs += capture
                timedWordSum += words

                // Peak eligibility: enough words and enough capture time to be
                // a meaningful, non-noisy per-session rate.
                if words >= 8, capture >= 2000 {
                    let wpm = Double(words) / (Double(capture) / 60_000)
                    if let current = peakSessionWPM {
                        peakSessionWPM = Swift.max(current, wpm)
                    } else {
                        peakSessionWPM = wpm
                    }
                }
            }

            if let outcome = session.outcome {
                if let bundleId = outcome.targetBundleId, !bundleId.isEmpty {
                    bundleCounts[bundleId, default: 0] += 1
                }
            }

            let hour = calendar.component(.hour, from: session.createdAt)
            if hour >= 0, hour < 24 {
                hourBuckets[hour] += 1
            }

            if let offset = calendar.dateComponents([.day], from: dayStart, to: today).day,
                offset >= 0, offset <= 13
            {
                dayWordCounts[13 - offset] += words
            }

            if words > longestWords {
                longestWords = words
                longestText = session.text
            }
        }

        // Corpus
        self.sessionCount = sessions.count
        self.totalWords = totalWords
        self.totalCharacters = totalCharacters
        self.uniqueWordCount = uniqueWords.count
        self.earliestDate = earliestDate
        self.spansMultipleDays = distinctDays.count > 1

        // Time economy
        self.timedSessionCount = timedSessionCount
        self.totalCaptureMs = totalCaptureMs
        self.timeSavedMs = timeSavedMs
        self.isTimeSavedEstimated = timedSessionCount < sessions.count

        // Velocity: guard the denominator — no measured capture time, no rate.
        if totalCaptureMs > 0 {
            let captureMinutes = Double(totalCaptureMs) / 60_000
            let wpm = Double(timedWordSum) / captureMinutes
            self.speakingWPM = wpm
            self.speedMultiplier = wpm / Self.typingBaselineWPM
        } else {
            self.speakingWPM = nil
            self.speedMultiplier = nil
        }
        self.peakSessionWPM = peakSessionWPM

        // Rhythm
        self.hourBuckets = hourBuckets
        self.dayWordCounts = dayWordCounts
        self.streakDays = Self.streak(days: distinctDays, calendar: calendar, now: now)

        // Records + destinations
        if sessions.isEmpty {
            self.longestSessionWords = nil
            self.longestSessionPreview = nil
        } else {
            self.longestSessionWords = longestWords
            let collapsed = (longestText ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.longestSessionPreview = collapsed.isEmpty ? "Empty transcript" : collapsed
        }

        let totalAttributed = bundleCounts.values.reduce(0, +)
        self.attributedOutcomeCount = totalAttributed
        self.destinations =
            bundleCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(8)
            .map {
                Destination(
                    bundleId: $0.key,
                    count: $0.value,
                    share: totalAttributed > 0 ? Double($0.value) / Double(totalAttributed) : 0
                )
            }
    }

    // MARK: - Statistics helpers

    /// Consecutive calendar days, walking back from today, on which at least
    /// one session occurred. Zero when today itself has no session.
    private static func streak(days: Set<Date>, calendar: Calendar, now: Date) -> Int {
        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
