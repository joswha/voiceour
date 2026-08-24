import Foundation
import Testing

@testable import VoiceCore

/// The lifetime ledger is the one place in this app whose whole job is to still
/// be right months later: the transcript journal evicts, this does not, and a
/// streak or a total that drifts is a claim about the reader's own history. Its
/// arithmetic is therefore tested against explicit days rather than the wall
/// clock.
@Suite("Dictation stats")
struct DictationStatsTests {
    /// A day key `offset` days from `fixedNow` in UTC, which has no daylight
    /// saving, so a whole-day step is always exactly one calendar day.
    private func key(_ offset: Int) -> String {
        DictationStatsLedger.dayKey(
            for: fixedNow.addingTimeInterval(Double(offset) * day),
            calendar: utc
        )
    }

    private var today: String { key(0) }

    private func mondayFirst() -> Calendar {
        var calendar = utc
        calendar.firstWeekday = 2
        return calendar
    }

    // MARK: Recording

    @Test func repeatedRecordsOnOneDayFoldIntoOneBucket() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 30, seconds: 12, day: today)
        ledger.record(words: 12, seconds: 8, day: today)

        #expect(ledger.days.count == 1)
        #expect(ledger.days[today] == DictationDayStat(sessions: 2, words: 42, seconds: 20))
        #expect(ledger.totalSessions == 2)
        #expect(ledger.totalWords == 42)
        #expect(isClose(ledger.totalSeconds, 20))
        #expect(ledger.totalActiveDays == 1)
    }

    /// `totalActiveDays` counts days, not dictations, and it must keep counting
    /// days the retention window has already dropped — which is why it is stored
    /// rather than derived from `days.count`.
    @Test func activeDaysAdvanceOnlyOnANewDay() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 5, seconds: 3, day: key(-1))
        ledger.record(words: 5, seconds: 3, day: key(-1))
        #expect(ledger.totalActiveDays == 1)

        ledger.record(words: 5, seconds: 3, day: today)
        #expect(ledger.totalActiveDays == 2)

        ledger.record(words: 5, seconds: 3, day: key(-1))
        #expect(ledger.totalActiveDays == 2)
    }

    @Test func longestStreakTracksTheRunItWasRecordedIn() {
        var ledger = DictationStatsLedger()
        for offset in [-4, -3, -2] {
            ledger.record(words: 10, seconds: 5, day: key(offset))
        }
        #expect(ledger.longestStreakDays == 3)

        // A gap, then a shorter run: the record stands.
        ledger.record(words: 10, seconds: 5, day: today)
        #expect(ledger.longestStreakDays == 3)
    }

    /// Recording out of order still finds the run: the streak is measured over
    /// the keys present, not over the order they arrived in.
    @Test func longestStreakIgnoresRecordingOrder() {
        var ledger = DictationStatsLedger()
        for offset in [-2, -5, -3, -4] {
            ledger.record(words: 10, seconds: 5, day: key(offset))
        }
        #expect(ledger.longestStreakDays == 4)
    }

    @Test func pruningDropsOldDaysAndKeepsEveryTotal() {
        var ledger = DictationStatsLedger()
        let ancient = key(-(DictationStatsPolicy.dayRetentionDays + 5))
        ledger.record(words: 100, seconds: 60, day: ancient)
        for offset in [-3, -2, -1] {
            ledger.record(words: 10, seconds: 5, day: key(offset))
        }
        ledger.record(words: 7, seconds: 4, day: today)

        #expect(ledger.days[ancient] == nil)
        #expect(ledger.days.count == 4)
        #expect(ledger.totalWords == 137)
        #expect(isClose(ledger.totalSeconds, 79))
        #expect(ledger.totalSessions == 5)
        #expect(ledger.totalActiveDays == 5)
        #expect(ledger.longestStreakDays == 4)
    }

    @Test func theRetentionBoundaryKeepsExactlyItsWindow() {
        var ledger = DictationStatsLedger()
        let oldest = key(-(DictationStatsPolicy.dayRetentionDays - 1))
        let dropped = key(-DictationStatsPolicy.dayRetentionDays)
        ledger.record(words: 1, seconds: 1, day: oldest)
        ledger.record(words: 1, seconds: 1, day: dropped)
        ledger.record(words: 1, seconds: 1, day: today)

        #expect(ledger.days[oldest] != nil)
        #expect(ledger.days[dropped] == nil)
    }

    // MARK: Streaks

    @Test func anEmptyLedgerHasNoStreaks() {
        let summary = DictationStatsCalculator.summary(
            of: DictationStatsLedger(),
            today: fixedNow,
            calendar: utc
        )
        #expect(summary.currentStreakDays == 0)
        #expect(summary.longestStreakDays == 0)
        #expect(summary.activeDays == 0)
        #expect(summary.averageWPM == 0)
    }

    @Test func theCurrentStreakCountsARunEndingToday() {
        var ledger = DictationStatsLedger()
        for offset in [-2, -1, 0] {
            ledger.record(words: 10, seconds: 5, day: key(offset))
        }
        #expect(
            DictationStatsCalculator.summary(of: ledger, today: fixedNow, calendar: utc)
                .currentStreakDays == 3
        )
    }

    /// A habit is intact on a morning nobody has spoken into anything yet, so a
    /// run ending yesterday still counts as current.
    @Test func theCurrentStreakCountsARunEndingYesterday() {
        var ledger = DictationStatsLedger()
        for offset in [-3, -2, -1] {
            ledger.record(words: 10, seconds: 5, day: key(offset))
        }
        #expect(
            DictationStatsCalculator.summary(of: ledger, today: fixedNow, calendar: utc)
                .currentStreakDays == 3
        )
    }

    @Test func awholeMissedDayEndsTheCurrentStreak() {
        var ledger = DictationStatsLedger()
        for offset in [-4, -3, -2] {
            ledger.record(words: 10, seconds: 5, day: key(offset))
        }
        let summary = DictationStatsCalculator.summary(of: ledger, today: fixedNow, calendar: utc)
        #expect(summary.currentStreakDays == 0)
        #expect(summary.longestStreakDays == 3)
    }

    @Test func theLongestStreakSurvivesPruning() {
        var ledger = DictationStatsLedger()
        let base = -(DictationStatsPolicy.dayRetentionDays + 10)
        for offset in base..<(base + 5) {
            ledger.record(words: 10, seconds: 5, day: key(offset))
        }
        #expect(ledger.longestStreakDays == 5)

        ledger.record(words: 10, seconds: 5, day: today)
        #expect(ledger.days.count == 1)
        #expect(
            DictationStatsCalculator.summary(of: ledger, today: fixedNow, calendar: utc)
                .longestStreakDays == 5
        )
    }

    // MARK: Heatmap

    @Test func theLastColumnHoldsTodayAndNothingLater() throws {
        let model = DictationStatsCalculator.heatmap(
            of: DictationStatsLedger(),
            today: fixedNow,
            calendar: utc,
            weeks: 5
        )
        #expect(model.columns.count == 5)
        #expect(model.columns.allSatisfy { $0.count == 7 })

        let lastColumn = try #require(model.columns.last)
        #expect(lastColumn.contains { $0.dayKey == today })
        // Everything up to and including today is in range; nothing after it is.
        for cell in model.columns.flatMap({ $0 }) {
            #expect(cell.isInRange == (cell.dayKey <= today))
        }
        // fixedNow is a Tuesday and this calendar starts its weeks on Sunday, so
        // the window's last column has four days the calendar has not reached.
        #expect(lastColumn.filter { !$0.isInRange }.count == 4)
    }

    @Test func theWindowStartsAWholeNumberOfWeeksBeforeTodaysWeek() throws {
        let model = DictationStatsCalculator.heatmap(
            of: DictationStatsLedger(),
            today: fixedNow,
            calendar: utc,
            weeks: 4
        )
        let firstKey = try #require(model.columns.first?.first?.dayKey)
        // Sunday-first: fixedNow (a Tuesday) sits in the week beginning two days
        // earlier, and the window opens three weeks before that.
        #expect(firstKey == key(-2 - 21))
        #expect(try #require(model.columns.last?.first?.dayKey) == key(-2))
    }

    @Test func mondayFirstCalendarsRotateBothRowsAndColumns() throws {
        let calendar = mondayFirst()
        let model = DictationStatsCalculator.heatmap(
            of: DictationStatsLedger(),
            today: fixedNow,
            calendar: calendar,
            weeks: 3
        )
        #expect(model.weekdaySymbols.first == calendar.veryShortWeekdaySymbols[1])
        #expect(model.weekdaySymbols.last == calendar.veryShortWeekdaySymbols[0])
        #expect(model.weekdaySymbols.count == 7)
        // fixedNow is a Tuesday, so a Monday-first week opens one day earlier.
        #expect(try #require(model.columns.last?.first?.dayKey) == key(-1))
    }

    @Test func sundayFirstCalendarsLeaveTheSymbolsAlone() {
        let model = DictationStatsCalculator.heatmap(
            of: DictationStatsLedger(),
            today: fixedNow,
            calendar: utc,
            weeks: 3
        )
        #expect(model.weekdaySymbols == utc.veryShortWeekdaySymbols)
    }

    /// Levels are quartiles of the window's busiest day, and any dictation at
    /// all reaches level 1 — a day the reader used the app must not read as a
    /// day they did not.
    @Test func levelsAreQuartilesOfTheBusiestDay() {
        #expect(DictationStatsCalculator.level(words: 0, maxWords: 400) == 0)
        #expect(DictationStatsCalculator.level(words: 1, maxWords: 400) == 1)
        #expect(DictationStatsCalculator.level(words: 100, maxWords: 400) == 1)
        #expect(DictationStatsCalculator.level(words: 101, maxWords: 400) == 2)
        #expect(DictationStatsCalculator.level(words: 200, maxWords: 400) == 2)
        #expect(DictationStatsCalculator.level(words: 300, maxWords: 400) == 3)
        #expect(DictationStatsCalculator.level(words: 400, maxWords: 400) == 4)
        // A lone day is its own maximum.
        #expect(DictationStatsCalculator.level(words: 7, maxWords: 7) == 4)
        #expect(DictationStatsCalculator.level(words: 5, maxWords: 0) == 0)
    }

    @Test func theSoleActiveDayReachesTheTopLevel() throws {
        var ledger = DictationStatsLedger()
        ledger.record(words: 12, seconds: 6, day: key(-3))
        let model = DictationStatsCalculator.heatmap(
            of: ledger,
            today: fixedNow,
            calendar: utc,
            weeks: 4
        )
        #expect(model.maxWords == 12)
        #expect(model.activeDaysInWindow == 1)
        let lit = try #require(model.columns.flatMap { $0 }.first { $0.dayKey == key(-3) })
        #expect(lit.level == 4)
        #expect(model.columns.flatMap { $0 }.filter { $0.level > 0 }.count == 1)
    }

    /// A day the window cannot reach contributes nothing to the ladder: a future
    /// square must not be able to scale the colours of the real ones.
    @Test func daysOutsideTheLedgerDoNotLightUp() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 900, seconds: 300, day: key(-400))
        let model = DictationStatsCalculator.heatmap(
            of: ledger,
            today: fixedNow,
            calendar: utc,
            weeks: 4
        )
        #expect(model.maxWords == 0)
        #expect(model.columns.flatMap { $0 }.allSatisfy { $0.level == 0 })
    }

    @Test func monthLabelsMarkOnlyTheColumnsThatChangeMonth() {
        let model = DictationStatsCalculator.heatmap(
            of: DictationStatsLedger(),
            today: fixedNow,
            calendar: utc,
            weeks: 5
        )
        // Columns open Oct 15, Oct 22, Oct 29, Nov 5, Nov 12 — one transition,
        // and column 0 is never labelled because its month began off-screen.
        #expect(model.monthLabels.count == 1)
        #expect(model.monthLabels.first?.column == 3)
        #expect(model.monthLabels.first?.label == utc.shortMonthSymbols[10])
        #expect(!model.monthLabels.contains { $0.column == 0 })
    }

    /// The month names a reader sees come from the *display* calendar's locale.
    /// A calendar with no locale resolves ICU's root fallback ("M11"), which is
    /// why the console resolves calendar, locale and time zone together.
    @Test func monthLabelsFollowTheCalendarsLocale() {
        var localized = utc
        localized.locale = Locale(identifier: "en_US_POSIX")
        let model = DictationStatsCalculator.heatmap(
            of: DictationStatsLedger(),
            today: fixedNow,
            calendar: localized,
            weeks: 5
        )
        #expect(model.monthLabels.first?.label == "Nov")
    }

    // MARK: Summary

    @Test func wordsPerMinuteNeedsMeasuredTime() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 120, seconds: 0, day: today)
        let summary = DictationStatsCalculator.summary(of: ledger, today: fixedNow, calendar: utc)
        #expect(summary.averageWPM == 0)
        // Words with no measured time still saved the whole typing cost.
        #expect(isClose(summary.timeSavedSeconds, 180))
    }

    @Test func wordsPerMinuteRoundsToTheNearestWord() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 36_127, seconds: 16_320, day: today)
        let summary = DictationStatsCalculator.summary(of: ledger, today: fixedNow, calendar: utc)
        #expect(summary.averageWPM == 133)
        #expect(isClose(summary.timeSavedSeconds, 37_870.5))
    }

    /// Dictation slower than the typing baseline saved no time; it did not cost
    /// the reader any.
    @Test func timeSavedIsFlooredAtZero() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 10, seconds: 600, day: today)
        let summary = DictationStatsCalculator.summary(of: ledger, today: fixedNow, calendar: utc)
        #expect(summary.timeSavedSeconds == 0)
        #expect(summary.averageWPM == 1)
    }

    /// The one-time backfill folds journal rows through the same `record`, so a
    /// ledger seeded from history must equal one grown a dictation at a time.
    @Test func foldingAHistoryMatchesRecordingItLive() {
        let rows: [(day: Int, words: Int, seconds: Double)] = [
            (-6, 40, 20), (-5, 15, 9), (-5, 60, 31), (-2, 90, 44), (0, 12, 7),
        ]
        var seeded = DictationStatsLedger()
        for row in rows {
            seeded.record(words: row.words, seconds: row.seconds, day: key(row.day))
        }

        var live = DictationStatsLedger()
        for row in rows {
            live.record(words: row.words, seconds: row.seconds, day: key(row.day))
        }

        #expect(seeded == live)
        #expect(seeded.totalSessions == 5)
        #expect(seeded.totalActiveDays == 4)
        #expect(seeded.totalWords == 217)
    }

    @Test func negativeInputsCannotReduceATotal() {
        var ledger = DictationStatsLedger()
        ledger.record(words: -5, seconds: -3, day: today)
        #expect(ledger.totalWords == 0)
        #expect(ledger.totalSeconds == 0)
        #expect(ledger.totalSessions == 1)
    }

    // MARK: Word count

    @Test func wordCountCountsContiguousNonWhitespaceRuns() {
        #expect(WordCount.count(in: "") == 0)
        #expect(WordCount.count(in: "   \n\t ") == 0)
        #expect(WordCount.count(in: "one") == 1)
        #expect(WordCount.count(in: "  leading and trailing  ") == 3)
        #expect(WordCount.count(in: "tabs\tand\nnewlines") == 3)
        #expect(WordCount.count(in: text(40)) == 40)
    }

    /// `RecentSession.wordCount` now delegates here; the journal's reported
    /// counts must not move.
    @Test func recentSessionWordCountDelegatesToTheSharedCount() {
        let body = "  Wire the offscreen renderer\tand capture.  "
        #expect(RecentSession(text: body).wordCount == WordCount.count(in: body))
        #expect(RecentSession(text: body).wordCount == 6)
    }

    // MARK: Day keys

    @Test func dayKeysAreIsoOrderedAndZeroPadded() {
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 7
        let date = utc.date(from: components)
        #expect(DictationStatsLedger.dayKey(for: date ?? fixedNow, calendar: utc) == "2025-03-07")
        #expect(DictationStatsLedger.dayKey(offsetting: "2025-03-01", byDays: -1) == "2025-02-28")
        #expect(DictationStatsLedger.dayKey(offsetting: "2024-02-28", byDays: 1) == "2024-02-29")
        #expect(DictationStatsLedger.dayKey(offsetting: "not-a-day", byDays: 1) == nil)
    }

    // MARK: Per-app tallies

    @Test func recordingWithAnAppFoldsItsOwnBucket() {
        var ledger = DictationStatsLedger()
        let ghostty = DictationAppIdentity(bundleId: "com.mitchellh.ghostty", name: "Ghostty")
        ledger.record(words: 30, seconds: 12, day: today, app: ghostty)
        ledger.record(words: 12, seconds: 8, day: today, app: ghostty)

        #expect(
            ledger.apps["com.mitchellh.ghostty"]
                == DictationAppStat(sessions: 2, words: 42, seconds: 20, name: "Ghostty", lastDay: today)
        )
        #expect(ledger.totalSessions == 2)
        #expect(ledger.days[today]?.sessions == 2)
    }

    @Test func distinctAppsGetDistinctBuckets() {
        var ledger = DictationStatsLedger()
        ledger.record(
            words: 10,
            seconds: 5,
            day: today,
            app: DictationAppIdentity(bundleId: "com.apple.TextEdit", name: "TextEdit")
        )
        ledger.record(
            words: 20,
            seconds: 6,
            day: today,
            app: DictationAppIdentity(bundleId: "com.apple.Terminal", name: "Terminal")
        )

        #expect(ledger.apps.count == 2)
        #expect(ledger.apps["com.apple.TextEdit"]?.words == 10)
        #expect(ledger.apps["com.apple.Terminal"]?.words == 20)
        #expect(ledger.totalWords == 30)
    }

    /// A dictation the app could not attribute still counts in the totals: the
    /// words were spoken. It just has no destination to rank.
    @Test func recordingWithoutAnAppLeavesTheAppsMapEmpty() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 25, seconds: 10, day: today)

        #expect(ledger.apps.isEmpty)
        #expect(ledger.totalSessions == 1)
        #expect(ledger.totalWords == 25)
    }

    @Test func negativeInputsCannotReduceAnAppTotal() {
        var ledger = DictationStatsLedger()
        let app = DictationAppIdentity(bundleId: "com.apple.TextEdit", name: "TextEdit")
        ledger.record(words: 10, seconds: 5, day: today, app: app)
        ledger.record(words: -5, seconds: -3, day: today, app: app)

        let bucket = ledger.apps["com.apple.TextEdit"]
        #expect(bucket?.sessions == 2)
        #expect(bucket?.words == 10)
        #expect(bucket?.seconds == 5)
    }

    /// A rename is the newer truth, and a fold that could not name the app must
    /// not erase one that could.
    @Test func theLastNameSeenWinsAndNilPreservesTheExistingOne() {
        var ledger = DictationStatsLedger()
        let bundleId = "com.example.editor"
        ledger.record(words: 5, seconds: 2, day: today, app: DictationAppIdentity(bundleId: bundleId))
        #expect(ledger.apps[bundleId]?.name == nil)

        ledger.record(
            words: 5,
            seconds: 2,
            day: today,
            app: DictationAppIdentity(bundleId: bundleId, name: "Editor")
        )
        #expect(ledger.apps[bundleId]?.name == "Editor")

        ledger.record(words: 5, seconds: 2, day: today, app: DictationAppIdentity(bundleId: bundleId))
        #expect(ledger.apps[bundleId]?.name == "Editor")

        ledger.record(
            words: 5,
            seconds: 2,
            day: today,
            app: DictationAppIdentity(bundleId: bundleId, name: "Editor Pro")
        )
        #expect(ledger.apps[bundleId]?.name == "Editor Pro")
    }

    /// The backfill folds chronologically, but an amended day can arrive after a
    /// later one; `lastDay` has to stay the latest day, not the last fold.
    @Test func lastDayTakesTheChronologicallyLaterKey() {
        var ledger = DictationStatsLedger()
        let app = DictationAppIdentity(bundleId: "com.apple.Safari", name: "Safari")
        ledger.record(words: 5, seconds: 2, day: key(-1), app: app)
        #expect(ledger.apps["com.apple.Safari"]?.lastDay == key(-1))

        ledger.record(words: 5, seconds: 2, day: key(-5), app: app)
        #expect(ledger.apps["com.apple.Safari"]?.lastDay == key(-1))

        ledger.record(words: 5, seconds: 2, day: today, app: app)
        #expect(ledger.apps["com.apple.Safari"]?.lastDay == today)
    }

    /// What the apps-only backfill depends on: the sessions it walks were
    /// already counted in the totals on disk, so seeding must not touch them.
    @Test func recordingAnAppAloneLeavesTotalsAndDaysUntouched() {
        var ledger = DictationStatsLedger()
        ledger.record(words: 40, seconds: 20, day: today)
        let totals = (ledger.totalSessions, ledger.totalWords, ledger.totalSeconds, ledger.totalActiveDays)
        let days = ledger.days

        ledger.recordApp(
            DictationAppIdentity(bundleId: "com.apple.TextEdit", name: "TextEdit"),
            words: 40,
            seconds: 20,
            day: today
        )

        #expect((ledger.totalSessions, ledger.totalWords, ledger.totalSeconds, ledger.totalActiveDays) == totals)
        #expect(ledger.days == days)
        #expect(ledger.apps["com.apple.TextEdit"]?.sessions == 1)
        #expect(ledger.longestStreakDays == 1)
    }

    @Test func perAppTalliesSurviveTheStoreRoundTrip() throws {
        let fixture = temporaryCoreTestFile(named: "dictation-activity.json")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = DictationStatsStore(url: fixture.url)

        var ledger = DictationStatsLedger()
        ledger.record(
            words: 42,
            seconds: 21,
            day: today,
            app: DictationAppIdentity(bundleId: "com.mitchellh.ghostty", name: "Ghostty")
        )
        try store.save(ledger)

        #expect(try store.load() == ledger)
        #expect(try store.load().apps["com.mitchellh.ghostty"]?.name == "Ghostty")
    }

    /// An apps-only ledger is not an empty one, so it must persist rather than
    /// delete its own file.
    @Test func aLedgerCarryingOnlyAppTalliesIsNotEmpty() throws {
        let fixture = temporaryCoreTestFile(named: "dictation-activity.json")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = DictationStatsStore(url: fixture.url)

        var ledger = DictationStatsLedger()
        ledger.recordApp(
            DictationAppIdentity(bundleId: "com.apple.TextEdit", name: "TextEdit"),
            words: 3,
            seconds: 1,
            day: today
        )
        try store.save(ledger)

        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try store.load().apps.count == 1)
    }

    @Test func aLedgerWrittenBeforePerAppTalliesDecodesAnEmptyMap() throws {
        let data = Data("{\"totalWords\": 12, \"totalSessions\": 3}".utf8)
        let ledger = try JSONDecoder().decode(DictationStatsLedger.self, from: data)

        #expect(ledger.apps.isEmpty)
        #expect(ledger.totalSessions == 3)
    }

    @Test func anAppStatWrittenWithMissingFieldsDecodesZeroes() throws {
        let data = Data("{\"apps\": {\"com.apple.TextEdit\": {\"sessions\": 2}}}".utf8)
        let ledger = try JSONDecoder().decode(DictationStatsLedger.self, from: data)
        let bucket = try #require(ledger.apps["com.apple.TextEdit"])

        #expect(bucket == DictationAppStat(sessions: 2, words: 0, seconds: 0, name: nil, lastDay: nil))
    }

    // MARK: Top apps

    @Test func topAppsRanksBySessionsThenWordsThenBundleId() {
        var ledger = DictationStatsLedger()
        ledger.apps = [
            "com.b.app": DictationAppStat(sessions: 4, words: 10, name: "B"),
            "com.a.app": DictationAppStat(sessions: 4, words: 10, name: "A"),
            "com.c.app": DictationAppStat(sessions: 4, words: 99, name: "C"),
            "com.d.app": DictationAppStat(sessions: 9, words: 1, name: "D"),
        ]

        let figures = DictationStatsCalculator.topApps(of: ledger, limit: 5)

        #expect(figures.map(\.bundleId) == ["com.d.app", "com.c.app", "com.a.app", "com.b.app"])
        #expect(figures.map(\.id) == figures.map(\.bundleId))
    }

    @Test func topAppsSharesAreRelativeToTheLeader() throws {
        var ledger = DictationStatsLedger()
        ledger.apps = [
            "com.apple.dt.Xcode": DictationAppStat(sessions: 64, words: 12_400, name: "Xcode"),
            "com.apple.Safari": DictationAppStat(sessions: 16, words: 3_000, name: "Safari"),
        ]

        let figures = DictationStatsCalculator.topApps(of: ledger, limit: 5)

        #expect(figures.count == 2)
        #expect(figures[0].share == 1)
        #expect(figures[1].share == 0.25)
        #expect(figures[0].name == "Xcode")
        #expect(figures[0].words == 12_400)
    }

    @Test func topAppsHonoursItsLimitAndAnEmptyLedgerRanksNothing() {
        var ledger = DictationStatsLedger()
        for index in 0..<8 {
            ledger.apps["com.example.app\(index)"] = DictationAppStat(sessions: index + 1, words: index)
        }

        #expect(DictationStatsCalculator.topApps(of: ledger, limit: 5).count == 5)
        #expect(
            DictationStatsCalculator.topApps(of: ledger, limit: 5).map(\.bundleId).first
                == "com.example.app7"
        )
        #expect(DictationStatsCalculator.topApps(of: ledger, limit: 0).isEmpty)
        #expect(DictationStatsCalculator.topApps(of: DictationStatsLedger(), limit: 5).isEmpty)
    }

    // MARK: Store

    @Test func theStoreRoundTripsAndAnEmptyLedgerRemovesTheFile() throws {
        let fixture = temporaryCoreTestFile(named: "dictation-activity.json")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = DictationStatsStore(url: fixture.url)

        #expect(try store.load() == DictationStatsLedger())

        var ledger = DictationStatsLedger()
        ledger.record(words: 42, seconds: 21, day: today)
        try store.save(ledger)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try store.load() == ledger)

        try store.save(DictationStatsLedger())
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test func absentFieldsDecodeAsZero() throws {
        let data = Data("{\"totalWords\": 12}".utf8)
        let ledger = try JSONDecoder().decode(DictationStatsLedger.self, from: data)
        #expect(ledger.totalWords == 12)
        #expect(ledger.totalSessions == 0)
        #expect(ledger.totalActiveDays == 0)
        #expect(ledger.days.isEmpty)
    }
}
