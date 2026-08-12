import Foundation

/// Lifetime dictation counters, kept apart from the transcripts they came from.
///
/// `RecentSessionStore` keeps the newest 500 transcripts and drops the rest.
/// That is the right bound for text a person may want to re-read and the wrong
/// one for a tally: deriving "all time" figures from a ring buffer makes every
/// lifetime number a rolling window. Once the cap is reached each new dictation
/// evicts an old one, so totals plateau or fall, "since <date>" walks forward,
/// and the dictation count freezes at exactly the cap. Time saved stops moving
/// on the very day the app has the most to say about it.
///
/// This ledger is the counting half of that split, and it is append-only in
/// spirit: `ingest` folds each session exactly once, keyed by session id, so
/// the tally survives eviction of the transcript it was derived from.
///
/// It stores aggregates — counts, milliseconds, per-hour and per-day tallies,
/// per-app tallies — plus two personal bests. The single quoted record line is
/// the only transcript text here, capped at `previewLimit`, and
/// `forget(sessionID:)` drops it the moment its session is deleted. Clearing
/// history clears the whole ledger.
public struct DictationStatsLedger: Codable, Equatable, Sendable {
    /// Bumped only when a stored ledger can no longer be read as written. An
    /// unknown version is discarded and rebuilt from whatever transcripts are
    /// still retained, which is exactly what a fresh install does.
    public static let currentVersion = 1

    /// How many session ids the ledger remembers having folded.
    ///
    /// Must stay above `RecentSessionStore`'s retention cap: `ingest` decides
    /// what is new by asking whether an id is in this ring, so a ring shorter
    /// than the retained corpus would re-count sessions it had already folded
    /// every time the app relaunched. `DictationStatsLedgerTests` pins the
    /// relationship.
    public static let ingestMemory = 512

    /// How many daily rows survive a trim. Home reads fourteen and the Sessions
    /// strip reads one calendar month; the rest is headroom for longer windows.
    public static let dayMemory = 400

    /// Characters of the record transcript kept for the RECORDS quote. The card
    /// shows one truncated line, so this is generous already, and it bounds how
    /// much dictated text lives outside the transcript store.
    public static let previewLimit = 320

    /// A calendar day on which at least one dictation happened.
    public struct Day: Codable, Equatable, Sendable {
        public var startOfDay: Date
        public var dictations: Int
        public var words: Int

        public init(startOfDay: Date, dictations: Int = 0, words: Int = 0) {
            self.startOfDay = startOfDay
            self.dictations = dictations
            self.words = words
        }
    }

    /// Personal bests. Each carries the session it came from so a deleted
    /// transcript can take its quote with it.
    public struct Records: Codable, Equatable, Sendable {
        public var longestWords: Int?
        public var longestPreview: String?
        public var longestSessionID: UUID?
        /// Best measured *speaking* rate — words over microphone time alone,
        /// which is why it is labelled "spoken" wherever it is rendered and is
        /// not the rate the time-saved arithmetic uses.
        public var fastestSpokenWPM: Double?
        public var fastestSessionID: UUID?

        public init(
            longestWords: Int? = nil,
            longestPreview: String? = nil,
            longestSessionID: UUID? = nil,
            fastestSpokenWPM: Double? = nil,
            fastestSessionID: UUID? = nil
        ) {
            self.longestWords = longestWords
            self.longestPreview = longestPreview
            self.longestSessionID = longestSessionID
            self.fastestSpokenWPM = fastestSpokenWPM
            self.fastestSessionID = fastestSessionID
        }
    }

    /// One remembered session: whether the ledger folded it, and whether its
    /// terminal outcome landed.
    ///
    /// Two phases because the journal writes a session at transcription and
    /// amends it after insertion; the destination app and the post-speech wait
    /// only exist on that second write. Without the flag the amendment is
    /// invisible to the ledger and Home is permanently one dictation behind on
    /// TOP APPS.
    struct Counted: Codable, Equatable, Sendable {
        var id: UUID
        var settled: Bool
    }

    public var version: Int
    /// The earliest dictation the ledger ever counted. Never rewritten, which
    /// is the whole point: "since <date>" must not advance as old transcripts
    /// are evicted.
    public var startedAt: Date?

    public var dictations: Int
    public var words: Int
    /// Characters of final text — the keystrokes that were not typed.
    public var characters: Int

