import SwiftUI

// MARK: - Empty state

/// First run, on the shared `EmptyState` (EmptyState.swift) so the glyph,
/// title and body sit on the same baseline here as in Sessions and Glossary.
/// Left-flush on the same column the populated grid starts from, and it names
/// the one keystroke the whole app turns on — a screen that describes the
/// reward without saying how to earn it is not an onboarding screen.
struct HomeEmptyState: View {
    var body: some View {
        EmptyState(
            glyph: "chart.bar.xaxis",
            title: "No dictations yet",
            body: "Your instrument panel lights up after the first dictation — "
                + "time saved, how fast you speak, and your top apps."
        ) {
            HStack(spacing: VoiceOourMetrics.Space.xs) {
                Text("HOLD")
                    .roleStyle(.micro)
                KeyCap("Fn")
                Text("or")
                    .roleStyle(.caption)
                KeyCap("Globe")
                Text("TO DICTATE")
                    .roleStyle(.micro)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hold Fn or Globe to dictate")
        }
    }
}
