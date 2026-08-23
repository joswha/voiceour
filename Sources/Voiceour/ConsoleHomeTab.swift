import SwiftUI
import VoiceCore

/// Home: what this Mac has dictated, all of it.
///
/// The console's one non-`Form` tab. Every other tab is a list of settings and
/// readouts, which is exactly what `Form` is for; this one is a page of figures,
/// and a grouped form would render four section plates around four numbers.
///
/// It navigates nowhere. Nothing here is a control over anything else, so the
/// tab takes no selection binding — the reader arrives, reads, and leaves by the
/// tab bar they came in on.
struct ConsoleHomeTab: View {
    var coordinator: DictationCoordinator

    @State private var isShowingPrivacyDetail = false
    /// Corrected by geometry below; starts at the measure a console at or above
    /// its intended width gives the grid, so the first pass draws the final span.
    @State private var gridWidth = ActivityHeatmap.Geometry.defaultWidth

    private var a11y = A11y()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: Derived figures

    /// All three Foundation seams resolved together, the way
    /// `RenderFormatters.dateFormatter()` does. Missing one bakes this Mac's
    /// region into a committed golden: the calendar decides which local day a
    /// dictation counts as, and the locale decides both the month names under
    /// the grid and which weekday its rows start on.
    private var calendar: Calendar {
        var calendar = RenderOverrides.calendar ?? Calendar.current
        calendar.locale = RenderOverrides.locale ?? Locale.current
        calendar.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        return calendar
    }

    private var now: Date {
        RenderOverrides.now ?? Date()
    }

    private var summary: DictationStatsSummary {
        DictationStatsCalculator.summary(
            of: coordinator.dictationStats,
            today: now,
            calendar: calendar
        )
    }

    private var heatmap: HeatmapModel {
        DictationStatsCalculator.heatmap(
            of: coordinator.dictationStats,
            today: now,
            calendar: calendar,
            weeks: ActivityHeatmap.Geometry.weeks(fitting: gridWidth)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xl) {
                hero
                statsIsland(summary)
                activityIsland(summary)
            }
            .frame(maxWidth: VoiceourMetrics.Content.table, alignment: .leading)
            .padding(VoiceourMetrics.Space.xl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background {
            HomeDotGrid()
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.sm) {
            Text("Speak, don't type")
                .roleStyle(.heroMetric)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.hero")

            if summary.totalSessions == 0 {
                Text("Dictate once to light this up.")
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
                    .accessibilityIdentifier("home.empty")
            }

            privacyDisclosure
        }
    }

    /// The privacy claim, and the sentence behind it.
    ///
    /// Inline rather than a popover: the offscreen harness's window is
    /// `.prohibited` and can never order a second window front, so a popover
    /// would be a claim about this app's privacy that no gate can read.
    private var privacyDisclosure: some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            Button {
                withAnimation(a11y.reduceMotion ? nil : VoiceourMotion.quick) {
                    isShowingPrivacyDetail.toggle()
                }
            } label: {
                HStack(spacing: VoiceourMetrics.Space.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: VoiceourMetrics.Icon.mark, weight: .semibold))
                        .foregroundStyle(VoiceourPalette.Alien.bloom)
                        .accessibilityHidden(true)
                    Text("Your data stays private.")
                        .roleStyle(.caption)
                        .foregroundStyle(a11y.textMid)
                        .underline(pattern: .dot)
                }
                .frame(minHeight: VoiceourMetrics.Control.small, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your data stays private")
            .accessibilityValue(isShowingPrivacyDetail ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("home.privacy.toggle")

            if isShowingPrivacyDetail {
                Text(
                    "Stats are computed on this Mac from your local dictation journal. "
                        + "Nothing ever leaves your machine."
                )
                .roleStyle(.caption)
                .foregroundStyle(a11y.textMid)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home.privacy.detail")
            }
        }
    }

    // MARK: Islands

    private func statsIsland(_ summary: DictationStatsSummary) -> some View {
        HomeIsland {
            Grid(
                alignment: .leading,
                horizontalSpacing: VoiceourMetrics.Space.xl,
                verticalSpacing: VoiceourMetrics.Space.xl
            ) {
                GridRow {
                    HomeStatTile(
                        icon: "clock.fill",
                        value: StatsFormatting.duration(seconds: summary.totalSeconds),
                        unit: nil,
                        caption: "Total dictation time"
                    )
                    .accessibilityIdentifier("home.tile.time")

                    HomeStatTile(
                        icon: "mic.fill",
                        value: StatsFormatting.compactCount(summary.totalWords),
                        unit: "words",
                        caption: "Words dictated"
                    )
                    .accessibilityIdentifier("home.tile.words")
                }
                GridRow {
                    HomeStatTile(
                        icon: "hourglass",
                        value: StatsFormatting.duration(seconds: summary.timeSavedSeconds),
                        unit: nil,
                        caption:
                            "Time saved vs typing at "
                            + "\(DictationStatsPolicy.assumedTypingWordsPerMinute) wpm"
                    )
                    .accessibilityIdentifier("home.tile.saved")

                    HomeStatTile(
                        icon: "bolt.fill",
                        value: String(summary.averageWPM),
                        unit: "wpm",
                        caption: "Average speaking speed"
                    )
                    .accessibilityIdentifier("home.tile.wpm")
                }
            }
        }
    }

    private func activityIsland(_ summary: DictationStatsSummary) -> some View {
        HomeIsland {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xl) {
                HStack(alignment: .top, spacing: VoiceourMetrics.Space.xl) {
                    HomeStreakStat(
                        value: String(summary.activeDays),
                        label: "Active days"
                    )
                    .accessibilityIdentifier("home.streak.active")

                    HomeStreakStat(
                        value: StatsFormatting.dayLabel(summary.currentStreakDays),
                        label: "Current streak"
                    )
                    .accessibilityIdentifier("home.streak.current")

                    HomeStreakStat(
                        value: StatsFormatting.dayLabel(summary.longestStreakDays),
                        label: "Longest streak"
                    )
                    .accessibilityIdentifier("home.streak.longest")
                }

                ActivityHeatmap(model: heatmap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // Measured, not laid out: the grid's span depends on the
                        // width it is given, and a `GeometryReader` in the
                        // content would claim all of it.
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { gridWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { gridWidth = proxy.size.width }
                        }
                    }
            }
        }
    }
}
