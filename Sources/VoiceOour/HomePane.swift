import Foundation
import SwiftUI
import VoiceCore

/// Home dashboard — the console's landing "dictation instrument panel".
///
/// Every figure is derived from `coordinator.recentSessions` (the count-capped
/// local store, never date-capped) via `DictationInsights`. The pane lays those
/// figures out as four shelves on one **twelve-column** measure
/// (`Content.grid`, clamped to the region), each shelf answering one question a
/// person actually asks of a dictation tool:
///
/// 1. TIME SAVED — a full-width hero cut into two equal halves by one vertical
///    rule on the card's midline. Left: the saved-time figure at the 64pt hero
///    face, plus the LISTENING badge while a capture runs, over the one sentence
///    that shows the figure's arithmetic. Right: the speed ratio at the 32pt
///    metric face over the YOU / TYPING gauges it is measured from.
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

    /// Snapshot of the derived digest. `DictationInsights.init` tokenizes every
    /// session's full transcript (O(total characters)), so recomputing it on
    /// every body eval — which fires on any coordinator publish — is wasteful.
    /// It is instead recomputed only when the session list itself changes
    /// (append/delete-only, so an id-list is a sound invalidation key). A nil
    /// snapshot is computed inline for the very first frame so the dashboard
    /// never flashes empty before `.onAppear` fills the cache.
    @State private var insights: DictationInsights?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Group {
            if coordinator.recentSessions.isEmpty {
                HomeEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                HomeDashboard(insights: insights ?? makeInsights(), capture: capture)
            }
        }
        .onAppear {
            if insights == nil {
                insights = makeInsights()
            }
        }
        .onChange(of: coordinator.recentSessions.map(\.id)) {
            // Fourteen readouts replacing themselves in one frame is the most
            // abrupt change the surface can make, and it happens at the exact
            // moment the dashboard exists for.
            if a11y.reduceMotion {
                insights = makeInsights()
            } else {
                withAnimation(VoiceOourMotion.standard) { insights = makeInsights() }
            }
        }
    }

    /// The single live signal the dashboard publishes in its own content region,
    /// so a capture is legible from the landing pane rather than only from the
    /// rail footer's status word.
    private var capture: String? {
        switch coordinator.state {
        case .recording:
            "LISTENING"
        case .checkingPermissions, .finalizingAudio, .transcribing, .cleaning, .refining, .readyToInsert:
            "WORKING"
        default:
            nil
        }
    }

    /// `DictationInsights` derives the 14-day trend and the dictation streak
    /// relative to "now". `RenderOverrides.renderNow` is the wall clock in
    /// production and a pinned instant under the offscreen UI harness, so a
    /// golden of this dashboard does not change at midnight.
    private func makeInsights() -> DictationInsights {
        DictationInsights(
            sessions: coordinator.recentSessions,
            calendar: RenderOverrides.calendar ?? Calendar.current,
            now: RenderOverrides.renderNow
        )
    }
}
