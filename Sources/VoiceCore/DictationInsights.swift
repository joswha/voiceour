import Foundation

/// A read-only statistical digest of dictation activity, computed in a single
/// construction from the lifetime ledger plus the transcripts still retained.
///
/// Two windows, never mixed silently. Everything the ledger counts is
/// **lifetime**: it keeps counting after a transcript is evicted, so totals
/// only ever grow and "since <date>" stays put. The two fields that need the
/// text itself — the vocabulary count and the quoted record line — can only
/// cover the **kept transcripts**, so they are named for that and rendered
/// with their window stated.
///
/// Honesty rationale: every optional field here is an *honest absence*. When
/// the underlying data does not exist — no measured sessions, no recorded
/// outcomes, an empty store — the field is `nil` rather than a fabricated `0`,
/// so the view can omit the element instead of rendering a misleading value.
/// The time economy is measured-only for the same reason: a session recorded
/// before capture timing existed contributes nothing to it rather than an
/// invented speaking rate, and the coverage caption says so until the last
/// untimed session ages out.
public struct DictationInsights: Equatable, Sendable {
    /// Default assumed typing speed, in words per minute.
    ///
    /// 52 wpm is the mean of 168,000 volunteers over 136 million keystrokes
    /// (Dhakal, Feit, Kristensson & Oulasvirta, *Observations on Typing from
    /// 136 Million Keystrokes*, CHI 2018 — 51.56 wpm, SD 20.2). The 40 wpm
    /// this dashboard used before is a folk figure with no measurement behind
    /// it, and it flattered every comparison on the pane. It is still a
    /// population average rather than *this* reader's speed, which is why
    /// `Settings.typingSpeedWPM` exists and why every figure derived from it
    /// takes the baseline as an argument instead of reading a constant.
    public static let defaultTypingWPM = 52

    /// Bounds for a hand-entered baseline. Below 10 wpm the counterfactual is
    /// no longer typing; above 200 it is beyond the fastest measured typists.
    public static let typingWPMRange: ClosedRange<Int> = 10...200

    public struct Destination: Equatable, Sendable, Identifiable {
        public var bundleId: String
        public var count: Int
        public var share: Double  // 0...1 of all outcomes carrying a bundle id
        public var id: String { bundleId }
    }

    // MARK: Lifetime corpus

    public var dictationCount: Int
    public var totalWords: Int
    public var totalCharacters: Int  // characters of final text, i.e. keystrokes spared
    /// First dictation the ledger ever counted; never rewritten by eviction.
    public var startedAt: Date?
    public var spansMultipleDays: Bool

    // MARK: Lifetime time economy, measured sessions only

    public var measuredDictationCount: Int
    public var measuredWords: Int
    /// Microphone time.
    public var spokenMs: Int
    /// Everything else the dictation cost: recorder start latency, then
    /// transcription, refinement and insertion after the key is released.
    public var waitMs: Int

    // MARK: Lifetime rhythm

    public var hourBuckets: [Int]  // exactly 24
    public var dayWordCounts: [Int]  // exactly 14: words per calendar day, oldest -> newest, ending today
    public var streakDays: Int

    // MARK: Lifetime records and destinations

    public var longestSessionWords: Int?
    /// Newline-collapsed record transcript. Absent once that session is
    /// deleted, and absent for a record whose transcript was empty.
    public var longestSessionPreview: String?
    /// Best measured speaking rate — words over microphone time, excluding the
    /// wait. A record of speech, so it is labelled "spoken" rather than
    /// compared against the typing baseline.
    public var peakSpokenWPM: Double?
    public var destinations: [Destination]  // top 8 by count desc, ties by bundleId asc
    /// Every outcome that named a target app — the denominator `share` is
    /// computed against. `destinations` is truncated to eight; a consumer
    /// stating "N of M" must use this M, never a sum over the truncated list.
    public var attributedOutcomeCount: Int

    // MARK: Kept transcripts only

    /// Transcripts still on disk. Always <= `dictationCount`, and the window
    /// `uniqueWordCount` covers.
    public var keptTranscriptCount: Int
    public var uniqueWordCount: Int

    public static let empty = DictationInsights()

