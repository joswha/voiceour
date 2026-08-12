import SwiftUI
import VoiceCore

struct HomeRecordsShelf: View {
    let insights: DictationInsights

    // MARK: Shelf 4 — RECORDS

    /// The bests as ONE strip at the tile face, below the tally they are drawn
    /// from rather than beside it: a record is a footnote to a running total,
    /// not a peer of it. The shelf disappears entirely when there is neither a
    /// record nor a transcript to quote.
    ///
    /// Two records are lifetime; the vocabulary count is not, and cannot be —
    /// counting distinct words needs the words, and only the retained
    /// transcripts still have them. That is the one window difference on the
    /// pane, so the cell is named for its window rather than left to look like
    /// the lifetime figures beside it.
    @ViewBuilder
    var body: some View {
        let cells = recordsCells
        let preview = insights.longestSessionPreview
        if !cells.isEmpty || preview != nil {
            ContentCard(eyebrow: "RECORDS") {
                VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.md) {
                    if !cells.isEmpty {
                        HomeMetricRow(cells: cells, scale: .tile, labels: true)
                    }

                    if let preview {
                        LongestDictationQuote(text: preview)
                    }
                }
            }
        }
    }

    /// Personal bests, labelled — a bare "181" is a record of nothing. An
    /// absent record is omitted rather than printed as a zero, and the
    /// survivors re-divide the strip instead of leaving a hole in it.
    ///
    /// Transcription latency is not a personal best: nobody dictated faster
    /// because the engine answered in 295 ms. Diagnostics owns the engine's
    /// timings, and this shelf now holds only things the *user* did.
    private var recordsCells: [MetricCell] {
        var cells: [MetricCell] = []
        if let words = insights.longestSessionWords {
            cells.append(
                MetricCell(
                    id: "LONGEST DICTATION",
                    parts: HomeFormat.countParts(words, unit: words == 1 ? "word" : "words")
                )
            )
        }
        if let peak = insights.peakSpokenWPM {
            cells.append(
                MetricCell(
                    id: "FASTEST SPOKEN",
                    parts: HomeFormat.countParts(Int(peak.rounded()), unit: "wpm")
                )
            )
        }
        if insights.uniqueWordCount > 0 {
            cells.append(
                MetricCell(
                    id: "DIFFERENT WORDS · KEPT",
                    parts: HomeFormat.countParts(insights.uniqueWordCount)
                )
            )
        }
        return cells
    }
}
