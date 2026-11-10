import AppKit
import SwiftUI
import VoiceCore
import VoiceMac

/// Home's measures, shared with ``ActivityHeatmap`` so the grid's first span
/// matches the column it lands in.
enum HomeLayout {
    /// The page's centred column. Wider and the stat tiles drift apart; the
    /// heat grid stops growing at its policy's 30 weeks well before this.
    static let column: CGFloat = 940
    /// Below this column width four stat tiles leave a figure too little room
    /// even at its smallest scale, so they pair up in two rows of two.
    static let fourUpMinimum: CGFloat = 760
    /// Gutter between stat-tile cards.
    static let tileGutter: CGFloat = 12
}

/// Home: what this Mac has dictated, all of it.
///
/// A page of figures rather than a page of controls: the hero line, then cards
/// of figures on the screen's ground — four stat tiles, the apps that receive
/// the most dictation, and the activity grid. A fresh install sees the
/// "Get started" checklist above them instead of the zero caption.
///
/// It navigates nowhere. Nothing here is a control over anything else, so the
/// tab takes no selection binding — the reader arrives, reads, and leaves by the
/// tab bar they came in on.
struct ConsoleHomeTab: View {
    var coordinator: DictationCoordinator

    /// The column's measured width, starting at its full width so a console at
    /// or above its default size draws its final layout on the first pass.
    @State private var columnWidth = HomeLayout.column
    /// Corrected by geometry below; starts at the measure a full-width column
    /// gives the grid, so the first pass draws the final span.
    @State private var gridWidth = ActivityHeatmap.Geometry.defaultWidth

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
        RenderOverrides.now ?? .now
    }

    /// Home ranks the five destinations that receive the most dictations. Five
    /// because the card is a ranking, not a directory: a reader learns where
    /// their speech goes from the leaders, and a sixth row only lengthens the
    /// page.
    private static let topAppLimit = 5

    var body: some View {
        // Resolved once per pass from the ledger, which is the figures' only
        // source: the first offscreen frame is already the final one, and the
        // card and the caption it supersedes read the same answer.
        let calendar = self.calendar
        let today = now
        let ledger = coordinator.dictationStats
        let summary = DictationStatsCalculator.summary(of: ledger, today: today, calendar: calendar)
        let topApps = DictationStatsCalculator.topApps(of: ledger, limit: Self.topAppLimit)
        let heatmap = DictationStatsCalculator.heatmap(
            of: ledger,
            today: today,
            calendar: calendar,
            weeks: ActivityHeatmap.Geometry.weeks(fitting: gridWidth)
        )
        let owesGuidance = coordinator.owesFirstRunGuidance

        return Kit.Screen {
            ScrollView {
                VStack(alignment: .leading, spacing: Kit.Metrics.sectionGap) {
                    hero(showsZeroCaption: !owesGuidance && summary.totalSessions == 0)
                    // Above the figures, because on the launch it appears the figures
                    // are four zeros and this is the whole page. It retires itself on
                    // the first delivered dictation, which is the same moment the
                    // figures start saying something, so the two never compete.
                    if owesGuidance {
                        ConsoleFirstRunCard(coordinator: coordinator)
                    }
                    statTiles(summary)
                    // Absent rather than empty on a Mac with nothing to rank: a
                    // card headed "Top apps" over no rows states nothing.
                    if !topApps.isEmpty {
                        topAppsCard(topApps)
                    }
                    activityCard(summary, heatmap: heatmap, calendar: calendar)
                }
                .frame(maxWidth: HomeLayout.column, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    columnWidth = $0
                }
                .padding(Kit.Metrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Hero

    private func hero(showsZeroCaption: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kit.Hero("voiceouurs, rejoice!")
                .accessibilityIdentifier("home.hero")

            // Only for a reader who has dictated before and has nothing to show
            // for it — a quarantined ledger, an erased history. A genuinely fresh
            // install gets the checklist instead, which names the same gesture in
            // full: two lines teaching one tap is one line too many. Home is the
            // tab the console opens on, so the zeroed page still owes the reader
            // how to start, in `ConsoleHotkeyHint`'s wording.
            if showsZeroCaption {
                Text("\(ConsoleHotkeyHint.sentence) — your first dictation lights this up.")
                    .roleStyle(.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.empty")
            }
        }
    }

    // MARK: Stat tiles

    /// Four tiles in one row, or two rows of two when the column is too narrow
    /// for four figures side by side. Each tile is its own card so a row reads
    /// as four separate facts rather than one table.
    @ViewBuilder
    private func statTiles(_ summary: DictationStatsSummary) -> some View {
        if columnWidth >= HomeLayout.fourUpMinimum {
            tileRow {
                timeTile(summary)
                wordsTile(summary)
                savedTile(summary)
                speedTile(summary)
            }
        } else {
            VStack(spacing: HomeLayout.tileGutter) {
                tileRow {
                    timeTile(summary)
                    wordsTile(summary)
                }
                tileRow {
                    savedTile(summary)
                    speedTile(summary)
                }
            }
        }
    }

    /// Equal-width cards of equal height: every card claims an even share of
    /// the row, and the row takes its tallest card's height so a label that
    /// wraps in one tile does not leave its neighbours short.
    private func tileRow<Tiles: View>(@ViewBuilder _ tiles: () -> Tiles) -> some View {
        HStack(alignment: .top, spacing: HomeLayout.tileGutter) {
            tiles()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tileCard(
        label: String,
        value: String,
        unit: String?,
        systemImage: String,
        identifier: String
    ) -> some View {
        Kit.Card {
            // The identifier goes on the tile, the one accessibility element,
            // not on the card around it.
            Kit.StatTile(label: label, value: value, unit: unit, systemImage: systemImage)
                .accessibilityIdentifier(identifier)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timeTile(_ summary: DictationStatsSummary) -> some View {
        tileCard(
            label: "Total dictation time",
            value: StatsFormatting.duration(seconds: summary.totalSeconds),
            unit: nil,
            systemImage: "clock.fill",
            identifier: "home.tile.time"
        )
    }

    private func wordsTile(_ summary: DictationStatsSummary) -> some View {
        tileCard(
            label: "Words dictated",
            value: StatsFormatting.compactCount(summary.totalWords),
            unit: StatsFormatting.noun("word", count: summary.totalWords),
            systemImage: "mic.fill",
            identifier: "home.tile.words"
        )
    }

    private func savedTile(_ summary: DictationStatsSummary) -> some View {
        tileCard(
            label: "Time saved vs typing at \(DictationStatsPolicy.assumedTypingWordsPerMinute) wpm",
            value: StatsFormatting.duration(seconds: summary.timeSavedSeconds),
            unit: nil,
            systemImage: "hourglass",
            identifier: "home.tile.saved"
        )
    }

    private func speedTile(_ summary: DictationStatsSummary) -> some View {
        tileCard(
            label: "Average speaking speed",
            value: String(summary.averageWPM),
            unit: "wpm",
            systemImage: "bolt.fill",
            identifier: "home.tile.wpm"
        )
    }

    // MARK: Top apps

    private func topAppsCard(_ figures: [DictationAppFigure]) -> some View {
        Kit.Card {
            VStack(alignment: .leading, spacing: 4) {
                Kit.SectionHeader("Top apps") { EmptyView() }
                    .accessibilityIdentifier("home.apps.title")

                ForEach(figures) { figure in
                    appRow(figure)
                }
            }
            // No identifier on the stack: an identifier on a container replaces
            // the one on every element inside it, which would cost the heading
            // its own id and give all five rows the same one. The rows are
            // addressed by label, exactly as the Journal's are.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One app's rank: its icon, its name over its share of all dictations, and
    /// its counts. One accessibility element, named by the app and valued by the
    /// full counts, because read as parts VoiceOver would stop five times for one
    /// fact.
    private func appRow(_ figure: DictationAppFigure) -> some View {
        let identity = AppIdentity.resolve(bundleId: figure.bundleId, persistedName: figure.name)
        return Kit.MeterRow(
            title: identity.label,
            fraction: figure.share,
            value: String(figure.sessions),
            caption: "\(StatsFormatting.noun("dictation", count: figure.sessions)) · "
                + "\(StatsFormatting.compactCount(figure.words)) \(StatsFormatting.noun("word", count: figure.words))",
            accessibilityValue: "\(figure.sessions) \(StatsFormatting.noun("dictation", count: figure.sessions)), "
                + "\(figure.words) \(StatsFormatting.noun("word", count: figure.words))"
        ) {
            Kit.AppIcon(name: identity.label, icon: identity.icon, size: 32)
        }
    }

    // MARK: Activity

    private func activityCard(
        _ summary: DictationStatsSummary,
        heatmap: HeatmapModel,
        calendar: Calendar
    ) -> some View {
        Kit.Card {
            VStack(alignment: .leading, spacing: 16) {
                Kit.SectionHeader("Activity") { EmptyView() }
                    .accessibilityIdentifier("home.activity.title")

                HStack(alignment: .top, spacing: 32) {
                    Kit.Figure(
                        value: String(summary.activeDays),
                        label: "Active days"
                    )
                    .accessibilityIdentifier("home.streak.active")

                    Kit.Figure(
                        value: StatsFormatting.dayLabel(summary.currentStreakDays),
                        label: "Current streak"
                    )
                    .accessibilityIdentifier("home.streak.current")

                    Kit.Figure(
                        value: StatsFormatting.dayLabel(summary.longestStreakDays),
                        label: "Longest streak"
                    )
                    .accessibilityIdentifier("home.streak.longest")
                }

                ActivityHeatmap(model: heatmap, calendar: calendar)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Measured, not laid out: the grid's span depends on the width
                    // it is given, and a `GeometryReader` in the content would
                    // claim all of it.
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        gridWidth = $0
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Home's "Get started" checklist: the three things a fresh install cannot
/// learn from a menu-bar glyph, and nothing else.
///
/// A reader cannot otherwise learn the gesture, see that a 1.26 GB model is
/// downloading, or tell which permissions matter. Those are the three rows.
/// It is not a settings pane and not a tutorial: every state it names is
/// already reported on Settings, and this is a temporary readout of the same
/// `ConsoleReadiness` values while they are the only news on the page. A row's
/// circle fills when its readout is healthy, which the app detects; nothing
/// here is ticked by hand.
///
/// It retires on the first delivered dictation (see
/// `DictationCoordinator.completeFirstRun()`), so it is never dismissed, never
/// stepped through, and owns no state a reader has to clear.
struct ConsoleFirstRunCard: View {
    var coordinator: DictationCoordinator

    /// Real TCC state in production; the harness pins a fixed snapshot through the
    /// same seam the Settings tab reads, so a golden never encodes this Mac's
    /// privacy grants.
    private let permissions: PermissionsChecking = RenderOverrides.permissions ?? SystemPermissions()
    @Environment(\.theme) private var theme

    @State private var microphone: PermissionState = .notDetermined
    @State private var synthPaste: PermissionState = .notDetermined

    /// Rows are at least this tall, so the checklist keeps one rhythm whether a
    /// row carries a remediation button or not.
    private static let rowMinHeight: CGFloat = 44
    /// The download meter stops here so a wide card does not stretch a
    /// progress bar into a rule.
    private static let meterMaxWidth: CGFloat = 320

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        Kit.Card {
            VStack(alignment: .leading, spacing: 4) {
                Kit.SectionHeader("Get started") { EmptyView() }

                // The instruction itself, kept as a header so VoiceOver's
                // heading navigation lands on what to do, not only on the title.
                Text(ConsoleHotkeyHint.fullGesture)
                    .roleStyle(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.first-run.gesture")
                    .padding(.bottom, 8)

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
                // row is caution at worst and never critical.
                row(
                    "Accessibility — optional",
                    ConsoleReadiness.insertion(synthPaste),
                    identifier: "home.first-run.accessibility"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// One step: whether it is done, what it is about, the sentence that
    /// explains it, the word for where it stands, and the one thing the reader
    /// can do about it.
    ///
    /// The text column has layout priority and the trailing pill and button
    /// keep their size, so a long sentence wraps beside them instead of the
    /// title breaking per character.
    private func row(_ title: String, _ readout: ConsoleReadout, identifier: String) -> some View {
        let isDone = readout.severity == .ok
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            // The pill carries the state in words; the circle repeats it as a
            // shape, so it is silent to VoiceOver.
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isDone ? theme.success.text : theme.text3)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .roleStyle(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)

                Text(readout.detail)
                    .roleStyle(.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).detail")

                if let progress = readout.progress {
                    downloadMeter(progress)
                        .accessibilityIdentifier("\(identifier).progress")
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Kit.Pill(
                    Kit.Pill.sentence(readout.label),
                    tone: Kit.Pill.Tone(readout.severity),
                    size: .regular
                )
                .accessibilityIdentifier(identifier)

                if let remediation = readout.remediation?.identified("\(identifier).action") {
                    Kit.Button(remediation.title, prominence: .secondary, action: remediation.perform)
                        // The closure form replaces the label the kit button derives
                        // from its title, whatever order the modifiers resolve in.
                        .accessibilityLabel { _ in Text(remediation.accessibilityLabel) }
                        .accessibilityIdentifier(remediation.identifier)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 6)
        .frame(minHeight: Self.rowMinHeight, alignment: .leading)
    }

    /// The model download: `Kit.Meter` names what is downloading and how far along it
    /// is; the sentence beside it states the bytes.
    private func downloadMeter(_ progress: Double) -> some View {
        Kit.Meter(fraction: progress, style: .download)
            .frame(maxWidth: Self.meterMaxWidth, alignment: .leading)
    }

    private func refreshPermissions() {
        microphone = permissions.microphone()
        synthPaste = permissions.synthPaste()
    }
}
