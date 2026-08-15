import Foundation
import SwiftUI
import VoiceCore

/// Home dashboard — the console's landing "dictation instrument panel".
///
/// Every figure comes from `coordinator.insights`, the digest the journal
/// republishes on each change. Its lifetime half is counted by
/// `DictationStatsLedger`, which keeps counting after the transcript store
/// drops a session, so the all-time figures no longer plateau at the retention
/// cap; its two text-derived fields cover the kept transcripts and say so.
///
/// The pane lays those figures out as four shelves on one **twelve-column** measure
/// (`Content.grid`, clamped to the region), each shelf answering one question a
/// person actually asks of a dictation tool:
///
/// 1. TIME SAVED — a full-width hero cut into two equal halves by one vertical
///    rule on the card's midline. Left: the saved-time figure at the 64pt hero
///    face, plus the LISTENING badge while a capture runs, over the one sentence
///    that shows the figure's arithmetic. Right: the speed ratio at the 32pt
///    metric face over the YOU / TYPING gauges it is measured from, the second
///    of which the reader can correct.
/// 2. ALL TIME — one full-width strip whose four equal quarters carry the units
///    that name them ("108 words", "4 days in a row"), in the same grammar as
///    the Sessions TOTALS strip (RecentSessionMetricStrip.swift).
/// 3. The chart trio at 4 / 4 / 4 columns — WHEN YOU DICTATE, LAST 14 DAYS,
///    TOP APPS. This is the one shelf that needs the `BentoRow` column engine;
///    the strips above and below are single cards dividing their own measure,
///    so a strip's interior rules are card-local quarters, not grid columns.
/// 4. RECORDS — one full-width strip at the 20pt tile face: up to three
///    labelled personal bests, then a line quoting the longest dictation itself.
///
/// Absence renders as a quiet caption *inside* its card rather than a dropped
/// card, so the grid keeps its rhythm; only RECORDS cells are omitted outright
/// — there is no honest placeholder for a record that has not happened — and
/// the survivors re-divide the strip between them.
/// The chart components live in sibling files (HomeHourChart.swift,
/// HomeDayChart.swift, HomeDestinations.swift); interactions honor reduce-motion.
struct HomePane: View {
    var coordinator: DictationCoordinator

    private var a11y = A11y()

    /// No cached digest: `coordinator.insights` is the digest, republished by
    /// the journal whenever the ledger or the retained corpus changes. The
    /// cache this replaced keyed on the session id list, which cannot see the
    /// in-place amendment that attaches the destination app and the
    /// post-speech timing to the session just recorded — so TOP APPS and the
    /// time economy were always one dictation behind.

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Group {
            if coordinator.insights.dictationCount == 0 {
                // Keep first run on the populated grid's column and name the
                // one keystroke the whole app turns on.
                EmptyState(
                    glyph: "chart.bar.xaxis",
                    title: "No dictations yet",
                    body: "Your instrument panel lights up after the first dictation — "
                        + "time saved, how fast you speak, and your top apps."
                ) {
                    DictationHotkeyHint()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                HomeDashboard(
                    insights: coordinator.insights,
                    capture: capture,
                    typingWPM: coordinator.settings.typingSpeedWPM,
                    setTypingWPM: setTypingWPM
                )
            }
        }
        // Fourteen readouts replacing themselves in one frame is the most
        // abrupt change the surface can make, and it happens at the exact
        // moment the dashboard exists for.
        .animation(a11y.reduceMotion ? nil : VoiceourMotion.standard, value: coordinator.insights)
        .onAppear {
            // The streak and the fourteen-day window are relative to "now", so
            // a console left open across midnight re-windows on re-entry
            // rather than waiting for the next dictation.
            coordinator.refreshInsights()
        }
    }

    /// The single live signal the dashboard publishes in its own content region,
    /// so a capture is legible from the landing pane rather than only from the
    /// rail footer's status word.
    private var capture: String? {
        switch coordinator.state {
        case .recording:
            "LISTENING"
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .readyToInsert:
            "WORKING"
        default:
            nil
        }
    }

    /// The one value on this pane the reader can set. Home states a typing
    /// speed it has no way to measure, so the assumption is corrigible exactly
    /// where it is claimed.
    private func setTypingWPM(_ wpm: Int) {
        let clamped = DictationInsights.clamp(wpm)
        guard clamped != coordinator.settings.typingSpeedWPM else { return }
        coordinator.settings.typingSpeedWPM = clamped
        coordinator.saveSettings()
    }
}
