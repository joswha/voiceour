import Foundation
import VoiceCore

/// The lifetime dictation ledger: the per-utterance fold, the one-time backfill
/// from the transcript journal, the destructive clear, and the serialized write.
///
/// An extension on `DictationCoordinator` rather than a separate collaborator,
/// for the same reason `RecentSessionJournal` is: every member here publishes to
/// `dictationStats`, which stays on the main actor with the rest of the UI state.
///
/// Writes share the transcript journal's FIFO. Two durable files that are
/// written independently drift: a snapshot queued behind a clear could resurrect
/// counts the reader just erased, and a stats write that overtook a history
/// write would leave Home claiming dictations History had already dropped.
@MainActor
extension DictationCoordinator {
    /// Folds one journaled dictation into the ledger.
    ///
    /// Publish-only and synchronous: the durable write is enqueued by
    /// `recordDeliveredDictation`, its one caller, in the same main-actor turn
    /// that appended the transcript row. Awaiting a write in here would put a
    /// suspension between the two records and make each separately observable,
    /// which is exactly what this file exists to prevent.
    ///
    /// Measured off the row itself rather than re-derived from the pipeline's
    /// locals, so the ledger cannot describe a different dictation than the
    /// journal does: `wordCount` is the journal's own count, `stages.captureMs`
    /// is the measured microphone duration the backfill below reads too, and the
    /// day is the day the row is stamped rather than a second read of the clock.
    func foldDictationStats(for session: RecentSession, deliveredTo app: DictationAppIdentity?) {
        dictationStats.record(
            words: session.wordCount,
            seconds: Double(session.stages?.captureMs ?? 0) / 1000,
            day: DictationStatsLedger.dayKey(for: session.createdAt, calendar: runtime.calendar()),
            app: app
        )
    }

    /// Erases the lifetime counts. Paired with the transcript clear rather than
    /// offered separately: the reader asked for what this Mac remembers to be
    /// gone, and a tally of it is something this Mac remembers.
    @discardableResult
    public func clearDictationStats() async -> Bool {
        guard !isPreparingForTermination else { return false }
        dictationStats = DictationStatsLedger()
        return await enqueueDictationStatsSnapshot().value
    }

    /// Seeds the ledger from the transcripts already on disk, once, on the first
    /// launch that has no ledger file.
    ///
    /// `stages.captureMs` is the measured microphone duration. Rows recorded
    /// before that field existed contribute their words with zero seconds rather
    /// than an assumed speaking rate: an invented duration would move both the
    /// words-per-minute readout and the time-saved claim, and neither is worth
    /// guessing at.
    func backfillDictationStats() {
        guard !recentSessions.isEmpty else { return }
        let calendar = runtime.calendar()
        // `recentSessions` is newest-first, so this walks it backwards to fold
        // chronologically. `record` measures the whole run a day sits in, so the
        // streaks come out right either way; the order matters for retention,
        // which prunes relative to the last day folded.
        for session in recentSessions.reversed() {
            dictationStats.record(
                words: session.wordCount,
                seconds: Double(session.stages?.captureMs ?? 0) / 1000,
                day: DictationStatsLedger.dayKey(for: session.createdAt, calendar: calendar),
                app: session.appIdentity
            )
        }
        enqueueDictationStatsSnapshot()
    }

    /// Seeds only the per-app buckets, for an install whose ledger predates
    /// them. Totals and day buckets are left alone: they already counted these
    /// same sessions, and folding them twice would double every Home figure.
    func backfillAppStats() {
        guard !recentSessions.isEmpty else { return }
        let calendar = runtime.calendar()
        var folded = false
        for session in recentSessions.reversed() {
            guard let app = session.appIdentity else { continue }
            dictationStats.recordApp(
                app,
                words: session.wordCount,
                seconds: Double(session.stages?.captureMs ?? 0) / 1000,
                day: DictationStatsLedger.dayKey(for: session.createdAt, calendar: calendar)
            )
            folded = true
        }
        guard folded else { return }
        enqueueDictationStatsSnapshot()
    }

    /// Serializes the durable write behind the transcript journal's tail so the
    /// two files cannot be written out of order relative to each other.
    @discardableResult
    func enqueueDictationStatsSnapshot() -> Task<Bool, Never> {
        let snapshot = dictationStats
        let previous = recentSessionPersistenceTail
        let store = dictationStatsStore
        let next = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                try store.save(snapshot)
                return true
            } catch {
                return false
            }
        }
        recentSessionPersistenceTail = next
        Task { @MainActor [weak self] in
            guard await next.value == false, let self else { return }
            self.errorMessage = "Dictation stats could not be saved."
        }
        return next
    }
}

extension RecentSession {
    /// The delivery target this row records, or nil when it names no app —
    /// a row from before bundle ids were persisted, or one this ledger cannot
    /// attribute.
    var appIdentity: DictationAppIdentity? {
        guard let bundleId = outcome?.targetBundleId else { return nil }
        return DictationAppIdentity(bundleId: bundleId, name: outcome?.targetAppName)
    }
}