    public init() {
        dictationCount = 0
        totalWords = 0
        totalCharacters = 0
        startedAt = nil
        spansMultipleDays = false
        measuredDictationCount = 0
        measuredWords = 0
        spokenMs = 0
        waitMs = 0
        hourBuckets = [Int](repeating: 0, count: 24)
        dayWordCounts = [Int](repeating: 0, count: Self.dayWindow)
        streakDays = 0
        longestSessionWords = nil
        longestSessionPreview = nil
        peakSpokenWPM = nil
        destinations = []
        attributedOutcomeCount = 0
        keptTranscriptCount = 0
        uniqueWordCount = 0
    }

    public init(
        ledger: DictationStatsLedger,
        keptSessions: [RecentSession],
        calendar: Calendar = .current,
        now: Date = Date()
    ) {
        dictationCount = ledger.dictations
        totalWords = ledger.words
        totalCharacters = ledger.characters
        startedAt = ledger.startedAt
        spansMultipleDays = ledger.days.count > 1

        measuredDictationCount = ledger.measuredDictations
        measuredWords = ledger.measuredWords
        spokenMs = ledger.spokenMs
        waitMs = ledger.waitMs

        hourBuckets = ledger.hours
        dayWordCounts = ledger.dayWords(length: Self.dayWindow, calendar: calendar, now: now)
        streakDays = ledger.streak(calendar: calendar, now: now)

        longestSessionWords = ledger.records.longestWords
        longestSessionPreview = ledger.records.longestPreview
        peakSpokenWPM = ledger.records.fastestSpokenWPM
        attributedOutcomeCount = ledger.attributedOutcomes
        destinations =
            ledger.apps
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(Self.destinationLimit)
            .map { bundleId, count in
                Destination(
                    bundleId: bundleId,
                    count: count,
                    share: ledger.attributedOutcomes > 0 ? Double(count) / Double(ledger.attributedOutcomes) : 0
                )
            }

        keptTranscriptCount = keptSessions.count
        var vocabulary = Set<String>()
        for session in keptSessions {
            // Lowercase, split on any non-alphanumeric, drop empties, count
            // distinct tokens across the kept corpus.
            for token in session.text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                vocabulary.insert(String(token))
            }
        }
        uniqueWordCount = vocabulary.count
    }

    public static let dayWindow = 14
    private static let destinationLimit = 8

    // MARK: - Derived readouts

    /// Wall-clock cost of every measured dictation: speech plus the wait around
    /// it. This is the quantity the saving is measured against, so the claim is
    /// "start of the hotkey to text on screen", not "time spent talking".
    public var elapsedMs: Int { spokenMs + waitMs }

    /// Words per minute end to end — the rate the typing baseline is compared
    /// against, because the baseline is also end to end.
    public var dictationWPM: Double? {
        guard measuredWords > 0, elapsedMs > 0 else { return nil }
        return Double(measuredWords) / (Double(elapsedMs) / 60_000)
    }

    /// Words per minute of speech alone, excluding the wait. Rendered only
    /// where it is named as speaking rate.
    public var spokenWPM: Double? {
        guard measuredWords > 0, spokenMs > 0 else { return nil }
        return Double(measuredWords) / (Double(spokenMs) / 60_000)
    }

    /// True once every counted dictation carries measured timing, at which
    /// point the coverage caption has nothing left to disclose.
    public var isFullyMeasured: Bool { measuredDictationCount == dictationCount }

    /// How long the measured words would have taken to type at `typingWPM`.
    public func typedMs(typingWPM: Int) -> Int {
        let wpm = Self.clamp(typingWPM)
        return Int((Double(measuredWords) / Double(wpm) * 60_000).rounded())
    }

    /// Typing time minus the wall clock the dictations actually cost.
    ///
    /// Clamped once, at the aggregate: clamping per session would discard every
    /// slow dictation's cost while keeping every fast one's saving, which is
    /// how a figure like this quietly inflates.
    public func timeSavedMs(typingWPM: Int) -> Int {
        max(0, typedMs(typingWPM: typingWPM) - elapsedMs)
    }

    /// How many times faster than typing, on the same end-to-end basis as the
    /// saving. `nil` until something has been measured.
    public func speedMultiplier(typingWPM: Int) -> Double? {
        guard let rate = dictationWPM else { return nil }
        return rate / Double(Self.clamp(typingWPM))
    }

    public static func clamp(_ typingWPM: Int) -> Int {
        min(max(typingWPM, typingWPMRange.lowerBound), typingWPMRange.upperBound)
    }
}