    /// Sessions carrying a measured microphone duration. Everything in the time
    /// economy below is counted over these alone, so the figures are evidence
    /// rather than an assumed speaking rate applied to an unmeasured session.
    public var measuredDictations: Int
    public var measuredWords: Int
    /// Measured microphone time.
    public var spokenMs: Int
    /// Measured time the dictation cost outside speech: recorder start latency,
    /// then transcription, refinement and insertion after the key is released.
    public var waitMs: Int

    /// Dictations per hour of the day, 24 entries.
    public var hours: [Int]
    /// Active days, oldest first, trimmed to `dayMemory`.
    public var days: [Day]
    /// Dictations per destination bundle id.
    public var apps: [String: Int]
    /// Outcomes that named a destination — the denominator an app's share is
    /// stated against, which is not the dictation count.
    public var attributedOutcomes: Int
    public var records: Records

    var counted: [Counted]

    public init() {
        version = Self.currentVersion
        startedAt = nil
        dictations = 0
        words = 0
        characters = 0
        measuredDictations = 0
        measuredWords = 0
        spokenMs = 0
        waitMs = 0
        hours = [Int](repeating: 0, count: 24)
        days = []
        apps = [:]
        attributedOutcomes = 0
        records = Records()
        counted = []
    }

    public var isEmpty: Bool { dictations == 0 }

    // MARK: - Folding

    /// Folds every session the ledger has not counted yet, and settles every
    /// outcome that has landed since the last call.
    ///
    /// Idempotent by session id, which makes one function serve four jobs: the
    /// first-run seed from an existing transcript store, the per-dictation
    /// append, the in-place outcome amendment, and reconciliation after a crash
    /// or a deleted ledger file. Callers hand it the whole retained corpus and
    /// never have to know which of those they are doing.
    public mutating func ingest(_ sessions: [RecentSession], calendar: Calendar) {
        guard !sessions.isEmpty else { return }

        var index = [UUID: Int](minimumCapacity: counted.count)
        for (offset, entry) in counted.enumerated() {
            index[entry.id] = offset
        }

        // Oldest first: `startedAt`, the day rows and the record preview all
        // read more naturally when a seed folds history in the order it
        // happened, and a same-instant tie under a pinned clock stays stable.
        for session in sessions.sorted(by: { $0.createdAt < $1.createdAt }) {
            var offset: Int
            if let known = index[session.id] {
                offset = known
            } else {
                fold(session, calendar: calendar)
                counted.append(Counted(id: session.id, settled: false))
                offset = counted.count - 1
                index[session.id] = offset
            }

            guard !counted[offset].settled, let outcome = session.outcome else { continue }
            settle(session, outcome: outcome)
            counted[offset].settled = true
        }

        trim()
    }

    /// Drops anything that quotes a session's text. The counts stay: a
    /// dictation that happened still happened, and the ledger cannot subtract a
    /// personal best without the corpus that would name its successor.
    public mutating func forget(sessionID: UUID) {
        if records.longestSessionID == sessionID {
            records.longestPreview = nil
        }
    }

    /// Clearing history clears the tally with it — a lifetime word count and a
    /// per-app breakdown are still a record of what the user asked to erase.
    public mutating func reset() {
        self = DictationStatsLedger()
    }

    private mutating func fold(_ session: RecentSession, calendar: Calendar) {
        let sessionWords = session.wordCount

        dictations += 1
        words += sessionWords
        characters += session.text.count

        if let earliest = startedAt {
            startedAt = Swift.min(earliest, session.createdAt)
        } else {
            startedAt = session.createdAt
        }

        let hour = calendar.component(.hour, from: session.createdAt)
        if hour >= 0, hour < hours.count {
            hours[hour] += 1
        }

        addDay(calendar.startOfDay(for: session.createdAt), words: sessionWords)

        if sessionWords > (records.longestWords ?? -1) {
            records.longestWords = sessionWords
            records.longestPreview = Self.preview(of: session.text)
            records.longestSessionID = session.id
        }

        guard let capture = session.stages?.captureMs, capture > 0 else { return }

        measuredDictations += 1
        measuredWords += sessionWords
        spokenMs += capture
        waitMs += Swift.max(0, session.stages?.startLatencyMs ?? 0)

        // Peak eligibility: enough words and enough microphone time to be a
        // rate rather than a rounding artefact of one short phrase.
        if sessionWords >= 8, capture >= 2000 {
            let wpm = Double(sessionWords) / (Double(capture) / 60_000)
            if wpm > (records.fastestSpokenWPM ?? 0) {
                records.fastestSpokenWPM = wpm
                records.fastestSessionID = session.id
            }
        }
    }

