import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

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

    /// Home ranks the five destinations that receive the most dictations. Five
    /// because the island is a ranking, not a directory: a reader learns where
    /// their speech goes from the leaders, and a sixth row only lengthens the
    /// page.
    private var topApps: [DictationAppFigure] {
        DictationStatsCalculator.topApps(of: coordinator.dictationStats, limit: 5)
    }

    /// Whether this install still owes its reader the first-run card. Read once
    /// per body so the card and the caption it supersedes cannot both appear.
    private var owesGuidance: Bool {
        coordinator.owesFirstRunGuidance
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xl) {
                hero
                // Above the figures, because on the launch it appears the figures
                // are four zeros and this is the whole page. It retires itself on
                // the first delivered dictation, which is the same moment the
                // figures start saying something, so the two never compete.
                if owesGuidance {
                    ConsoleFirstRunCard(coordinator: coordinator)
                }
                statsIsland(summary)
                // Absent rather than empty on a Mac with nothing to rank: an
                // island headed "Top apps" over no rows states nothing.
                if !topApps.isEmpty {
                    topAppsIsland(topApps)
                }
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
            Text("voiceouurs, rejoice!")
                .roleStyle(.heroMetric)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.hero")

            // Only for a reader who has dictated before and has nothing to show
            // for it — a quarantined ledger, an erased history. A genuinely fresh
            // install gets the card above instead, which names the same gesture in
            // full: two lines teaching one tap is one line too many.
            if !owesGuidance, summary.totalSessions == 0 {
                // Home is the tab the console opens on, so a reader who has dictated
                // nothing lands here rather than on History, whose own empty state also
                // names the gesture. `ConsoleHotkeyHint`'s wording, kept as one caption
                // line in Home's voice: this page is figures, and how to start is the
                // one thing a zeroed page still owes the reader.
                Text("\(ConsoleHotkeyHint.sentence) — your first session lights this up.")
                    .roleStyle(.caption)
                    .foregroundStyle(a11y.textMid)
                    .accessibilityIdentifier("home.empty")
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

    private func topAppsIsland(_ figures: [DictationAppFigure]) -> some View {
        HomeIsland {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
                Text("Top apps")
                    .roleStyle(.label)
                    .foregroundStyle(a11y.textMid)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.apps.title")

                ForEach(figures) { figure in
                    HomeAppRow(figure: figure)
                }
            }
            // No identifier on the stack: an identifier on a container replaces
            // the one on every element inside it, which cost the heading its own
            // id and gave all five rows the same one. The rows are addressed by
            // label, exactly as History's are.
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

                ActivityHeatmap(model: heatmap, calendar: calendar)
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

/// Home's first-run card: the three things a fresh install cannot learn from a
/// menu-bar glyph, and nothing else.
///
/// It exists because the app's whole first-run surface used to be a 👽 in the menu
/// bar. A reader could not learn the gesture, could not see that a 1.26 GB model
/// was downloading, and could not tell which permissions mattered. Those are the
/// three rows. It is not a settings pane and not a tutorial: every state it names
/// is already reported on Settings, and this is a temporary readout of the same
/// values while they are the only news on the page.
///
/// It retires on the first delivered dictation (see
/// `DictationCoordinator.completeFirstRun()`), so it is never dismissed, never
/// stepped through, and owns no state a reader has to clear.
///
/// The vocabulary is the island's, not the native window's: a `HomeIsland` is
/// fixed-dark in both system appearances, so its marks are ``StatusChip`` on the
/// app palette rather than ``ConsoleStateMark`` on system semantic colours. The
/// remediation button stays a stock `Button` — it is the same control Settings
/// offers, pointed at the same pane, and a control is entitled to its own chrome.
struct ConsoleFirstRunCard: View {
    var coordinator: DictationCoordinator

    /// Real TCC state in production; the harness pins a fixed snapshot through the
    /// same seam the Settings tab reads, so a golden never encodes this Mac's
    /// privacy grants.
    private let permissions: PermissionsChecking = RenderOverrides.permissions ?? SystemPermissions()
    private var a11y = A11y()

    @State private var microphone: PermissionState = .notDetermined
    @State private var synthPaste: PermissionState = .notDetermined

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        HomeIsland {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.lg) {
                // The headline is the instruction. A card teaching one gesture does
                // not also need a heading announcing that it is going to.
                Text(ConsoleHotkeyHint.fullGesture)
                    .roleStyle(.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.first-run.gesture")

                VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                    row(
                        "Speech model",
                        ConsoleReadiness.backend(coordinator),
                        identifier: "home.first-run.model"
                    )
                    // Required, and requested contextually: nothing prompts for the
                    // microphone until the first dictation actually needs it.
                    row(
                        "Microphone — required",
                        ConsoleReadiness.microphone(coordinator, microphone),
                        identifier: "home.first-run.microphone"
                    )
                    // Optional, and the sentence says what it buys: with the grant a
                    // transcript is pasted, without it the transcript is on the
                    // clipboard. Missing trust is a documented degradation, so this
                    // row is amber at worst and never crimson.
                    row(
                        "Accessibility — optional",
                        ConsoleReadiness.insertion(synthPaste),
                        identifier: "home.first-run.accessibility"
                    )
                }
            }
        }
        .onAppear {
            // The same probe the Settings tab and the menu fire, de-duplicated by
            // the coordinator's own TTL. The acquisition repoll chain it starts is
            // what keeps the percentage moving while the reader watches it.
            coordinator.refreshBackendHealth()
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Returning from System Settings is this card's most important state
            // change, exactly as it is on the Settings tab.
            refreshPermissions()
        }
    }

    /// One state: what it is about, the word for where it stands, the sentence
    /// that explains it, and the one thing the reader can do about it.
    private func row(_ label: String, _ readout: ConsoleReadout, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
            HStack(spacing: VoiceourMetrics.Space.sm) {
                Text(label)
                    .roleStyle(.label)

                StatusChip(label: readout.label, mode: StatusChip.Mode(readout.severity))
                    .accessibilityIdentifier(identifier)

                if let remediation = readout.remediation?.identified("\(identifier).action") {
                    Button(remediation.title, action: remediation.perform)
                        .accessibilityLabel(remediation.accessibilityLabel)
                        .accessibilityIdentifier(remediation.identifier)
                }
            }

            if let progress = readout.progress {
                MeterBar(fraction: progress, style: .download(ground: .painted))
                    .accessibilityIdentifier("\(identifier).progress")
            }

            Text(readout.detail)
                .roleStyle(.caption)
                .foregroundStyle(a11y.textMid)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).detail")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshPermissions() {
        microphone = permissions.microphone()
        synthPaste = permissions.synthPaste()
    }
}