    private mutating func settle(_ session: RecentSession, outcome: RecentSessionOutcomeMetadata) {
        if let bundleId = outcome.targetBundleId, !bundleId.isEmpty {
            apps[bundleId, default: 0] += 1
            attributedOutcomes += 1
        }

        // The wait belongs to the same measured population as the speech it is
        // added to, so an untimed session contributes neither.
        guard let stages = session.stages, let capture = stages.captureMs, capture > 0 else { return }

        if let endToEnd = stages.stopReleaseToInsertionOutcomeMs, endToEnd > 0 {
            // Already spans transcription, refinement and insertion; adding the
            // parts to it would count them twice.
            waitMs += endToEnd
        } else {
            waitMs += Swift.max(0, stages.asrMs ?? 0) + Swift.max(0, stages.insertMs ?? 0)
        }
    }

    private mutating func addDay(_ startOfDay: Date, words dayWords: Int) {
        if let last = days.last, last.startOfDay == startOfDay {
            days[days.count - 1].dictations += 1
            days[days.count - 1].words += dayWords
            return
        }
        if let existing = days.lastIndex(where: { $0.startOfDay == startOfDay }) {
            days[existing].dictations += 1
            days[existing].words += dayWords
            return
        }
        let insertion = days.firstIndex { $0.startOfDay > startOfDay } ?? days.count
        days.insert(Day(startOfDay: startOfDay, dictations: 1, words: dayWords), at: insertion)
    }

    private mutating func trim() {
        if days.count > Self.dayMemory {
            days.removeFirst(days.count - Self.dayMemory)
        }
        if counted.count > Self.ingestMemory {
            counted.removeFirst(counted.count - Self.ingestMemory)
        }
    }

    private static func preview(of text: String) -> String? {
        let collapsed =
            text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(previewLimit))
    }

    // MARK: - Windows

    /// Words per calendar day over the `length` days ending today, oldest
    /// first. Days with no dictation read zero, which is the chart's baseline.
    public func dayWords(length: Int, calendar: Calendar, now: Date) -> [Int] {
        guard length > 0 else { return [] }
        var counts = [Int](repeating: 0, count: length)
        let today = calendar.startOfDay(for: now)

        for day in days.reversed() {
            guard let offset = calendar.dateComponents([.day], from: day.startOfDay, to: today).day else { continue }
            if offset < 0 { continue }
            if offset > length - 1 { break }
            counts[length - 1 - offset] += day.words
        }
        return counts
    }

    /// Consecutive calendar days with at least one dictation, walking back from
    /// today. Zero when today itself has none.
    public func streak(calendar: Calendar, now: Date) -> Int {
        var active = Set<Date>(minimumCapacity: days.count)
        for day in days where day.dictations > 0 {
            active.insert(day.startOfDay)
        }

        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        while active.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case version
        case startedAt = "started_at"
        case dictations
        case words
        case characters
        case measuredDictations = "measured_dictations"
        case measuredWords = "measured_words"
        case spokenMs = "spoken_ms"
        case waitMs = "wait_ms"
        case hours
        case days
        case apps
        case attributedOutcomes = "attributed_outcomes"
        case records
        case counted
    }

    public init(from decoder: Decoder) throws {
        let defaults = DictationStatsLedger()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        dictations = try container.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        words = try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
        characters = try container.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        measuredDictations = try container.decodeIfPresent(Int.self, forKey: .measuredDictations) ?? 0
        measuredWords = try container.decodeIfPresent(Int.self, forKey: .measuredWords) ?? 0
        spokenMs = try container.decodeIfPresent(Int.self, forKey: .spokenMs) ?? 0
        waitMs = try container.decodeIfPresent(Int.self, forKey: .waitMs) ?? 0

        let storedHours = try container.decodeIfPresent([Int].self, forKey: .hours) ?? defaults.hours
        hours = storedHours.count == 24 ? storedHours : defaults.hours

        days = try container.decodeIfPresent([Day].self, forKey: .days) ?? []
        apps = try container.decodeIfPresent([String: Int].self, forKey: .apps) ?? [:]
        attributedOutcomes = try container.decodeIfPresent(Int.self, forKey: .attributedOutcomes) ?? 0
        records = try container.decodeIfPresent(Records.self, forKey: .records) ?? Records()
        counted = try container.decodeIfPresent([Counted].self, forKey: .counted) ?? []
    }
}
